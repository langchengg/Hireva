import AVFoundation
import Foundation
import Speech

final class SystemAudioTranscriptionPipeline: NSObject, TranscriptionProvider, SystemAudioBufferDelegate {
    let providerName = "System Audio ASR Pipeline"

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

        // Register to ScreenCaptureKitSystemAudioCaptureService
        ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
        
        do {
            try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
        } catch {
            self.serviceState = .failed
            throw error
        }
        
        self.serviceState = .running

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.emit(text: text)
                }
            } else if error != nil {
                print("[SystemAudioTranscriptionPipeline] Speech recognition task error: \(error?.localizedDescription ?? "")")
                Task { @MainActor in
                    self.serviceState = .failed
                }
            }
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        
        // Unregister and stop ScreenCaptureKit
        ScreenCaptureKitSystemAudioCaptureService.shared.unregister(self)
        ScreenCaptureKitSystemAudioCaptureService.shared.stopSystemAudioCapture()
        
        sessionID = nil
        self.serviceState = .stopped
    }

    // MARK: - SystemAudioBufferDelegate conformance

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        request?.append(buffer)
    }

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[SystemAudioTranscriptionPipeline] Failed with error: \(error.localizedDescription)")
        self.serviceState = .failed
    }

    @MainActor
    private func emit(text: String) {
        guard let sessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastEmittedText else { return }
        lastEmittedText = trimmed
        
        continuation?.yield(
            TranscriptSegment(
                id: UUID().uuidString,
                sessionID: sessionID,
                source: .systemAudio,
                speaker: .interviewer,
                text: trimmed,
                startTime: nil,
                endTime: nil,
                createdAt: Date(),
                inputDeviceName: nil,
                outputDeviceName: "System Audio Capture",
                deviceID: "system_audio",
                confidence: 1.0
            )
        )
    }
}
