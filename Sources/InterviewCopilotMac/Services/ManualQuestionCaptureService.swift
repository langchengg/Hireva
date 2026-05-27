import AVFoundation
import Foundation
import ScreenCaptureKit

public final class ManualQuestionCaptureService: NSObject, ObservableObject, SystemAudioBufferDelegate, AudioEngineBufferDelegate {
    public static let shared = ManualQuestionCaptureService()
    
    @Published public var isRecording = false
    @Published public var recordingDuration: Double = 0.0
    @Published public var rmsLevel: Double = 0.0
    @Published public var decibels: Double = -90.0
    @Published public var capturedBufferCount: Int = 0
    @Published public var lastBufferTimestamp: Date? = nil
    
    public private(set) var capturedBuffers: [AVAudioPCMBuffer] = []
    
    private var timer: Timer?
    private var maxSeconds: Int = 60
    private var onTimeoutTriggered: (() -> Void)?
    private var activeSource: ManualCaptureSource = .systemAudio
    
    private let queue = DispatchQueue(label: "com.interviewcopilot.manualcapture")
    
    private override init() {
        super.init()
    }
    
    public static var mockStartCapture: ((ManualCaptureSource, Int, @escaping () -> Void) async throws -> Void)?
    public static var mockStopCapture: (() -> [AVAudioPCMBuffer])?
    public static var mockCancelCapture: (() -> Void)?
    
    public var normalizedLevel: Double {
        min(max((decibels + 60) / 60, 0), 1)
    }
    
    @MainActor
    public func startCapture(
        source: ManualCaptureSource,
        maxDuration: Int = 60,
        onTimeout: @escaping () -> Void
    ) async throws {
        if let mock = ManualQuestionCaptureService.mockStartCapture {
            try await mock(source, maxDuration, onTimeout)
            return
        }
        
        self.isRecording = true
        self.recordingDuration = 0.0
        self.rmsLevel = 0.0
        self.decibels = -90.0
        self.capturedBufferCount = 0
        self.lastBufferTimestamp = nil
        self.capturedBuffers = []
        self.maxSeconds = maxDuration
        self.onTimeoutTriggered = onTimeout
        self.activeSource = source
        
        print("[ManualQuestionCapture] Starting capture using source = \(source.rawValue), maxDuration = \(maxDuration)")
        
        if source == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
            try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
        } else {
            AudioEngineManager.shared.register(self)
        }
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.recordingDuration += 0.1
                if self.recordingDuration >= Double(self.maxSeconds) {
                    print("[ManualQuestionCapture] Hard timeout of \(self.maxSeconds)s reached!")
                    self.timer?.invalidate()
                    self.timer = nil
                    self.onTimeoutTriggered?()
                }
            }
        }
    }
    
    @MainActor
    public func stopCaptureAndReturnBuffers() -> [AVAudioPCMBuffer] {
        if let mock = ManualQuestionCaptureService.mockStopCapture {
            return mock()
        }
        
        timer?.invalidate()
        timer = nil
        isRecording = false
        
        let buffers = capturedBuffers
        capturedBuffers = []
        
        if activeSource == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        } else {
            AudioEngineManager.shared.unregister(self)
        }
        
        print("[ManualQuestionCapture] Stopped capture. Compiled \(buffers.count) buffers.")
        return buffers
    }
    
    @MainActor
    public func cancelCapture() {
        if let mock = ManualQuestionCaptureService.mockCancelCapture {
            mock()
            return
        }
        
        timer?.invalidate()
        timer = nil
        isRecording = false
        capturedBuffers = []
        
        if activeSource == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        } else {
            AudioEngineManager.shared.unregister(self)
        }
        print("[ManualQuestionCapture] Cancelled capture.")
    }
    
    // MARK: - Metering helper
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        capturedBuffers.append(buffer)
        
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
        
        Task { @MainActor in
            self.rmsLevel = Double(rms)
            self.decibels = db
            self.capturedBufferCount = self.capturedBuffers.count
            self.lastBufferTimestamp = Date()
        }
    }
    
    // MARK: - SystemAudioBufferDelegate conformance
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        processBuffer(buffer)
    }
    
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[ManualQuestionCapture] ScreenCaptureKit stream error: \(error.localizedDescription)")
    }
    
    // MARK: - AudioEngineBufferDelegate conformance
    public func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        processBuffer(buffer)
    }
}
