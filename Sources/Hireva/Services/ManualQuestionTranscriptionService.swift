import AVFoundation
import Foundation
import os
import Speech

@MainActor
final class ManualTranscriptionFinalizationCoordinator {
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var terminalClaimCount = 0

    var hasPendingContinuation: Bool { continuation != nil }
    var currentGeneration: UInt64 { generation }

    func wait(
        timeout: Duration,
        fallbackText: @escaping @MainActor () -> String,
        onTimeout: @escaping @MainActor () -> Void
    ) async throws -> String {
        cancel()
        generation &+= 1
        let expectedGeneration = generation

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard self.generation == expectedGeneration else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.generation == expectedGeneration else { return }
                    onTimeout()
                    self.finish(.success(fallbackText()), expectedGeneration: expectedGeneration)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(expectedGeneration: expectedGeneration)
            }
        }
    }

    func resolve(_ result: Result<String, Error>) {
        finish(result, expectedGeneration: generation)
    }

    func cancel() {
        cancel(expectedGeneration: nil)
    }

    func cancel(expectedGeneration: UInt64) {
        cancel(expectedGeneration: Optional(expectedGeneration))
    }

    private func cancel(expectedGeneration: UInt64?) {
        if let expectedGeneration, expectedGeneration != generation { return }
        generation &+= 1
        finish(.failure(CancellationError()), expectedGeneration: nil)
    }

    private func finish(_ result: Result<String, Error>, expectedGeneration: UInt64?) {
        if let expectedGeneration, expectedGeneration != generation { return }
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        terminalClaimCount += 1
        continuation.resume(with: result)
    }
}

@MainActor
public final class ManualQuestionTranscriptionService: NSObject {
    public static let shared = ManualQuestionTranscriptionService()

    private let recognizer = SFSpeechRecognizer()
    private let finalization = ManualTranscriptionFinalizationCoordinator()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration: UInt64 = 0
    private var latestPartialResult = ""
    private var onPartialCallback: ((String) -> Void)?
    private var onFinalCallback: ((String) -> Void)?
    private var onErrorCallback: ((String) -> Void)?
    private var isFinalized = false

    private override init() { super.init() }

    public static var mockStartTranscription: ((@escaping (String) -> Void, @escaping (String) -> Void, @escaping (String) -> Void) async throws -> Void)?
    public static var mockEndAudioAndFinalize: ((Double) async throws -> String)?
    public static var mockCancel: (() -> Void)?

    public func startTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        if let mock = Self.mockStartTranscription {
            try await mock(onPartialResult, onFinalResult, onError)
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "ManualQuestionTranscriptionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Speech recognition is not available or disabled."]
            )
        }

        cancel()
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        latestPartialResult = ""
        onPartialCallback = onPartialResult
        onFinalCallback = onFinalResult
        onErrorCallback = onError
        isFinalized = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error, generation: generation)
            }
        }
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        generation: UInt64
    ) {
        guard generation == recognitionGeneration else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            latestPartialResult = text
            onPartialCallback?(text)
            if result.isFinal {
                PrivacySafeLogger.manualAppleSpeechFinal(characters: text.utf16.count)
                isFinalized = true
                onFinalCallback?(text)
                finalization.resolve(.success(text))
            }
            return
        }
        guard let error else { return }
        let nsError = error as NSError
        PrivacySafeLogger.audioFailure(operation: .manualAppleSpeech, code: nsError.code)
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 4 { return }
        onErrorCallback?(error.localizedDescription)
        finalization.resolve(.failure(error))
    }

    public func appendBuffer(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }

    public func endAudioAndFinalize(timeoutSeconds: Double = 10.0) async throws -> String {
        if let mock = Self.mockEndAudioAndFinalize { return try await mock(timeoutSeconds) }
        request?.endAudio()
        if isFinalized { return latestPartialResult }
        PrivacySafeLogger.manualAppleSpeechAudioEnded(timeoutSeconds: timeoutSeconds)
        return try await finalization.wait(
            timeout: .seconds(timeoutSeconds),
            fallbackText: { [weak self] in self?.latestPartialResult ?? "" },
            onTimeout: { [weak self] in
                guard let self else { return }
                PrivacySafeLogger.manualAppleSpeechTimedOut(
                    partialCharacters: self.latestPartialResult.utf16.count
                )
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        )
    }

    public func cancel() {
        if let mock = Self.mockCancel { mock(); return }
        recognitionGeneration &+= 1
        finalization.cancel()
        recognitionTask?.cancel()
        recognitionTask = nil
        request?.endAudio()
        request = nil
        onPartialCallback = nil
        onFinalCallback = nil
        onErrorCallback = nil
    }
}
