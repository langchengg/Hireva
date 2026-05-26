import AVFoundation
import Foundation

@MainActor
final class MicrophoneDiagnosticsService: ObservableObject {
    @Published var isRunning = false
    @Published var rmsLevel: Double = 0
    @Published var decibels: Double = -90
    @Published var selectedInputDeviceName: String = "Default Input"
    @Published var lastError: String?

    private let audioEngine = AVAudioEngine()

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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            let metrics = Self.audioMetrics(from: buffer)
            Task { @MainActor [weak self] in
                self?.rmsLevel = metrics.rms
                self?.decibels = metrics.decibels
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            isRunning = false
            rmsLevel = 0
            decibels = -90
            lastError = error.localizedDescription
        }
    }

    func stopMicTest() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        rmsLevel = 0
        decibels = -90
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
