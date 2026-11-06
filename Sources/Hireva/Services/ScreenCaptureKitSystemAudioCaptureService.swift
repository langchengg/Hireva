import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

protocol SystemAudioBufferDelegate: AnyObject {
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    )

    @MainActor
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    )
}

/// The native stream and deterministic lifecycle fixtures use the same owner.
protocol SystemAudioCaptureStream: AnyObject {
    /// Stable for this control's lifetime; native controls use their SDK stream's identity.
    var callbackIdentity: ObjectIdentifier { get }
    @MainActor func startCapture() async throws
    @MainActor func stopCapture() async throws
}

extension SystemAudioCaptureStream {
    var callbackIdentity: ObjectIdentifier { ObjectIdentifier(self) }
}

typealias NativeShareableContentCompletion = @Sendable (SCShareableContent?, Error?) -> Void

/// A single SDK enumeration has one result slot and one Swift waiter. The SDK
/// has no request cancellation handle: cancellation releases the Swift waiter
/// and rejects late results, while the framework may still invoke its callback.
private final class NativeShareableContentRequest: Sendable {
    private enum Phase: Equatable { case waiting, completed, cancelled, taken }
    private struct State {
        var phase = Phase.waiting
        var result: Result<SCShareableContent, Error>?
        var waiter: CheckedContinuation<Void, Never>?
    }
    // This private unchecked-state boundary transfers one callback reference.
    // All slot access is synchronous under the lock; MainActor alone extracts
    // and clears SDK content. No SDK object is asserted Sendable or resumed.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func install(_ waiter: CheckedContinuation<Void, Never>) -> Bool {
        let shouldFetch = state.withLockUnchecked { value in
            guard value.phase == .waiting, value.waiter == nil else { return false }
            value.waiter = waiter
            return true
        }
        if !shouldFetch { waiter.resume() }
        return shouldFetch
    }

    func receive(_ content: SCShareableContent?, error: Error?) {
        let waiter = state.withLockUnchecked { value -> CheckedContinuation<Void, Never>? in
            guard value.phase == .waiting else { return nil }
            value.phase = .completed
            if let error { value.result = .failure(error) }
            else if let content { value.result = .success(content) }
            else {
                value.result = .failure(NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No shareable display/window content."]))
            }
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func cancel() {
        let waiter = state.withLockUnchecked { value -> CheckedContinuation<Void, Never>? in
            guard value.phase == .waiting || value.phase == .completed else { return nil }
            value.phase = .cancelled
            // If already delivered, retain the SDK reference until take()
            // clears it on MainActor. A cancellation thread never reads it.
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    @MainActor func take() throws -> SCShareableContent {
        try state.withLockUnchecked { value in
            guard value.phase != .taken else {
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Shareable content result was already consumed."])
            }
            let phase = value.phase
            let result = value.result
            value.phase = .taken
            value.result = nil
            if phase == .cancelled { throw CancellationError() }
            guard phase == .completed, let result else {
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Shareable content result is incomplete."])
            }
            return try result.get()
        }
    }
}

/// The SDK reference remains on MainActor. Callbacks carry only its immutable
/// identity; SCStream and SCShareableContent are never asserted Sendable.
@MainActor
final class NativeSystemAudioCaptureStream: SystemAudioCaptureStream {
    let native: SCStream
    private let permissionAdmission: VerificationPermissionAdmission
    nonisolated let callbackIdentity: ObjectIdentifier

    init(native: SCStream, permissionAdmission: VerificationPermissionAdmission) {
        self.native = native
        self.permissionAdmission = permissionAdmission
        callbackIdentity = ObjectIdentifier(native)
    }

    func startCapture() async throws {
        try permissionAdmission.validateNativeScreenCapture(
            preflightAccess: { CGPreflightScreenCaptureAccess() })
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            native.startCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func stopCapture() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            native.stopCapture { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    static func shareableContent(
        permissionAdmission: VerificationPermissionAdmission = .current,
        preflightAccess: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        fetch: @MainActor (@escaping NativeShareableContentCompletion) -> Void = { completion in
            // The owned audio player may be offscreen; capture still requires its exact PID and bundle.
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: HirevaVerificationConfiguration.current == nil,
                completionHandler: completion)
        }
    ) async throws -> SCShareableContent {
        try Task.checkCancellation()
        try permissionAdmission.validateNativeScreenCapture(preflightAccess: preflightAccess)
        let request = NativeShareableContentRequest()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                guard request.install(waiter) else { return }
                // Cancellation may race this issuance. The one-shot slot still
                // rejects its eventual callback; the SDK provides no cancel API.
                fetch { content, error in request.receive(content, error: error) }
            }
        } onCancel: { request.cancel() }
        if Task.isCancelled { request.cancel() }
        return try request.take()
    }
}

/// Stable authority for one pending or active capture and its teardown.
/// MainActor updates one stop attempt; aliases follow explicit retries without
/// a task ancestry registry. The final resource binds after startup or its join.
@MainActor
final class SystemAudioCaptureStopReceipt {
    fileprivate struct Resource: Equatable {
        let source: ObjectIdentifier
        let revision: UInt64
    }
    fileprivate struct Attempt {
        let id: UUID
        let task: Task<Void, Error>
        var failed = false
    }
    fileprivate nonisolated let id = UUID()
    fileprivate var resource: Resource?
    fileprivate var resourceBound = false
    fileprivate var released = false
    fileprivate var attempt: Attempt?
    // A native startup fallback may already have attempted and failed cleanup.
    // The first stop reports it; only a subsequent explicit retry repeats I/O.
    fileprivate var startupCleanupFailure: Error?
    fileprivate init() {}

    // Read-only compatibility projection is absent while capture is active.
    var issuedStopTask: Task<Void, Error>? { attempt?.task }

    // Release phase belongs to this exact receipt, even after replacement.
    // This projection grants no current PCM or stop authority.
    var hasUnreleasedResource: Bool { !released }

    // Active callers join the separate startup task returned by begin; stop
    // publishes an attempt before accessing the required stop projection.
    var task: Task<Void, Error> {
        guard let attempt else { preconditionFailure("An unpublished stop receipt has no attempt") }
        return attempt.task
    }
}

@MainActor
final class ScreenCaptureKitSystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, ObservableObject {
    static let shared = ScreenCaptureKitSystemAudioCaptureService()

    // One committed value owns capture display. Reentrant synchronous sends
    // cannot restore an older setter's value over a newer capture submission.
    private let capturingSource = CurrentValueSubject<Bool, Never>(false)
    var isCapturing: Bool {
        get { capturingSource.value }
        set { capturingSource.send(newValue); objectWillChange.send() }
    }
    var isCapturingUpdates: AnyPublisher<Bool, Never> { capturingSource.eraseToAnyPublisher() }
    // Numeric fields commit together before observers run. This subject owns
    // the value; every display property below is a projection.
    private let displaySource = CurrentValueSubject<SystemAudioDisplayState, Never>(.init())
    var rmsLevel: Double { displaySource.value.rms }
    var decibels: Double { displaySource.value.decibels }
    // CurrentValueSubject is the only writable error storage. Its value
    // commits before synchronous observers can clear or replace this error.
    private let errorSource = CurrentValueSubject<String?, Never>(nil)
    var lastError: String? {
        get { errorSource.value }
        set { errorSource.send(newValue); objectWillChange.send() }
    }
    var lastErrorUpdates: AnyPublisher<String?, Never> { errorSource.eraseToAnyPublisher() }
    var lastBufferReceivedAt: Date? {
        get { displaySource.value.receivedAt }
        set {
            var value = displaySource.value
            value.receivedAt = newValue
            displaySource.send(value)
            objectWillChange.send()
        }
    }
    // Attribution comes from the committed callback revision, not wall-clock
    // ordering or the lifetime counter. Stop/replacement invalidates this tag.
    var currentCaptureBufferReceivedAt: Date? {
        let value = displaySource.value
        guard isCapturing, let revision = value.revision,
              startFence.isCurrent(revision) else { return nil }
        return value.receivedAt
    }
    var totalBuffersReceived: Int { displaySource.value.count }
    var sampleRate: Double { displaySource.value.sampleRate }
    var channelCount: Int { displaySource.value.channels }
    var lastBufferFrameCapacity: Int { displaySource.value.frames }
    var lastBufferReceivedAtUpdates: AnyPublisher<Date?, Never> {
        displaySource.map(\.receivedAt).removeDuplicates().eraseToAnyPublisher()
    }
    var totalBuffersReceivedUpdates: AnyPublisher<Int, Never> {
        displaySource.map(\.count).removeDuplicates().eraseToAnyPublisher()
    }

    private struct OwnedStream {
        let revision: UInt64
        let stream: any SystemAudioCaptureStream
        let receipt: SystemAudioCaptureStopReceipt
        let callbackDrain: SystemAudioCallbackDrain
        let removeOutput: @MainActor (any SCStreamOutput, SCStreamOutputType) throws -> Void
        var screenOutputRegistered = false
        var audioOutputRegistered = false
        // Native success stays acknowledged if a later output removal fails.
        var nativeStopAcknowledged = false
    }
    private let ownershipLock = NSRecursiveLock()
    private var ownedStream: OwnedStream?
    private var startupTask: (id: UUID, task: Task<Void, Error>, receipt: SystemAudioCaptureStopReceipt)?
    // This sole most-recent receipt also covers no-native automation capture.
    // It remains after release for queued terminal attribution; resource/PCM
    // admission excludes its released phase. Replacement overwrites this slot.
    private var teardownReceipt: SystemAudioCaptureStopReceipt?
    private let streamFactoryOverride: (() throws -> any SystemAudioCaptureStream)?
    private let registeredOutputsForTesting: Set<SCStreamOutputType>
    private let removeOutputForTesting: (@MainActor (any SystemAudioCaptureStream, SCStreamOutputType) throws -> Void)?
    private let onStartEntered: (() -> Void)?
    private let onFinishStoppingEntered: (@MainActor () -> Void)?
    private nonisolated let callbackState = SystemAudioCallbackState()
    nonisolated var pendingDiagnosticUpdates: Int { callbackState.pendingDisplayUpdates }
    private nonisolated let startFence = CaptureStartFence()
    private let queue = DispatchQueue(label: "com.langcheng.hireva.systemaudiocapture")
    private nonisolated let delegateRegistry = SystemAudioDelegateRegistry()
    private nonisolated let pcmProcessor = SystemAudioPCMProcessor()
    private nonisolated let verificationPCM = VerificationTiming.enabled ? VerificationPCMLeaf() : nil
    func takeVerificationPCMAnchors() -> VerificationPCMLeaf.Batch? { verificationPCM?.takeBatch() }
    private var lastUpdateTimestamp = Date.distantPast

    private var sampleWatchdogTask: Task<Void, Never>?

    // Native admission is distinct from the visual isCapturing flag. Pending
    // startup and retained failed teardown also own this shared resource.
    var hasOwnedCaptureRuntime: Bool {
        startupTask != nil || ownedStream != nil || teardownReceipt?.released == false
    }

    /// Pure authority projection. The compatibility isCapturing/Live Boolean
    /// cannot grant access to an independently replaced pending/native epoch.
    func isCurrentCaptureOwner(_ receipt: SystemAudioCaptureStopReceipt) -> Bool {
        teardownReceipt === receipt && !receipt.released
    }

    /// Terminal reconciliation may run after the exact native stream drained.
    /// This identity grants no PCM/start/stop authority and rejects replacement.
    func isMostRecentCaptureReceipt(_ receipt: SystemAudioCaptureStopReceipt) -> Bool {
        teardownReceipt === receipt
    }

    var normalizedLevel: Double {
        min(max((decibels + 60) / 60, 0), 1)
    }

    override init() {
        streamFactoryOverride = nil
        registeredOutputsForTesting = []
        removeOutputForTesting = nil
        onStartEntered = nil
        onFinishStoppingEntered = nil
        super.init()
    }

    init(streamFactory: @escaping () throws -> any SystemAudioCaptureStream, onStartEntered: (() -> Void)? = nil,
         onFinishStoppingEntered: (@MainActor () -> Void)? = nil,
         registeredOutputsForTesting: Set<SCStreamOutputType> = [],
         removeOutputForTesting: (@MainActor (any SystemAudioCaptureStream, SCStreamOutputType) throws -> Void)? = nil) {
        streamFactoryOverride = streamFactory
        self.registeredOutputsForTesting = registeredOutputsForTesting
        self.removeOutputForTesting = removeOutputForTesting
        self.onStartEntered = onStartEntered
        self.onFinishStoppingEntered = onFinishStoppingEntered
        super.init()
    }

    // Legacy diagnostic delegates intentionally observe the service. Capture
    // consumers instead bind membership to their one immutable receipt id.
    func register(_ delegate: any SystemAudioBufferDelegate) { delegateRegistry.register(delegate, captureID: nil) }

    func register(_ delegate: any SystemAudioBufferDelegate, capturedReceipt: SystemAudioCaptureStopReceipt) {
        delegateRegistry.register(delegate, captureID: capturedReceipt.id)
    }

    func unregister(_ delegate: any SystemAudioBufferDelegate) { delegateRegistry.unregister(delegate) }

    @MainActor
    func startSystemAudioCapture() async throws {
        let owned = beginSystemAudioCapture()
        try await finishStartingSystemAudioCapture(capturedStart: owned.startup, capturedReceipt: owned.receipt)
    }

    /// Synchronous submission freezes authority before the first suspension.
    /// The single startup task includes the prior capture's drain and native
    /// startup. Callers retain this same receipt for later exact stop/retry.
    func beginSystemAudioCapture(onOwned: (@MainActor (SystemAudioCaptureStopReceipt) -> Void)? = nil) -> (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>) {
        // Old cleanup freezes its task without notifying UI before this
        // request has registered its own cancellation/receipt authority.
        let previousStop = beginStopping(retryFailed: false, publishStoppedState: false)
        // Freeze the issued attempt, not a receipt which can follow retries.
        // A later retry may join this startup's cancellation; its prerequisite
        // must remain an older attempt to keep the join graph acyclic.
        let previousAttempt = previousStop.task
        let startRevision = startFence.begin()
        let receipt = SystemAudioCaptureStopReceipt()
        let startupID = UUID()
        let task = Task { @MainActor in
            var previousDrainCompleted = false
            do {
                // Captured before registering this task. Never join its own
                // stop attempt through the mutable current teardown slot.
                try await self.finishStoppingSystemAudioCapture(capturedStop: previousAttempt)
                previousDrainCompleted = true
                guard self.startFence.isCurrent(startRevision), !Task.isCancelled else { throw CancellationError() }
                // A cancelled intermediate request may have no resource while
                // an older native stop still failed. Never overwrite that owner.
                guard self.ownershipLock.withLock({ self.ownedStream == nil }) else {
                    throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "The previous system audio capture has not been released."])
                }
                if self.streamFactoryOverride == nil, isRunningUnderTestOrAutomation() {
                    print("[ScreenCaptureKitSystemAudioCaptureService] Skipping real capture startup (running under test/automation)")
                } else if let streamFactoryOverride = self.streamFactoryOverride {
                    let stream = try streamFactoryOverride()
                    self.own(stream: stream, revision: startRevision, receipt: receipt)
                    try await stream.startCapture()
                } else {
                    _ = try await self.startNativeStream(startRevision: startRevision, receipt: receipt)
                }
                guard self.startFence.isCurrent(startRevision), !Task.isCancelled else { throw CancellationError() }
                self.ownershipLock.withLock {
                    if let owned = self.ownedStream, owned.receipt === receipt {
                        receipt.resource = .init(source: owned.stream.callbackIdentity, revision: owned.revision)
                    }
                    receipt.resourceBound = true
                    if self.startupTask?.id == startupID { self.startupTask = nil }
                }
                self.isCapturing = true
                guard self.startFence.isCurrent(startRevision), self.teardownReceipt === receipt,
                      !Task.isCancelled else { throw CancellationError() }
                if self.streamFactoryOverride != nil || !isRunningUnderTestOrAutomation() {
                    let watchdog = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                        guard let self, !Task.isCancelled, self.startFence.isCurrent(startRevision),
                              self.isCapturing, !self.callbackState.hasReceivedSamples(revision: startRevision) else { return }
                        self.lastError = "System audio stream started but no samples received. Open a browser tab and play some audio (YouTube/music)."
                        self.notifyFailure(error: NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "System audio stream started but no samples received."]),
                            capturedReceipt: receipt)
                    }
                    self.ownershipLock.withLock { self.sampleWatchdogTask = watchdog }
                }
            } catch {
                // Retain the completed failed startup until its exact stop
                // joins it. That stop runs outside this task and owns cleanup.
                if self.startFence.isCurrent(startRevision) {
                    // Preserve the provenance of a retained stop failure. A
                    // successful retry clears that exact diagnostic, while a
                    // genuine error starting this stream remains a start error.
                    self.lastError = previousDrainCompleted ? error.localizedDescription
                        : "System audio stream could not stop: \(error.localizedDescription)"
                }
                throw error
            }
        }
        startupTask = (startupID, task, receipt)
        teardownReceipt = receipt
        onOwned?(receipt)
        if teardownReceipt === receipt, receipt.attempt == nil { lastError = nil }
        onStartEntered?()
        publishStoppedState(capturedReceipt: receipt)
        return (receipt, task)
    }

    /// Compatibility and typed callers share cancellation and error cleanup.
    /// This caller joins a separate stop task after startup has returned; the
    /// startup task itself never waits for a stop which must join startup.
    func finishStartingSystemAudioCapture(capturedStart: Task<Void, Error>,
        capturedReceipt: SystemAudioCaptureStopReceipt) async throws {
        do {
            try await withTaskCancellationHandler { try await capturedStart.value }
                onCancel: { capturedStart.cancel() }
            try Task.checkCancellation()
            guard teardownReceipt === capturedReceipt, capturedReceipt.attempt == nil,
                  !capturedReceipt.released else { throw CancellationError() }
        } catch {
            _ = stopSystemAudioCapture(capturedReceipt: capturedReceipt, retryFailed: false)
            try await finishStoppingSystemAudioCapture(capturedReceipt: capturedReceipt)
            throw error
        }
    }

    @MainActor
    private func startNativeStream(startRevision: UInt64, receipt: SystemAudioCaptureStopReceipt) async throws -> any SystemAudioCaptureStream {
        let verification = HirevaVerificationConfiguration.current
        let permissionAdmission = VerificationPermissionAdmission.resolve(verification: verification,
            environment: ProcessInfo.processInfo.environment,
            verificationOnlyBundle: Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool == true)
        try SystemAudioCaptureFilterPolicy.validateNativeCapture(verification: verification)

        // 1. Verify screen capture permissions
        let preflight = CGPreflightScreenCaptureAccess()
        var hasAccess = preflight
        let shareableContent: SCShareableContent

        do {
            shareableContent = try await NativeSystemAudioCaptureStream.shareableContent(
                permissionAdmission: permissionAdmission)
            hasAccess = true
        } catch {
            guard startFence.isCurrent(startRevision), !Task.isCancelled else { throw CancellationError() }
            if !hasAccess {
                let errorMsg = "Enable Screen & System Audio Recording in System Settings. (\(error.localizedDescription))"
                lastError = errorMsg
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            } else {
                let errorMsg = "No shareable display/window content: \(error.localizedDescription)"
                lastError = errorMsg
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
        }

        guard startFence.isCurrent(startRevision), !Task.isCancelled else { throw CancellationError() }
        guard let display = shareableContent.displays.first else {
            let errorMsg = "No shareable display detected."
            lastError = errorMsg
            throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        // 4. Configure stream configuration with dynamic video fallback
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // ScreenCaptureKit still produces screen frames for a display stream.
        // Register .screen output and discard it so the framework does not keep
        // logging "stream output NOT found" while we use the audio buffers.
        config.queueDepth = 3
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        var usingNativeResolution = false
        let streamInstance: NativeSystemAudioCaptureStream = try await Self.startFilteredCapture(
            verification: verification,
            applications: shareableContent.applications.map { ($0.processID, $0.bundleIdentifier) },
            filterFactory: { selection in
                switch selection {
                case .allDisplay:
                    return SCContentFilter(display: display, excludingWindows: [])
                case .application(let index):
                    return SCContentFilter(display: display, including: [shareableContent.applications[index]], exceptingWindows: [])
                }
            },
            streamFactory: { (filter: SCContentFilter, nativeResolution: Bool) in
                usingNativeResolution = nativeResolution
                if nativeResolution {
                    config.width = display.width
                    config.height = display.height
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                }
                let stream = NativeSystemAudioCaptureStream(
                    native: SCStream(filter: filter, configuration: config, delegate: self),
                    permissionAdmission: permissionAdmission)
                self.own(stream: stream, revision: startRevision, receipt: receipt)
                return stream
            },
            startStream: { (stream: NativeSystemAudioCaptureStream) in
                try stream.native.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                self.recordOutput(.screen, stream: stream)
                try stream.native.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                self.recordOutput(.audio, stream: stream)
                try await stream.startCapture()
                let resolution = usingNativeResolution ? "native fallback" : "16x16"
                print("[ScreenCaptureKitSystemAudioCaptureService] ScreenCaptureKit audio stream started with \(resolution) resolution.")
            },
            stopStream: { stream in
                do { try await self.stopExactStream(stream, revision: startRevision) }
                catch { receipt.startupCleanupFailure = error; throw error }
            },
            allowFallback: { error in
                guard self.startFence.isCurrent(startRevision), !Task.isCancelled else { throw CancellationError() }
                print("[ScreenCaptureKitSystemAudioCaptureService] Tiny 16x16 video stream configuration failed: code=\((error as NSError).code). Falling back to native display stream configuration.")
            }
        )

        return streamInstance
    }

    /// Both resolution attempts consume the same frozen filter. This function
    /// is also the deterministic factory boundary used by non-hardware tests.
    @MainActor
    static func startFilteredCapture<Filter, Stream>(
        verification: HirevaVerificationConfiguration?,
        applications: [(processID: Int32, bundleIdentifier: String)],
        filterFactory: @MainActor (SystemAudioCaptureFilterSelection) throws -> Filter,
        streamFactory: @MainActor (Filter, Bool) throws -> Stream,
        startStream: @MainActor (Stream) async throws -> Void,
        stopStream: @MainActor (Stream) async throws -> Void = { _ in },
        allowFallback: @MainActor (Error) throws -> Void
    ) async throws -> Stream {
        let selection = try SystemAudioCaptureFilterPolicy.select(verification: verification, applications: applications)
        let filter = try filterFactory(selection)
        var attempted: Stream?
        do {
            let stream = try streamFactory(filter, false)
            attempted = stream
            try await startStream(stream)
            return stream
        } catch {
            if let attempted { try await stopStream(attempted) }
            try allowFallback(error)
            let stream = try streamFactory(filter, true)
            do {
                try await startStream(stream)
                return stream
            } catch {
                try await stopStream(stream)
                throw error
            }
        }
    }

    @MainActor
    private func own(stream: any SystemAudioCaptureStream, revision: UInt64, receipt: SystemAudioCaptureStopReceipt) {
        let drain = SystemAudioCallbackDrain()
        let removeOutput: @MainActor (any SCStreamOutput, SCStreamOutputType) throws -> Void
        if let removeOutputForTesting, streamFactoryOverride != nil {
            removeOutput = { _, type in try removeOutputForTesting(stream, type) }
        } else if let native = stream as? NativeSystemAudioCaptureStream {
            removeOutput = { output, type in try native.native.removeStreamOutput(output, type: type) }
        } else {
            removeOutput = { _, _ in
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "The controlled stream has no output removal capability."])
            }
        }
        var ownership = OwnedStream(revision: revision, stream: stream, receipt: receipt,
            callbackDrain: drain, removeOutput: removeOutput)
        if streamFactoryOverride != nil {
            ownership.audioOutputRegistered = registeredOutputsForTesting.contains(.audio)
            ownership.screenOutputRegistered = registeredOutputsForTesting.contains(.screen)
        }
        ownershipLock.withLock { ownedStream = ownership }
        callbackState.open(stream: stream, revision: revision, captureID: receipt.id, drain: drain)
    }

    @MainActor
    private func recordOutput(_ type: SCStreamOutputType, stream: any SystemAudioCaptureStream) {
        ownershipLock.withLock {
            guard ownedStream?.stream === stream else { return }
            if type == .audio { ownedStream?.audioOutputRegistered = true }
            if type == .screen { ownedStream?.screenOutputRegistered = true }
        }
    }

    /// Synchronous invalidation closes PCM admission immediately. The retained
    /// teardown owns cancelled startup, the exact stream and queued callbacks.
    /// Call finishStoppingSystemAudioCapture when actual resource exit is needed.
    @discardableResult
    func stopSystemAudioCapture() -> Task<Void, Error> {
        stopSystemAudioCaptureAndReturnReceipt().task
    }

    @discardableResult
    func stopSystemAudioCaptureAndReturnReceipt() -> SystemAudioCaptureStopReceipt {
        beginStopping(retryFailed: true)
    }

    /// Only the retained receipt can issue another attempt. A released old
    /// receipt remains joinable but cannot close a replacement's admission.
    @discardableResult
    func retryStoppingSystemAudioCapture(capturedReceipt: SystemAudioCaptureStopReceipt)
        -> SystemAudioCaptureStopReceipt {
        stopSystemAudioCapture(capturedReceipt: capturedReceipt)
    }

    /// An active, pending, failed or released alias controls only its own epoch.
    /// A stale receipt is returned for joining without touching new admission.
    @discardableResult
    func stopSystemAudioCapture(capturedReceipt: SystemAudioCaptureStopReceipt, retryFailed: Bool = true)
        -> SystemAudioCaptureStopReceipt {
        // A pending newer start is authority too. Only an already-cancelled
        // request with no acquired stream may retire before an exact retry of
        // the still-retained older failed resource. Publish its own stop so a
        // later join of that cancelled request remains valid.
        if let startupTask, startupTask.receipt !== capturedReceipt {
            guard startupTask.task.isCancelled, ownedStream?.receipt === capturedReceipt,
                  capturedReceipt.attempt?.failed == true else { return capturedReceipt }
            _ = beginStopping(retryFailed: false, capturedReceipt: startupTask.receipt)
        }
        guard !capturedReceipt.released,
              startupTask?.receipt === capturedReceipt || ownedStream?.receipt === capturedReceipt ||
                teardownReceipt === capturedReceipt else { return capturedReceipt }
        return beginStopping(retryFailed: retryFailed, capturedReceipt: capturedReceipt)
    }

    @discardableResult
    private func beginStopping(retryFailed: Bool, capturedReceipt: SystemAudioCaptureStopReceipt? = nil,
        publishStoppedState: Bool = true) -> SystemAudioCaptureStopReceipt {
        startFence.invalidate()
        let callbackTasks = callbackState.close()
        let receipt = ownershipLock.withLock {
            sampleWatchdogTask?.cancel()
            startupTask?.task.cancel()
            let receipt = capturedReceipt ?? startupTask?.receipt ?? ownedStream?.receipt ??
                teardownReceipt ?? SystemAudioCaptureStopReceipt()
            if let attempt = receipt.attempt, !retryFailed || !attempt.failed { return receipt }
            let retryingFailure = receipt.attempt?.failed == true
            let previousStop = teardownReceipt?.id != receipt.id ? teardownReceipt?.attempt?.task : nil
            let startup = startupTask?.receipt === receipt ? startupTask : nil
            let watchdog = sampleWatchdogTask
            let id = UUID()
            let task = Task { @MainActor in
                _ = await previousStop?.result
                _ = await startup?.task.result
                for callback in callbackTasks { await callback.value }
                await watchdog?.value
                let stream = self.ownershipLock.withLock { self.ownedStream }
                if !receipt.resourceBound {
                    receipt.resource = stream.flatMap {
                        $0.receipt === receipt ? .init(source: $0.stream.callbackIdentity, revision: $0.revision) : nil
                    }
                    receipt.resourceBound = true
                }
                do {
                    if !retryingFailure, let failure = receipt.startupCleanupFailure { throw failure }
                    if let expected = receipt.resource {
                        guard let stream, stream.receipt === receipt, stream.stream.callbackIdentity == expected.source,
                              stream.revision == expected.revision else { throw CancellationError() }
                        try await self.stopExactStream(stream.stream, revision: expected.revision)
                    } else if stream?.receipt === receipt {
                        // A receipt which bound no resource never adopts a later one.
                        throw CancellationError()
                    }
                    self.ownershipLock.withLock {
                        guard receipt.attempt?.id == id else { return }
                        // Outcome belongs to the receipt even if a newer pending
                        // request installed another teardown slot while waiting.
                        receipt.released = true
                        receipt.startupCleanupFailure = nil
                        if self.startupTask?.id == startup?.id { self.startupTask = nil }
                        if self.teardownReceipt === receipt {
                            self.sampleWatchdogTask = nil
                            if retryingFailure, self.lastError?.hasPrefix("System audio stream could not stop: ") == true {
                                self.lastError = nil
                            }
                        }
                    }
                } catch {
                    // The native attempt and admitted callbacks have returned.
                    // Keep both this receipt and exact native resource for retry.
                    self.ownershipLock.withLock {
                        guard receipt.attempt?.id == id else { return }
                        receipt.attempt?.failed = true
                        if self.teardownReceipt === receipt {
                            self.lastError = "System audio stream could not stop: \(error.localizedDescription)"
                        }
                    }
                    throw error
                }
            }
            receipt.attempt = .init(id: id, task: task)
            teardownReceipt = receipt
            return receipt
        }
        // No external notification occurs while selecting/registering the
        // exact stop. A newer nested request cannot change this return handle.
        if publishStoppedState { self.publishStoppedState(capturedReceipt: receipt) }
        return receipt
    }

    private func publishStoppedState(capturedReceipt: SystemAudioCaptureStopReceipt) {
        guard teardownReceipt === capturedReceipt else { return }
        isCapturing = false
        guard teardownReceipt === capturedReceipt else { return }
        resetDisplayLevels()
    }

    @MainActor
    func finishStoppingSystemAudioCapture() async throws {
        // This legacy drain joins an issued stop; it never stops an active or
        // pending capture merely because its current receipt is registered.
        guard let receipt = teardownReceipt, receipt.attempt != nil else { return }
        try await finishStoppingSystemAudioCapture(capturedReceipt: receipt)
    }

    /// Join the stable resource receipt. If another authorized caller already
    /// retried its failed attempt, join that latest attempt rather than strand
    /// the old alias. No await permits adoption of another capture's receipt.
    @MainActor
    func finishStoppingSystemAudioCapture(capturedReceipt: SystemAudioCaptureStopReceipt) async throws {
        onFinishStoppingEntered?()
        while let attempt = capturedReceipt.attempt {
            do { try await attempt.task.value }
            catch {
                if capturedReceipt.attempt?.id != attempt.id { continue }
                if teardownReceipt?.id == capturedReceipt.id {
                    lastError = "System audio stream could not stop: \(error.localizedDescription)"
                }
                throw error
            }
            if capturedReceipt.attempt?.id != attempt.id { continue }
            precondition(capturedReceipt.released, "Successful stop must release its exact resource")
            return
        }
        preconditionFailure("A published stop receipt must own an attempt")
    }

    /// Compatibility joins retain the old attempt's result, but cannot publish
    /// its failure over a new attempt or capture. Receipt users follow retries.
    @MainActor
    func finishStoppingSystemAudioCapture(capturedStop: Task<Void, Error>) async throws {
        onFinishStoppingEntered?()
        do { try await capturedStop.value }
        catch {
            if teardownReceipt?.attempt?.task == capturedStop {
                lastError = "System audio stream could not stop: \(error.localizedDescription)"
            }
            throw error
        }
    }

    @MainActor
    private func stopExactStream(_ stream: any SystemAudioCaptureStream, revision: UInt64) async throws {
        guard let owned = ownershipLock.withLock({ () -> OwnedStream? in
            guard ownedStream?.stream === stream, ownedStream?.revision == revision else { return nil }
            return ownedStream
        }) else { return }
        let callbacks = callbackState.close(stream: stream, revision: revision)
        let nativeStop: Result<Void, Error>
        if owned.nativeStopAcknowledged {
            nativeStop = .success(())
        } else {
            do {
                try await stream.stopCapture()
                ownershipLock.withLock {
                    if ownedStream?.stream === stream, ownedStream?.revision == revision {
                        ownedStream?.nativeStopAcknowledged = true
                    }
                }
                nativeStop = .success(())
            } catch {
                // Report the stop error while admitted PCM is still being drained.
                // A failed SDK stop keeps the native stream/output ownership below.
                lastError = "System audio stream could not stop: \(error.localizedDescription)"
                nativeStop = .failure(error)
            }
        }
        // A native queue barrier consumes callbacks enqueued by SCStream. The
        // exact epoch's drain also covers callbacks already admitted at the
        // production input boundary, including controlled stream fixtures.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        await owned.callbackDrain.waitUntilDrained()
        for callback in callbacks { await callback.value }
        try nativeStop.get()
        if owned.audioOutputRegistered {
            try owned.removeOutput(self, .audio)
            ownershipLock.withLock {
                if ownedStream?.stream === stream, ownedStream?.revision == revision {
                    ownedStream?.audioOutputRegistered = false
                }
            }
        }
        if owned.screenOutputRegistered {
            try owned.removeOutput(self, .screen)
            ownershipLock.withLock {
                if ownedStream?.stream === stream, ownedStream?.revision == revision {
                    ownedStream?.screenOutputRegistered = false
                }
            }
        }
        ownershipLock.withLock {
            if ownedStream?.stream === stream, ownedStream?.revision == revision { ownedStream = nil }
        }
    }

    // MARK: - SCStreamOutput conformance

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        receiveAudioSampleBuffer(sampleBuffer, sourceID: ObjectIdentifier(stream))
    }

    // SCStreamDelegate uses the same source identity boundary as fixtures.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        receiveStreamFailure(error, sourceID: ObjectIdentifier(stream))
    }

    // Callback admission closes before waiting on UI. Error events do not
    // count as PCM, and a failed old stream cannot stop a replacement epoch.
    nonisolated func receiveStreamFailure(_ error: Error, from source: any SystemAudioCaptureStream) {
        receiveStreamFailure(error, sourceID: source.callbackIdentity)
    }

    nonisolated private func receiveStreamFailure(_ error: Error, sourceID: ObjectIdentifier) {
        callbackState.fail(from: sourceID, invalidate: { revision in
            self.startFence.invalidateIfCurrent(revision)
        }) { [weak self] revision, failureRevision in
            guard let self, self.startFence.isCurrent(failureRevision),
                  let capturedReceipt = self.ownershipLock.withLock({ () -> SystemAudioCaptureStopReceipt? in
                      guard let owned = self.ownedStream, owned.revision == revision,
                            owned.stream.callbackIdentity == sourceID else { return nil }
                      return owned.receipt
                  }) else { return }
            self.lastError = "System audio stream stopped: \(error.localizedDescription)"
            self.notifyFailure(error: error, capturedReceipt: capturedReceipt)
            self.stopSystemAudioCapture(capturedReceipt: capturedReceipt, retryFailed: false)
        }
    }

    // This is the actual callback boundary, also used by synthetic stream fixtures.
    nonisolated func receiveAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, from source: any SystemAudioCaptureStream) {
        receiveAudioSampleBuffer(sampleBuffer, sourceID: source.callbackIdentity)
    }

    nonisolated private func receiveAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, sourceID: ObjectIdentifier) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        callbackState.withAdmittedSource(sourceID) { revision, count, captureID in
            guard startFence.isCurrent(revision) else { return }
            do {
                // SDK input is borrowed synchronously by this checked leaf;
                // converter/log state never crosses to the UI or a Task.
                let verificationHostBefore = VerificationTiming.hostTicks()
                let (buffer, metrics) = try pcmProcessor.process(sampleBuffer, count: count)
                if let verificationHostBefore {
                    verificationPCM?.observe(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                        nativeSampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
                        callbackSourceIdentity: "capture_receipt:" + captureID.uuidString, captureRevision: revision,
                        hostBefore: verificationHostBefore)
                }
                guard startFence.isCurrent(revision) else { return }
                let snapshot = SystemAudioDisplaySnapshot(revision: revision, source: sourceID,
                    receivedAt: Date(), count: count, sampleRate: buffer.format.sampleRate,
                    channels: Int(buffer.format.channelCount), frames: Int(buffer.frameLength),
                    rms: metrics?.rms, decibels: metrics?.decibels)
                callbackState.offer(snapshot) { [weak self] snapshot in
                    self?.publish(snapshot)
                }
                let time = AVAudioTime(hostTime: mach_absolute_time())
                let activeDelegates = delegateRegistry.snapshot(captureID: captureID)
                for delegate in activeDelegates {
                    guard startFence.isCurrent(revision) else { break }
                    delegate.systemAudioCaptureService(self, didReceive: buffer, at: time)
                }
            } catch {
                callbackState.fail(revision: revision) { [weak self] in
                    guard let self, self.startFence.isCurrent(revision),
                          let capturedReceipt = self.ownershipLock.withLock({ () -> SystemAudioCaptureStopReceipt? in
                              guard let owned = self.ownedStream, owned.revision == revision,
                                    owned.stream.callbackIdentity == sourceID else { return nil }
                              return owned.receipt
                          }) else { return }
                    self.lastError = "Audio conversion failed: \(error.localizedDescription)"
                    self.notifyFailure(error: error, capturedReceipt: capturedReceipt)
                    self.stopSystemAudioCapture(capturedReceipt: capturedReceipt, retryFailed: false)
                }
            }
        }
    }

    @MainActor
    private func resetDisplayLevels() {
        var value = displaySource.value
        value.rms = 0
        value.decibels = -90
        displaySource.send(value)
        objectWillChange.send()
    }

    @MainActor
    private func publish(_ snapshot: SystemAudioDisplaySnapshot) {
        guard startFence.isCurrent(snapshot.revision), callbackState.matches(snapshot) else { return }
        var value = displaySource.value
        value.revision = snapshot.revision
        value.receivedAt = snapshot.receivedAt
        value.count = snapshot.count
        value.sampleRate = snapshot.sampleRate
        value.channels = snapshot.channels
        value.frames = snapshot.frames
        if let rms = snapshot.rms, let db = snapshot.decibels,
           snapshot.receivedAt.timeIntervalSince(lastUpdateTimestamp) >= 0.04 {
            lastUpdateTimestamp = snapshot.receivedAt
            let alpha = 0.3
            value.rms = alpha * rms + (1 - alpha) * value.rms
            value.decibels = alpha * max(db, -90) + (1 - alpha) * value.decibels
        }
        // A reentrant subscriber can replace capture. No state writes follow.
        displaySource.send(value)
        objectWillChange.send()
    }

    @MainActor
    private func notifyFailure(error: Error, capturedReceipt: SystemAudioCaptureStopReceipt) {
        let activeDelegates = delegateRegistry.snapshot(captureID: capturedReceipt.id)
        for delegate in activeDelegates {
            // A synchronous observer/delegate may submit a replacement. Stop
            // still belongs to this old receipt; its error cannot enter the new
            // round's delegates. Stopping the same receipt preserves delivery.
            guard teardownReceipt === capturedReceipt else { return }
            delegate.systemAudioCaptureService(self, didFailWithError: error)
        }
    }
}

/// Stop invalidates pending framework awaits even before an SCStream exists.
final class CaptureStartFence: Sendable {
    private let revision = OSAllocatedUnfairLock(initialState: UInt64(0))
    func begin() -> UInt64 { revision.withLock { $0 &+= 1; return $0 } }
    func invalidate() { revision.withLock { $0 &+= 1 } }
    func invalidateIfCurrent(_ token: UInt64) -> UInt64? {
        revision.withLock {
            guard token == $0 else { return nil }
            $0 &+= 1
            return $0
        }
    }
    func isCurrent(_ token: UInt64) -> Bool { revision.withLock { token == $0 } }
}

private struct SystemAudioDisplayState: Sendable {
    var revision: UInt64?
    var receivedAt: Date?
    var count = 0
    var sampleRate: Double = 0
    var channels = 0
    var frames = 0
    var rms: Double = 0
    var decibels: Double = -90
}

private struct SystemAudioDisplaySnapshot: Sendable {
    let revision: UInt64
    let source: ObjectIdentifier
    let receivedAt: Date
    let count: Int
    let sampleRate: Double
    let channels: Int
    let frames: Int
    let rms: Double?
    let decibels: Double?
}

/// Numeric display snapshots coalesce, while one terminal control event is
/// retained and joined. Admission never holds this lock over native conversion,
/// delegate append, await, or a synchronous UI wait.
private final class SystemAudioCallbackState: Sendable {
    private struct State: Sendable {
        var source: ObjectIdentifier?
        var revision: UInt64?
        var captureID: UUID?
        var drain: SystemAudioCallbackDrain?
        var samplesReceived = false
        var totalBuffers = 0
        var snapshot: SystemAudioDisplaySnapshot?
        var displayTask: (id: UUID, task: Task<Void, Never>)?
        var failureTask: (id: UUID, task: Task<Void, Never>)?
    }
    private let storage = OSAllocatedUnfairLock(initialState: State())
    var pendingDisplayUpdates: Int { storage.withLock { $0.displayTask == nil ? 0 : 1 } }

    func open(stream: any SystemAudioCaptureStream, revision: UInt64, captureID: UUID, drain: SystemAudioCallbackDrain) {
        let source = stream.callbackIdentity
        storage.withLock {
            $0.source = source
            $0.revision = revision
            $0.captureID = captureID
            $0.drain = drain
            $0.samplesReceived = false
        }
    }

    func withAdmittedSource(_ sourceID: ObjectIdentifier, body: (UInt64, Int, UUID) -> Void) {
        let admitted = storage.withLock { state -> (revision: UInt64, count: Int, captureID: UUID, drain: SystemAudioCallbackDrain)? in
            guard state.source == sourceID, let revision = state.revision, let captureID = state.captureID, let drain = state.drain,
                  state.failureTask == nil else { return nil }
            drain.enter()
            state.samplesReceived = true
            state.totalBuffers += 1
            return (revision, state.totalBuffers, captureID, drain)
        }
        guard let admitted else { return }
        defer { admitted.drain.leave() }
        body(admitted.revision, admitted.count, admitted.captureID)
    }

    func hasReceivedSamples(revision: UInt64) -> Bool {
        storage.withLock { $0.revision == revision && $0.samplesReceived }
    }

    func matches(_ snapshot: SystemAudioDisplaySnapshot) -> Bool {
        storage.withLock { $0.revision == snapshot.revision && $0.source == snapshot.source }
    }

    func offer(_ value: SystemAudioDisplaySnapshot,
        publish: @escaping @MainActor @Sendable (SystemAudioDisplaySnapshot) -> Void) {
        storage.withLock { state in
            guard state.revision == value.revision, state.source == value.source,
                  state.failureTask == nil else { return }
            state.snapshot = value
            guard state.displayTask == nil else { return }
            let id = UUID()
            let task = Task { @MainActor in
                let value = self.storage.withLock { state -> SystemAudioDisplaySnapshot? in
                    guard state.displayTask?.id == id else { return nil }
                    let value = state.snapshot
                    state.snapshot = nil
                    state.displayTask = nil
                    return value
                }
                if let value, !Task.isCancelled { publish(value) }
            }
            state.displayTask = (id, task)
        }
    }

    func fail(from sourceID: ObjectIdentifier, invalidate: @Sendable (UInt64) -> UInt64?,
        action: @escaping @MainActor @Sendable (UInt64, UInt64) -> Void) {
        storage.withLock { state in
            guard state.source == sourceID, let revision = state.revision, state.failureTask == nil,
                  let failureRevision = invalidate(revision) else { return }
            installFailure(in: &state) { action(revision, failureRevision) }
        }
    }

    func fail(revision: UInt64, action: @escaping @MainActor @Sendable () -> Void) {
        storage.withLock { state in
            guard state.revision == revision, state.failureTask == nil else { return }
            installFailure(in: &state, action: action)
        }
    }

    // The caller holds storage once; this helper never recursively takes it.
    private func installFailure(in state: inout State,
        action: @escaping @MainActor @Sendable () -> Void) {
        let id = UUID()
        let task = Task { @MainActor in
            if !Task.isCancelled { action() }
            self.storage.withLock {
                if $0.failureTask?.id == id { $0.failureTask = nil }
            }
        }
        state.failureTask = (id, task)
    }

    func close(stream: (any SystemAudioCaptureStream)? = nil,
        revision expectedRevision: UInt64? = nil) -> [Task<Void, Never>] {
        let source = stream?.callbackIdentity
        let closed = storage.withLock { state -> (display: Task<Void, Never>?, tasks: [Task<Void, Never>]) in
            if let source, state.source != source { return (nil, []) }
            if let expectedRevision, state.revision != expectedRevision { return (nil, []) }
            state.source = nil
            state.revision = nil
            state.captureID = nil
            state.drain = nil
            state.snapshot = nil
            let display = state.displayTask?.task
            let tasks = [display, state.failureTask?.task].compactMap { $0 }
            state.displayTask = nil
            state.failureTask = nil
            return (display, tasks)
        }
        // Cancelling replaceable display work does not cancel the one failure
        // event. Its exact epoch check/publication remains retained by stop.
        closed.display?.cancel()
        return closed.tasks
    }
}

/// One epoch retains in-flight synchronous PCM borrows after admission closes.
/// Waiters are resumed outside the lock; no thread or actor waits synchronously
/// for a delegate to return, and no later epoch can enter this drain.
private final class SystemAudioCallbackDrain: Sendable {
    private struct State {
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func enter() { state.withLock { $0.inFlight += 1 } }

    func leave() {
        let finished = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            precondition(state.inFlight > 0)
            state.inFlight -= 1
            guard state.inFlight == 0 else { return [] }
            let finished = state.waiters
            state.waiters.removeAll()
            return finished
        }
        finished.forEach { $0.resume() }
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let alreadyDrained = state.withLock { state in
                guard state.inFlight > 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyDrained { continuation.resume() }
        }
    }
}

/// Synchronous SDK input/output is borrowed only by the calling native queue.
/// Converter cache and log cadence are private lock-held state; no native
/// buffer, converter or format is sent into an actor Task.
private final class SystemAudioPCMProcessor: Sendable {
    private struct State {
        let converter = SampleBufferAudioConverter()
        var lastLogTimestamp = Date.distantPast
    }
    private let storage = OSAllocatedUnfairLock(uncheckedState: State())

    func process(_ sample: CMSampleBuffer, count: Int) throws
        -> (AVAudioPCMBuffer, (rms: Double, decibels: Double)?) {
        try storage.withLockUnchecked { state in
            let buffer = try state.converter.convert(sampleBuffer: sample)
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let metrics = Self.calculateMetrics(from: buffer, timestamp: timestamp,
                count: count, lastLogTimestamp: &state.lastLogTimestamp)
            return (buffer, metrics)
        }
    }

    private static func calculateMetrics(from buffer: AVAudioPCMBuffer, timestamp: Double, count: Int, lastLogTimestamp: inout Date) -> (rms: Double, decibels: Double)? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return nil }
        let sampleStride = buffer.stride
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame * sampleStride]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(channelCount * frameLength))
        let db = 20 * log10(max(Double(rms), 0.000_001))
        let now = Date()
        if now.timeIntervalSince(lastLogTimestamp) >= 1 {
            lastLogTimestamp = now
            print(String(format: "[ScreenCaptureKitSystemAudioCaptureService] Real CMSampleBuffer received: timestamp = %.3f s | Converted format = %@ | sampleRate = %.1f Hz | channelCount = %d | frameLength = %d | system audio dBFS = %.1f dB | totalBuffers = %d",
                timestamp, buffer.format.description, buffer.format.sampleRate,
                channelCount, frameLength, db, count))
        }
        return (Double(rms), db)
    }

}

/// Membership is synchronized separately from delivery. Strong snapshots are
/// borrowed for synchronous callbacks after unlock; no delegate or SDK buffer
/// is captured across an await. The protocol's existing callback executor
/// contract remains unchanged and does not claim all backends are Sendable.
private final class SystemAudioDelegateRegistry: Sendable {
    private struct WeakDelegate {
        weak var value: (any SystemAudioBufferDelegate)?
        let captureID: UUID?
    }
    private let storage = OSAllocatedUnfairLock(uncheckedState: [WeakDelegate]())

    func register(_ delegate: any SystemAudioBufferDelegate, captureID: UUID?) {
        storage.withLockUnchecked {
            $0.removeAll { $0.value === delegate || $0.value == nil }
            $0.append(WeakDelegate(value: delegate, captureID: captureID))
        }
    }

    func unregister(_ delegate: any SystemAudioBufferDelegate) {
        storage.withLockUnchecked { $0.removeAll { $0.value === delegate || $0.value == nil } }
    }

    func snapshot(captureID: UUID) -> [any SystemAudioBufferDelegate] {
        storage.withLockUnchecked { values in
            values.compactMap { entry in
                guard entry.captureID == nil || entry.captureID == captureID else { return nil }
                return entry.value
            }
        }
    }
}
