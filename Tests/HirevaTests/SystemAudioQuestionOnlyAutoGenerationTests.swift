import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
@MainActor
struct SystemAudioQuestionOnlyAutoGenerationTests {
    @Test
    func interviewerOnlySystemAudioUnknownSpeakerAutoGeneratesEveryQuestionWithoutQuestionMarks() async throws {
        let (appState, session, client) = try makeAppState()
        let questions = [
            "First, could you tell me a little bit about yourself and what brought you into software systems",
            "Great, thanks. Could you walk me through your synthetic event-processing project",
            "What was the hardest technical challenge you faced",
            "How did you handle noisy events or routing errors",
            "Why did the diffusion decoder perform better in your synthetic sequence-model evaluation",
            "What would you change first if you had another month",
            "Why do you want to join our team",
            "How comfortable are you with Python, C plus plus, and SQL"
        ]

        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: "question-only-greeting",
            sessionID: session.id,
            text: "Welcome, Synthetic Candidate, to this fictional interview"
        ))
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 0)

        var detectedQuestionIDs = Set<String>()
        for (index, text) in questions.enumerated() {
            let segmentID = "question-only-\(index)"
            let beforeDetected = appState.detectedQuestionsInSessionCount
            await appState.handleTranscriptSegment(systemAudioUnknownSegment(
                id: segmentID,
                sessionID: session.id,
                text: text
            ))

            try await waitUntil(appState: appState, timeout: 10.0) {
                appState.detectedQuestionsInSessionCount == beforeDetected + 1 &&
                appState.lastDetectedQuestion?.transcriptSegmentID == segmentID &&
                appState.currentSuggestion?.questionID == appState.lastDetectedQuestion?.id &&
                appState.currentGenerationTelemetry.questionID == appState.lastDetectedQuestion?.id &&
                appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated &&
                appState.visibleAnswerExists &&
                appState.generationUIState.isTerminal &&
                !appState.currentSpinnerVisible
            }

            let question = try #require(appState.lastDetectedQuestion)
            detectedQuestionIDs.insert(question.id)
            #expect(question.shouldTrigger)
            #expect(question.questionComplete)
            #expect(question.confidence >= 0.75)
            #expect(appState.activeTriggerPath == .autoDetect)
            #expect(appState.lastDetectedQuestionSource == AudioSourceType.systemAudio.rawValue)
            #expect(appState.lastDetectedQuestionSpeaker == SpeakerRole.unknown.rawValue)
            #expect(appState.currentSuggestion?.questionID == question.id)
            #expect(!appState.currentSpinnerVisible)
            #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered)
            #expect(appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated)
        }

        #expect(detectedQuestionIDs.count == questions.count)
        #expect(appState.detectedQuestionsInSessionCount == questions.count)
        #expect(client.detectionCallCount == 0)
    }

    @Test
    func transcriptQuestionWithoutGenerationRecordsBlockedTrace() async throws {
        let (appState, session, _) = try makeAppState(autoDetectEnabled: false)
        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: "blocked-question",
            sessionID: session.id,
            text: "What was the hardest technical challenge you faced"
        ))
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(appState.transcriptSegments.contains { $0.id == "blocked-question" })
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastTranscriptQuestionGenerationTrace.transcriptSegmentID == "blocked-question")
        #expect(appState.lastTranscriptQuestionGenerationTrace.questionCandidate)
        #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered == false)
        #expect(appState.lastTranscriptQuestionGenerationTrace.generationBlockedReason == "autoDetectDisabled")
    }

    @Test
    func partialWhyDoYouWantDoesNotRunDetectionOrPersistQuestion() async throws {
        let (appState, session, client) = try makeAppState()

        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: "partial-why-role",
            sessionID: session.id,
            text: "why do you want",
            asrFinalizationReason: "partial"
        ))

        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(client.detectionCallCount == 0)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastTranscriptQuestionGenerationTrace.isFinal == false)
        #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered == false)
    }

    @Test
    func finalWhyRoleSupersedesPartialPrefixWithSameSegmentID() async throws {
        let (appState, session, client) = try makeAppState()
        let segmentID = "partial-to-final-why-role"

        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: segmentID,
            sessionID: session.id,
            text: "why do you want",
            asrFinalizationReason: "partial"
        ))
        try await Task.sleep(nanoseconds: 10_000_000)
        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: segmentID,
            sessionID: session.id,
            text: "Why do you want to join our team",
            asrFinalizationReason: "final_accepted"
        ))

        try await waitUntil(appState: appState, timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.lastDetectedQuestion?.transcriptSegmentID == segmentID &&
            appState.currentSuggestion?.questionID == appState.lastDetectedQuestion?.id &&
            appState.visibleAnswerExists &&
            appState.generationUIState.isTerminal &&
            !appState.currentSpinnerVisible
        }

        #expect(client.detectionCallCount == 0)
        #expect(appState.lastDetectedQuestion?.questionText == "Why do you want to join our team")
        #expect(appState.currentSuggestion?.questionText == "Why do you want to join our team")
        #expect(appState.currentSuggestion?.questionText != "why do you want")
    }

    private func makeAppState(autoDetectEnabled: Bool = true) throws -> (AppState, InterviewSession, QuestionOnlyLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "SystemAudioQuestionOnlyAutoGenerationTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = QuestionOnlyLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: QuestionOnlyEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = RealDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = autoDetectEnabled
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try makeHermeticContextBoundSession(appState: appState, prefix: "question-only")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return (appState, session, client)
    }

    private func systemAudioUnknownSegment(
        id: String,
        sessionID: String,
        text: String,
        asrFinalizationReason: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .unknown,
            text: text,
            createdAt: Date(),
            confidence: 1.0,
            asrFinalizationReason: asrFinalizationReason
        )
    }

    private func waitUntil(
        appState: AppState,
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "SystemAudioQuestionOnlyAutoGenerationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: [
                        "Timed out waiting for transcript-to-answer state.",
                        "detected=\(appState.detectedQuestionsInSessionCount)",
                        "lastSegment=\(appState.lastDetectedQuestion?.transcriptSegmentID ?? "nil")",
                        "lastQuestionID=\(appState.lastDetectedQuestion?.id ?? "nil")",
                        "suggestionQuestionID=\(appState.currentSuggestion?.questionID ?? "nil")",
                        "telemetryQuestionID=\(appState.currentGenerationTelemetry.questionID ?? "nil")",
                        "visible=\(appState.visibleAnswerExists)",
                        "terminal=\(appState.generationUIState.isTerminal)",
                        "spinner=\(appState.currentSpinnerVisible)",
                        "generationError=\(appState.visibleAssistantRenderState.generationErrorText ?? "nil")",
                        "alignmentError=\(appState.lastAlignmentError)"
                    ].joined(separator: " | ")]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class QuestionOnlyLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var detectionCalls = 0
    private var answerCalls = 0

    var detectionCallCount: Int {
        lock.withLock { detectionCalls }
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
        let prompt = messages.map(\.content).joined(separator: "\n")
        if prompt.contains("Decide whether the interviewer has asked") {
            lock.withLock { detectionCalls += 1 }
            return detectionResult(for: prompt)
        }

        lock.withLock { answerCalls += 1 }
        let answer = answerText(for: prompt)
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": \(jsonString(answer)),
          "key_points": ["\(answer.prefix(90))", "Keep the response grounded in the synthetic candidate evidence"],
          "follow_up_ready": ["I can go deeper into implementation details."],
          "confidence": 0.86,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "question-only-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let answer = answerText(for: prompt)
        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                if prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.") {
                    for section in [
                        "STRATEGY:\nDirect answer\n",
                        "SAY_FIRST:\n\(answer)\n",
                        "KEY_POINTS:\n",
                        "- \(answer.prefix(90))\n",
                        "- Keep the response grounded in the synthetic candidate evidence\n",
                        "FOLLOW_UP_READY:\n",
                        "- I can go deeper into implementation details.\n",
                        "CAUTION:\nNone\n"
                    ] {
                        continuation.yield(section)
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

    private func answerText(for prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("do you have any questions for us") {
            return "I would ask how the synthetic engineering team defines success for dependable deployed services and how debugging ownership is shared."
        }
        if lower.contains("how comfortable are you with python") {
            return "The synthetic candidate is comfortable with Python, C++, and SQL after using them to build and debug ingestion, routing, and persistence pipelines."
        }
        if lower.contains("why do you want to join our team") {
            return "For this synthetic candidate, I want to join this team because the role matches sample experience building dependable deployed services and aligns with my goal to deepen production reliability work."
        }
        if lower.contains("what would you change first") || lower.contains("another month") {
            return "With another month, I would first strengthen production-like evaluation and recovery tests around ingestion, routing, and persistence failures."
        }
        if lower.contains("diffusion decoder") {
            return "Compared with the autoregressive decoder, the diffusion decoder performed better in the synthetic sequence-model evaluation because it represented forecast distributions smoothly and tolerated input uncertainty better."
        }
        if lower.contains("noisy events") || lower.contains("routing errors") {
            return "The synthetic candidate diagnosed noisy events and routing errors by inspecting logs, confidence values, timestamps, schema drift, and retry state. Repeated observations, validation guards, and safe retry recovery reduced risk before committing work."
        }
        if lower.contains("hardest technical challenge") {
            return "The hardest technical challenge was making ingestion, validation, routing, and persistence behave reliably together in production. The synthetic candidate debugged each handoff with timestamp logs, isolated schema errors, and validated recovery tests."
        }
        if lower.contains("walk me through") || lower.contains("event-processing project") {
            return "The synthetic candidate built an event-processing pipeline that connected ingestion, validation, routing, persistence, and recovery behaviour. The result was repeatable end-to-end processing, and timestamp and schema validation proved essential at every handoff."
        }
        if lower.contains("tell me a little bit about yourself") {
            return "The synthetic candidate built a message-driven service connecting ingestion, validation, routing, persistence, and recovery behaviour, and that sample work anchors the technical background."
        }
        return "The synthetic candidate would answer the interviewer directly with a specific, evidence-grounded software example."
    }

    private func detectionResult(for prompt: String) -> LLMChatResult {
        let latestLine = latestTranscriptLine(from: prompt)
        let lower = latestLine.lowercased()
        let question: String?
        if lower.contains("could you tell me a little bit about yourself") {
            question = "Could you tell me a little bit about yourself and what brought you into software systems?"
        } else if lower.contains("could you walk me through your synthetic event-processing project") {
            question = "Could you walk me through your synthetic event-processing project?"
        } else if lower.contains("what was the hardest technical challenge") {
            question = "What was the hardest technical challenge you faced?"
        } else if lower.contains("how did you handle noisy events") {
            question = "How did you handle noisy events or routing errors?"
        } else if lower.contains("why did the diffusion decoder perform better") {
            question = "Why did the diffusion decoder perform better in your synthetic sequence-model evaluation?"
        } else if lower.contains("what would you change first") {
            question = "What would you change first if you had another month?"
        } else if lower.contains("why do you want to join our team") {
            question = "Why do you want to join our team?"
        } else if lower.contains("how comfortable are you with python") {
            question = "How comfortable are you with Python, C++, and SQL?"
        } else if lower.contains("do you have any questions for us") {
            question = "Do you have any questions for us?"
        } else {
            question = nil
        }

        let content: String
        if let question {
            content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": \(jsonString(question)),
              "intent": "technical",
              "answer_strategy": "direct_answer",
              "confidence": 0.95,
              "reason": "Complete interviewer question."
            }
            """
        } else {
            content = """
            {
              "should_trigger": false,
              "question_complete": false,
              "question_text": "",
              "intent": "small_talk",
              "answer_strategy": "wait",
              "confidence": 0.15,
              "reason": "Not an answer-worthy question."
            }
            """
        }
        return LLMChatResult(content: content, modelName: "question-only-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
    }

    private func latestTranscriptLine(from prompt: String) -> String {
        let transcript = prompt
            .components(separatedBy: "Recent transcript:")
            .last?
            .components(separatedBy: "Decide whether")
            .first ?? prompt
        return transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { line in
                let lower = line.lowercased()
                return lower.hasPrefix("interviewer:") || lower.hasPrefix("unknown:")
            }?
            .replacingOccurrences(of: "Interviewer:", with: "")
            .replacingOccurrences(of: "Unknown:", with: "")
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

private final class QuestionOnlyEmptyContextRetrievalService: ContextRetrievalService {
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
