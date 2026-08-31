import Foundation
import ScreenCaptureKit
import CoreGraphics
import AVFoundation

struct ScreenSystemAudioPermissionProbeResult: Hashable, Sendable {
    let preflightGranted: Bool
    let shareableContentProbeSucceeded: Bool
    let streamAudioProbeSucceeded: Bool
    let errorDescription: String?
    let likelyIdentityMismatch: Bool
}

protocol ScreenSystemAudioPermissionProbing: Sendable {
    func probe() async -> ScreenSystemAudioPermissionProbeResult
}

private actor ScreenSystemAudioProbeLifecycleCoordinator {
    private enum State {
        case idle
        case starting
        case started
        case stopping(Task<Bool, Never>)
        case stopped(Bool)
    }

    private let startOperation: @Sendable () async throws -> Void
    private let stopOperation: @Sendable () async throws -> Void
    private var state = State.idle

    init(
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async throws -> Void
    ) {
        startOperation = start
        stopOperation = stop
    }

    func start() async -> Bool {
        guard case .idle = state else { return false }

        do {
            try Task.checkCancellation()
            state = .starting
            try await startOperation()
            if case .starting = state {
                state = .started
            }
            return true
        } catch {
            // Leave a partially started operation eligible for the shared
            // stop path. ScreenCaptureKit can fail after allocating resources.
            return false
        }
    }

    func stop() async -> Bool {
        switch state {
        case .idle:
            // A cancellation can win before start enters the actor. Marking
            // the lifecycle stopped prevents a late start from beginning.
            state = .stopped(true)
            return true
        case .stopping(let task):
            return await task.value
        case .stopped(let succeeded):
            return succeeded
        case .starting, .started:
            let stopOperation = self.stopOperation
            let task = Task {
                do {
                    try await stopOperation()
                    return true
                } catch {
                    return false
                }
            }
            state = .stopping(task)
            let succeeded = await task.value
            state = .stopped(succeeded)
            return succeeded
        }
    }
}

enum ScreenSystemAudioProbeLifecycle {
    static func run(
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let coordinator = ScreenSystemAudioProbeLifecycleCoordinator(
            start: start,
            stop: stop
        )

        return await withTaskCancellationHandler {
            let started = await coordinator.start()
            let stopped = await coordinator.stop()
            return started && stopped && !Task.isCancelled
        } onCancel: {
            Task {
                _ = await coordinator.stop()
            }
        }
    }
}

final class ScreenSystemAudioPermissionProbe: ScreenSystemAudioPermissionProbing, @unchecked Sendable {
    static let shared = ScreenSystemAudioPermissionProbe()
    static var mockProbe: (() async -> ScreenSystemAudioPermissionProbeResult)?

    private init() {}

    func probe() async -> ScreenSystemAudioPermissionProbeResult {
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
        let preflight = CGPreflightScreenCaptureAccess()

        guard !Task.isCancelled else {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: preflight,
                shareableContentProbeSucceeded: false,
                streamAudioProbeSucceeded: false,
                errorDescription: "System audio verification was cancelled.",
                likelyIdentityMismatch: false
            )
        }
        
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

        // 2. SCShareableContent probe
        let shareableContent: SCShareableContent?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            shareableContent = content
            shareableSucceeded = true
        } catch {
            errorDescription = "Screen & System Audio Recording permission check failed."
            shareableContent = nil
            
            // If preflight says true but SCShareableContent fails with typical access denied, it indicates mismatch!
            let nsError = error as NSError
            if preflight && (nsError.code == -3801 || nsError.localizedDescription.contains("permission") || nsError.localizedDescription.contains("denied")) {
                likelyIdentityMismatch = true
            }
        }

        guard !Task.isCancelled else {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: preflight,
                shareableContentProbeSucceeded: shareableSucceeded,
                streamAudioProbeSucceeded: false,
                errorDescription: "System audio verification was cancelled.",
                likelyIdentityMismatch: likelyIdentityMismatch
            )
        }
        
        // 3. Minimal SCStream audio probe
        if shareableSucceeded, let display = shareableContent?.displays.first {
            let streamHelper = StreamAudioProbeHelper()
            streamSucceeded = await streamHelper.runProbe(display: display)
            if !streamSucceeded {
                errorDescription = "Audio stream failed to start."
            }
        }
        
        let result = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: preflight,
            shareableContentProbeSucceeded: shareableSucceeded,
            streamAudioProbeSucceeded: streamSucceeded,
            errorDescription: errorDescription,
            likelyIdentityMismatch: likelyIdentityMismatch
        )
        PrivacySafeLogger.screenSystemAudioPermissionProbe(
            preflightGranted: result.preflightGranted,
            shareableContentSucceeded: result.shareableContentProbeSucceeded,
            streamAudioSucceeded: result.streamAudioProbeSucceeded,
            identityMismatch: result.likelyIdentityMismatch
        )
        return result
    }
}

fileprivate final class StreamAudioProbeHelper: NSObject, SCStreamOutput {
    func runProbe(display: SCDisplay) async -> Bool {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 3
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        
        let queue = DispatchQueue(label: "com.langcheng.Hireva.streamProbeQueue")
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        } catch {
            return false
        }

        // This is a permission/startup probe, not an audio-activity meter. A
        // successful start is sufficient, but the probe must await teardown
        // before the caller is allowed to start the production stream.
        return await ScreenSystemAudioProbeLifecycle.run(
            start: { try await stream.startCapture() },
            stop: { try await stream.stopCapture() }
        )
    }
    
    func stream(_: SCStream, didOutputSampleBuffer _: CMSampleBuffer, of _: SCStreamOutputType) {}
}
