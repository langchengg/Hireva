import Foundation
import Testing
@testable import Hireva

@Suite("Apple Speech provider lifecycle", .serialized)
@MainActor
struct AppleSpeechProviderLifecycleTests {
    @Test
    func consumerCancellationStopsOwnedSpeechSession() async throws {
        let service = AppleSpeechTranscriptionService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("cancelled-consumer"))
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = try? await consumer.value
        await provider.waitForCurrentTranscriptionEnd()
        #expect(service.microphoneSession == nil)
        #expect(!provider.hasOwnedTranscriptionWork)
        await provider.stopTranscription()
    }

    @Test
    func explicitStopFinishesTheReturnedStream() async throws {
        let service = AppleSpeechTranscriptionService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("explicit-stop"))
        let consumer = Task { for try await _ in stream {} }
        await provider.stopTranscription()
        try await consumer.value
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func normalSourceFinishReclaimsBridgeAndResources() async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("normal"))
        service.emit(segment("normal", text: "A complete synthetic answer."))
        service.finish()
        var segments: [TranscriptSegment] = []
        for try await segment in stream { segments.append(segment) }
        await provider.waitForCurrentTranscriptionEnd()
        #expect(segments.map(\.text) == ["A complete synthetic answer."])
        #expect(!service.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func sourceFailureIsThrownAndCleanupIsIdempotent() async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("source-failure"))
        service.finish(error: FixtureError.runtime)
        do {
            for try await _ in stream {}
            Issue.record("Underlying speech failure was presented as a normal finish")
        } catch {
            #expect(error as? FixtureError == .runtime)
        }
        await provider.waitForCurrentTranscriptionEnd()
        #expect(!service.running)
        let stopCalls = service.stopCalls
        await provider.stopTranscription()
        await provider.stopTranscription()
        #expect(service.stopCalls == stopCalls)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func startupFailureCleansUpBeforePropagating() async {
        let service = ControlledSpeechService()
        service.startupError = .startup
        let provider = AppleSpeechASRProvider(service: service)
        do {
            _ = try await provider.startTranscription(config: config("startup-failure"))
            Issue.record("Startup error did not propagate")
        } catch {
            #expect(error as? FixtureError == .startup)
        }
        #expect(!service.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func cancelledNoncooperativeStartupIsDrainedBeforeNewStart() async throws {
        let service = ControlledSpeechService()
        let gate = Gate()
        service.startGate = gate
        let provider = AppleSpeechASRProvider(service: service)
        let oldStart = Task { try await provider.startTranscription(config: config("old-start")) }
        await gate.waitUntilEntered()
        oldStart.cancel()
        let stopEntered = Gate()
        service.onStop = { stopEntered.open() }
        let stop = Task { await provider.stopTranscription() }
        await stopEntered.wait()
        let newStart = Task { try await provider.startTranscription(config: config("new-start")) }
        // This fake deliberately ignores cancellation until its gate is opened;
        // all test exits release the gate and await the owned tasks.
        service.startGate = nil
        gate.open()
        let oldResult = await oldStart.result
        if case .success = oldResult { Issue.record("Cancelled startup returned a stream") }
        await stop.value
        let newStream = try await newStart.value
        #expect(service.startedSessions == ["old-start", "new-start"])
        #expect(service.running)
        service.emit(segment("new-start", text: "Fresh synthetic transcript."))
        service.finish()
        var received: [TranscriptSegment] = []
        for try await value in newStream { received.append(value) }
        #expect(received.map(\.sessionID) == ["new-start"])
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func cancellingAnOldConsumerCannotStopNewRound() async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        let oldStream = try await provider.startTranscription(config: config("old"))
        let oldConsumer = Task { for try await _ in oldStream {} }
        let newStream = try await provider.startTranscription(config: config("new"))
        oldConsumer.cancel()
        _ = try? await oldConsumer.value
        #expect(service.running)
        service.emit(segment("new", text: "Current synthetic answer."))
        service.finish()
        var received: [TranscriptSegment] = []
        for try await value in newStream { received.append(value) }
        #expect(received.map(\.sessionID) == ["new"])
    }

    @Test
    func retainedStreamEarlyBreakRequiresExplicitStop() async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("early-break"))
        service.emit(segment("early-break", text: "One synthetic result."))
        for try await _ in stream { break }
        #expect(provider.hasOwnedTranscriptionWork)
        await provider.stopTranscription()
        #expect(!service.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func restartedRealServiceRejectsOldSessionEvents() async throws {
        let service = AppleSpeechTranscriptionService()
        let provider = AppleSpeechASRProvider(service: service)
        _ = try await provider.startTranscription(config: config("old-session"))
        let oldSession = try #require(service.microphoneSession)
        let stream = try await provider.startTranscription(config: config("new-session"))
        let currentSession = try #require(service.microphoneSession)
        oldSession.simulateEmit(text: "Stale synthetic transcript.", isFinal: true)
        currentSession.simulateEmit(text: "Current synthetic transcript.", isFinal: true)
        service.stop()
        var received: [TranscriptSegment] = []
        for try await value in stream { received.append(value) }
        #expect(received.map(\.sessionID) == ["new-session"])
        #expect(received.map(\.text) == ["Current synthetic transcript."])
    }

    @Test
    func directDiagnosticRestartFinishesOldStreamAndPublishesOnlyNewRound() async throws {
        let service = AppleSpeechTranscriptionService()
        service.startDiagnosticSystemAudioSession(sessionID: "old-direct-round")
        let oldStream = service.segments
        let oldSession = try #require(service.systemAudioSession)
        service.startDiagnosticSystemAudioSession(sessionID: "new-direct-round")
        let newStream = service.segments
        oldSession.simulateEmit(text: "Stale synthetic transcript.", isFinal: true)
        service.systemAudioSession?.simulateEmit(text: "Current synthetic transcript.", isFinal: true)
        service.stop()

        var oldValues: [TranscriptSegment] = []
        for await value in oldStream { oldValues.append(value) }
        var newValues: [TranscriptSegment] = []
        for await value in newStream { newValues.append(value) }
        #expect(oldValues.isEmpty)
        #expect(newValues.map(\.sessionID) == ["new-direct-round"])
        #expect(newValues.map(\.text) == ["Current synthetic transcript."])
    }

    @Test
    func liveDiagnosticConsumesTheStreamOfItsStartedRound() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        let fragment = "what did you learn from comp"
        await app.runLiveSystemAudioFinalCallbackDiagnostic(question: fragment)
        let service = try #require(app.appleSpeechService)
        let consumer = app.transcriptionTask
        service.stop()
        await consumer?.value

        #expect(app.transcriptSegments.contains {
            $0.text == fragment && $0.asrSource == .appleASR && $0.recognitionIsFinal == true
        })
        app.stopListening()
        await app.captureTeardownTask?.value
    }

    @Test
    func combinedSourceFailureKeepsOtherChannelAlive() async throws {
        let service = AppleSpeechTranscriptionService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: .init(sessionID: "combined", captureMode: .microphoneAndSystem))
        service.audioEngineManager(AudioEngineManager.shared, didFailWith: FixtureError.runtime)
        #expect(service.systemAudioSession?.isRecognitionActive == true)
        service.systemAudioSession?.simulateEmit(text: "Synthetic system question?", isFinal: true)
        service.stop()
        var received: [TranscriptSegment] = []
        for try await value in stream { received.append(value) }
        #expect(received.map(\.source) == [.systemAudio])
    }

    @Test
    func realServiceSourceFailureEndsBridgeWithError() async throws {
        let service = AppleSpeechTranscriptionService()
        let provider = AppleSpeechASRProvider(service: service)
        let stream = try await provider.startTranscription(config: config("failed-source"))
        service.audioEngineManager(AudioEngineManager.shared, didFailWith: FixtureError.runtime)
        do {
            for try await _ in stream {}
            Issue.record("Capture failure did not reach the provider consumer")
        } catch {
            #expect(error as? FixtureError == .runtime)
        }
        #expect(!provider.hasOwnedTranscriptionWork)
        #expect(service.microphoneSession == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["queue", "text"])
    func pausedAppleProviderOutputFailsExplicitlyAfterExactBridgeCleanup(mode: String) async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        do {
            let stream = try await provider.startTranscription(config: .init(sessionID: "bounded-apple-output", captureMode: .systemAudioOnly))
            let inputs: [TranscriptSegment] = mode == "queue" ? (0..<65).map { index in
                TranscriptSegment(id: "synthetic-\(index)", sessionID: "bounded-apple-output",
                    source: .systemAudio, speaker: .unknown, text: "Synthetic 中文🙂 \(index)",
                    asrSource: .appleASR, asrFinalizationReason: index.isMultiple(of: 2) ? "final" : "partial",
                    recognitionIsFinal: index.isMultiple(of: 2))
            } : [TranscriptSegment(id: "synthetic-large", sessionID: "bounded-apple-output",
                source: .systemAudio, speaker: .unknown, text: String(repeating: "X", count: 65_537),
                asrSource: .appleASR, recognitionIsFinal: true)]
            // These finite same-actor emits run before the owned bridge can
            // resume; no provider transcript consumer has been started.
            inputs.forEach(service.emit)
            service.finish()
            await provider.waitForCurrentTranscriptionEnd()
            var values: [TranscriptSegment] = []
            var failure: String?
            do { for try await value in stream { values.append(value) } }
            catch { failure = error.localizedDescription }
            if mode == "queue" {
                #expect(values == Array(inputs.prefix(64)), "Admitted partial/final provenance remains unchanged and ordered.")
                #expect(failure == "Apple Speech transcript output buffer overflow (64 events).")
            } else {
                #expect(values.isEmpty)
                #expect(failure == "Apple Speech transcript text exceeded 65536 bytes.")
            }
            #expect(!service.running)
            #expect(!provider.hasOwnedTranscriptionWork)
            let stopCalls = service.stopCalls
            await provider.stopTranscription()
            #expect(service.stopCalls == stopCalls, "Explicit stop after overflow only joins the completed exact bridge.")
        } catch {
            service.finish()
            await provider.stopTranscription()
            await provider.waitForCurrentTranscriptionEnd()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exactAppleProviderEventBudgetPreservesNormalPartialFinalCompletion() async throws {
        let service = ControlledSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        do {
            let stream = try await provider.startTranscription(config: .init(sessionID: "exact-apple-output", captureMode: .systemAudioOnly))
            let inputs = (0..<64).map { index in
                TranscriptSegment(id: "synthetic-\(index)", sessionID: "exact-apple-output",
                    source: .systemAudio, speaker: .unknown, text: "Synthetic 中文🙂 \(index)",
                    asrSource: .appleASR, asrFinalizationReason: index.isMultiple(of: 2) ? "final" : "partial",
                    recognitionIsFinal: index.isMultiple(of: 2))
            }
            inputs.forEach(service.emit)
            service.finish()
            await provider.waitForCurrentTranscriptionEnd()
            var values: [TranscriptSegment] = []
            for try await value in stream { values.append(value) }
            #expect(values == inputs)
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(!service.running)
            await provider.stopTranscription()
        } catch {
            service.finish()
            await provider.stopTranscription()
            await provider.waitForCurrentTranscriptionEnd()
            throw error
        }
    }

    private func config(_ sessionID: String) -> ASRConfig {
        .init(sessionID: sessionID, captureMode: .microphoneOnly)
    }

    private func segment(_ sessionID: String, text: String) -> TranscriptSegment {
        .init(id: UUID().uuidString, sessionID: sessionID, source: .microphone, speaker: .unknown, text: text)
    }

    private enum FixtureError: Error, Equatable { case startup, runtime }

    @MainActor
    private final class ControlledSpeechService: AppleSpeechProviderService {
        private(set) var segments = AsyncStream<TranscriptSegment> { $0.finish() }
        private var continuation: AsyncStream<TranscriptSegment>.Continuation?
        private(set) var terminalError: Error?
        private(set) var running = false
        private(set) var stopCalls = 0
        private(set) var startedSessions: [String] = []
        var startupError: FixtureError?
        var startGate: Gate?
        var onStop: (() -> Void)?

        func start(sessionID: String, captureMode: AudioCaptureMode) async throws {
            startedSessions.append(sessionID)
            let pair = AsyncStream<TranscriptSegment>.makeStream()
            segments = pair.stream
            continuation = pair.continuation
            terminalError = nil
            await startGate?.wait()
            running = true
            if let startupError { throw startupError }
        }

        func emit(_ segment: TranscriptSegment) { continuation?.yield(segment) }
        func finish(error: Error? = nil) {
            terminalError = error
            continuation?.finish()
        }
        func stop() {
            stopCalls += 1
            onStop?()
            running = false
            continuation?.finish()
        }
    }

    @MainActor
    private final class Gate {
        private var entered = false
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            let observers = entryWaiters; entryWaiters.removeAll()
            observers.forEach { $0.resume() }
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}
