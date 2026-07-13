import Foundation
import ScreenCaptureKit
import CoreGraphics
import AVFoundation
import OSLog

struct ScreenSystemAudioPermissionProbeResult: Hashable {
    let preflightGranted: Bool
    let shareableContentProbeSucceeded: Bool
    let streamAudioProbeSucceeded: Bool
    let errorDescription: String?
    let likelyIdentityMismatch: Bool
}

final class ScreenSystemAudioPermissionProbe {
    static let shared = ScreenSystemAudioPermissionProbe()
    static var mockProbe: (() async -> ScreenSystemAudioPermissionProbeResult)?
    private let logger = Logger(
        subsystem: HirevaProductIdentity.bundleIdentifier,
        category: "ScreenSystemAudioPermissionProbe"
    )

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
            errorDescription = error.localizedDescription
            shareableContent = nil
            
            // If preflight says true but SCShareableContent fails with typical access denied, it indicates mismatch!
            let nsError = error as NSError
            if preflight && (nsError.code == -3801 || nsError.localizedDescription.contains("permission") || nsError.localizedDescription.contains("denied")) {
                likelyIdentityMismatch = true
            }
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
        logger.info("probe preflight=\(result.preflightGranted) shareable=\(result.shareableContentProbeSucceeded) stream=\(result.streamAudioProbeSucceeded) identityMismatch=\(result.likelyIdentityMismatch) error=\(result.errorDescription ?? "nil", privacy: .public)")
        return result
    }
}

fileprivate final class StreamAudioProbeHelper: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var stream: SCStream?
    
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
        
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            
            do {
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                self.stream = stream
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                
                Task {
                    do {
                        try await stream.startCapture()
                        // This is a permission/startup probe, not an audio
                        // activity meter. The live capture service has its
                        // own watchdog for "stream started but no samples".
                        self.finish(succeeded: true)
                    } catch {
                        self.finish(succeeded: false)
                    }
                }
            } catch {
                self.finish(succeeded: false)
            }
        }
    }
    
    private func finish(succeeded: Bool) {
        if let continuation = self.continuation {
            self.continuation = nil
            Task {
                if let stream = self.stream {
                    try? await stream.stopCapture()
                }
                continuation.resume(returning: succeeded)
            }
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            finish(succeeded: true)
        }
    }
}
