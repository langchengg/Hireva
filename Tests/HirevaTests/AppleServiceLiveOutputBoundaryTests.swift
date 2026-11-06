import Combine
import Foundation
import Testing
@testable import Hireva

/// Real service admission and real Live consumer, without native capture,
/// recognition task execution, microphone access, model or cloud requests.
@MainActor
struct AppleServiceLiveOutputBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["queue", "text"])
    func pausedActualServiceOverflowEndsWithExplicitCauseAndRetainsAdmittedFinals(mode: String) async throws {
        let trace = TestEventWaitTrace(label: #function)
        trace.mark("caller.main_actor.entered")
        let speech = makeSpeech()
        speech.startDiagnosticSystemAudioSession(sessionID: "bounded-direct-speech")
        let stream = speech.segments
        do {
            let producer = try #require(speech.systemAudioSession)
            if mode == "queue" {
                for index in 0..<65 { producer.simulateEmit(text: "Synthetic final \(index)", isFinal: true) }
            } else { producer.simulateEmit(text: String(repeating: "X", count: 65_537), isFinal: true) }
            let cause = speech.terminalError?.localizedDescription
            #expect(cause == (mode == "queue" ?
                "Apple Speech transcript output buffer overflow (64 events)." :
                "Apple Speech transcript text exceeded 65536 bytes."))
            // Always finish the baseline unbounded stream too, so this RED has
            // no unbounded iterator wait, timed escape or inferred process kill.
            trace.mark("caller.service_stop.requested")
            speech.stop(retryFailedResource: false)
            trace.mark("caller.service_stop.returned")
            await speech.finishStoppingAudioInput()
            trace.mark("caller.service_drain.returned")
            let received = await collectStoppedOutput(stream,
                maximumEvents: AppleSpeechTranscriptionService.maximumPendingTranscriptEvents, trace: trace)
            trace.mark("caller.main_actor.resumed.collected_output")
            #expect(received.map(\.text) == (mode == "queue" ? (0..<64).map { "Synthetic final \($0)" } : []))
            #expect(received.allSatisfy { $0.source == .systemAudio && $0.recognitionIsFinal == true })
            #expect(!speech.hasUnreleasedAudioInput)
        } catch {
            speech.stop(retryFailedResource: false)
            await speech.finishStoppingAudioInput()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exactServiceCountBudgetKeepsMixedPartialFinalUTF8AndNormalEOF() async throws {
        let trace = TestEventWaitTrace(label: #function)
        trace.mark("caller.main_actor.entered")
        let speech = makeSpeech()
        speech.startDiagnosticSystemAudioSession(sessionID: "exact-direct-speech")
        let stream = speech.segments
        do {
            let producer = try #require(speech.systemAudioSession)
            for index in 0..<64 {
                producer.simulateEmit(text: "Synthetic 中文🙂 \(index)", isFinal: index.isMultiple(of: 2))
            }
            #expect(speech.terminalError == nil)
            trace.mark("caller.service_stop.requested")
            speech.stop(retryFailedResource: false)
            trace.mark("caller.service_stop.returned")
            await speech.finishStoppingAudioInput()
            trace.mark("caller.service_drain.returned")
            let received = await collectStoppedOutput(stream,
                maximumEvents: AppleSpeechTranscriptionService.maximumPendingTranscriptEvents, trace: trace)
            trace.mark("caller.main_actor.resumed.collected_output")
            #expect(received.map(\.text) == (0..<64).map { "Synthetic 中文🙂 \($0)" })
            #expect(received.map(\.recognitionIsFinal) == (0..<64).map { Optional($0.isMultiple(of: 2)) })
            #expect(received.allSatisfy { $0.source == .systemAudio && $0.speaker == .unknown && $0.asrSource == .appleASR })
            #expect(!speech.hasUnreleasedAudioInput)
        } catch {
            speech.stop(retryFailedResource: false)
            await speech.finishStoppingAudioInput()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualLiveConsumerTreatsAppleSourceFailureAsFailureAndStopsItsOwnedService() async throws {
        let fixture = try LiveSpeechBoundaryFixture()
        do {
            let originalConsumer = try #require(fixture.bind(fixture.speech))
            fixture.fail(fixture.speech)
            #expect(fixture.speech.terminalError as? LiveSpeechFixtureFailure == .source)
            await originalConsumer.value
            await fixture.app.captureLifecycle.drain()
            #expect(fixture.app.stopReason == .asrTaskFailed)
            #expect(fixture.app.activeTranscriptionProvider == nil)
            #expect(fixture.app.latestActionFeedback(for: ActionID.startInterview)?.kind == .error)
            #expect(fixture.app.latestActionFeedback(for: ActionID.startInterview)?.message == "Synthetic speech source failed.")
            #expect(!fixture.speech.hasUnreleasedAudioInput)
            try await fixture.cleanup()
        } catch { try? await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func feedbackObserverReplacingLiveConsumerCannotGiveOldTerminalAuthorityToStopNewSpeech() async throws {
        let fixture = try LiveSpeechBoundaryFixture()
        var observation: AnyCancellable?
        do {
            let originalConsumer = try #require(fixture.bind(fixture.speech))
            let replacement = makeSpeech()
            fixture.retainedSpeech.append(replacement)
            var didReplace = false
            observation = fixture.app.activeActionFeedbacksUpdates.sink { feedback in
                MainActor.assumeIsolated {
                    guard !didReplace, feedback.contains(where: { $0.actionID == ActionID.startInterview && $0.kind == .error }) else { return }
                    didReplace = true
                    _ = fixture.bind(replacement)
                }
            }
            fixture.fail(fixture.speech)
            await originalConsumer.value
            #expect(didReplace, "The current terminal must become visible through the real feedback boundary.")
            #expect(fixture.app.activeTranscriptionProvider === replacement)
            #expect(replacement.systemAudioSession?.isRecognitionActive == true)
            #expect(fixture.app.stopReason == nil, "Feedback publication revoked the old consumer before it could stop the replacement.")
            observation?.cancel(); observation = nil
            try await fixture.cleanup()
        } catch { observation?.cancel(); try? await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func oldStreamEOFCannotReadTheSameServicesReplacementTerminalCause() async throws {
        let fixture = try LiveSpeechBoundaryFixture()
        do {
            let originalConsumer = try #require(fixture.bind(fixture.speech))
            // Same service object and business session; the old output finished
            // normally before the replacement stream received its own failure.
            fixture.speech.startDiagnosticSystemAudioSession(sessionID: fixture.sessionID)
            fixture.fail(fixture.speech)
            await originalConsumer.value
            #expect(fixture.app.stopReason == nil)
            #expect(fixture.app.activeTranscriptionProvider === fixture.speech)
            #expect(fixture.speech.terminalError as? LiveSpeechFixtureFailure == .source)
            #expect(fixture.app.latestActionFeedback(for: ActionID.startInterview) == nil,
                "A mutable provider lookup must not relabel an older normal EOF as the new stream's error.")
            try await fixture.cleanup()
        } catch { try? await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func oldAppleProviderEOFCannotStopTheConcreteServicesReplacementRecognition() async throws {
        let speech = makeSpeech()
        let provider = AppleSpeechASRProvider(service: speech)
        do {
            let oldStream = try await provider.startTranscription(config: .init(
                sessionID: "same-wrapper-business-session", captureMode: .systemAudioOnly))
            // DEBUG actual start is native-free; direct diagnostic start ends
            // the old real service stream and installs a same-object replacement.
            speech.startDiagnosticSystemAudioSession(sessionID: "same-wrapper-business-session")
            let replacement = try #require(speech.systemAudioSession)
            await provider.waitForCurrentTranscriptionEnd()
            #expect(speech.systemAudioSession === replacement)
            #expect(replacement.isRecognitionActive,
                "An older wrapper EOF owns only its old stream, never this new recognition session.")
            #expect(!provider.hasOwnedTranscriptionWork)
            speech.stop(retryFailedResource: false)
            await speech.finishStoppingAudioInput()
            await provider.stopTranscription(retryFailedResource: false)
            var oldValues: [TranscriptSegment] = []
            for try await value in oldStream { oldValues.append(value) }
            #expect(oldValues.isEmpty)
        } catch {
            speech.stop(retryFailedResource: false)
            await speech.finishStoppingAudioInput()
            await provider.stopTranscription(retryFailedResource: false)
            throw error
        }
    }

    // Service mutations and native drain remain MainActor. Only immutable
    // stopped output is collected without a per-element UI executor round trip.
    private nonisolated func collectStoppedOutput(
        _ stream: AsyncStream<TranscriptSegment>, maximumEvents: Int, trace: TestEventWaitTrace
    ) async -> [TranscriptSegment] {
        trace.mark("collector.nonisolated.entered")
        var values: [TranscriptSegment] = []
        for await value in stream {
            values.append(value)
            if values.count == 1 || values.count == 64 { trace.mark("collector.count.\(values.count)") }
            // Retain one assertion-failing overflow witness while bounding the
            // fixture even if the production stream's admission regresses.
            if values.count > maximumEvents {
                trace.mark("collector.unexpected_extra_value")
                break
            }
        }
        trace.mark("collector.return.count.\(values.count)")
        return values
    }

    private func makeSpeech() -> AppleSpeechTranscriptionService {
        AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
    }
}

private enum LiveSpeechFixtureFailure: LocalizedError, Equatable {
    case source
    var errorDescription: String? { "Synthetic speech source failed." }
}

@MainActor
private final class LiveSpeechBoundaryFixture {
    let database: AppDatabase
    let app: AppState
    let speech: AppleSpeechTranscriptionService
    let capture: ScreenCaptureKitSystemAudioCaptureService
    let sessionID: String
    var retainedSpeech: [AppleSpeechTranscriptionService] = []
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "Hireva.Tests.AppleOutput." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        database = try AppDatabase(inMemory: true)
        let ownedCapture = ScreenCaptureKitSystemAudioCaptureService()
        capture = ownedCapture
        speech = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: ownedCapture, dialogueDefaults: defaults,
            diagnosticsTraceStore: RuntimeTranscriptTraceStore())
        app.settings.audioCaptureMode = .systemAudioOnly
        app.settings.automaticQuestionDetectionEnabled = false
        app.settings.saveTranscriptsLocally = false
        app.settings.diagnosticTraceMode = .off
        let session = try app.sessionRepository.createSession(mode: .microphone)
        sessionID = session.id
        app.currentSession = session
        retainedSpeech.append(speech)
    }
    @discardableResult
    func bind(_ provider: AppleSpeechTranscriptionService) -> Task<Void, Never>? {
        provider.startDiagnosticSystemAudioSession(sessionID: sessionID)
        app.appleSpeechService = provider
        app.activeTranscriptionProvider = provider
        app.markActiveASRProvider(.appleSpeech)
        app.liveState = .listening
        app.currentCaptureRuntimeState = .listening
        app.consumeSegments(from: provider)
        return app.transcriptionTask
    }
    func fail(_ provider: AppleSpeechTranscriptionService) {
        provider.systemAudioCaptureService(capture, didFailWithError: LiveSpeechFixtureFailure.source)
    }
    func cleanup() async throws {
        for provider in retainedSpeech {
            provider.stop(retryFailedResource: false)
            await provider.finishStoppingAudioInput()
        }
        #expect(await app.shutdownResources(), "All owned Swift consumers and simulated inputs must drain.")
        try database.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
