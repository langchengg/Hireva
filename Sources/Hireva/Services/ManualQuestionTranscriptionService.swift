import AVFoundation
import Foundation
import Speech

public final class ManualQuestionTranscriptionService: NSObject {
    public static let shared = ManualQuestionTranscriptionService()

    private let recognizer = SFSpeechRecognizer()
    // Speech callbacks and audio buffers may arrive off the main actor.
    private let stateLock = NSRecursiveLock()
    private var revision: UInt64 = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdog: Task<Void, Never>?
    private var latestPartialResult = ""
    private var onPartialCallback: ((String) -> Void)?
    private var onFinalCallback: ((String) -> Void)?
    private var onErrorCallback: ((String) -> Void)?
    private var isFinalized = false
    private var completionContinuation: CheckedContinuation<String, Error>?

    private override init() { super.init() }

    public static var mockStartTranscription: ((@escaping (String) -> Void, @escaping (String) -> Void, @escaping (String) -> Void) async throws -> Void)?
    public static var mockEndAudioAndFinalize: ((Double) async throws -> String)?
    public static var mockCancel: (() -> Void)?

    public func startTranscription(
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        let token = stateLock.withLock {
            cancelLocked()
            latestPartialResult = ""
            isFinalized = false
            onPartialCallback = onPartialResult
            onFinalCallback = onFinalResult
            onErrorCallback = onError
            return revision
        }
        if let mock = Self.mockStartTranscription {
            try await mock(
                { [weak self] in self?.accept(text: $0, final: false, error: nil, revision: token) },
                { [weak self] in self?.accept(text: $0, final: true, error: nil, revision: token) },
                { [weak self] in self?.accept(text: nil, final: false, error: NSError(domain: "ManualTranscriptionTest", code: -1, userInfo: [NSLocalizedDescriptionKey: $0]), revision: token) }
            )
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "ManualQuestionTranscriptionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Apple Speech recognition is not available or disabled."])
        }
        try stateLock.withLock {
            guard revision == token, !Task.isCancelled else { throw CancellationError() }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.accept(text: result?.bestTranscription.formattedString, final: result?.isFinal ?? false,
                             error: error, revision: token)
            }
        }
    }

    private func accept(text: String?, final: Bool, error: Error?, revision token: UInt64) {
        stateLock.withLock {
            guard revision == token, !isFinalized else { return }
            if let text {
                latestPartialResult = text
                onPartialCallback?(text)
                // A callback may synchronously cancel or replace this request.
                guard revision == token else { return }
                if final {
                    isFinalized = true
                    watchdog?.cancel(); watchdog = nil
                    let completion = completionContinuation; completionContinuation = nil
                    onFinalCallback?(text)
                    completion?.resume(returning: text)
                }
            } else if let error {
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 4 { return }
                isFinalized = true
                watchdog?.cancel(); watchdog = nil
                let completion = completionContinuation; completionContinuation = nil
                onErrorCallback?(error.localizedDescription)
                completion?.resume(throwing: error)
            }
        }
    }

    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.withLock { if !isFinalized { request?.append(buffer) } }
    }

    public func endAudioAndFinalize(timeoutSeconds: Double = 10) async throws -> String {
        if let mock = Self.mockEndAudioAndFinalize { return try await mock(timeoutSeconds) }
        let token = stateLock.withLock { revision }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.withLock {
                    guard revision == token, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    if isFinalized { continuation.resume(returning: latestPartialResult); return }
                    guard completionContinuation == nil else {
                        continuation.resume(throwing: NSError(domain: "ManualQuestionTranscriptionService", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Already waiting for this transcription."]))
                        return
                    }
                    completionContinuation = continuation
                    request?.endAudio()
                    watchdog = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(max(0, timeoutSeconds))) } catch { return }
                        self?.finishTimeout(revision: token)
                    }
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { if self.revision == token { self.cancelLocked() } }
        }
    }

    private func finishTimeout(revision token: UInt64) {
        stateLock.withLock {
            guard revision == token, let completion = completionContinuation else { return }
            completionContinuation = nil
            isFinalized = true
            recognitionTask?.cancel(); recognitionTask = nil
            request?.endAudio(); request = nil
            completion.resume(returning: latestPartialResult)
        }
    }

    private func cancelLocked() {
        revision &+= 1
        watchdog?.cancel(); watchdog = nil
        let completion = completionContinuation; completionContinuation = nil
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        isFinalized = true
        onPartialCallback = nil; onFinalCallback = nil; onErrorCallback = nil
        completion?.resume(throwing: CancellationError())
    }

    public func cancel() {
        stateLock.withLock { cancelLocked() }
        Self.mockCancel?()
    }
}
