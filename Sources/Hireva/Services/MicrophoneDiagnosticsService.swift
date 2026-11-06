import AVFoundation
import Foundation
import os

@MainActor
final class MicrophoneDiagnosticsService: ObservableObject {
    @Published var isRunning = false
    @Published var rmsLevel: Double = 0
    @Published var decibels: Double = -90
    @Published var selectedInputDeviceName: String = "Default Input"
    @Published var lastError: String?

    private struct MeteringLease {
        let id: UUID
        let receiver: MicrophoneDiagnosticsReceiver
        let callbacks: MicrophoneDiagnosticsCallbacks
    }
    private let manager: AudioEngineManager
    private let inputDeviceName: @MainActor () -> String
    private let delay: any DelayProvider
    private let now: @Sendable () -> TimeInterval
    private let onCallbackScheduled: (@Sendable (Task<Void, Never>) -> Void)?
    private var activeLease: MeteringLease?
    private var retiringLeases: [UUID: MeteringLease] = [:]
    private var admissionClosed = false
    // @Published sends before storing. Reentrant lifecycle intent closes native
    // admission immediately; its display/start effects wait for that setter.
    private enum DisplayIntent {
        case startTest
        case stop(selectedDevice: String)
        case refresh(UUID?), recover(UUID)
    }
    private var applyingDisplayTransition = false
    private var pendingDisplayIntent: DisplayIntent?

    init(manager: AudioEngineManager = .shared,
         inputDeviceName: @escaping @MainActor () -> String = {
             AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Input"
         },
         onCallbackScheduled: (@Sendable (Task<Void, Never>) -> Void)? = nil,
         delay: any DelayProvider = RealDelayProvider(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.manager = manager
        self.inputDeviceName = inputDeviceName
        self.onCallbackScheduled = onCallbackScheduled
        self.delay = delay
        self.now = now
    }

    var normalizedLevel: Double { min(max((decibels + 60) / 60, 0), 1) }
    var pendingCallbackTaskCount: Int {
        (activeLease?.callbacks.pendingTaskCount ?? 0) +
            retiringLeases.values.reduce(0) { $0 + $1.callbacks.pendingTaskCount }
    }
    var hasOwnedCallbackWork: Bool {
        activeLease?.callbacks.isQuiescent == false ||
            retiringLeases.values.contains { !$0.callbacks.isQuiescent }
    }
    var activeReceiverForTesting: (any AudioEngineBufferDelegate)? { activeLease?.receiver }
    var pendingControlCountForTesting: Int { activeLease?.callbacks.pendingControlCount ?? 0 }
    var coalescedNumericUpdatesForTesting: Int { activeLease?.callbacks.coalescedNumericUpdates ?? 0 }

    func refreshSelectedInputDevice() {
        guard !admissionClosed else { return }
        if applyingDisplayTransition {
            // A lifecycle change refreshes its own metadata. Do not replace it
            // with a display-only request for the superseded registration.
            if pendingDisplayIntent == nil { pendingDisplayIntent = .refresh(activeLease?.id) }
            return
        }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        refreshDeviceName(for: activeLease?.id)
    }

    func startMicTest() {
        guard !admissionClosed else { return }
        if applyingDisplayTransition {
            retireActiveLease()
            pendingDisplayIntent = .startTest
            return
        }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        startTestImmediately()
    }

    /// Live owns its capture; metering registers only its own immutable receiver.
    /// isRunning keeps its existing meaning of the standalone microphone test.
    func startMeteringForCapture() throws {
        // A throwing synchronous entry must return its actual registration
        // result. It cannot report success for deferred reentrant native work.
        guard !admissionClosed, !applyingDisplayTransition else { throw CancellationError() }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        try beginMetering(isStandaloneTest: false)
    }

    private func startTestImmediately() {
        guard !admissionClosed else { return }
        do { try beginMetering(isStandaloneTest: true) }
        catch {
            guard !(error is CancellationError), !admissionClosed,
                  matchesDisplayScope(nil) else { return }
            isRunning = false
            guard matchesDisplayScope(nil) else { return }
            lastError = error.localizedDescription
        }
    }

    private func beginMetering(isStandaloneTest: Bool) throws {
        retireActiveLease()
        let id = UUID()
        let callbacks = MicrophoneDiagnosticsCallbacks(delay: delay, now: now,
            onScheduled: onCallbackScheduled) { [weak self] event in
                self?.publish(event, leaseID: id) ?? false
            }
        let receiver = MicrophoneDiagnosticsReceiver(callbacks: callbacks)
        let lease = MeteringLease(id: id, receiver: receiver, callbacks: callbacks)
        // Install identity before any publisher or injected metadata callback.
        activeLease = lease
        do {
            guard resetDisplay(for: id), !admissionClosed else { throw CancellationError() }
            refreshDeviceName(for: id)
            guard isCurrentLease(id) else { throw CancellationError() }
            try manager.register(receiver).get()
            guard isCurrentLease(id) else { throw CancellationError() }
            isRunning = isStandaloneTest
            guard isCurrentLease(id) else { throw CancellationError() }
        } catch {
            retire(lease)
            throw error
        }
    }

    /// Native admission closes synchronously even inside a Published subscriber.
    /// Only display reset/replacement registration waits for the current setter.
    func stopMicTest() {
        let selectedDevice = selectedInputDeviceName
        retireActiveLease()
        if applyingDisplayTransition {
            // A device-name willSet may still resume after this call. This
            // immutable stop receipt preserves the metadata seen at stop.
            pendingDisplayIntent = .stop(selectedDevice: selectedDevice)
            return
        }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        applyStoppedDisplay(selectedDevice: selectedDevice)
    }

    private func applyStoppedDisplay(selectedDevice: String) {
        guard resetDisplay(for: nil), matchesDisplayScope(nil) else { return }
        if selectedInputDeviceName != selectedDevice { selectedInputDeviceName = selectedDevice }
    }

    private func retireActiveLease() {
        if let lease = activeLease { retire(lease) }
    }
    private func retire(_ lease: MeteringLease) {
        guard retiringLeases[lease.id]?.callbacks !== lease.callbacks else { return }
        if activeLease?.id == lease.id { activeLease = nil }
        lease.callbacks.closeAdmission()
        manager.unregister(lease.receiver)
        retiringLeases[lease.id] = lease
    }

    private func matchesDisplayScope(_ id: UUID?) -> Bool {
        guard activeLease?.id == id else { return false }
        switch pendingDisplayIntent {
        case .some(.startTest), .some(.stop(_)): return false
        default: return true
        }
    }
    private func isCurrentLease(_ id: UUID) -> Bool {
        !admissionClosed && matchesDisplayScope(id)
    }
    @discardableResult
    private func resetDisplay(for id: UUID?) -> Bool {
        guard matchesDisplayScope(id) else { return false }
        isRunning = false
        guard matchesDisplayScope(id) else { return false }
        rmsLevel = 0
        guard matchesDisplayScope(id) else { return false }
        decibels = -90
        guard matchesDisplayScope(id) else { return false }
        lastError = nil
        return matchesDisplayScope(id)
    }
    private func refreshDeviceName(for id: UUID?) {
        guard !admissionClosed, matchesDisplayScope(id) else { return }
        let name = inputDeviceName()
        guard !admissionClosed, matchesDisplayScope(id) else { return }
        selectedInputDeviceName = name
    }

    // One pending intent, no async dispatch or numeric mirror. A later stop/start
    // supersedes an earlier pending request; closeAdmission permanently denies
    // subsequent starts. Native callback control events keep their separate FIFO.
    private func finishDisplayTransition() {
        while let intent = pendingDisplayIntent {
            pendingDisplayIntent = nil
            switch intent {
            case .startTest:
                if !admissionClosed { startTestImmediately() }
            case .stop(let selectedDevice):
                applyStoppedDisplay(selectedDevice: selectedDevice)
            case .refresh(let id):
                refreshDeviceName(for: id)
            case .recover(let id):
                applyRecovering(for: id)
            }
        }
        applyingDisplayTransition = false
        reapDrainedLeases()
    }

    func finishStoppingMicTest() async {
        let captured = Array(retiringLeases.values)
        for lease in captured { await lease.callbacks.finish() }
        for lease in captured where retiringLeases[lease.id]?.callbacks === lease.callbacks {
            if lease.callbacks.isQuiescent { retiringLeases[lease.id] = nil }
        }
    }

    func closeAdmission() {
        admissionClosed = true
        stopMicTest()
    }
    func shutdown() async {
        closeAdmission()
        await finishStoppingMicTest()
    }

    private func reapDrainedLeases() {
        retiringLeases = retiringLeases.filter { !$0.value.callbacks.isQuiescent }
    }

    private func publish(_ event: MicrophoneDiagnosticsEvent, leaseID: UUID) -> Bool {
        guard !applyingDisplayTransition, isCurrentLease(leaseID) else { return false }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        switch event {
        case .metrics(let rms, let db):
            let alpha = 0.3
            rmsLevel = alpha * rms + (1 - alpha) * rmsLevel
            guard isCurrentLease(leaseID) else { return false }
            decibels = alpha * db + (1 - alpha) * decibels
            guard isCurrentLease(leaseID) else { return false }
            if lastError == "Recovering audio input..." { lastError = nil }
        case .routeRestarted:
            rmsLevel = 0
            guard isCurrentLease(leaseID) else { return false }
            decibels = -90
            guard isCurrentLease(leaseID) else { return false }
            lastError = nil
            guard isCurrentLease(leaseID) else { return false }
            refreshDeviceName(for: leaseID)
        case .failure(let message):
            rmsLevel = 0
            guard isCurrentLease(leaseID) else { return false }
            decibels = -90
            guard isCurrentLease(leaseID) else { return false }
            lastError = message
        case .overflow(let cause):
            // The terminal lease retains its exact worker/drain receipt until
            // stop. Overflow has already denied all further native admission.
            if let lease = activeLease { manager.unregister(lease.receiver) }
            isRunning = false
            guard isCurrentLease(leaseID) else { return false }
            rmsLevel = 0
            guard isCurrentLease(leaseID) else { return false }
            decibels = -90
            guard isCurrentLease(leaseID) else { return false }
            lastError = "Microphone diagnostic control backlog exceeded 32 events; metering stopped. " + cause
        }
        return isCurrentLease(leaseID)
    }

    func markAsRecovering() {
        guard !admissionClosed, let id = activeLease?.id else { return }
        if applyingDisplayTransition {
            // Preserve pending lifecycle intent; a current presentation request
            // may supersede only another presentation request for this lease.
            switch pendingDisplayIntent {
            case .some(.startTest), .some(.stop(_)): return
            default: pendingDisplayIntent = .recover(id)
            }
            return
        }
        applyingDisplayTransition = true
        defer { finishDisplayTransition() }
        applyRecovering(for: id)
    }
    private func applyRecovering(for id: UUID) {
        guard isCurrentLease(id) else { return }
        rmsLevel = 0
        guard isCurrentLease(id) else { return }
        decibels = -90
        guard isCurrentLease(id) else { return }
        lastError = "Recovering audio input..."
    }

}

private enum MicrophoneDiagnosticsEvent: Sendable {
    case metrics(rms: Double, decibels: Double)
    case routeRestarted
    case failure(String)
    case overflow(String)
}

/// One registration retains native PCM admission, one numeric snapshot, one
/// worker, and an ordered control FIFO. No SDK buffer or error crosses an await.
private final class MicrophoneDiagnosticsCallbacks: Sendable {
    private struct Worker: Sendable { let id: UUID; let task: Task<Void, Never> }
    private struct State: Sendable {
        var open = true
        var overflowed = false
        var latestMetrics: MicrophoneDiagnosticsEvent?
        var controls: [MicrophoneDiagnosticsEvent] = []
        var worker: Worker?
        var inFlightPCM = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
        var coalescedNumericUpdates = 0
        var lastPublishedAt: TimeInterval?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let delay: any DelayProvider
    private let now: @Sendable () -> TimeInterval
    private let onScheduled: (@Sendable (Task<Void, Never>) -> Void)?
    private let publish: @MainActor @Sendable (MicrophoneDiagnosticsEvent) -> Bool

    init(delay: any DelayProvider, now: @escaping @Sendable () -> TimeInterval, onScheduled: (@Sendable (Task<Void, Never>) -> Void)?,
         publish: @escaping @MainActor @Sendable (MicrophoneDiagnosticsEvent) -> Bool) {
        self.delay = delay
        self.now = now
        self.onScheduled = onScheduled
        self.publish = publish
    }
    var pendingTaskCount: Int { state.withLock { $0.worker == nil ? 0 : 1 } }
    var pendingControlCount: Int { state.withLock { $0.controls.count } }
    var coalescedNumericUpdates: Int { state.withLock { $0.coalescedNumericUpdates } }
    var isQuiescent: Bool { state.withLock { $0.worker == nil && $0.inFlightPCM == 0 } }

    func withPCMAdmission(_ body: () -> MicrophoneDiagnosticsEvent) {
        let admitted = state.withLock { value in
            guard value.open, !value.overflowed else { return false }
            value.inFlightPCM += 1
            return true
        }
        guard admitted else { return }
        defer { leavePCM() }
        offer(body())
    }

    private func leavePCM() {
        let waiters = state.withLock { value -> [CheckedContinuation<Void, Never>] in
            precondition(value.inFlightPCM > 0)
            value.inFlightPCM -= 1
            guard value.inFlightPCM == 0 else { return [] }
            let ready = value.drainWaiters
            value.drainWaiters.removeAll()
            return ready
        }
        waiters.forEach { $0.resume() }
    }

    func offer(_ event: MicrophoneDiagnosticsEvent) {
        let scheduled = state.withLock { value -> Task<Void, Never>? in
            guard value.open, !value.overflowed else { return nil }
            switch event {
            case .metrics:
                if value.latestMetrics != nil { value.coalescedNumericUpdates += 1 }
                value.latestMetrics = event
            case .routeRestarted, .failure:
                // Earlier levels cannot restore a meter after a route control.
                value.latestMetrics = nil
                if value.controls.count < 32 {
                    value.controls.append(event)
                } else {
                    let cause: String
                    if case .failure(let message) = event { cause = message }
                    else { cause = "A route restart arrived while the control queue was full." }
                    value.controls.append(.overflow(cause))
                    value.overflowed = true
                }
            case .overflow: preconditionFailure("Overflow is created only by bounded admission")
            }
            guard value.worker == nil else { return nil }
            let id = UUID()
            let task = Task { @MainActor in await self.run(id: id) }
            value.worker = Worker(id: id, task: task)
            return task
        }
        if let scheduled { onScheduled?(scheduled) }
    }

    @MainActor
    private func run(id: UUID) async {
        defer {
            state.withLock {
                if $0.worker?.id == id { $0.worker = nil }
            }
        }
        while !Task.isCancelled {
            let next = state.withLock { value -> MicrophoneDiagnosticsEvent? in
                guard value.worker?.id == id else { return nil }
                if !value.controls.isEmpty { return value.controls.removeFirst() }
                if let metrics = value.latestMetrics {
                    value.latestMetrics = nil
                    return metrics
                }
                // Retire under the same lock as admission to avoid a lost wakeup.
                value.worker = nil
                return nil
            }
            guard let next else { return }
            if case .metrics = next {
                let remaining = state.withLock { value in
                    max(0, 0.04 - (now() - (value.lastPublishedAt ?? -1)))
                }
                if remaining > 0 {
                    do { try await delay.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                // A control arriving during sleep supersedes this old display.
                let current = state.withLock { $0.open && !$0.overflowed && $0.controls.isEmpty }
                if current, publish(next) {
                    state.withLock { $0.lastPublishedAt = now() }
                }
            } else {
                guard !Task.isCancelled else { return }
                _ = publish(next)
            }
        }
    }

    func closeAdmission() {
        let worker = state.withLock { value -> Task<Void, Never>? in
            value.open = false
            value.latestMetrics = nil
            value.controls.removeAll()
            return value.worker?.task
        }
        worker?.cancel()
    }

    func finish() async {
        let worker = state.withLock { $0.worker?.task }
        await worker?.value
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finished = state.withLock { value in
                guard value.inFlightPCM > 0 else { return true }
                value.drainWaiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}

/// Immutable registration identity. The manager may retain an old delegate
/// snapshot during unregister; only this old lease receives that callback.
private final class MicrophoneDiagnosticsReceiver: AudioEngineBufferDelegate, Sendable {
    private let callbacks: MicrophoneDiagnosticsCallbacks
    init(callbacks: MicrophoneDiagnosticsCallbacks) { self.callbacks = callbacks }
    func audioEngineManager(_ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        callbacks.withPCMAdmission { Self.metrics(from: buffer) }
    }
    func audioEngineManagerDidRestartAfterRouteChange(_ manager: AudioEngineManager) {
        callbacks.offer(.routeRestarted)
    }
    func audioEngineManager(_ manager: AudioEngineManager, didFailWith error: Error) {
        callbacks.offer(.failure(error.localizedDescription))
    }
    private static func metrics(from buffer: AVAudioPCMBuffer) -> MicrophoneDiagnosticsEvent {
        guard let channelData = buffer.floatChannelData else { return .metrics(rms: 0, decibels: -90) }
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength), sampleStride = buffer.stride
        guard channels > 0, frames > 0 else { return .metrics(rms: 0, decibels: -90) }
        var sum: Float = 0
        for channel in 0..<channels {
            let samples = channelData[channel]
            for frame in 0..<frames { let sample = samples[frame * sampleStride]; sum += sample * sample }
        }
        let rms = sqrt(sum / Float(channels * frames))
        let db = 20 * log10(max(Double(rms), 0.000_001))
        return .metrics(rms: Double(rms), decibels: max(db, -90))
    }
}
