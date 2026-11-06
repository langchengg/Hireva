import Foundation
import os
import Testing
@testable import Hireva

@Suite
struct QuestionDetectionFallbackTests {
    @Test
    func detectorFailurePreservesScopeAndRejectsIncompleteOrMultipleQuestions() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ScopedQuestionFallback")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let client = FailingQuestionDetectionClient()
        let service = QuestionDetectionService(llmRouter: LLMRouter(
            settingsRepository: settingsRepository, clients: [.deepSeek: client]
        ))
        for question in [
            "In your prototype, how did you test rollback?",
            "For notification delivery, how can an idempotency key prevent duplicate processing?"
        ] {
            let result = try await service.detect(transcriptContext: "Interviewer: \(question)",
                sessionID: "scoped-session", transcriptSegmentID: "scoped-segment")
            #expect(result.question.shouldTrigger)
            #expect(result.question.questionComplete)
            #expect(result.question.questionText == question)
            #expect(result.question.providerName == "Local Question Fallback")
            #expect(result.question.isLocal)
        }
        #expect(client.chatCompletionCallCount == 2)
        for rejected in [
            "In your prototype, why did you choose?",
            "For notification delivery, how can an idempotency key?",
            "In your report, you explained how the rollback was tested.",
            "How did you test rollback? In your prototype, which metrics did you compare?"
        ] {
            let result = try await service.detect(transcriptContext: rejected,
                sessionID: "scoped-session", transcriptSegmentID: "rejected-segment")
            #expect(!result.question.shouldTrigger)
            #expect(!result.question.questionComplete)
        }
    }

    @Test
    func conservativeDetectorUsesSharedAcceptanceForScopedQuestion() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ScopedQuestionNormalization")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let question = "For notification delivery, how can an idempotency key prevent duplicate processing?"
        let client = StaticQuestionDetectionClient(content: """
        {"should_trigger":false,"question_complete":false,"question_text":"\(question)",
         "intent":"project_deep_dive","answer_strategy":"wait","confidence":0.6,"reason":"Conservative detector"}
        """)
        let service = QuestionDetectionService(llmRouter: LLMRouter(
            settingsRepository: settingsRepository, clients: [.deepSeek: client]
        ))
        let result = try await service.detect(transcriptContext: question,
            sessionID: "scoped-session", transcriptSegmentID: "scoped-segment")
        #expect(result.question.shouldTrigger)
        #expect(result.question.questionComplete)
        #expect(result.question.questionText == question)
        #expect(result.question.reason?.contains("Local guardrail") == true)
    }

    @Test
    func providerConservativeWaitIsCorrectedForCompleteProjectQuestion() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let conservativeClient = StaticQuestionDetectionClient(content: """
        {
          "should_trigger": false,
          "question_complete": false,
          "question_text": "Could you walk me through your LeoRover project",
          "intent": "project_deep_dive",
          "answer_strategy": "wait",
          "confidence": 0.6,
          "reason": "The question appears incomplete; the interviewer likely intends to ask for more details about the project."
        }
        """)
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: conservativeClient])
        let service = QuestionDetectionService(llmRouter: router)

        let result = try await service.detect(
            transcriptContext: "Interviewer: Could you walk me through your LeoRover project",
            sessionID: "session-1",
            transcriptSegmentID: "segment-1"
        )

        #expect(result.question.shouldTrigger)
        #expect(result.question.questionComplete)
        #expect(result.question.questionText == "Could you walk me through your LeoRover project")
        #expect(result.question.intent == .projectDeepDive)
        #expect(result.question.answerStrategy == .projectWalkthrough)
        #expect(result.question.confidence >= 0.85)
        #expect(result.question.providerName == "Static Question Detection")
        #expect(result.question.reason?.contains("Local guardrail") == true)
    }

    @Test
    func localFallbackReturnsQuestionWhenDetectorProviderFails() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let failingClient = FailingQuestionDetectionClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: failingClient])
        let service = QuestionDetectionService(llmRouter: router)

        let result = try await service.detect(
            transcriptContext: "Interviewer: Why do you want this role can you",
            sessionID: "session-1",
            transcriptSegmentID: "segment-1"
        )

        #expect(result.question.shouldTrigger)
        #expect(result.question.questionComplete)
        #expect(result.question.questionText == "Why do you want this role")
        #expect(result.question.intent == .companyFit)
        #expect(result.question.providerName == "Local Question Fallback")
        #expect(result.question.isLocal)
        #expect(result.response.providerName == "Local Question Fallback")
    }

    @Test
    func localFallbackStillSkipsNonQuestionsWithoutCallingProvider() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let failingClient = FailingQuestionDetectionClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: failingClient])
        let service = QuestionDetectionService(llmRouter: router)

        let result = try await service.detect(
            transcriptContext: "Interviewer: I will share some background before the question.",
            sessionID: "session-1",
            transcriptSegmentID: "segment-1"
        )

        #expect(!result.question.shouldTrigger)
        #expect(!result.question.questionComplete)
        #expect(failingClient.chatCompletionCallCount == 0)
    }

    @Test
    func cancellationDoesNotCreateLocalFallbackQuestion() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let failingClient = FailingQuestionDetectionClient(error: CancellationError())
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: failingClient])
        let service = QuestionDetectionService(llmRouter: router)

        do {
            _ = try await service.detect(
                transcriptContext: "Interviewer: Why do you want this role?",
                sessionID: "session-1",
                transcriptSegmentID: "segment-1"
            )
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(failingClient.chatCompletionCallCount == 1)
        }
    }
}

private final class StaticQuestionDetectionClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let content: String

    init(content: String) {
        self.content = content
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        LLMChatResult(
            content: content,
            modelName: "deepseek-v4-flash",
            providerKind: .deepSeek,
            providerName: "Static Question Detection",
            baseURL: "https://example.invalid",
            latencyMS: 1,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}

private final class FailingQuestionDetectionClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var chatCompletionCallCount: Int { calls.withLock { $0 } }
    private let error: Error

    init(error: Error = LLMProviderError.invalidResponse("simulated detector failure")) {
        self.error = error
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        calls.withLock { $0 += 1 }
        throw error
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}
