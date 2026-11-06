import AVFoundation
import AppKit
import Combine
import Foundation
import os

/// MainActor owns route presentation. Each instance owns its notification
/// registrations and exact reset/engine handles; shutdown never closes a shared engine.
@MainActor
public final class AudioDeviceRouteMonitor: ObservableObject {
    public static let shared = AudioDeviceRouteMonitor()

    @Published public private(set) var currentInputDeviceName = "Default Input"
    @Published public private(set) var currentInputDeviceID = "default"
    @Published public private(set) var lastRouteChangeAt = Date()
    @Published public private(set) var routeChangeReason = "Initialized"
    @Published public private(set) var isRecoveringAudioRoute = false

    private let dependencies: AudioRouteMonitorDependencies
    private let registrations: AudioRouteObserverRegistrations
    private let work = AudioRouteMonitorWork()
    var ownedRecoveryTasksForTesting: [Task<Void, Never>] { work.tasks }
    var hasOwnedRecoveryWork: Bool { !work.tasks.isEmpty }
    var engineRecoveryState: String { dependencies.recoveryState() }

    private convenience init() { self.init(dependencies: .native()) }

    init(dependencies: AudioRouteMonitorDependencies) {
        self.dependencies = dependencies
        registrations = AudioRouteObserverRegistrations(center: dependencies.center)
        setupObservers()
        refreshInputDevice()
    }

    deinit {
        registrations.close()
        work.closeAndCancel()
    }

    private func setupObservers() {
        guard dependencies.observeExternalNotifications else { return }
        registrations.add(dependencies.observeEngineConfiguration(dependencies.center) { [weak self] in
            // Native configuration notifications are forwarded to OperationQueue.main.
            // Recovery schedules work; this callback never deallocates the engine.
            MainActor.assumeIsolated {
                self?.handleRouteChange(reason: "AVAudioEngine Configuration Changed")
            }
        })
        registrations.add(dependencies.center.addObserver(forName: .AVCaptureDeviceWasConnected,
            object: nil, queue: .main) { [weak self] notification in
            let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Device"
            MainActor.assumeIsolated { self?.handleRouteChange(reason: "Audio device connected: \(name)") }
        })
        registrations.add(dependencies.center.addObserver(forName: .AVCaptureDeviceWasDisconnected,
            object: nil, queue: .main) { [weak self] notification in
            let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Device"
            MainActor.assumeIsolated { self?.handleRouteChange(reason: "Audio device disconnected: \(name)") }
        })
        registrations.add(dependencies.center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputDevice() }
        })
    }

    /// Identity changes before cancellation. A retiring worker removes only
    /// its own handle; it can never reset a later route's presentation.
    public func handleRouteChange(reason: String) {
        guard let id = work.begin() else { return }
        work.cancelRetiring()
        lastRouteChangeAt = Date()
        routeChangeReason = reason
        isRecoveringAudioRoute = true
        refreshInputDevice()
        guard work.isCurrent(id) else { return }
        let engine = dependencies.requestRecovery(reason)
        let delay = dependencies.delay, work = self.work
        let worker = Task { @MainActor [weak self] in
            defer { work.finish(id) }
            var delayFailure: Error?
            do {
                try await delay.sleep(nanoseconds: 1_200_000_000)
            } catch { delayFailure = error }
            // Preserve the native exit boundary even if cancellation invalidated
            // display admission. The exact handle cannot stop a later engine job.
            await engine?.value
            guard !Task.isCancelled, work.isCurrent(id), let self else { return }
            if delayFailure != nil { self.routeChangeReason = "Audio route recovery delay failed." }
            self.isRecoveringAudioRoute = false
        }
        work.register(id, reset: worker, engine: engine)
    }

    public func refreshInputDevice() {
        guard !work.isClosed else { return }
        let input = dependencies.inputDevice()
        currentInputDeviceName = input.name
        currentInputDeviceID = input.id
    }

    /// Synchronous admission is separate from awaited resource exit.
    func closeAdmission() {
        registrations.close()
        work.closeAndCancel()
    }

    func shutdown() async {
        closeAdmission()
        let captured = work.tasks
        for task in captured { await task.value }
        isRecoveringAudioRoute = false
    }
}

@MainActor
struct AudioRouteMonitorDependencies {
    let inputDevice: @MainActor () -> (name: String, id: String)
    let requestRecovery: @MainActor (String) -> Task<Void, Never>?
    let recoveryState: @MainActor () -> String
    let observeEngineConfiguration: @MainActor (NotificationCenter, @escaping @Sendable () -> Void) -> any NSObjectProtocol
    let delay: any DelayProvider
    let center: NotificationCenter
    let observeExternalNotifications: Bool

    static func native() -> Self {
        .init(inputDevice: {
            guard let device = AVCaptureDevice.default(for: .audio) else { return ("Default Input", "default") }
            return (device.localizedName, device.uniqueID)
        }, requestRecovery: { AudioEngineManager.shared.restartForRouteChange(reason: $0) },
            recoveryState: { AudioEngineManager.shared.audioRecoveryState },
            observeEngineConfiguration: { center, body in
                AudioEngineManager.shared.addConfigurationObserver(in: center, body)
            }, delay: RealDelayProvider(), center: .default,
            observeExternalNotifications: !isRunningUnderTestOrAutomation())
    }
}

/// The SDK lock exclusively owns opaque Foundation tokens. They never cross an
/// await or escape as mutable state. Removing them is synchronous and idempotent.
private final class AudioRouteObserverRegistrations: Sendable {
    private struct State { var tokens: [any NSObjectProtocol] = []; var closed = false }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let center: NotificationCenter
    init(center: NotificationCenter) { self.center = center }
    func add(_ token: any NSObjectProtocol) {
        let removeNow = state.withLockUnchecked { value in
            guard !value.closed else { return true }
            value.tokens.append(token)
            return false
        }
        if removeNow { center.removeObserver(token) }
    }
    func close() {
        let tokens = state.withLockUnchecked { value in
            value.closed = true
            let captured = value.tokens
            value.tokens.removeAll()
            return captured
        }
        for token in tokens { center.removeObserver(token) }
    }
}

/// Sole validity and handle authority, also safe in synchronous deinit. Task
/// cancellation occurs outside the short lock because handlers may reenter it.
private final class AudioRouteMonitorWork: Sendable {
    private struct Entry: Sendable { let reset: Task<Void, Never>; let engine: Task<Void, Never>? }
    private struct State: Sendable {
        var current: UUID?
        var closed = false
        var entries: [UUID: Entry] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isClosed: Bool { state.withLock { $0.closed } }
    var tasks: [Task<Void, Never>] {
        state.withLock { $0.entries.values.flatMap { [$0.reset, $0.engine].compactMap { $0 } } }
    }
    func begin() -> UUID? {
        state.withLock {
            guard !$0.closed else { return nil }
            let id = UUID(); $0.current = id; return id
        }
    }
    func isCurrent(_ id: UUID) -> Bool { state.withLock { !$0.closed && $0.current == id } }
    func register(_ id: UUID, reset: Task<Void, Never>, engine: Task<Void, Never>?) {
        let cancelled = state.withLock {
            $0.entries[id] = Entry(reset: reset, engine: engine)
            return $0.closed || $0.current != id
        }
        if cancelled { reset.cancel(); engine?.cancel() }
    }
    func finish(_ id: UUID) {
        state.withLock {
            $0.entries[id] = nil
            if $0.current == id { $0.current = nil }
        }
    }
    func cancelRetiring() { tasks.forEach { $0.cancel() } }
    func closeAndCancel() {
        state.withLock { $0.closed = true; $0.current = nil }
        cancelRetiring()
    }
}
