import AVFoundation
import Foundation

@MainActor
final class MicrophoneDiagnosticsService: ObservableObject, AudioEngineBufferDelegate {
    @Published var isRunning = false
    @Published var rmsLevel: Double = 0
    @Published var decibels: Double = -90
    @Published var selectedInputDeviceName: String = "Default Input"
    @Published var lastError: String?

    private var lastUpdateTimestamp = Date.distantPast

    var normalizedLevel: Double {
        min(max((decibels + 60) / 60, 0), 1)
    }

    func refreshSelectedInputDevice() {
        selectedInputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Input"
    }

    func startMicTest() {
        stopMicTest()
        refreshSelectedInputDevice()
        lastError = nil

        AudioEngineManager.shared.register(self)
        isRunning = true
    }

    func stopMicTest() {
        AudioEngineManager.shared.unregister(self)
        isRunning = false
        rmsLevel = 0
        decibels = -90
        lastError = nil
    }

    // MARK: - AudioEngineBufferDelegate conformance

    nonisolated func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        let metrics = Self.audioMetrics(from: buffer)
        
        // Lightweight callback: compute and dispatch throttled updates to @MainActor
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            // Throttle UI level updates to at most ~25 FPS (0.04s interval)
            guard now.timeIntervalSince(self.lastUpdateTimestamp) >= 0.04 else { return }
            self.lastUpdateTimestamp = now

            // Apply exponential moving average (alpha = 0.3) for level smoothing
            let alpha = 0.3
            self.rmsLevel = alpha * metrics.rms + (1.0 - alpha) * self.rmsLevel
            self.decibels = alpha * metrics.decibels + (1.0 - alpha) * self.decibels
            
            // Clear route recovery message if audio buffers resume
            if self.lastError == "Recovering audio input..." {
                self.lastError = nil
            }
        }
    }

    nonisolated func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rmsLevel = 0
            self.decibels = -90
            self.lastError = nil
            self.refreshSelectedInputDevice()
        }
    }

    nonisolated func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rmsLevel = 0
            self.decibels = -90
            self.lastError = error.localizedDescription
        }
    }

    /// Sets the status explicitly during the recovery process.
    func markAsRecovering() {
        self.rmsLevel = 0
        self.decibels = -90
        self.lastError = "Recovering audio input..."
    }

    private nonisolated static func audioMetrics(from buffer: AVAudioPCMBuffer) -> (rms: Double, decibels: Double) {
        guard let channelData = buffer.floatChannelData else {
            return (0, -90)
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return (0, -90)
        }

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
        return (Double(rms), max(db, -90))
    }
}
