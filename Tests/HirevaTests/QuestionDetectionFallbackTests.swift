import Foundation
import Testing
@testable import Hireva

@Suite
struct QuestionDetectionFallbackTests {
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
    private(set) var chatCompletionCallCount = 0
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
        chatCompletionCallCount += 1
        throw error
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}
