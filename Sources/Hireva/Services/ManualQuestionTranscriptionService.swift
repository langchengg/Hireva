import AVFoundation
import Foundation
import Speech
import os

/// Manual Capture submits its owned, stopped PCM buffers on MainActor. Speech
/// controls and callbacks use that same executor; realtime capture storage is
/// owned separately by ManualQuestionCaptureService.
@MainActor
public final class ManualQuestionTranscriptionService: NSObject {
    public static let shared = ManualQuestionTranscriptionService()

    private let recognizer = SFSpeechRecognizer()
    private let finalizeDelayProvider: any DelayProvider
    private var revision: UInt64 = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdog: Task<Void, Never>?
    private var latestPartialResult = ""
    private var onPartialCallback: ((String) -> Void)?
    private var onFinalCallback: ((String) -> Void)?
    private var onErrorCallback: ((String) -> Void)?
    private var isFinalized = false
    private var completion: ManualTranscriptionCompletion?

    private override init() {
        finalizeDelayProvider = RealDelayProvider()
        super.init()
    }

    init(finalizeDelayProvider: any DelayProvider) {
        self.finalizeDelayProvider = finalizeDelayProvider
        super.init()
    }

    // The existing compatibility hooks share the service's control executor.
    public static var mockStartTranscription: (@MainActor (@escaping (String) -> Void,
        @escaping (String) -> Void, @escaping (String) -> Void) async throws -> Void)?
    public static var mockEndAudioAndFinalize: (@MainActor (Double) async throws -> String)?
    public static var mockCancel: (@MainActor () -> Void)?

    public func startTranscription(
        requiresOnDeviceRecognition: Bool = false,
        onPartialResult: @escaping (String) -> Void,
        onFinalResult: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        cancelCurrent()
        let token = revision
        latestPartialResult = ""
        isFinalized = false
        onPartialCallback = onPartialResult
        onFinalCallback = onFinalResult
        onErrorCallback = onError
        if let mock = Self.mockStartTranscription {
            do {
                try await mock(
                    { [weak self] in self?.accept(text: $0, final: false, error: nil, revision: token) },
                    { [weak self] in self?.accept(text: $0, final: true, error: nil, revision: token) },
                    { [weak self] in self?.accept(text: nil, final: false,
                        error: NSError(domain: "ManualTranscriptionTest", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: $0]), revision: token) }
                )
                guard revision == token, !Task.isCancelled else { throw CancellationError() }
                return
            } catch {
                if revision == token { cancelCurrent() }
                throw error
            }
        }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "ManualQuestionTranscriptionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Apple Speech recognition is not available or disabled."])
        }
        try Task.checkCancellation()
        let request = try AppleSpeechRequestFactory.make(
            requiresOnDeviceRecognition: requiresOnDeviceRecognition,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)
        self.request = request
        // SFSpeechRecognizer.queue governs its task handlers. Setting it
        // explicitly makes the same executor contract as the live backend.
        recognizer.queue = .main
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            MainActor.assumeIsolated {
                self?.accept(text: result?.bestTranscription.formattedString,
                    final: result?.isFinal ?? false, error: error, revision: token)
            }
        }
    }

    private func accept(text: String?, final: Bool, error: Error?, revision token: UInt64) {
        guard revision == token, !isFinalized else { return }
        if let text {
            latestPartialResult = text
            onPartialCallback?(text)
            // A synchronous observer may replace or cancel the old round.
            guard revision == token else { return }
            if final {
                isFinalized = true
                watchdog?.cancel(); watchdog = nil
                let completed = completion; completion = nil
                onFinalCallback?(text)
                completed?.finish(.success(text))
            }
        } else if let error {
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 4 { return }
            isFinalized = true
            watchdog?.cancel(); watchdog = nil
            let completed = completion; completion = nil
            onErrorCallback?(error.localizedDescription)
            completed?.finish(.failure(error))
        }
    }

    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        if !isFinalized { request?.append(buffer) }
    }

    public func endAudioAndFinalize(timeoutSeconds: Double = 10) async throws -> String {
        let token = revision
        if let mock = Self.mockEndAudioAndFinalize {
            do {
                let text = try await mock(timeoutSeconds)
                guard revision == token, !Task.isCancelled else { throw CancellationError() }
                return text
            } catch {
                if revision == token, Task.isCancelled { cancelCurrent() }
                throw error
            }
        }
        let waiter = ManualTranscriptionCompletion()
        let delayProvider = finalizeDelayProvider
        let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        var ownedWatchdog: Task<Void, Never>?
        do {
            let text = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    guard revision == token, !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    if isFinalized { continuation.resume(returning: latestPartialResult); return }
                    guard completion == nil else {
                        continuation.resume(throwing: NSError(domain: "ManualQuestionTranscriptionService", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Already waiting for this transcription."]))
                        return
                    }
                    completion = waiter
                    waiter.install(continuation)
                    let deadline = Task { @MainActor [weak self] in
                        do { try await delayProvider.sleep(nanoseconds: nanoseconds) } catch { return }
                        self?.finishTimeout(revision: token)
                    }
                    watchdog = deadline
                    ownedWatchdog = deadline
                    request?.endAudio()
                }
            } onCancel: {
                // This synchronous Sendable handoff resumes only this waiter.
                // Cleanup runs in the resumed owner, with its revision fence;
                // it creates no unowned Task and never touches a new round.
                waiter.cancel()
            }
            await ownedWatchdog?.value
            try Task.checkCancellation()
            return text
        } catch {
            if revision == token, completion === waiter || Task.isCancelled { cancelCurrent() }
            ownedWatchdog?.cancel()
            await ownedWatchdog?.value
            throw error
        }
    }

    private func finishTimeout(revision token: UInt64) {
        guard revision == token, let completed = completion else { return }
        completion = nil
        watchdog = nil
        isFinalized = true
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        completed.finish(.success(latestPartialResult))
    }

    private func cancelCurrent() {
        revision &+= 1
        watchdog?.cancel(); watchdog = nil
        let completed = completion; completion = nil
        recognitionTask?.cancel(); recognitionTask = nil
        request?.endAudio(); request = nil
        isFinalized = true
        onPartialCallback = nil; onFinalCallback = nil; onErrorCallback = nil
        completed?.cancel()
    }

    public func cancel() {
        cancelCurrent()
        Self.mockCancel?()
    }
}

/// Cancellation may run on any executor and before waiter registration. Only
/// continuation ownership crosses that boundary; native Speech stays on main.
private final class ManualTranscriptionCompletion: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var continuation: CheckedContinuation<String, Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func install(_ continuation: CheckedContinuation<String, Error>) {
        let cancelled = state.withLock {
            if $0.cancelled { return true }
            $0.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }
    func finish(_ result: Result<String, Error>) {
        let continuation = state.withLock {
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
    func cancel() {
        let continuation = state.withLock {
            $0.cancelled = true
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
