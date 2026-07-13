import AVFoundation
import Foundation
import Speech

public final class ManualQuestionTranscriptionService: NSObject {
    public static let shared = ManualQuestionTranscriptionService()
    
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private var latestPartialResult: String = ""
    private var onPartialCallback: ((String) -> Void)?
    private var onFinalCallback: ((String) -> Void)?
    private var onErrorCallback: ((String) -> Void)?
    private var isFinalized = false
    
    private var completionContinuation: CheckedContinuation<String, Error>?
    
    private override init() {
        super.init()
    }
    
    public static var mockStartTranscription: ((@escaping (String) -> Void, @escaping (String) -> Void, @escaping (String) -> Void) async throws -> Void)?
    public static var mockEndAudioAndFinalize: ((Double) async throws -> String)?
    public static var mockCancel: (() -> Void)?
    
    public func startTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        if let mock = ManualQuestionTranscriptionService.mockStartTranscription {
            try await mock(onPartialResult, onFinalResult, onError)
            return
        }
        
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "ManualQuestionTranscriptionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Speech recognition is not available or disabled."]
            )
        }
        
        // Reset previous ASR tasks
        cancel()
        
        self.latestPartialResult = ""
        self.onPartialCallback = onPartialResult
        self.onFinalCallback = onFinalResult
        self.onErrorCallback = onError
        self.isFinalized = false
        self.completionContinuation = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.latestPartialResult = text
                self.onPartialCallback?(text)
                
                if result.isFinal {
                    print("[ManualTranscriptionService] ASR Final result: \"\(text)\"")
                    self.isFinalized = true
                    self.onFinalCallback?(text)
                    self.completionContinuation?.resume(returning: text)
                    self.completionContinuation = nil
                }
            } else if let error = error {
                print("[ManualTranscriptionService] Task error: \(error.localizedDescription)")
                // If it was cancelled by us, do not treat as failure
                let nsErr = error as NSError
                if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 4 { // User cancelled
                    return
                }
                self.onErrorCallback?(error.localizedDescription)
                self.completionContinuation?.resume(throwing: error)
                self.completionContinuation = nil
            }
        }
    }
    
    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }
    
    public func endAudioAndFinalize(timeoutSeconds: Double = 10.0) async throws -> String {
        if let mock = ManualQuestionTranscriptionService.mockEndAudioAndFinalize {
            return try await mock(timeoutSeconds)
        }
        
        request?.endAudio()
        
        if isFinalized {
            return latestPartialResult
        }
        
        print("[ManualQuestionTranscriptionService] Audio ended. Waiting up to \(timeoutSeconds)s for final transcription...")
        
        return try await withCheckedThrowingContinuation { continuation in
            self.completionContinuation = continuation
            
            // Set timeout watchdog
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard let activeContinuation = self.completionContinuation else { return }
                self.completionContinuation = nil
                
                print("[ManualQuestionTranscriptionService] Timeout watchdog triggered. Using best available partial result: \"\(self.latestPartialResult)\"")
                
                // Cancel existing task to stop listening
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                
                // Complete with the best available partial transcript
                activeContinuation.resume(returning: self.latestPartialResult)
            }
        }
    }
    
    public func cancel() {
        if let mock = ManualQuestionTranscriptionService.mockCancel {
            mock()
            return
        }
        
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        completionContinuation = nil
    }
}
