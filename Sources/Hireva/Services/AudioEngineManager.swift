import AVFoundation
import Foundation
import os

/// A class-only protocol that listeners must conform to to receive audio buffers and route change notifications.
public protocol AudioEngineBufferDelegate: AnyObject {
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    )

    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    )

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    )
}

/// Provide default empty implementations so existing delegates are not forced to implement them all.
public extension AudioEngineBufferDelegate {
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {}

    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    ) {}

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {}
}

/// A wrapper to hold weak references to delegate listeners.
struct WeakAudioBufferDelegateBox {
    weak var value: AnyObject?
}

/// Per-instance synthetic I/O used by startup resource tests. No device or
/// input-node access occurs when these six operations are provided.
struct AudioEngineStartupTestingOperations: Sendable {
    let installAndPrepareTap: @Sendable () throws -> Void
    let start: @Sendable () throws -> Void
    let stop: @Sendable () -> Void
    let removeTap: @Sendable () -> Void
    let reset: @Sendable () -> Void
    let isRunning: @Sendable () -> Bool
}

/// The serial queue owns microphone engine controls. PCM delivery uses a short
/// membership lock and never waits for start/stop/rebuild on that control queue.
/// Delegate callbacks keep their existing executors and borrow SDK PCM only
/// synchronously. SDK graph state never escapes this control boundary.
public final class AudioEngineManager: Sendable {
    public static let shared = AudioEngineManager()

    // AVAudioEngine is not Sendable in the installed SDK. This is the only
    // native graph reference: every app-side access stays inside a synchronous
    // lock scope, and no engine/node/format reference is returned to callers.
    // The PCM callback never acquires this lock or the engine control queue.
    private struct NativeState {
        let engine = AVAudioEngine()
        var isTapInstalled = false
    }
    private let native = OSAllocatedUnfairLock(uncheckedState: NativeState())
    private let testingOperations: AudioEngineStartupTestingOperations?
    private let routeDelayProvider: any DelayProvider
    private let routeRebuildOverride: (@Sendable (ObjectIdentifier, String) -> Void)?
    private let onRouteJoinStarted: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.langcheng.hireva.audiomanager")
    private let queueKey = DispatchSpecificKey<Bool>()
    // Weak membership alone is protected here. Copies are borrowed only for
    // synchronous callbacks after releasing this lock, never across an await.
    private let listeners = OSAllocatedUnfairLock(uncheckedState: [WeakAudioBufferDelegateBox]())
    private var isTapInstalled: Bool {
        get { native.withLock { $0.isTapInstalled } }
        set { native.withLock { $0.isTapInstalled = newValue } }
    }
    private struct Telemetry: Sendable {
        var lastAudioBufferAt: Date?
        var recoveryState = "Idle"
    }
    private let telemetry = OSAllocatedUnfairLock(initialState: Telemetry())
    private let routeIdentity = AudioEngineRouteIdentity()
    @MainActor private var routeRecoveryTasks: [UUID: Task<Void, Never>] = [:]

    public var lastAudioBufferAt: Date? { telemetry.withLock { $0.lastAudioBufferAt } }
    public var audioRecoveryState: String { telemetry.withLock { $0.recoveryState } }

    public var isEngineRunning: Bool { onEngineQueue { engineRunningOnQueue } }
    private var engineRunningOnQueue: Bool {
        if let testingOperations { return testingOperations.isRunning() }
        return native.withLock { $0.engine.isRunning }
    }

    @MainActor
    func addConfigurationObserver(in center: NotificationCenter,
        _ body: @escaping @Sendable () -> Void) -> any NSObjectProtocol {
        native.withLockUnchecked {
            center.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: $0.engine, queue: .main) { _ in body() }
        }
    }

    private init() {
        testingOperations = nil
        routeDelayProvider = RealDelayProvider()
        routeRebuildOverride = nil
        onRouteJoinStarted = nil
        queue.setSpecific(key: queueKey, value: true)
    }

    init(testingOperations: AudioEngineStartupTestingOperations,
        routeDelayProvider: any DelayProvider = RealDelayProvider(),
        routeRebuildOverride: (@Sendable (ObjectIdentifier, String) -> Void)? = nil,
        onRouteJoinStarted: (@Sendable () -> Void)? = nil) {
        self.testingOperations = testingOperations
        self.routeDelayProvider = routeDelayProvider
        self.routeRebuildOverride = routeRebuildOverride
        self.onRouteJoinStarted = onRouteJoinStarted
        queue.setSpecific(key: queueKey, value: true)
    }

    @MainActor
    var ownedRouteRecoveryTasksForTesting: [Task<Void, Never>] {
        Array(routeRecoveryTasks.values)
    }
    @MainActor public var hasOwnedRouteRecoveryWork: Bool { !routeRecoveryTasks.isEmpty }

    @MainActor public func shutdownRouteRecovery() async {
        routeIdentity.close()
        await cancelAndJoinRouteRecovery()
    }

    /// Invalidate before cancellation, then join current and retiring workers.
    /// Each worker removes only its own handle after native queue work returns.
    @MainActor
    public func cancelAndJoinRouteRecovery() async {
        routeIdentity.invalidate()
        let owned = Array(routeRecoveryTasks.values)
        onRouteJoinStarted?()
        owned.forEach { $0.cancel() }
        for task in owned { await task.value }
    }

    var registeredDelegateCountForTesting: Int {
        listeners.withLockUnchecked { $0.compactMap(\.value).count }
    }

    /// Registers a delegate to receive audio buffer callbacks.
    @discardableResult
    public func register(_ delegate: any AudioEngineBufferDelegate) -> Result<Void, Error> {
        queue.sync {
            let alreadyExists = listeners.withLockUnchecked { delegates in
                delegates.removeAll { $0.value == nil }
                let exists = delegates.contains { $0.value === delegate }
                if !exists { delegates.append(WeakAudioBufferDelegateBox(value: delegate)) }
                return exists
            }
            
            do {
                try ensureTapInstalled()
                return .success(())
            } catch {
                rollbackFailedStartup()
                if !alreadyExists {
                    listeners.withLockUnchecked { $0.removeAll { $0.value === delegate } }
                }
                // The failed shared tap also invalidates existing listeners.
                // The rejected new listener receives the exact error via Result.
                notifyRouteFailed(error: error)
                return .failure(error)
            }
        }
    }

    /// Unregisters a delegate from receiving audio buffer callbacks.
    public func unregister(_ delegate: any AudioEngineBufferDelegate) {
        queue.sync {
            let empty = listeners.withLockUnchecked { delegates in
                delegates.removeAll { $0.value === delegate || $0.value == nil }
                return delegates.isEmpty
            }
            if empty { removeTap() }
        }
    }

    /// Queries the current dynamic inputNode format from CoreAudio.
    public func currentInputFormatDescription() -> String {
        onEngineQueue {
            native.withLock {
                let format = $0.engine.inputNode.outputFormat(forBus: 0)
                return "\(Int(format.sampleRate))Hz \(format.channelCount)Ch"
            }
        }
    }

    // Engine queries also occur in route callbacks on this queue. Re-entering
    // with queue.sync would deadlock; other threads serialize the native query.
    private func onEngineQueue<Value>(_ operation: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return operation() }
        return queue.sync(execute: operation)
    }

    /// Route controls are called by the MainActor app/route monitor. PCM never
    /// reads these task slots and keeps its callback executor.
    @MainActor
    public func handleAudioConfigurationChanged() {
        restartForRouteChange(reason: "AVAudioEngine Configuration Changed")
    }

    @MainActor
    @discardableResult
    public func restartForRouteChange(reason: String) -> Task<Void, Never>? {
        guard let id = routeIdentity.begin() else { return nil }
        routeRecoveryTasks.values.forEach { $0.cancel() }
        let delay = routeDelayProvider, identity = routeIdentity
        let worker = Task { @MainActor [weak self] in
            defer {
                identity.finish(id)
                self?.routeRecoveryTasks[id] = nil
            }
            do { try await delay.sleep(nanoseconds: 800_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, identity.isCurrent(id) else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.queue.async { [weak self] in
                        defer { continuation.resume() }
                        guard let self, identity.isCurrent(id) else { return }
                        if let execution = self.routeRebuildOverride {
                            execution(ObjectIdentifier(self), reason)
                        } else {
                            self.rebuildInputTap(reason: reason)
                        }
                    }
                }
            } onCancel: { identity.cancel(id) }
        }
        routeRecoveryTasks[id] = worker
        return worker
    }

    /// Performs an immediate rebuild of the input tap.
    public func rebuildInputTap() {
        queue.sync {
            self.rebuildInputTap(reason: "Immediate rebuild requested")
        }
    }

    /// Performs the safe, safe teardown and dynamic tap rebuild.
    private func rebuildInputTap(reason: String) {
        print("[AudioEngineManager] Rebuilding input tap due to: \(reason)")
        
        // 1. Stop engine safely
        stopEngine()
        
        // 2. Remove tap
        removeInputTap()
        isTapInstalled = false
        
        // 3. Reset the engine to clear stale formats
        resetEngine()
        
        // 4. Update recovery state attributes
        telemetry.withLock {
            $0.lastAudioBufferAt = nil
            $0.recoveryState = "Reconnecting..."
        }
        
        // 5. Re-query inputNode and install tap if we have delegates
        if !activeDelegates().isEmpty {
            do {
                try installInputTapAndPrepare(clearPreviousTap: false)
                isTapInstalled = true
                try startEngine()
                telemetry.withLock { $0.recoveryState = "Active" }
                
                // 6. Notify delegates that the audio route changed successfully
                notifyRouteRestarted()
            } catch {
                print("[AudioEngineManager] Recovery failed: code=\((error as NSError).code)")
                rollbackFailedStartup()
                notifyRouteFailed(error: error)
            }
        } else {
            telemetry.withLock { $0.recoveryState = "Idle" }
        }
    }

    /// Installs a single tap on AVAudioEngine inputNode bus 0 and starts the engine.
    private func ensureTapInstalled() throws {
        guard !isTapInstalled else {
            if !engineRunningOnQueue {
                try startEngine()
            }
            return
        }

        try installInputTapAndPrepare(clearPreviousTap: true)
        isTapInstalled = true
        try startEngine()
        telemetry.withLock { $0.recoveryState = "Active" }
    }

    /// Stops the shared audio engine and uninstalls the tap.
    private func removeTap() {
        guard isTapInstalled else { return }
        stopEngine()
        removeInputTap()
        isTapInstalled = false
        telemetry.withLock { $0.recoveryState = "Idle" }
    }

    private func rollbackFailedStartup() {
        // Installation may have succeeded before engine.start threw. Removal
        // must therefore run even when the old installed flag was still false.
        stopEngine()
        removeInputTap()
        isTapInstalled = false
        resetEngine()
        telemetry.withLock { $0.recoveryState = "Failed" }
    }

    private func installInputTapAndPrepare(clearPreviousTap: Bool) throws {
        if let testingOperations {
            if clearPreviousTap { testingOperations.removeTap() }
            try testingOperations.installAndPrepareTap()
            return
        }
        native.withLock { state in
            let inputNode = state.engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            if clearPreviousTap { inputNode.removeTap(onBus: 0) }
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                self?.broadcast(buffer: buffer, time: time)
            }
            state.engine.prepare()
        }
    }
    private func startEngine() throws {
        if let testingOperations { try testingOperations.start() }
        else { try native.withLock { try $0.engine.start() } }
    }
    private func stopEngine() {
        if let testingOperations { testingOperations.stop() }
        else { native.withLock { $0.engine.stop() } }
    }
    private func removeInputTap() {
        if let testingOperations { testingOperations.removeTap() }
        else { native.withLock { $0.engine.inputNode.removeTap(onBus: 0) } }
    }
    private func resetEngine() {
        if let testingOperations { testingOperations.reset() }
        else { native.withLock { $0.engine.reset() } }
    }

    /// PCM callback membership is independent of engine control work. Neither
    /// of these short locks remains held while invoking a delegate.
    func broadcast(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        telemetry.withLock { $0.lastAudioBufferAt = Date() }
        for delegate in activeDelegates() {
            delegate.audioEngineManager(self, didReceive: buffer, at: time)
        }
    }

    private func activeDelegates() -> [any AudioEngineBufferDelegate] {
        listeners.withLockUnchecked {
            $0.compactMap { $0.value as? (any AudioEngineBufferDelegate) }
        }
    }

    private func notifyRouteRestarted() {
        for delegate in activeDelegates() {
            delegate.audioEngineManagerDidRestartAfterRouteChange(self)
        }
    }

    private func notifyRouteFailed(error: Error) {
        for delegate in activeDelegates() {
            delegate.audioEngineManager(self, didFailWith: error)
        }
    }
}

/// One authority for route-work validity, usable by native queue callbacks and
/// synchronous cancellation handlers without crossing an executor or await.
private final class AudioEngineRouteIdentity: Sendable {
    private struct State: Sendable { var current: UUID?; var closed = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func begin() -> UUID? {
        state.withLock {
            guard !$0.closed else { return nil }
            let id = UUID()
            $0.current = id
            return id
        }
    }
    func isCurrent(_ id: UUID) -> Bool { state.withLock { !$0.closed && $0.current == id } }
    func cancel(_ id: UUID) { state.withLock { if $0.current == id { $0.current = nil } } }
    func finish(_ id: UUID) { cancel(id) }
    func invalidate() { state.withLock { $0.current = nil } }
    func close() { state.withLock { $0.closed = true; $0.current = nil } }
}
