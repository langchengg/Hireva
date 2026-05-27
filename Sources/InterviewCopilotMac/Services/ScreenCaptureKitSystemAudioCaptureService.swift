import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol SystemAudioBufferDelegate: AnyObject {
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    )

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    )
}

final class ScreenCaptureKitSystemAudioCaptureService: NSObject, SCStreamOutput, ObservableObject {
    static let shared = ScreenCaptureKitSystemAudioCaptureService()

    @Published var isCapturing = false
    @Published var rmsLevel: Double = 0
    @Published var decibels: Double = -90
    @Published var lastError: String?
    @Published var lastBufferReceivedAt: Date? = nil
    @Published var totalBuffersReceived: Int = 0
    @Published var sampleRate: Double = 0
    @Published var channelCount: Int = 0
    @Published var lastBufferFrameCapacity: Int = 0

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.interviewcopilot.systemaudiocapture")
    private let delegateQueue = DispatchQueue(label: "com.interviewcopilot.systemaudiodelegates")
    private var delegates: [WeakAudioBufferDelegateBox] = []
    
    private let converter = SampleBufferAudioConverter()
    private var lastUpdateTimestamp = Date.distantPast
    private var lastLogTimestamp = Date.distantPast
    
    private var sampleWatchdogTask: Task<Void, Never>?
    private var hasReceivedSamplesSinceStart = false

    var normalizedLevel: Double {
        min(max((decibels + 60) / 60, 0), 1)
    }

    private override init() {
        super.init()
    }

    func register(_ delegate: any SystemAudioBufferDelegate) {
        delegateQueue.sync {
            delegates.removeAll { $0.value == nil }
            let alreadyExists = delegates.contains { $0.value === delegate }
            if !alreadyExists {
                delegates.append(WeakAudioBufferDelegateBox(value: delegate))
            }
        }
    }

    func unregister(_ delegate: any SystemAudioBufferDelegate) {
        delegateQueue.sync {
            delegates.removeAll { $0.value === delegate || $0.value == nil }
        }
    }

    @MainActor
    func startSystemAudioCapture() async throws {
        lastError = nil
        stopSystemAudioCapture()

        // 1. Verify screen capture permissions
        let preflight = CGPreflightScreenCaptureAccess()
        var hasAccess = preflight
        let shareableContent: SCShareableContent
        
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            hasAccess = true
        } catch {
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

        guard let display = shareableContent.displays.first else {
            let errorMsg = "No shareable display detected."
            lastError = errorMsg
            throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        // 3. Create content filter
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 4. Configure stream configuration with dynamic video fallback
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        
        // Attempt premium tiny video size (16x16) to conserve system resources
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)

        var streamInstance: SCStream?
        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            streamInstance = stream
            print("[ScreenCaptureKitSystemAudioCaptureService] ScreenCaptureKit audio stream started with 16x16 resolution.")
        } catch {
            print("[ScreenCaptureKitSystemAudioCaptureService] Tiny 16x16 video stream configuration failed: \(error.localizedDescription). Falling back to native display stream configuration.")
            
            // Fallback to display's native width/height to avoid resolution rejection, but ignore video frames
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // Ultra slow video frames
            
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            streamInstance = stream
            print("[ScreenCaptureKitSystemAudioCaptureService] ScreenCaptureKit audio stream started with native fallback resolution.")
        }

        self.stream = streamInstance
        self.isCapturing = true
        
        // 5. Start sample delivery watchdog
        sampleWatchdogTask?.cancel()
        hasReceivedSamplesSinceStart = false
        sampleWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            } catch {
                return
            }
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            if self.isCapturing && !self.hasReceivedSamplesSinceStart {
                print("[ScreenCaptureKitSystemAudioCaptureService] Watchdog: Started capture but no audio samples received.")
                Task { @MainActor in
                    self.lastError = "System audio stream started but no samples received. Open a browser tab and play some audio (YouTube/music)."
                    self.notifyFailure(error: NSError(
                        domain: "ScreenCaptureKitSystemAudioCaptureService",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "System audio stream started but no samples received."]
                    ))
                }
            }
        }
    }

    func stopSystemAudioCapture() {
        sampleWatchdogTask?.cancel()
        sampleWatchdogTask = nil

        guard let stream = stream else { return }
        self.stream = nil
        self.isCapturing = false
        self.rmsLevel = 0
        self.decibels = -90
        
        let streamToStop = stream
        Task {
            try? await streamToStop.stopCapture()
        }
        print("[ScreenCaptureKitSystemAudioCaptureService] System audio capture stopped.")
    }

    // MARK: - SCStreamOutput conformance

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        
        if !hasReceivedSamplesSinceStart {
            hasReceivedSamplesSinceStart = true
        }
        
        Task { @MainActor in
            self.lastBufferReceivedAt = Date()
            self.totalBuffersReceived += 1
        }

        do {
            // Convert CMSampleBuffer audio into AVAudioPCMBuffer using our dedicated converter
            let pcmBuffer = try converter.convert(sampleBuffer: sampleBuffer)
            
            Task { @MainActor in
                self.sampleRate = pcmBuffer.format.sampleRate
                self.channelCount = Int(pcmBuffer.format.channelCount)
                self.lastBufferFrameCapacity = Int(pcmBuffer.frameLength)
            }
            
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let seconds = CMTimeGetSeconds(presentationTime)
            calculateMetrics(from: pcmBuffer, timestamp: seconds)
            
            let time = AVAudioTime(hostTime: mach_absolute_time())
            
            // Broadcast buffer to active delegates
            let activeDelegates: [any SystemAudioBufferDelegate] = delegateQueue.sync {
                delegates.compactMap { $0.value as? (any SystemAudioBufferDelegate) }
            }

            for delegate in activeDelegates {
                delegate.systemAudioCaptureService(self, didReceive: pcmBuffer, at: time)
            }
        } catch {
            print("[ScreenCaptureKitSystemAudioCaptureService] Audio conversion error: \(error.localizedDescription)")
            Task { @MainActor in
                self.lastError = "Audio conversion failed: \(error.localizedDescription)"
                self.notifyFailure(error: error)
            }
        }
    }

    private func calculateMetrics(from buffer: AVAudioPCMBuffer, timestamp: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(channelCount * frameLength))
        let db = 20 * log10(max(Double(rms), 0.000_001))

        let now = Date()
        if now.timeIntervalSince(self.lastLogTimestamp) >= 1.0 {
            self.lastLogTimestamp = now
            print(String(format: "[ScreenCaptureKitSystemAudioCaptureService] Real CMSampleBuffer received: timestamp = %.3f s | Converted format = %@ | sampleRate = %.1f Hz | channelCount = %d | frameLength = %d | system audio dBFS = %.1f dB | totalBuffers = %d",
                timestamp,
                buffer.format.description,
                buffer.format.sampleRate,
                channelCount,
                frameLength,
                db,
                self.totalBuffersReceived
            ))
        }

        Task { @MainActor in
            // Throttle level meter updates to 25 FPS (0.04s)
            guard now.timeIntervalSince(self.lastUpdateTimestamp) >= 0.04 else { return }
            self.lastUpdateTimestamp = now

            let alpha = 0.3
            self.rmsLevel = alpha * Double(rms) + (1.0 - alpha) * self.rmsLevel
            self.decibels = alpha * max(db, -90) + (1.0 - alpha) * self.decibels
        }
    }

    private func notifyFailure(error: Error) {
        let activeDelegates: [any SystemAudioBufferDelegate] = delegateQueue.sync {
            delegates.compactMap { $0.value as? (any SystemAudioBufferDelegate) }
        }
        for delegate in activeDelegates {
            delegate.systemAudioCaptureService(self, didFailWithError: error)
        }
    }
}
