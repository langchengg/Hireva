import AVFoundation
import Foundation
import Speech

final class AppleSpeechTranscriptionService: TranscriptionProvider, AudioEngineBufferDelegate {
    let providerName = "Apple Speech"

    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var sessionID: String?
    private var lastEmittedText = ""

    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { continuation in
        self.continuation = continuation
    }

    func start(sessionID: String) async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.unavailable("Apple Speech recognition is not available for the current locale.")
        }

        stop()
        self.sessionID = sessionID
        lastEmittedText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        // Register to the shared AudioEngineManager
        AudioEngineManager.shared.register(self)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.emit(text: result.bestTranscription.formattedString)
            } else if error != nil {
                self.stop()
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
    }

    // AudioEngineBufferDelegate conformance
    func audioEngineDidReceiveBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        request?.append(buffer)
    }

    private func emit(text: String) {
        guard let sessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastEmittedText else { return }
        lastEmittedText = trimmed
        continuation?.yield(
            TranscriptSegment(
                id: UUID().uuidString,
                sessionID: sessionID,
                speaker: .audioInput,
                text: trimmed,
                startTime: nil,
                endTime: nil,
                createdAt: Date()
            )
        )
    }
}
