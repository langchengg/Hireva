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
    private var onError: ((String) -> Void)?
    private var onPartialResult: ((String) -> Void)?
    private var onFinalResult: ((String) -> Void)?
    
    public private(set) var totalBuffersAppended: Int = 0

    private(set) var serviceState: TranscriptionServiceState = .idle
    var isRecognitionRequestActive: Bool { request != nil }
    var isRecognitionTaskActive: Bool { recognitionTask != nil }


    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { continuation in
        self.continuation = continuation
    }

    override init() {
        super.init()
    }

    func start(sessionID: String) async throws {
        try await start(sessionID: sessionID, onPartialResult: nil, onFinalResult: nil, onError: nil)
    }

    func start(
        sessionID: String,
        startCapture: Bool = true,
        onPartialResult: ((String) -> Void)? = nil,
        onFinalResult: ((String) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) async throws {
        guard let recognizer, recognizer.isAvailable else {
            self.serviceState = .failed
            throw TranscriptionError.unavailable("Apple Speech recognition is not available for the locale.")
        }

        stop()
        self.sessionID = sessionID
        self.lastEmittedText = ""
        self.onPartialResult = onPartialResult
        self.onFinalResult = onFinalResult
        self.onError = onError
        self.totalBuffersAppended = 0
        self.serviceState = .starting

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        if startCapture {
            // Register to ScreenCaptureKitSystemAudioCaptureService
            ScreenCaptureKitSystemAudioCaptureService.shared.register(self)
            
            do {
                try await ScreenCaptureKitSystemAudioCaptureService.shared.startSystemAudioCapture()
            } catch {
                self.serviceState = .failed
                throw error
            }
        }
        
        self.serviceState = .running


        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.emit(text: text)
                    if result.isFinal {
                        print("[SystemAudioTranscriptionPipeline] ASR FINAL transcript: \"\(text)\"")
                        self.onFinalResult?(text)
                    } else {
                        print("[SystemAudioTranscriptionPipeline] ASR PARTIAL transcript: \"\(text)\"")
                        self.onPartialResult?(text)
                    }
                }
            } else if let error = error {
                let errMsg = error.localizedDescription
                print("[SystemAudioTranscriptionPipeline] Speech recognition task error: \(errMsg)")
                Task { @MainActor in
                    self.serviceState = .failed
                    self.onError?(errMsg)
                }
            }
        }
    }

    func endAudio() {
        request?.endAudio()
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
        self.totalBuffersAppended = 0
        self.serviceState = .stopped
    }

    // MARK: - SystemAudioBufferDelegate conformance

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        request?.append(buffer)
        totalBuffersAppended += 1
        if totalBuffersAppended % 100 == 0 || totalBuffersAppended == 1 {
            print("[SystemAudioTranscriptionPipeline] Real buffer appended to ASR request. Total buffers appended: \(totalBuffersAppended)")
        }
    }

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    ) {
        print("[SystemAudioTranscriptionPipeline] Failed with error: \(error.localizedDescription)")
        self.serviceState = .failed
        self.onError?(error.localizedDescription)
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
