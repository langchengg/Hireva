import Combine
import Foundation

/// Owns permission observations, explicit Speech authorization Swift waiters,
/// and native system-audio probes. Capture startup joins the prior native probe.
@MainActor
final class SystemAudioPermissionController: ObservableObject {
    private struct Operation {
        let id: UUID
        let task: Task<ScreenSystemAudioPermissionProbeResult, Error>
        let cancellation: AsyncStream<Void>.Continuation
        let cancellationWatcher: Task<Void, Never>
    }
    private struct Retirement {
        let id: UUID
        let task: Task<Void, Error>
    }

    // A visual system-audio test is independent of the short TCC probe. Its
    // exact native receipt survives successful startup and failed cleanup.
    @MainActor
    private final class DiagnosticCapture {
        var receipt: SystemAudioCaptureStopReceipt?
        var startup: Task<Void, Error>?
        var stop: (id: UUID, task: Task<Void, Error>)?
        var cleanupFailure: Error?
    }
    private let diagnosticCaptureService: ScreenCaptureKitSystemAudioCaptureService
    // Native authority and visible error are committed before notifying UI.
    // Published willSet callbacks cannot observe an unregistered new worker.
    private var diagnosticCapture: DiagnosticCapture?
    private(set) var diagnosticCaptureError: String?
    // closeAdmission may run well before shutdown's awaited phase. Freeze its
    // first stop and whether failure already existed at that submission; do
    // not retrospectively authorize retry when that initial attempt fails.
    private var initialDiagnosticShutdownStop: Task<Void, Error>?
    private var initialDiagnosticShutdownCanRetry = false
    private var initialDiagnosticShutdownJoined = false
    private var shutdownWork: (id: UUID, task: Task<Void, Error>)?

    private let permissions: PermissionService
    private let probe: @MainActor () async throws -> ScreenSystemAudioPermissionProbeResult
    private let stopProbe: @MainActor (Bool) async throws -> Void
    @Published private var baseSnapshot = PermissionSnapshot(
        microphone: .unknown, speechRecognition: .unknown,
        screenRecording: .unknown, systemAudioCapture: .notDetermined)
    @Published private(set) var probeResult: ScreenSystemAudioPermissionProbeResult?
    @Published private var cleanupFailure: Error?
    private var requestedID: UUID?
    private var current: Operation?
    private var retiring: [UUID: Operation] = [:]
    private var retirement: Retirement?
    private var closed = false
    // Explicit UI Speech authorization is independent of a system-audio probe.
    // Direct Live/Manual/Practice awaits stay owned by their existing workers.
    private var speechAuthorization: (id: UUID, task: Task<Void, Never>)?

    // Source-compatible injection for native-free observations and existing
    // fixtures. Native assembly uses the typed stop capability below.
    convenience init(permissions: PermissionService,
        initialSnapshot: PermissionSnapshot = .init(microphone: .unknown,
            speechRecognition: .unknown, screenRecording: .unknown, systemAudioCapture: .notDetermined),
        initialProbeResult: ScreenSystemAudioPermissionProbeResult? = nil,
        probe: @escaping @MainActor () async throws -> ScreenSystemAudioPermissionProbeResult,
        stopProbe: @escaping @MainActor () async throws -> Void,
        diagnosticCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil) {
        self.init(permissions: permissions, initialSnapshot: initialSnapshot,
            initialProbeResult: initialProbeResult, probe: probe,
            stopProbe: { _ in try await stopProbe() },
            diagnosticCaptureService: diagnosticCaptureService)
    }

    init(permissions: PermissionService,
        initialSnapshot: PermissionSnapshot = .init(microphone: .unknown,
            speechRecognition: .unknown, screenRecording: .unknown, systemAudioCapture: .notDetermined),
        initialProbeResult: ScreenSystemAudioPermissionProbeResult? = nil,
        probe: @escaping @MainActor () async throws -> ScreenSystemAudioPermissionProbeResult,
        stopProbe: @escaping @MainActor (Bool) async throws -> Void,
        diagnosticCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil) {
        self.permissions = permissions
        self.baseSnapshot = initialSnapshot
        self.probeResult = initialProbeResult
        self.probe = probe
        self.stopProbe = stopProbe
        self.diagnosticCaptureService = diagnosticCaptureService ?? .shared
    }

    var permissionSnapshot: PermissionSnapshot {
        var snapshot = baseSnapshot
        if probeResult != nil || cleanupFailure != nil {
            let state: PermissionState
            switch systemAudioPermissionState {
            case .granted: state = .granted
            case .permissionMissing: state = .denied
            default: state = .unknown
            }
            snapshot.screenRecording = state
            snapshot.systemAudioCapture = state
        }
        return snapshot
    }

    var microphonePermissionState: MicrophonePermissionState {
        switch baseSnapshot.microphone {
        case .granted: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .unknown: return .unknown
        }
    }

    var systemAudioPermissionState: ScreenSystemAudioPermissionState {
        if let cleanupFailureDescription { return .streamAudioProbeFailed(cleanupFailureDescription) }
        if let probeResult { return Self.state(for: probeResult) }
        return .permissionMissing
    }

    var hasOwnedProbeWork: Bool {
        current != nil || !retiring.isEmpty || retirement != nil
    }

    var cleanupFailureDescription: String? { cleanupFailure?.localizedDescription }
    var hasUnreleasedProbeResources: Bool { hasOwnedProbeWork || cleanupFailure != nil }
    var hasOwnedDiagnosticCapture: Bool { diagnosticCapture != nil }
    var hasUnreleasedResources: Bool {
        hasUnreleasedProbeResources || hasOwnedDiagnosticCapture || shutdownWork != nil ||
            speechAuthorization != nil
    }
    var canStartDiagnosticCapture: Bool {
        !closed && cleanupFailure == nil && diagnosticCapture == nil &&
            !diagnosticCaptureService.hasOwnedCaptureRuntime
    }

    var hasOwnedSpeechAuthorizationWork: Bool { speechAuthorization != nil }

    /// Register before starting the SDK bridge. Repeated UI submission joins
    /// this exact request; closing admission cancels and drains its Swift waiter.
    @discardableResult
    func requestSpeechAuthorization(
        onCompletion: @escaping @MainActor (PermissionState) -> Void
    ) -> Task<Void, Never>? {
        guard !closed else { return nil }
        if let owned = speechAuthorization { return owned.task }
        let id = UUID()
        let task = Task { @MainActor [self, permissions] in
            let result = await permissions.requestSpeechRecognition()
            guard speechAuthorization?.id == id else { return }
            speechAuthorization = nil
            // Retire before a synchronous UI callback can submit another request
            // or close this owner. The worker writes nothing after notification.
            guard !closed, !Task.isCancelled else { return }
            onCompletion(result)
        }
        speechAuthorization = (id, task)
        return task
    }

    /// UI submission retains a task before any probe drain can suspend. Native
    /// authority is published synchronously by begin before its startup await.
    @discardableResult
    func requestDiagnosticCapture() -> Task<Void, Error>? {
        guard canStartDiagnosticCapture else { return nil }
        guard permissionSnapshot.screenRecording == .granted else {
            let message = "Screen & System Audio Recording permission is required."
            if diagnosticCaptureError != message {
                diagnosticCaptureError = message
                objectWillChange.send()
            }
            return nil
        }
        cancelProbe()
        let priorRetirement = retirement
        let owned = DiagnosticCapture()
        diagnosticCapture = owned
        diagnosticCaptureError = nil
        let task = Task { @MainActor [self, owned] in
            defer { owned.startup = nil }
            do {
                try await priorRetirement?.task.value
                try Task.checkCancellation()
                guard !closed, diagnosticCapture === owned, owned.stop == nil else { throw CancellationError() }
                // Another runtime can acquire the service during the probe join.
                guard !diagnosticCaptureService.hasOwnedCaptureRuntime else {
                    throw TranscriptionError.unavailable("System audio is owned by another capture.")
                }
                let native = diagnosticCaptureService.beginSystemAudioCapture(onOwned: { owned.receipt = $0 })
                try await diagnosticCaptureService.finishStartingSystemAudioCapture(
                    capturedStart: native.startup, capturedReceipt: native.receipt)
                try Task.checkCancellation()
                guard !closed, diagnosticCapture === owned, owned.stop == nil else { throw CancellationError() }
            } catch {
                // Never join the owner stop task from its own startup worker:
                // that stop task joins this worker. Drain only the exact leaf.
                if let receipt = owned.receipt {
                    diagnosticCaptureService.stopSystemAudioCapture(capturedReceipt: receipt, retryFailed: false)
                    do { try await diagnosticCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: receipt) }
                    catch { owned.cleanupFailure = error }
                }
                if diagnosticCapture === owned {
                    if let failure = owned.cleanupFailure { diagnosticCaptureError = failure.localizedDescription }
                    else {
                        if !(error is CancellationError) { diagnosticCaptureError = error.localizedDescription }
                        if owned.stop == nil { diagnosticCapture = nil }
                    }
                    objectWillChange.send()
                }
                throw owned.cleanupFailure ?? error
            }
        }
        owned.startup = task
        // Admission and its exact task are visible before any synchronous
        // observer requests another start, stop, or closes this owner.
        objectWillChange.send()
        guard !closed, diagnosticCapture === owned, owned.stop == nil else { return nil }
        return task
    }

    /// Repeated explicit stop joins an in-flight attempt. Only a failed attempt
    /// already observed at submission permits another exact native retry.
    @discardableResult
    func stopDiagnosticCapture() -> Task<Void, Error>? {
        beginStoppingDiagnosticCapture(retryRequested: true)
    }

    private func beginStoppingDiagnosticCapture(retryRequested: Bool) -> Task<Void, Error>? {
        guard let owned = diagnosticCapture else { return nil }
        if let stop = owned.stop { return stop.task }
        let retryAuthorized = retryRequested && owned.cleanupFailure != nil
        let startup = owned.startup
        let receipt = owned.receipt
        let id = UUID()
        let task = Task { @MainActor [self, owned] in
            defer { if owned.stop?.id == id { owned.stop = nil } }
            var failure: Error?
            if let receipt {
                do { try await diagnosticCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: receipt) }
                catch { failure = error }
            }
            _ = await startup?.result
            // No identity update or await can adopt another controller record.
            // A startup cancelled before receipt publication cannot acquire one
            // after its admission check, but this closes an injected late start.
            if let late = owned.receipt, late !== receipt {
                diagnosticCaptureService.stopSystemAudioCapture(capturedReceipt: late, retryFailed: false)
                do { try await diagnosticCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: late) }
                catch { failure = failure ?? error }
            }
            if let failure {
                owned.cleanupFailure = failure
                if diagnosticCapture === owned {
                    diagnosticCaptureError = failure.localizedDescription
                    if owned.stop?.id == id { owned.stop = nil }
                    objectWillChange.send()
                }
                throw failure
            }
            owned.cleanupFailure = nil
            if diagnosticCapture === owned {
                diagnosticCapture = nil
                diagnosticCaptureError = nil
                if owned.stop?.id == id { owned.stop = nil }
                objectWillChange.send()
            }
        }
        // Register this wrapper before cancellation/native stop can notify
        // synchronous callers. They join the same complete cleanup attempt.
        owned.stop = (id, task)
        startup?.cancel()
        if let receipt {
            diagnosticCaptureService.stopSystemAudioCapture(capturedReceipt: receipt, retryFailed: retryAuthorized)
        }
        return task
    }

    /// Reads TCC observations only; it never creates a capture stream.
    func refreshPassive() {
        guard !closed else { return }
        let next = permissions.refreshPermissions()
        if next.screenRecording != baseSnapshot.screenRecording ||
            next.systemAudioCapture != baseSnapshot.systemAudioCapture {
            if probeResult != nil { probeResult = nil }
            cancelProbe()
        }
        if baseSnapshot != next { baseSnapshot = next }
    }

    /// An automatic refresh probes only a selected system source. Explicit
    /// diagnostics use probeNow(), independently of the selected source.
    @discardableResult
    func refresh(captureMode: AudioCaptureMode, automaticallyProbe: Bool = true)
        -> Task<ScreenSystemAudioPermissionProbeResult, Error>? {
        refreshPassive()
        guard automaticallyProbe else { return nil }
        guard captureMode != .microphoneOnly else {
            cancelProbe()
            return nil
        }
        return beginProbe()?.task
    }

    /// A synchronous UI action can schedule explicit diagnostics without
    /// creating a task outside this owner. The returned handle is read-only.
    @discardableResult
    func requestExplicitProbe() -> Task<ScreenSystemAudioPermissionProbeResult, Error>? {
        beginProbe()?.task
    }

    func probeNow() async throws -> ScreenSystemAudioPermissionProbeResult {
        if let cleanupFailure { throw cleanupFailure }
        guard let operation = beginProbe() else { throw CancellationError() }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: { [task = operation.task, cancellation = operation.cancellation] in
                task.cancel()
                cancellation.yield(())
            }
            releaseJoined(operation)
            try Task.checkCancellation()
            return result
        } catch {
            releaseJoined(operation)
            throw error
        }
    }

    func cancelProbe() {
        requestedID = nil
        retireCurrent()
    }

    /// Cancellation invalidates publication immediately. Resource ownership
    /// ends only when the retained retirement fence has actually exited.
    func finishPreparingForCapture() async throws {
        cancelProbe()
        let captureStop = beginStoppingDiagnosticCapture(retryRequested: false)
        var failure: Error?
        do { try await joinRetirement() } catch { failure = error }
        do { try await captureStop?.value } catch { failure = failure ?? error }
        if let cleanupFailure { throw cleanupFailure }
        if let failure { throw failure }
    }

    func shutdown() async throws {
        closeAdmission()
        if let work = shutdownWork { try await work.task.value; return }
        // The closed controller is the sole production wrapper caller. Freeze
        // authorization before joining the retiring worker: its later first
        // failure cannot retroactively authorize another native attempt.
        let speechWaiter = speechAuthorization?.task
        let retryProbeCleanup = cleanupFailure != nil
        let firstJoin = !initialDiagnosticShutdownJoined
        let firstStop = firstJoin ? initialDiagnosticShutdownStop : nil
        let mayRetryBeforeClose = firstJoin && initialDiagnosticShutdownCanRetry
        let id = UUID()
        let task = Task { @MainActor [self] in
            defer {
                if firstJoin {
                    initialDiagnosticShutdownJoined = true
                    initialDiagnosticShutdownStop = nil
                    initialDiagnosticShutdownCanRetry = false
                }
                if shutdownWork?.id == id { shutdownWork = nil }
            }
            var failure: Error?
            await speechWaiter?.value
            do { try await joinRetirement() } catch { failure = error }
            do {
                try await stopProbe(retryProbeCleanup)
                if retryProbeCleanup {
                    // All retiring probe callbacks have joined, and the exact
                    // wrapper has confirmed release. Only then retire its error.
                    cleanupFailure = nil
                    failure = nil
                }
            } catch {
                cleanupFailure = error
                failure = error
            }
            if firstJoin {
                // This immutable handle survives completed stop-task retirement.
                // A failure arising after close is still the first attempt.
                do { try await firstStop?.value }
                catch { if !mayRetryBeforeClose { failure = failure ?? error } }
            }
            if !firstJoin || mayRetryBeforeClose {
                let captureStop = beginStoppingDiagnosticCapture(retryRequested: true)
                do { try await captureStop?.value } catch { failure = failure ?? error }
            }
            if let cleanupFailure { throw cleanupFailure }
            if let failure { throw failure }
        }
        shutdownWork = (id, task)
        try await task.value
    }

    func closeAdmission() {
        guard !closed else { return }
        closed = true
        speechAuthorization?.task.cancel()
        cancelProbe()
        initialDiagnosticShutdownCanRetry = diagnosticCapture?.cleanupFailure != nil
        initialDiagnosticShutdownStop = beginStoppingDiagnosticCapture(retryRequested: false)
    }

    private func beginProbe() -> Operation? {
        guard !closed, cleanupFailure == nil, diagnosticCapture == nil else { return nil }
        let id = UUID()
        requestedID = id
        retireCurrent()
        let priorRetirement = retirement
        let cancellation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // The cancellation bridge exists before native startup. onCancel only
        // signals this retained task; it never creates an unmanaged cleanup task.
        let watcher = Task { @MainActor [self, stopProbe] in
            var iterator = cancellation.stream.makeAsyncIterator()
            guard await iterator.next() != nil else { return }
            do { try await stopProbe(false) }
            catch { cleanupFailure = error }
        }
        let task = Task { @MainActor [self, probe, stopProbe] in
            // All awaits and native cleanup precede completion. The final
            // identity update and return do not allow MainActor reentrancy.
            defer { if current?.id == id { current = nil } }
            var result: ScreenSystemAudioPermissionProbeResult?
            var failure: Error?
            var nativeProbeAttempted = false
            do {
                try await priorRetirement?.task.value
                try requireCurrent(id)
                nativeProbeAttempted = true
                result = try await withTaskCancellationHandler {
                    try await probe()
                } onCancel: { [signal = cancellation.continuation] in
                    signal.yield(())
                }
            }
            catch { failure = error }
            cancellation.continuation.finish()
            await watcher.value
            // Even an uncooperative cancelled probe is stopped before this
            // operation can exit. A later probe awaits its retirement fence.
            if nativeProbeAttempted {
                do { try await stopProbe(false) }
                catch { cleanupFailure = error }
            }
            if let cleanupFailure { throw cleanupFailure }
            if let failure { throw failure }
            try requireCurrent(id)
            guard let result else { throw CancellationError() }
            if probeResult != result { probeResult = result }
            return result
        }
        let operation = Operation(id: id, task: task,
            cancellation: cancellation.continuation, cancellationWatcher: watcher)
        current = operation
        return operation
    }

    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard requestedID == id, !closed else { throw CancellationError() }
        if let cleanupFailure { throw cleanupFailure }
    }

    private func retireCurrent() {
        guard let operation = current else { return }
        current = nil
        retiring[operation.id] = operation
        operation.task.cancel()
        operation.cancellation.yield(())
        let previous = retirement
        let id = UUID()
        let task = Task { @MainActor [self, stopProbe] in
            defer { if retirement?.id == id { retirement = nil } }
            var failure: Error?
            do { try await previous?.task.value }
            catch { failure = error }
            // The retained watcher requests native stop while the probe awaits.
            // The worker joins it and drains a possible late acquisition.
            _ = await operation.task.result
            await operation.cancellationWatcher.value
            do { try await stopProbe(false) }
            catch { failure = failure ?? error }
            retiring.removeValue(forKey: operation.id)
            if let failure {
                cleanupFailure = failure
                throw failure
            }
        }
        retirement = Retirement(id: id, task: task)
    }

    private func joinRetirement() async throws {
        guard let owned = retirement else { return }
        try await owned.task.value
        if retirement?.id == owned.id { retirement = nil }
    }

    private func releaseJoined(_ operation: Operation) {
        if current?.id == operation.id { current = nil }
        retiring.removeValue(forKey: operation.id)
    }

    static func state(for result: ScreenSystemAudioPermissionProbeResult) -> ScreenSystemAudioPermissionState {
        if result.shareableContentProbeSucceeded {
            if result.likelyIdentityMismatch { return .identityMismatch }
            if !result.streamAudioProbeSucceeded {
                return .streamAudioProbeFailed(result.errorDescription ?? "Audio stream unavailable; no native error was reported.")
            }
            return .granted
        }
        if result.likelyIdentityMismatch { return .identityMismatch }
        return result.preflightGranted ? .restartLikely : .permissionMissing
    }
}
