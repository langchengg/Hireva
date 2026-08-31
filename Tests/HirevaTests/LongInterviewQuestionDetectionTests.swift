import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
@MainActor
struct LongInterviewQuestionDetectionTests {
    @Test
    func longInterviewDetectsOnlyAnswerWorthyInterviewerQuestions() async throws {
        let (appState, session, _) = try makeAppState()
        let dialogue: [(AudioSourceType, SpeakerRole, String, String?)] = [
            (.systemAudio, .interviewer, "Welcome, Synthetic Candidate. We’ll start this fictional interview with a few questions about your background.", nil),
            (.systemAudio, .interviewer, "First, could you tell me a little bit about yourself and what brought you into software systems?", "Could you tell me a little bit about yourself and what brought you into software systems?"),
            (.microphone, .candidate, "This synthetic candidate completed a software systems certificate at Example Technical Institute.", nil),
            (.systemAudio, .interviewer, "Great, thanks. I saw the synthetic event-processing project in your sample profile.", nil),
            (.systemAudio, .interviewer, "Could you walk me through that project, especially your role in the ingestion and routing pipeline?", "Could you walk me through that project, especially your role in the ingestion and routing pipeline?"),
            (.microphone, .candidate, "The synthetic project was an event-processing service for sample incident records.", nil),
            (.systemAudio, .interviewer, "Okay, interesting. And what was the hardest technical challenge you faced?", "What was the hardest technical challenge you faced?"),
            (.microphone, .candidate, "The hardest part was integrating ingestion with routing and persistence.", nil),
            (.systemAudio, .interviewer, "Right. You mentioned the message bus and classifier. How did you handle noisy events or routing errors?", "How did you handle noisy events or routing errors?"),
            (.microphone, .candidate, "The synthetic service used filtering and recovery behaviour.", nil),
            (.systemAudio, .interviewer, "Makes sense. Let’s move to the synthetic sequence-model evaluation.", nil),
            (.systemAudio, .interviewer, "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your synthetic evaluation?", "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your synthetic evaluation?"),
            (.microphone, .candidate, "The diffusion sequence model was more robust on the sample trials.", nil),
            (.systemAudio, .interviewer, "Okay. Suppose you had another month to improve the system, what would you change first?", "Suppose you had another month to improve the system, what would you change first?"),
            (.microphone, .candidate, "The synthetic candidate would improve the evaluation and add more robust recovery tests.", nil),
            (.systemAudio, .interviewer, "Thanks. Now thinking about this role, why do you want to join our team?", "Why do you want to join our team?"),
            (.microphone, .candidate, "The synthetic candidate is interested because the opportunity focuses on dependable software.", nil),
            (.systemAudio, .interviewer, "Great. That covers my questions. Do you have any questions for us?", nil)
        ]

        var detected: [DetectedQuestion] = []
        var detectedIDs = Set<String>()
        var generationQuestionIDs = [String]()

        for (index, item) in dialogue.enumerated() {
            let segment = segment(
                id: "long-\(index)",
                sessionID: session.id,
                source: item.0,
                speaker: item.1,
                text: item.2
            )
            let previousDetectedCount = appState.detectedQuestionsInSessionCount
            await appState.handleTranscriptSegment(segment)

            if let expectedQuestion = item.3 {
                try await waitUntil(timeout: 8.0) {
                    appState.lastDetectedQuestion?.transcriptSegmentID == segment.id &&
                    appState.detectedQuestionsInSessionCount == previousDetectedCount + 1 &&
                    appState.activeQuestionID == appState.lastDetectedQuestion?.id
                }
                let question = try #require(appState.lastDetectedQuestion)
                detected.append(question)
                detectedIDs.insert(question.id)
                generationQuestionIDs.append(try #require(appState.activeQuestionID))

                #expect(question.questionText == expectedQuestion)
                #expect(question.shouldTrigger)
                #expect(question.questionComplete)
                #expect(question.confidence >= 0.75)
                #expect(appState.activeTriggerPath == .autoDetect)
                #expect(appState.lastDetectedQuestionSource == AudioSourceType.systemAudio.rawValue)
                #expect(appState.lastDetectedQuestionSpeaker == SpeakerRole.interviewer.rawValue)
                #expect(appState.currentGenerationTelemetry.source == AudioSourceType.systemAudio.rawValue)
                #expect(appState.currentGenerationTelemetry.speaker == SpeakerRole.interviewer.rawValue)
                #expect(appState.lastQuestionConfidence >= 0.75)
            } else {
                try await Task.sleep(nanoseconds: 80_000_000)
                #expect(appState.transcriptSegments.contains { $0.id == segment.id })
                #expect(appState.detectedQuestionsInSessionCount == previousDetectedCount)
            }
        }

        #expect(detected.map(\.questionText) == dialogue.compactMap(\.3))
        #expect(detected.count == 7)
        #expect(detectedIDs.count == 7)
        #expect(generationQuestionIDs.count == 7)
        #expect(Set(generationQuestionIDs).count == 7)
        #expect(Set(appState.transcriptSegments.map(\.id)).count == dialogue.count)
    }

    @Test
    func asrPartialFinalUpdatesTriggerOnlyOnce() async throws {
        let (appState, session, _) = try makeAppState()
        let segmentID = "partial-final-question"
        let partials = [
            "Could you walk me",
            "Could you walk me through your synthetic service",
            "Could you walk me through your synthetic service project"
        ]

        for partial in partials {
            await appState.handleTranscriptSegment(segment(
                id: segmentID,
                sessionID: session.id,
                source: .systemAudio,
                speaker: .interviewer,
                text: partial,
                recognitionIsFinal: false
            ))
            try await Task.sleep(nanoseconds: 10_000_000)
            #expect(appState.detectedQuestionsInSessionCount == 0)
            #expect(appState.currentSpinnerVisible == false)
        }

        await appState.handleTranscriptSegment(segment(
            id: segmentID,
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Could you walk me through your synthetic service project, especially your role in the ingestion and routing pipeline?",
            recognitionIsFinal: true
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.lastDetectedQuestion?.transcriptSegmentID == segmentID
        }
        try await waitUntil(timeout: 8.0) {
            appState.visibleAnswerExists && !appState.currentSpinnerVisible
        }

        let question = try #require(appState.lastDetectedQuestion)
        #expect(question.questionText == "Could you walk me through your synthetic service project, especially your role in the ingestion and routing pipeline?")
        #expect(appState.activeQuestionID == question.id)
        #expect(!appState.currentSpinnerVisible)
        #expect(appState.duplicateSuppressionCount == 0)
    }

    @Test
    func rotatedCumulativeCallbacksDoNotRestartConsumedQuestions() async throws {
        let (appState, session, _) = try makeAppState()
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-cumulative-\(UUID().uuidString).jsonl")
        appState.runtimeTranscriptTraceLogURL = traceURL
        var traceSettings = appState.settings
        traceSettings.saveTranscriptsLocally = true
        traceSettings.diagnosticTraceMode = .fullText
        appState.saveSettings(traceSettings)
        let firstQuestion = "Could you explain your synthetic event-processing project from end to end?"
        let secondQuestion = "How did you convert archived event records into inputs that a deterministic staging simulator could use?"

        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: firstQuestion,
            recognitionTaskID: "rotated-apple-task",
            recognitionEventSequence: 1
        ))
        try await waitUntil(timeout: 8.0) {
            appState.currentSuggestion?.questionText == SystemAudioQuestionExtractor.extract(from: firstQuestion).last?.text
        }

        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }
        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-2",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "\(firstQuestion) \(secondQuestion)",
            recognitionTaskID: "rotated-apple-task-restart",
            recognitionEventSequence: 1
        ))
        let expectedSecondQuestion = try #require(SystemAudioQuestionExtractor.extract(from: secondQuestion).last?.text)
        try await waitUntil(timeout: 8.0) {
            appState.currentSuggestion?.questionText == expectedSecondQuestion &&
                appState.pendingAcceptedQuestions.isEmpty
        }
        #expect(appState.detectedQuestionsInSessionCount == 2)
        #expect(appState.currentSuggestion?.questionText == expectedSecondQuestion)
        #expect(appState.activeQuestionID == appState.currentSuggestion?.detectedQuestionID)

        appState.transcriptReconciler.reset()
        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }
        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-3",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "\(firstQuestion) \(secondQuestion)",
            recognitionTaskID: "rotated-apple-task-second-replay",
            recognitionEventSequence: 1
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 2)
        #expect(appState.currentSuggestion?.questionText == expectedSecondQuestion)
        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        #expect(trace.contains("\"event_type\":\"cumulativeReplayRejected\""))
        #expect(trace.contains("\"old_recognition_task_id\":\"rotated-apple-task"))
        #expect(trace.contains("\"new_recognition_task_id\":\"rotated-apple-task-second-replay\""))
    }

    @Test
    func distinctNewUtteranceCanIntentionallyRepeatAQuestion() async throws {
        let (appState, session, _) = try makeAppState()
        let question = "What was the hardest technical challenge in making the production service work reliably?"

        await appState.handleTranscriptSegment(segment(
            id: "explicit-repeat-utterance-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: question
        ))
        try await waitUntil(timeout: 8.0) { appState.detectedQuestionsInSessionCount == 1 }
        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }

        await appState.handleTranscriptSegment(segment(
            id: "explicit-repeat-utterance-2",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: question
        ))
        try await waitUntil(timeout: 8.0) { appState.detectedQuestionsInSessionCount == 2 }

        #expect(appState.lastDetectedQuestion?.questionText == question)
        let repeatedID = try #require(appState.lastDetectedQuestion?.id)
        #expect(appState.intentionalRepeatQuestionIDs.contains(repeatedID))
    }

    @Test
    func longInterviewerMonologueDetectsOnlyFinalQuestion() async throws {
        let (appState, session, _) = try makeAppState()
        let text = "Before I ask the next question, let me explain a little bit about this synthetic opportunity. The fictional team works with deployed software services, event processing, observability, and production reliability. The team is small, so it values people who can debug across application and infrastructure layers. With that context, can you explain how your previous software systems experience prepares you for this role?"
        await appState.handleTranscriptSegment(segment(id: "monologue", sessionID: session.id, source: .systemAudio, speaker: .interviewer, text: text))

        try await waitUntil(timeout: 8.0) {
            appState.lastDetectedQuestion?.transcriptSegmentID == "monologue"
        }

        #expect(appState.detectedQuestionsInSessionCount == 1)
        #expect(appState.lastDetectedQuestion?.questionText == "Can you explain how your previous software systems experience prepares you for this role?")
    }

    @Test
    func consecutiveFollowUpQuestionsQueueSafely() async throws {
        let (appState, session, _) = try makeAppState()
        let questions = [
            "What was the hardest technical challenge in your synthetic event-processing project?",
            "How did you solve the noisy event and routing timing issue in your synthetic project?",
            "If the same issue happened again in the synthetic ingestion and persistence pipeline, what would you do differently?"
        ]
        var activeQuestionIDs: [String] = []
        var acceptedQuestions: [DetectedQuestion] = []
        for (index, text) in questions.enumerated() {
            let id = "follow-up-\(index)"
            await appState.handleTranscriptSegment(segment(id: id, sessionID: session.id, source: .systemAudio, speaker: .interviewer, text: text))
            try await waitUntil(timeout: 8.0) {
                appState.lastDetectedQuestion?.transcriptSegmentID == id &&
                appState.detectedQuestionsInSessionCount == index + 1 &&
                appState.activeQuestionID == appState.lastDetectedQuestion?.id
            }
            acceptedQuestions.append(try #require(appState.lastDetectedQuestion))
            activeQuestionIDs.append(try #require(appState.activeQuestionID))
        }

        #expect(appState.detectedQuestionsInSessionCount == 3)
        #expect(Set(activeQuestionIDs).count == 3)
        #expect(appState.lastDetectedQuestion?.questionText == "If the same issue happened again in the synthetic ingestion and persistence pipeline, what would you do differently?")
        #expect(appState.currentGenerationTelemetry.questionID == activeQuestionIDs.last)
        let middleQuestion = acceptedQuestions[1]
        let middleSnapshot = appState.makeInitialFirstAnswerFallbackCard(
            cardID: "middle-question-alignment-regression",
            question: middleQuestion,
            session: session,
            requestStart: Date()
        )
        #expect(AnswerRelevancePolicy.intent(for: middleQuestion.questionText) == .errorHandling)
        let middleAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: middleQuestion.questionText,
            answerText: ([middleSnapshot.sayFirst] + middleSnapshot.keyPoints + middleSnapshot.followUpReady).joined(separator: " "),
            sayFirst: middleSnapshot.sayFirst,
            stageBCompleted: true
        )
        #expect(middleAlignment.verdict == .aligned, "Middle snapshot alignment: \(middleAlignment.reason)")
        try await waitUntil(timeout: 8.0) {
            appState.visibleAnswerExists && !appState.currentSpinnerVisible
        }
        try await waitUntil(timeout: 8.0) {
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == questions.count
        }
        let persistedCards = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(persistedCards.count == questions.count)
        #expect(Set(persistedCards.compactMap(\.detectedQuestionID)) == Set(activeQuestionIDs))
        let middleCard = try #require(persistedCards.first { $0.detectedQuestionID == activeQuestionIDs[1] })
        #expect(middleCard.alignmentVerdict == .aligned)
        #expect(middleCard.stageBStatus == "superseded" || middleCard.stageBStatus == "queued_next_question")
        #expect(appState.currentSuggestion?.detectedQuestionID == activeQuestionIDs.last)
        // A queued question may supersede each preceding generation once after
        // the two-second handoff deadline. Repeated cancellation is not valid.
        #expect(appState.cancelledGenerationCount <= questions.count - 1)
        #expect(!appState.currentSpinnerVisible)
    }

    @Test
    func candidateQuestionLikeSpeechNeverAutoTriggers() async throws {
        let (appState, session, _) = try makeAppState()
        await appState.handleTranscriptSegment(segment(
            id: "candidate-rhetorical-question",
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "The synthetic candidate would answer by explaining an event pipeline. Maybe the question is, how did I handle routing errors? The sample answer uses retry and recovery behaviour."
        ))

        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(appState.lastDetectedQuestion == nil)
        #expect(appState.activeQuestionID == nil)
        #expect(appState.ignoredCandidateQuestionCount == 1)
    }

    private func makeAppState() throws -> (AppState, InterviewSession, LongInterviewLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "LongInterviewQuestionDetectionTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let client = LongInterviewLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: LongInterviewEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = RealDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)

        let session = try makeHermeticContextBoundSession(appState: appState, prefix: "long-interview")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return (appState, session, client)
    }

    private func segment(
        id: String,
        sessionID: String,
        source: AudioSourceType,
        speaker: SpeakerRole,
        text: String,
        recognitionTaskID: String? = nil,
        recognitionEventSequence: Int? = nil,
        recognitionIsFinal: Bool? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: source,
            speaker: speaker,
            text: text,
            createdAt: Date(),
            asrFinalizationReason: recognitionIsFinal.map { $0 ? "final_accepted" : "partial" },
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: recognitionEventSequence,
            sourceTextStartUTF16: recognitionTaskID == nil ? nil : 0,
            sourceTextEndUTF16: recognitionTaskID == nil ? nil : (text as NSString).length,
            recognitionIsFinal: recognitionIsFinal ?? (recognitionTaskID == nil ? nil : true)
        )
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "LongInterviewQuestionDetectionTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for long interview question detection state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class LongInterviewLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek

    private let answerWorthyQuestions: [(needle: String, question: String, intent: String, strategy: String)] = [
        ("could you tell me a little bit about yourself", "Could you tell me a little bit about yourself and what brought you into software systems?", "behavioral", "star_story"),
        ("could you walk me through that project", "Could you walk me through that project, especially your role in the ingestion and routing pipeline?", "project_deep_dive", "project_walkthrough"),
        ("what was the hardest technical challenge you faced", "What was the hardest technical challenge you faced?", "behavioral", "star_story"),
        ("how did you handle noisy events", "How did you handle noisy events or routing errors?", "technical", "technical_explanation"),
        ("why did the diffusion decoder perform better", "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your synthetic evaluation?", "technical", "technical_explanation"),
        ("suppose you had another month to improve the system", "Suppose you had another month to improve the system, what would you change first?", "technical", "direct_answer"),
        ("why do you want to join our team", "Why do you want to join our team?", "company_fit", "direct_answer"),
        ("do you have any questions for us", "Do you have any questions for us?", "company_fit", "direct_answer"),
        ("can you explain how your previous software systems experience prepares you for this role", "Can you explain how your previous software systems experience prepares you for this role?", "company_fit", "direct_answer"),
        ("what was the hardest technical challenge in your synthetic event-processing project", "What was the hardest technical challenge in your synthetic event-processing project?", "behavioral", "star_story"),
        ("how did you solve the noisy event and routing timing issue in your synthetic project", "How did you solve the noisy event and routing timing issue in your synthetic project?", "technical", "technical_explanation"),
        ("if the same issue happened again in the synthetic ingestion and persistence pipeline", "If the same issue happened again in the synthetic ingestion and persistence pipeline, what would you do differently?", "behavioral", "star_story"),
        ("and how did you solve it", "And how did you solve it?", "technical", "technical_explanation"),
        ("if the same issue happened again", "If the same issue happened again, what would you do differently?", "behavioral", "star_story"),
        ("could you walk me through your synthetic service project, especially your role", "Could you walk me through your synthetic service project, especially your role in the ingestion and routing pipeline?", "project_deep_dive", "project_walkthrough")
    ]

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Mock OK", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        if prompt.contains("Decide whether the interviewer has asked") {
            return detectionResult(for: prompt)
        }
        let answer = hermeticRuntimeAnswer(for: prompt)
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": \(hermeticJSONString(answer)),
          "key_points": ["\(answer.prefix(90))", "Ground the answer in the synthetic candidate evidence"],
          "follow_up_ready": ["I can go deeper into the implementation."],
          "confidence": 0.86,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "long-interview-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let answer = hermeticRuntimeAnswer(for: prompt)
        return AsyncThrowingStream { continuation in
            Task {
                if prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.") {
                    for token in hermeticRuntimeSectionTokens(for: prompt) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                    return
                }
                for token in answer.split(separator: " ") {
                    continuation.yield(String(token) + " ")
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    private func detectionResult(for prompt: String) -> LLMChatResult {
        let latestInterviewerLine = latestInterviewerLine(from: prompt)
        let lower = latestInterviewerLine.lowercased()
        if let match = answerWorthyQuestions.first(where: { lower.contains($0.needle) }) {
            let content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": \(jsonString(match.question)),
              "intent": "\(match.intent)",
              "answer_strategy": "\(match.strategy)",
              "confidence": 0.95,
              "reason": "Complete interviewer question."
            }
            """
            return LLMChatResult(content: content, modelName: "long-interview-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
        }

        let content = """
        {
          "should_trigger": false,
          "question_complete": false,
          "question_text": "",
          "intent": "small_talk",
          "answer_strategy": "wait",
          "confidence": 0.15,
          "reason": "Small talk, explanation, or candidate speech should not trigger an answer."
        }
        """
        return LLMChatResult(content: content, modelName: "long-interview-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
    }

    private func latestInterviewerLine(from prompt: String) -> String {
        let transcript = prompt
            .components(separatedBy: "Recent transcript:")
            .last?
            .components(separatedBy: "Decide whether")
            .first ?? prompt
        return transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { $0.lowercased().hasPrefix("interviewer:") }?
            .replacingOccurrences(of: "Interviewer:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

private final class LongInterviewEmptyContextRetrievalService: ContextRetrievalService {
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
