import Foundation
import ScreenCaptureKit
import CoreGraphics
import AVFoundation
import OSLog

struct ScreenSystemAudioPermissionProbeResult: Hashable, Sendable {
    let preflightGranted: Bool
    let shareableContentProbeSucceeded: Bool
    let streamAudioProbeSucceeded: Bool
    let errorDescription: String?
    let likelyIdentityMismatch: Bool
}

@MainActor
final class ScreenSystemAudioPermissionProbe {
    static let shared = ScreenSystemAudioPermissionProbe()
    static var mockProbe: (() async -> ScreenSystemAudioPermissionProbeResult)?
    private let logger = Logger(
        subsystem: HirevaProductIdentity.bundleIdentifier,
        category: "ScreenSystemAudioPermissionProbe"
    )

    @MainActor private var activeStreamProbe: StreamAudioProbeHelper?

    private init() {}

    // Native I/O seam: the wrapper still executes its actual stop contract.
    init(streamProbeForTesting: StreamAudioProbeHelper) {
        activeStreamProbe = streamProbeForTesting
    }

    @MainActor
    func probe(
        verification: HirevaVerificationConfiguration? = .current
    ) async -> ScreenSystemAudioPermissionProbeResult {
        if isRunningUnderTestOrAutomation() {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }
        if let mock = ScreenSystemAudioPermissionProbe.mockProbe {
            return await mock()
        }
        let permissionAdmission = VerificationPermissionAdmission.resolve(verification: verification,
            environment: ProcessInfo.processInfo.environment,
            verificationOnlyBundle: Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool == true)
        do {
            try SystemAudioCaptureFilterPolicy.validateNativeCapture(verification: verification)
        } catch {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: CGPreflightScreenCaptureAccess(),
                shareableContentProbeSucceeded: false,
                streamAudioProbeSucceeded: false,
                errorDescription: error.localizedDescription,
                likelyIdentityMismatch: false
            )
        }
        let preflight = CGPreflightScreenCaptureAccess()

        var shareableSucceeded = false
        var streamSucceeded = false
        var errorDescription: String? = nil
        var likelyIdentityMismatch = false

        // 1. Check identity parameters
        let expectedBundleID = HirevaProductIdentity.bundleIdentifier
        let actualBundleID = Bundle.main.bundleIdentifier ?? ""
        let runningFromApp = Bundle.main.bundlePath.hasSuffix(".app")

        // Check if executable path belongs to currently launched .app bundle
        let processPath = CommandLine.arguments.first ?? ""
        let runningFromCorrectPath = !processPath.isEmpty && processPath.hasPrefix(Bundle.main.bundlePath)

        if actualBundleID != expectedBundleID || !runningFromApp || !runningFromCorrectPath {
            likelyIdentityMismatch = true
        }

        // A failed native stop retains its exact helper; a concurrent probe must
        // not create another stream while the prior round still owns resources.
        if let activeStreamProbe, activeStreamProbe.hasPendingProbeResult || activeStreamProbe.hasUnreleasedStream {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: preflight,
                shareableContentProbeSucceeded: false,
                streamAudioProbeSucceeded: false,
                errorDescription: activeStreamProbe.lastFailureDescription ?? "System audio permission probe is still stopping.",
                likelyIdentityMismatch: likelyIdentityMismatch
            )
        }

        // 2. SCShareableContent probe
        let shareableContent: SCShareableContent?
        do {
            let content = try await NativeSystemAudioCaptureStream.shareableContent(
                permissionAdmission: permissionAdmission)
            shareableContent = content
            shareableSucceeded = true
        } catch {
            errorDescription = error.localizedDescription
            shareableContent = nil

            // If preflight says true but SCShareableContent fails with typical access denied, it indicates mismatch!
            let nsError = error as NSError
            if preflight && (nsError.code == -3801 || nsError.localizedDescription.contains("permission") || nsError.localizedDescription.contains("denied")) {
                likelyIdentityMismatch = true
            }
        }

        // 3. Minimal SCStream audio probe
        if shareableSucceeded, !Task.isCancelled, let display = shareableContent?.displays.first {
            // SCShareableContent is an await boundary; another caller may have
            // acquired the native stream while this request was suspended.
            if let activeStreamProbe, activeStreamProbe.hasPendingProbeResult || activeStreamProbe.hasUnreleasedStream {
                return ScreenSystemAudioPermissionProbeResult(
                    preflightGranted: preflight,
                    shareableContentProbeSucceeded: shareableSucceeded,
                    streamAudioProbeSucceeded: false,
                    errorDescription: activeStreamProbe.lastFailureDescription ?? "System audio permission probe is still stopping.",
                    likelyIdentityMismatch: likelyIdentityMismatch
                )
            }
            let streamHelper = StreamAudioProbeHelper()
            activeStreamProbe = streamHelper
            streamSucceeded = await streamHelper.runProbe(
                display: display,
                applications: shareableContent?.applications ?? [],
                verification: verification,
                permissionAdmission: permissionAdmission
            )
            if activeStreamProbe === streamHelper, !streamHelper.hasUnreleasedStream {
                activeStreamProbe = nil
            }
            if !streamSucceeded {
                errorDescription = streamHelper.lastFailureDescription ?? "Audio stream failed to start or was cancelled."
            }
        } else if shareableSucceeded {
            errorDescription = Task.isCancelled
                ? "System audio stream probe was cancelled before capture."
                : "No capture display available; system audio stream probe was not attempted."
        }

        let result = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: preflight,
            shareableContentProbeSucceeded: shareableSucceeded,
            streamAudioProbeSucceeded: streamSucceeded,
            errorDescription: errorDescription,
            likelyIdentityMismatch: likelyIdentityMismatch
        )
        logger.info("probe preflight=\(result.preflightGranted) shareable=\(result.shareableContentProbeSucceeded) stream=\(result.streamAudioProbeSucceeded) identityMismatch=\(result.likelyIdentityMismatch) error=\(result.errorDescription ?? "nil", privacy: .public)")
        return result
    }

    /// Automatic cancellation and handoff only join the owned attempt. An
    /// explicit shutdown may retry a failure already observed at submission.
    @MainActor
    func finishStoppingProbe(retryFailedResource: Bool = false) async throws {
        guard let helper = activeStreamProbe else { return }
        try await helper.stop(retryFailedResource: retryFailedResource)
        if activeStreamProbe === helper { activeStreamProbe = nil }
    }

    @MainActor
    static func createFilteredProbeStream<Filter, Stream>(
        verification: HirevaVerificationConfiguration?,
        applications: [(processID: Int32, bundleIdentifier: String)],
        filterFactory: @MainActor (SystemAudioCaptureFilterSelection) throws -> Filter,
        streamFactory: @MainActor (Filter) throws -> Stream
    ) throws -> Stream {
        let selection = try SystemAudioCaptureFilterPolicy.select(verification: verification, applications: applications)
        let filter = try filterFactory(selection)
        return try streamFactory(filter)
    }
}

@MainActor
final class StreamAudioProbeHelper: NSObject, SCStreamOutput {
    private struct OwnedStream {
        let id: UUID
        let stream: any SystemAudioCaptureStream
        let removeOutput: @MainActor (any SCStreamOutput, SCStreamOutputType) throws -> Void
        var screenOutputRegistered = false
        var audioOutputRegistered = false
        var nativeStopAcknowledged = false
    }
    @MainActor private var ownedStream: OwnedStream?
    @MainActor private var work: (id: UUID, task: Task<Bool, Never>)?
    private struct Cleanup {
        let id: UUID
        let roundID: UUID
        let task: Task<Void, Error>
        var failed = false
    }
    @MainActor private var cleanup: Cleanup?
    @MainActor private(set) var lastFailureDescription: String?
    @MainActor var hasPendingProbeResult: Bool { work != nil }
    @MainActor var hasUnreleasedStream: Bool { ownedStream != nil }
    private let queue = DispatchQueue(label: "com.langcheng.Hireva.streamProbeQueue")
    private let registeredOutputsForTesting: Set<SCStreamOutputType>
    private let removeOutputForTesting: (@MainActor (any SystemAudioCaptureStream, SCStreamOutputType) throws -> Void)?

    override init() {
        registeredOutputsForTesting = []
        removeOutputForTesting = nil
        super.init()
    }

    init(registeredOutputsForTesting: Set<SCStreamOutputType>,
        removeOutputForTesting: @escaping @MainActor (any SystemAudioCaptureStream, SCStreamOutputType) throws -> Void) {
        self.registeredOutputsForTesting = registeredOutputsForTesting
        self.removeOutputForTesting = removeOutputForTesting
        super.init()
    }

    @MainActor
    func runProbe(
        display: SCDisplay,
        applications: [SCRunningApplication],
        verification: HirevaVerificationConfiguration?,
        permissionAdmission: VerificationPermissionAdmission
    ) async -> Bool {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 3
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        return await runProbe(makeStream: {
            try ScreenSystemAudioPermissionProbe.createFilteredProbeStream(
                verification: verification,
                applications: applications.map { ($0.processID, $0.bundleIdentifier) },
                filterFactory: { selection in
                    switch selection {
                    case .allDisplay:
                        return SCContentFilter(display: display, excludingWindows: [])
                    case .application(let index):
                        return SCContentFilter(display: display, including: [applications[index]], exceptingWindows: [])
                    }
                },
                streamFactory: { filter in
                    NativeSystemAudioCaptureStream(native: SCStream(filter: filter, configuration: config, delegate: nil),
                        permissionAdmission: permissionAdmission)
                }
            )
        })
    }

    @MainActor
    func runProbe(makeStream: @escaping @MainActor () throws -> any SystemAudioCaptureStream) async -> Bool {
        guard work == nil, cleanup == nil, ownedStream == nil else { return false }
        lastFailureDescription = nil
        let id = UUID()
        let task = Task { @MainActor in
            var started = false
            do {
                try Task.checkCancellation()
                let stream = try makeStream()
                let removeOutput: @MainActor (any SCStreamOutput, SCStreamOutputType) throws -> Void
                if let testing = self.removeOutputForTesting {
                    removeOutput = { _, type in try testing(stream, type) }
                } else if let native = (stream as? NativeSystemAudioCaptureStream)?.native {
                    removeOutput = { output, type in try native.removeStreamOutput(output, type: type) }
                } else { removeOutput = { _, _ in } }
                self.ownedStream = OwnedStream(id: id, stream: stream, removeOutput: removeOutput)
                if self.removeOutputForTesting != nil {
                    self.ownedStream?.audioOutputRegistered = self.registeredOutputsForTesting.contains(.audio)
                    self.ownedStream?.screenOutputRegistered = self.registeredOutputsForTesting.contains(.screen)
                }
                if let native = (stream as? NativeSystemAudioCaptureStream)?.native {
                    try native.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    self.ownedStream?.screenOutputRegistered = true
                    try native.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                    self.ownedStream?.audioOutputRegistered = true
                }
                try await stream.startCapture()
                started = true
            } catch {
                self.lastFailureDescription = error.localizedDescription
            }
            do { try await self.finishCleanup(roundID: id) }
            catch { self.lastFailureDescription = "Audio permission probe could not stop: \(error.localizedDescription)" }
            return started && !Task.isCancelled && self.ownedStream == nil
        }
        work = (id, task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if work?.id == id { work = nil }
        return result && !Task.isCancelled
    }

    @MainActor
    func stop(retryFailedResource: Bool = true) async throws {
        let roundID = work?.id ?? ownedStream?.id
        // Authorization freezes the already observed failed attempt. A failure
        // created during the startup await is joined, never silently retried.
        let retryingFailedAttempt = retryFailedResource && cleanup?.failed == true ? cleanup?.id : nil
        if let current = work {
            current.task.cancel()
            _ = await current.task.value
            if work?.id == current.id { work = nil }
        }
        // Capture the round before awaiting: an old stop must not release a
        // later round even if the same helper instance is reused.
        if let roundID { try await finishCleanup(roundID: roundID, retryingFailedAttempt: retryingFailedAttempt) }
    }

    @MainActor
    private func finishCleanup(roundID: UUID, retryingFailedAttempt: UUID? = nil) async throws {
        guard ownedStream?.id == roundID else { return }
        let current: Cleanup
        if let cleanup, !cleanup.failed || cleanup.id != retryingFailedAttempt {
            current = cleanup
        } else {
            let id = UUID()
            // Outcome retires inside this exact worker before any waiter
            // returns. Borrowers never depend on the original caller resuming.
            let task = Task { @MainActor in
                do {
                    try await self.releaseOwnedStream(roundID: roundID)
                    if self.cleanup?.id == id { self.cleanup = nil }
                } catch {
                    if self.cleanup?.id == id { self.cleanup?.failed = true }
                    throw error
                }
            }
            current = Cleanup(id: id, roundID: roundID, task: task)
            cleanup = current
        }
        try await current.task.value
    }

    @MainActor
    private func releaseOwnedStream(roundID: UUID) async throws {
        guard let current = ownedStream, current.id == roundID else { return }
        if !current.nativeStopAcknowledged {
            try await current.stream.stopCapture()
            guard ownedStream?.id == roundID, ownedStream?.stream === current.stream else { return }
            ownedStream?.nativeStopAcknowledged = true
        }
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        guard ownedStream?.id == roundID, ownedStream?.stream === current.stream else { return }
        if ownedStream?.audioOutputRegistered == true {
            try current.removeOutput(self, .audio)
            ownedStream?.audioOutputRegistered = false
        }
        if ownedStream?.screenOutputRegistered == true {
            try current.removeOutput(self, .screen)
            ownedStream?.screenOutputRegistered = false
        }
        ownedStream = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // An early SDK buffer cannot complete startup or release its stream.
        // The owned start/stop task is the permission-only result authority.
    }

    nonisolated func receiveAudio(from stream: any SystemAudioCaptureStream) {
        // Buffers can precede startCapture completion. The owned startup/stop
        // task determines this permission-only result; audio never finishes it.
    }
}
