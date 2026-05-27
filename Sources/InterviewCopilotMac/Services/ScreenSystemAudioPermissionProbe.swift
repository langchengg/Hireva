import Foundation
import ScreenCaptureKit
import CoreGraphics
import AVFoundation

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

    private init() {}

    func probe() async -> ScreenSystemAudioPermissionProbeResult {
        if let mock = ScreenSystemAudioPermissionProbe.mockProbe {
            return await mock()
        }
        let preflight = CGPreflightScreenCaptureAccess()
        
        var shareableSucceeded = false
        var streamSucceeded = false
        var errorDescription: String? = nil
        var likelyIdentityMismatch = false
        
        // 1. Check identity parameters
        let expectedBundleID = "com.langcheng.InterviewCopilotMac"
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
                errorDescription = "Audio stream started but timed out waiting for audio sample buffers."
            }
        }
        
        return ScreenSystemAudioPermissionProbeResult(
            preflightGranted: preflight,
            shareableContentProbeSucceeded: shareableSucceeded,
            streamAudioProbeSucceeded: streamSucceeded,
            errorDescription: errorDescription,
            likelyIdentityMismatch: likelyIdentityMismatch
        )
    }
}

fileprivate final class StreamAudioProbeHelper: NSObject, SCStreamOutput {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var stream: SCStream?
    
    func runProbe(display: SCDisplay) async -> Bool {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        
        let queue = DispatchQueue(label: "com.langcheng.InterviewCopilotMac.streamProbeQueue")
        
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            
            do {
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                self.stream = stream
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                
                Task {
                    do {
                        try await stream.startCapture()
                        // Wait up to 1.5 seconds for at least one audio sample buffer callback
                        try? await Task.sleep(for: .milliseconds(1500))
                        self.finish(succeeded: false)
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
