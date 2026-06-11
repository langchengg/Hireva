import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct SystemAudioQuestionOnlyAutoGenerationTests {
    @Test
    func interviewerOnlySystemAudioUnknownSpeakerAutoGeneratesEveryQuestionWithoutQuestionMarks() async throws {
        let (appState, session, client) = try makeAppState()
        let questions = [
            "First, could you tell me a little bit about yourself and what brought you into robotics",
            "Great, thanks. Could you walk me through your LeoRover project",
            "What was the hardest technical challenge you faced",
            "How did you handle noisy detections or localisation errors",
            "Why did the diffusion decoder perform better in your MuJoCo evaluation",
            "What would you change first if you had another month",
            "Why do you want to join our team",
            "How comfortable are you with Python, C plus plus, and ROS two",
            "Do you have any questions for us"
        ]

        await appState.handleTranscriptSegment(systemAudioUnknownSegment(
            id: "question-only-greeting",
            sessionID: session.id,
            text: "Hi Lang, thanks for joining today"
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

            try await waitUntil(timeout: 10.0) {
                appState.detectedQuestionsInSessionCount == beforeDetected + 1 &&
                appState.lastDetectedQuestion?.transcriptSegmentID == segmentID &&
                appState.currentSuggestion?.questionID == appState.lastDetectedQuestion?.id &&
                appState.currentGenerationTelemetry.questionID == appState.lastDetectedQuestion?.id &&
                appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated
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
        #expect(client.detectionCallCount == questions.count)
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
            contextRetrievalService: QuestionOnlyEmptyContextRetrievalService()
        )
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = autoDetectEnabled
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return (appState, session, client)
    }

    private func systemAudioUnknownSegment(id: String, sessionID: String, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .unknown,
            text: text,
            createdAt: Date(),
            confidence: 1.0
        )
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "SystemAudioQuestionOnlyAutoGenerationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for transcript-to-answer state."]
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
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": "I would answer this with a concise first-person robotics example.",
          "key_points": ["Connect the question to robotics experience", "Explain the technical choice", "Close with the result"],
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
        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                if prompt.contains("Return plain text sections only") {
                    continuation.finish()
                    return
                }
                for token in ["I ", "would ", "answer ", "with ", "a ", "specific ", "robotics ", "example."] {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    private func detectionResult(for prompt: String) -> LLMChatResult {
        let latestLine = latestTranscriptLine(from: prompt)
        let lower = latestLine.lowercased()
        let question: String?
        if lower.contains("could you tell me a little bit about yourself") {
            question = "Could you tell me a little bit about yourself and what brought you into robotics?"
        } else if lower.contains("could you walk me through your leorover project") || lower.contains("could you walk me through your leo rover project") {
            question = "Could you walk me through your LeoRover project?"
        } else if lower.contains("what was the hardest technical challenge") {
            question = "What was the hardest technical challenge you faced?"
        } else if lower.contains("how did you handle noisy detections") {
            question = "How did you handle noisy detections or localisation errors?"
        } else if lower.contains("why did the diffusion decoder perform better") {
            question = "Why did the diffusion decoder perform better in your MuJoCo evaluation?"
        } else if lower.contains("what would you change first") {
            question = "What would you change first if you had another month?"
        } else if lower.contains("why do you want to join our team") {
            question = "Why do you want to join our team?"
        } else if lower.contains("how comfortable are you with python") {
            question = "How comfortable are you with Python, C++, and ROS2?"
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
