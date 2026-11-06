import Combine
import Dispatch
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct SystemAudioTranscriptToAnswerRuntimeTests {
    @Test(.timeLimit(.minutes(1)))
    func oneLongSystemAudioTranscriptExtractsAllQuestionsAndGeneratesLatestAnswer() async throws {
        let trace = TestEventWaitTrace(label: "system_audio_long_transcript_phases")
        trace.mark("body.entered")
        defer { trace.mark("body.return_or_throw") }
        let (appState, database, session, client) = try makeAppState()
        trace.mark("fixture.ready")
        let observation = LongTranscriptCausalObservation(app: appState)
        defer { observation.close() }
        let fixture = ControlledGenerationWatchdogFixture(app: appState)
        try await fixture.run {
            let transcript = Self.realRuntimeLongTranscriptFixture
            let monotonicStartNS = DispatchTime.now().uptimeNanoseconds

            trace.mark("transcript.handle.begin")
            await appState.handleTranscriptSegment(systemAudioSegment(
                id: "real-runtime-long-transcript",
                sessionID: session.id,
                speaker: .interviewer,
                text: transcript
            ))
            trace.mark("transcript.handle.return")

            let expectedQuestionID = try #require(appState.lastDetectedQuestion?.id)
            #expect(appState.lastDetectedQuestion?.transcriptSegmentID == "real-runtime-long-transcript")
            let ready: @MainActor () -> Bool = {
                appState.detectedQuestionsInSessionCount == 9 &&
                appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 9 &&
                appState.currentSuggestion != nil &&
                appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated
            }
            // This is a functional routing/publishing/persistence check. Its
            // whole-test time limit bounds setup; loaded test-host scheduling
            // is not a ten-second product latency budget.
            trace.mark("terminal.wait.begin")
            let terminal = try await observation.terminal(questionID: expectedQuestionID)
            trace.mark("terminal.consumed")
            let expectedGenerationID = terminal.generationID
            #expect(appState.currentGenerationID == expectedGenerationID)
            let capturedRequest = appState.generationCoordinator.requestTask
            let capturedStageA = appState.generationCoordinator.stageATask
            let capturedStageB = appState.generationCoordinator.stageBTask
            do {
                trace.mark("persistence.wait.begin")
                let persisted = try await observation.persisted(sessionID: session.id,
                    questionID: expectedQuestionID, generationID: expectedGenerationID)
                trace.mark("persistence.consumed")
                await withTaskCancellationHandler {
                    await capturedRequest?.value
                    _ = await capturedStageA?.result
                    await capturedStageB?.value
                } onCancel: {
                    capturedRequest?.cancel(); capturedStageA?.cancel(); capturedStageB?.cancel()
                }
                print("[LongTranscriptLateTerminal] \(terminal.metadataJSON)")
                print("[LongTranscriptLatePersistence] \(persisted.metadataJSON)")
                print("[LongTranscriptLateControl] " + generationFixtureControlSnapshot(app: appState,
                    clock: fixture.clock, monotonicStartNS: monotonicStartNS))
                print("[LongTranscriptMockControl] " + client.streamControlSnapshot())
                #expect(appState.currentSession?.id == session.id)
                #expect(appState.lastDetectedQuestion?.id == expectedQuestionID)
                #expect(appState.lastDetectedQuestion?.transcriptSegmentID == "real-runtime-long-transcript")
                #expect(appState.generationUIState.questionID == expectedQuestionID)
                #expect(appState.generationUIState.generationID == expectedGenerationID)
                #expect(appState.generationUIState.isTerminal)
                #expect(ready())
                #expect(try appState.suggestionRepository.suggestions(sessionID: session.id).contains {
                    $0.questionID == expectedQuestionID && $0.generationID == expectedGenerationID
                })
            } catch {
                capturedRequest?.cancel(); capturedStageA?.cancel(); capturedStageB?.cancel()
                fixture.clock.cancelAll()
                appState.cancelActiveGenerationForStop()
                await capturedRequest?.value
                _ = await capturedStageA?.result
                await capturedStageB?.value
                throw error
            }

            let detectedQuestions = try detectedQuestionTexts(database: database)
            #expect(detectedQuestions.count == 9)
            #expect(detectedQuestions[0].localizedCaseInsensitiveContains("could you tell me a little bit about yourself"))
            #expect(detectedQuestions[1].localizedCaseInsensitiveContains("could you walk me through your"))
            #expect(detectedQuestions[2].localizedCaseInsensitiveContains("what was the hardest technical challenge"))
            #expect(detectedQuestions[3].localizedCaseInsensitiveContains("how did you handle noisy detections"))
            #expect(detectedQuestions[4].localizedCaseInsensitiveContains("why did the diffusion decoder perform better"))
            #expect(detectedQuestions[5].localizedCaseInsensitiveContains("what would you change first"))
            #expect(detectedQuestions[6].localizedCaseInsensitiveContains("why do you want to join our team"))
            #expect(detectedQuestions[7].localizedCaseInsensitiveContains("how comfortable are you with python"))
            #expect(detectedQuestions[8].localizedCaseInsensitiveContains("do you have any questions for us"))

            let currentQuestion = try #require(appState.currentSuggestion?.questionText)
            #expect(currentQuestion.localizedCaseInsensitiveContains("do you have any questions for us"))
            #expect(appState.pendingAcceptedQuestions.isEmpty)
            #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered)
            #expect(appState.lastTranscriptQuestionGenerationTrace.currentSuggestionExists)
            #expect(client.answerCallCount <= 2)
            trace.mark("fixture.close.before")
        }
        trace.mark("fixture.close.return")
    }

    @Test
    func sourceSystemAudioSpeakerUnknownStillExtractsLongTranscriptQuestions() async throws {
        let (appState, database, session, _) = try makeAppState()
        let fixture = ControlledGenerationWatchdogFixture(app: appState)
        try await fixture.run {
            let monotonicStartNS = DispatchTime.now().uptimeNanoseconds
            await appState.handleTranscriptSegment(systemAudioSegment(
                id: "real-runtime-long-transcript-unknown",
                sessionID: session.id,
                speaker: .unknown,
                text: Self.realRuntimeLongTranscriptFixture
            ))

            try await waitUntil(timeout: 10.0, stateSnapshot: {
                runtimeStateSnapshot(appState: appState, session: session, transcript: Self.realRuntimeLongTranscriptFixture) + " | " +
                    generationFixtureControlSnapshot(app: appState, clock: fixture.clock,
                        monotonicStartNS: monotonicStartNS)
            }) {
                appState.detectedQuestionsInSessionCount == 9 &&
                appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 9 &&
                appState.currentSuggestion != nil
            }

            #expect(try detectedQuestionTexts(database: database).count == 9)
            #expect(appState.lastDetectedQuestionSpeaker == SpeakerRole.unknown.rawValue)
            #expect(appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("do you have any questions for us") == true)
            #expect(appState.pendingAcceptedQuestions.isEmpty)
            #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered)
        }
    }

    @Test
    func syntheticRuntimeTranscriptFixtureExtractsQuestionsDeterministically() async throws {
        let (appState, _, session, _) = try makeAppState()
        let fixture = ControlledGenerationWatchdogFixture(app: appState)
        try await fixture.run {
            let transcript = Self.gatedRealDatabaseSystemAudioTranscript() ?? Self.realRuntimeLongTranscriptFixture

            await appState.handleTranscriptSegment(systemAudioSegment(
                id: "real-db-replay-transcript",
                sessionID: session.id,
                speaker: .interviewer,
                text: transcript
            ))

            try await waitUntil(timeout: 10.0) {
                appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount >= 1 &&
                appState.detectedQuestionsInSessionCount >= 1 &&
                appState.lastTranscriptQuestionGenerationTrace.generationTriggered &&
                appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated &&
                appState.currentSuggestion != nil
            }

            #expect(appState.currentSuggestion != nil)
            #expect(!appState.currentSpinnerVisible)
        }
    }

    private static let realRuntimeLongTranscriptFixture = "Hi thanks for joining today first could you tell me a little bit about yourself and what brought you into robotics great thanks could you walk me through your Leah Rover project what was the hardest technical challenge you faced how did you handle noisy detections or localization error errors why did the diffusion decoder perform better in your Mouko evaluation what would you change first if you had another month why do you want to join our team how comfortable are you with python C and Rose two do you have any questions for us"

    private func makeAppState() throws -> (AppState, AppDatabase, InterviewSession, RuntimeTranscriptLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "SystemAudioTranscriptToAnswerRuntimeTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = RuntimeTranscriptLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: RuntimeTranscriptEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = RealDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try makeHermeticContextBoundSession(appState: appState, prefix: "transcript-runtime")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return (appState, database, session, client)
    }

    private func systemAudioSegment(
        id: String,
        sessionID: String,
        speaker: SpeakerRole,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: speaker,
            text: text,
            createdAt: Date(),
            confidence: 1.0
        )
    }

    private func detectedQuestionTexts(database: AppDatabase) throws -> [String] {
        try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT question_text FROM detected_questions ORDER BY created_at ASC")
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        stateSnapshot: (@MainActor () -> String)? = nil,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                let snapshot = stateSnapshot?() ?? ""
                throw NSError(
                    domain: "SystemAudioTranscriptToAnswerRuntimeTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for long transcript-to-answer state. \(snapshot)"]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func runtimeStateSnapshot(
        appState: AppState,
        session: InterviewSession,
        transcript: String
    ) -> String {
        let extracted = SystemAudioQuestionExtractor.extract(from: transcript).map(\.text)
        let questions = (try? appState.suggestionRepository.questions(sessionID: session.id).count) ?? -1
        let suggestions = (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) ?? -1
        let currentQuestion = appState.currentSuggestion?.questionText ?? "nil"
        return [
            "pureExtracted=\(extracted.count)",
            "pureQuestions=\(extracted.joined(separator: " || "))",
            "detected=\(appState.detectedQuestionsInSessionCount)",
            "traceExtracted=\(appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount)",
            "questionRows=\(questions)",
            "suggestionRows=\(suggestions)",
            "pending=\(appState.pendingAcceptedQuestions.count)",
            "current=\(currentQuestion)",
            "generationState=\(appState.generationUIState.displayName)",
            "lastAlignmentError=\(appState.lastAlignmentError)"
        ].joined(separator: " | ")
    }

    private static func gatedRealDatabaseSystemAudioTranscript() -> String? { nil }
}

// The test owns both subscriptions. Sinks use their Published parameter,
// never actor-owned AppState, and emit only immutable identity/time metadata.
private struct LongTranscriptCausalEvent: Sendable {
    let sessionID: String?
    let questionID: String
    let generationID: String
    let subscribedAtNS: UInt64
    let observedAtNS: UInt64
    var metadataJSON: String {
        let fields: [String: Any] = ["session_id": sessionID ?? "", "question_id": questionID,
            "generation_id": generationID, "subscribed_at_ns": subscribedAtNS,
            "observed_at_ns": observedAtNS,
            "elapsed_ms": Double(observedAtNS - subscribedAtNS) / 1_000_000]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "metadata_serialization_failed" }
        return String(decoding: data, as: UTF8.self)
    }
}
@MainActor
private final class LongTranscriptCausalObservation {
    private let terminals = AsyncStream<LongTranscriptCausalEvent>.makeStream(bufferingPolicy: .bufferingOldest(32))
    private let persistences = AsyncStream<LongTranscriptCausalEvent>.makeStream(bufferingPolicy: .bufferingOldest(32))
    private let trace = TestEventWaitTrace(label: "long_transcript_actual_completion")
    private var subscriptions: [AnyCancellable] = []
    init(app: AppState) {
        let subscribed = DispatchTime.now().uptimeNanoseconds
        subscriptions.append(app.liveInterview.generationStateUpdates.sink { @Sendable [continuation = terminals.continuation] state in
            guard state.isTerminal, let questionID = state.questionID,
                  let generationID = state.generationID else { return }
            let event = LongTranscriptCausalEvent(sessionID: nil, questionID: questionID,
                generationID: generationID, subscribedAtNS: subscribed,
                observedAtNS: DispatchTime.now().uptimeNanoseconds)
            if case .dropped = continuation.yield(event) { Issue.record("Terminal causal observation exceeded its owned buffer") }
        })
        subscriptions.append(app.diagnosticsState.$recentEvents.sink { @Sendable [continuation = persistences.continuation] records in
            guard let record = records.last, record.name == "queuedAnswerPersisted",
                  let questionID = record.questionID, let generationID = record.generationID else { return }
            let event = LongTranscriptCausalEvent(sessionID: record.sessionID, questionID: questionID,
                generationID: generationID, subscribedAtNS: subscribed,
                observedAtNS: DispatchTime.now().uptimeNanoseconds)
            if case .dropped = continuation.yield(event) { Issue.record("Persistence causal observation exceeded its owned buffer") }
        })
    }
    func terminal(questionID: String, generationID: String? = nil) async throws -> LongTranscriptCausalEvent {
        while true {
            let event = try await trace.nextEvent(in: terminals.stream, event: "terminal")
            if event.questionID == questionID && (generationID == nil || event.generationID == generationID) { return event }
        }
    }
    func persisted(sessionID: String, questionID: String, generationID: String) async throws -> LongTranscriptCausalEvent {
        while true {
            let event = try await trace.nextEvent(in: persistences.stream, event: "persistence")
            if event.sessionID == sessionID && event.questionID == questionID && event.generationID == generationID { return event }
        }
    }
    func close() {
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
        terminals.continuation.finish(); persistences.continuation.finish()
    }
}

private final class RuntimeTranscriptLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var answerCalls = 0
    private struct StreamCounts {
        var requests = 0, entered = 0, yielded = 0, finished = 0
        var requestedAt: UInt64 = 0, enteredAt: UInt64 = 0, finishedAt: UInt64 = 0
    }
    private var streamCounts: [Bool: StreamCounts] = [:]
    private func countStream(_ sections: Bool, _ mutate: (inout StreamCounts) -> Void) {
        lock.withLock {
            var counts = streamCounts[sections] ?? StreamCounts()
            mutate(&counts); streamCounts[sections] = counts
        }
    }
    func streamControlSnapshot() -> String {
        let fields: [String: UInt64] = lock.withLock {
            var values: [String: UInt64] = [:]
            for section in [false, true] {
                let value = streamCounts[section] ?? StreamCounts()
                let prefix = section ? "stage_b_mock" : "stage_a_mock"
                values[prefix + "_requests"] = UInt64(value.requests)
                values[prefix + "_entered"] = UInt64(value.entered)
                values[prefix + "_yielded"] = UInt64(value.yielded)
                values[prefix + "_finished"] = UInt64(value.finished)
                values[prefix + "_request_ns"] = value.requestedAt
                values[prefix + "_entered_ns"] = value.enteredAt
                values[prefix + "_finished_ns"] = value.finishedAt
            }
            return values
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "mock_control_serialization_failed" }
        return String(decoding: data, as: UTF8.self)
    }

    var answerCallCount: Int {
        lock.withLock { answerCalls }
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Mock OK", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        lock.withLock { answerCalls += 1 }
        let prompt = messages.map(\.content).joined(separator: "\n")
        let answer = hermeticRuntimeAnswer(for: prompt)
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": \(hermeticJSONString(answer)),
          "key_points": ["\(answer.prefix(90))", "Ground the answer in the synthetic candidate evidence"],
          "follow_up_ready": ["I can add more detail if needed."],
          "confidence": 0.86,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "runtime-transcript-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let answer = hermeticRuntimeAnswer(for: prompt)
        let sectionStream = prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.")
        countStream(sectionStream) { $0.requests += 1; $0.requestedAt = DispatchTime.now().uptimeNanoseconds }
        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                self.countStream(sectionStream) { $0.entered += 1; $0.enteredAt = DispatchTime.now().uptimeNanoseconds }
                defer { self.countStream(sectionStream) { $0.finished += 1; $0.finishedAt = DispatchTime.now().uptimeNanoseconds } }
                if sectionStream {
                    for token in hermeticRuntimeSectionTokens(for: prompt) {
                        self.countStream(sectionStream) { $0.yielded += 1 }
                        continuation.yield(token)
                    }
                    continuation.finish()
                    return
                }
                for token in answer.split(separator: " ") {
                    self.countStream(sectionStream) { $0.yielded += 1 }
                    continuation.yield(String(token) + " ")
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}

private final class RuntimeTranscriptEmptyContextRetrievalService: ContextRetrievalService {
    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
        let trace = RetrievalTrace(
            id: UUID(),
            query: question,
            intent: intent.rawValue,
            createdAt: Date(),
            rankedCVChunks: [],
            rankedJDChunks: [],
            includedCVChunks: [],
            includedJDChunks: [],
            excludedCVChunks: [],
            excludedJDChunks: [],
            cvWordsUsed: 0,
            jdWordsUsed: 0,
            cvWordBudget: maxCVWords,
            jdWordBudget: maxJDWords,
            retrievalLatencyMS: 0,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        return (context, trace)
    }
}
