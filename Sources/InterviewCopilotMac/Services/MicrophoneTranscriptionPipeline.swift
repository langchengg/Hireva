import AVFoundation
import Foundation
import Speech

final class MicrophoneTranscriptionPipeline: NSObject, TranscriptionProvider, AudioEngineBufferDelegate {
    let providerName = "Microphone ASR Pipeline"

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var sessionID: String?
    private var lastEmittedText = ""

    private(set) var serviceState: TranscriptionServiceState = .idle

    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { continuation in
        self.continuation = continuation
    }

    override init() {
        super.init()
    }

    func start(sessionID: String) async throws {
        guard let recognizer, recognizer.isAvailable else {
            self.serviceState = .failed
            throw TranscriptionError.unavailable("Apple Speech recognition is not available for the locale.")
        }

        stop()
        self.sessionID = sessionID
        self.lastEmittedText = ""
        self.serviceState = .starting

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        // Register to the shared AudioEngineManager
        AudioEngineManager.shared.register(self)
        self.serviceState = .running

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.emit(text: text)
                }
            } else if error != nil {
                print("[MicrophoneTranscriptionPipeline] Speech recognition task error: \(error?.localizedDescription ?? "")")
            }
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        
        // Unregister from the shared AudioEngineManager
        AudioEngineManager.shared.unregister(self)
        
        sessionID = nil
        self.serviceState = .stopped
    }

    // MARK: - AudioEngineBufferDelegate conformance

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        request?.append(buffer)
    }

    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    ) {
        guard self.sessionID != nil else { return }
        print("[MicrophoneTranscriptionPipeline] Re-initializing microphone speech capture request after route change...")

        self.serviceState = .recoveringRoute

        // End old recognition request and task cleanly
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil

        // Recreate recognition request/task using the new audio format
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.emit(text: text)
                }
            } else if error != nil {
                print("[MicrophoneTranscriptionPipeline] Recognition task error during route recovery: \(error?.localizedDescription ?? "")")
            }
        }

        self.serviceState = .running
    }

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {
        print("[MicrophoneTranscriptionPipeline] Failed with error: \(error.localizedDescription)")
        self.serviceState = .failed
    }

    @MainActor
    private func emit(text: String) {
        guard let sessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastEmittedText else { return }
        lastEmittedText = trimmed
        
        let deviceName = AudioDeviceManager.shared.currentInputDeviceName
        let deviceID = AudioDeviceManager.shared.currentInputDeviceID
        
        continuation?.yield(
            TranscriptSegment(
                id: UUID().uuidString,
                sessionID: sessionID,
                source: .microphone,
                speaker: .candidate,
                text: trimmed,
                startTime: nil,
                endTime: nil,
                createdAt: Date(),
                inputDeviceName: deviceName,
                outputDeviceName: nil,
                deviceID: deviceID,
                confidence: 1.0
            )
        )
    }
}
