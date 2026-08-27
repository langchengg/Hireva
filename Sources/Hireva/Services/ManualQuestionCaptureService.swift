import AVFoundation
import Foundation
import ScreenCaptureKit

final class ManualCaptureBufferStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.langcheng.hireva.manualcapture.buffers")
    private var buffers: [AVAudioPCMBuffer] = []
    private var acceptingBuffers = false

    func beginCapture() {
        queue.sync {
            buffers.removeAll(keepingCapacity: true)
            acceptingBuffers = true
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Int? {
        queue.sync {
            guard acceptingBuffers else { return nil }
            buffers.append(buffer)
            return buffers.count
        }
    }

    func drain() -> [AVAudioPCMBuffer] {
        queue.sync {
            let result = buffers
            buffers.removeAll(keepingCapacity: true)
            acceptingBuffers = false
            return result
        }
    }

    func removeAll() {
        queue.sync {
            acceptingBuffers = false
            buffers.removeAll(keepingCapacity: true)
        }
    }
    var count: Int { queue.sync { buffers.count } }
    var snapshot: [AVAudioPCMBuffer] { queue.sync { buffers } }
}

public final class ManualQuestionCaptureService: NSObject, ObservableObject, SystemAudioBufferDelegate, AudioEngineBufferDelegate {
    public static let shared = ManualQuestionCaptureService()
    
    @Published public var isRecording = false
    @Published public var recordingDuration: Double = 0.0
    @Published public var rmsLevel: Double = 0.0
    @Published public var decibels: Double = -90.0
    @Published public var capturedBufferCount: Int = 0
    @Published public var lastBufferTimestamp: Date? = nil
    
    public var capturedBuffers: [AVAudioPCMBuffer] { bufferStore.snapshot }
    
    private var timer: Timer?
    private var maxSeconds: Int = 60
    private var onTimeoutTriggered: (() -> Void)?
    private var onFatalCaptureError: ((Error) -> Void)?
    private var activeSource: ManualCaptureSource = .systemAudio
    
    private let bufferStore = ManualCaptureBufferStore()
    
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
        onTimeout: @escaping () -> Void,
        onFatalCaptureError: @escaping (Error) -> Void = { _ in }
    ) async throws {
        if let mock = ManualQuestionCaptureService.mockStartCapture {
            try await mock(source, maxDuration, onTimeout)
            return
        }

        // A new start replaces any stale prior registration. `cancelCapture`
        // is idempotent and leaves both shared capture backends detached.
        cancelCapture()
        self.recordingDuration = 0.0
        self.rmsLevel = 0.0
        self.decibels = -90.0
        self.capturedBufferCount = 0
        self.lastBufferTimestamp = nil
        self.bufferStore.beginCapture()
        self.maxSeconds = maxDuration
        self.onTimeoutTriggered = onTimeout
        self.onFatalCaptureError = onFatalCaptureError
        self.activeSource = source

        do {
            if source == .systemAudio {
                ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
                try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
            } else {
                try AudioEngineManager.shared.registerForCapture(self)
            }

            self.isRecording = true
            installRecordingTimer()
        } catch {
            rollbackFailedStart(source: source)
            throw error
        }
    }

    @MainActor
    private func rollbackFailedStart(source: ManualCaptureSource) {
        timer?.invalidate()
        timer = nil
        isRecording = false
        onTimeoutTriggered = nil
        onFatalCaptureError = nil
        bufferStore.removeAll()

        if source == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        } else {
            AudioEngineManager.shared.unregister(self)
        }
    }

    @MainActor
    private func installRecordingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(recordingTimerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @MainActor
    @objc private func recordingTimerDidFire(_ timer: Timer) {
        recordingDuration += timer.timeInterval
        if recordingDuration >= Double(maxSeconds) {
            timer.invalidate()
            if self.timer === timer {
                self.timer = nil
            }
            onTimeoutTriggered?()
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
        onTimeoutTriggered = nil
        
        let buffers = bufferStore.drain()
        onFatalCaptureError = nil
        
        if activeSource == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        } else {
            AudioEngineManager.shared.unregister(self)
        }
        
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
        onTimeoutTriggered = nil
        onFatalCaptureError = nil
        bufferStore.removeAll()
        
        if activeSource == .systemAudio {
            ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
            ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        } else {
            AudioEngineManager.shared.unregister(self)
        }
    }
    
    // MARK: - Metering helper
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let bufferCount = bufferStore.append(buffer) else { return }
        
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
            self.capturedBufferCount = bufferCount
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
        PrivacySafeLogger.audioFailure(
            operation: .manualQuestionCapture,
            code: (error as NSError).code
        )
        Task { @MainActor in self.handleFatalCaptureError(error) }
    }
    
    // MARK: - AudioEngineBufferDelegate conformance
    public func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        processBuffer(buffer)
    }

    public func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {
        PrivacySafeLogger.audioFailure(
            operation: .manualQuestionCapture,
            code: (error as NSError).code
        )
        Task { @MainActor in self.handleFatalCaptureError(error) }
    }

    @MainActor
    private func handleFatalCaptureError(_ error: Error) {
        guard let callback = onFatalCaptureError else { return }
        onFatalCaptureError = nil
        cancelCapture()
        callback(error)
    }

    @MainActor
    func installFatalCaptureErrorHandlerForTesting(_ callback: @escaping (Error) -> Void) {
        onFatalCaptureError = callback
        activeSource = .microphone
        isRecording = true
    }
}
