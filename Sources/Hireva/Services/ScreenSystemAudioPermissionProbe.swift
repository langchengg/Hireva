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
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var stream: SCStream?
    private var isFinished = false
    
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
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isFinished {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                if Task.isCancelled {
                    finish(succeeded: false)
                    return
                }

                do {
                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

                    lock.lock()
                    let shouldStart = !isFinished
                    if shouldStart {
                        self.stream = stream
                    }
                    lock.unlock()

                    guard shouldStart else { return }

                    Task {
                        guard !self.hasFinished else { return }
                        do {
                            try await stream.startCapture()
                            if self.hasFinished {
                                try? await stream.stopCapture()
                                return
                            }
                            // This is a permission/startup probe, not an audio
                            // activity meter. The live capture service has its
                            // own watchdog for "stream started but no samples".
                            self.finish(succeeded: true)
                        } catch {
                            self.finish(succeeded: false)
                        }
                    }
                } catch {
                    finish(succeeded: false)
                }
            }
        } onCancel: {
            finish(succeeded: false)
        }
    }

    private var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    private func finish(succeeded: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let stream = self.stream
        self.stream = nil
        lock.unlock()

        continuation?.resume(returning: succeeded)
        if let stream {
            Task {
                try? await stream.stopCapture()
            }
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            finish(succeeded: true)
        }
    }
}
