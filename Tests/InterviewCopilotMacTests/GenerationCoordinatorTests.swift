import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct GenerationCoordinatorTests {
    @Test
    func coordinatorInitializesWithDependenciesWithoutAppState() async throws {
        let delayProvider = RecordingDelayProvider()
        let dependencies = GenerationCoordinator.Dependencies(delayProvider: delayProvider)
        let coordinator = GenerationCoordinator(dependencies: dependencies)

        try await coordinator.dependencies.delayProvider.sleep(nanoseconds: 123)

        #expect(coordinator.dependencies.suggestionGenerationService == nil)
        #expect(delayProvider.recordedSleeps == [123])
    }

    @Test
    func elapsedMSIsDeterministicWhenNowIsSupplied() {
        let start = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 101.5)

        #expect(GenerationCoordinator.elapsedMS(since: start, now: now) == 1500)
    }

    @Test
    func timeoutHelperReturnsCompletedOperation() async throws {
        let value = try await GenerationCoordinator.withTimeout(seconds: 1.0) {
            "completed"
        }

        #expect(value == "completed")
    }

    @Test
    func timeoutHelperThrowsSameTimeoutErrorShape() async throws {
        do {
            _ = try await GenerationCoordinator.withTimeout(seconds: 0.001) {
                try await Task.sleep(nanoseconds: 50_000_000)
                return "late"
            }
            Issue.record("Expected timeout helper to throw")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "TimeoutDomain")
            #expect(nsError.code == 1)
            #expect(nsError.localizedDescription.contains("Request timed out after 0.001s"))
        }
    }

    @Test
    func specificAnswerCheckMatchesExistingCompletenessRules() {
        #expect(GenerationCoordinator.isSpecificAnswer("short answer") == false)
        #expect(GenerationCoordinator.isSpecificAnswer("Based on my experience") == false)
        #expect(GenerationCoordinator.isSpecificAnswer("The diffusion policy was more stable because it produced smoother continuous actions and recovered better from small trajectory errors.") == true)
    }

    @Test
    func providerExecutionReturnsTypedSuccessResultWithoutAppState() async throws {
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
        let client = CoordinatorProviderMockClient(
            result: .success(Self.successfulProviderJSON),
            modelName: "mock-model-\(rawKey)",
            providerName: "DeepSeek \(rawKey)"
        )
        let coordinator = try makeProviderCoordinator(client: client)
        let input = makeProviderInput(
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            providerModel: "deepseek-v4-\(rawKey)"
        )

        let result = await coordinator.executeProviderRequest(
            input.request,
            question: input.question,
            context: input.context,
            transcriptContext: input.transcript,
            sessionID: input.session.id,
            cvSummary: input.cvSummary,
            jdSummary: input.jdSummary,
            providerConfiguration: input.providerConfiguration
        )

        #expect(result.providerStatus == .completed)
        #expect(result.errorClassification == nil)
        #expect(result.sayFirst.localizedCaseInsensitiveContains("diffusion"))
        #expect(result.sayFirst.localizedCaseInsensitiveContains("autoregressive"))
        #expect(result.keyPoints == [
            "Diffusion models smooth continuous actions.",
            "Autoregressive models can accumulate sequential errors."
        ])
        #expect(result.followUp == ["I would validate this across more object starts."])
        #expect(result.providerModel == "mock-model-[REDACTED_API_KEY]")
        #expect(result.providerName == "DeepSeek [REDACTED_API_KEY]")
        #expect(result.safeDiagnostics.values.contains { $0.contains(rawKey) } == false)
        #expect(client.chatCallCount == 1)
        #expect(client.lastResponseFormat == .jsonObject)
        #expect(client.lastOptions?.stream == false)
    }

    @Test
    func providerExecutionReturnsTypedFailureResult() async throws {
        let client = CoordinatorProviderMockClient(
            result: .failure(LLMProviderError.networkFailure(providerName: "DeepSeek", message: "offline"))
        )
        let coordinator = try makeProviderCoordinator(client: client)
        let input = makeProviderInput(questionText: "Why do you want to join our team?")

        let result = await coordinator.executeProviderRequest(
            input.request,
            question: input.question,
            context: input.context,
            transcriptContext: input.transcript,
            sessionID: input.session.id,
            cvSummary: input.cvSummary,
            jdSummary: input.jdSummary,
            providerConfiguration: input.providerConfiguration
        )

        #expect(result.providerStatus == .failed)
        #expect(result.errorClassification == .network)
        #expect(result.sayFirst.isEmpty)
        #expect(result.keyPoints.isEmpty)
        #expect(result.providerModel == input.request.model)
        #expect(result.safeDiagnostics["errorClassification"] == "network")
    }

    @Test
    func providerExecutionClassifiesTimeoutLikeOldTimeoutPath() async throws {
        let timeout = NSError(
            domain: "TimeoutDomain",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out after 15.0s"]
        )
        let client = CoordinatorProviderMockClient(result: .failure(timeout))
        let coordinator = try makeProviderCoordinator(client: client)
        let input = makeProviderInput(questionText: "Why do you want to join our team?")

        let result = await coordinator.executeProviderRequest(
            input.request,
            question: input.question,
            context: input.context,
            transcriptContext: input.transcript,
            sessionID: input.session.id,
            cvSummary: input.cvSummary,
            jdSummary: input.jdSummary,
            providerConfiguration: input.providerConfiguration
        )

        #expect(result.providerStatus == .timedOut)
        #expect(result.errorClassification == .timeout)
        #expect(result.errorMessage?.contains("timed out") == true)
    }

    private static let successfulProviderJSON = """
    {
      "strategy": "Direct comparison",
      "say_first": "I would say diffusion is more stable because it denoises a whole continuous action trajectory, while autoregressive prediction can accumulate errors step by step.",
      "key_points": [
        "Diffusion models smooth continuous actions.",
        "Autoregressive models can accumulate sequential errors."
      ],
      "follow_up_ready": [
        "I would validate this across more object starts."
      ],
      "confidence": 0.86,
      "caution": "",
      "evidence_used": [],
      "risk_level": "low"
    }
    """

    private func makeProviderCoordinator(client: CoordinatorProviderMockClient) throws -> GenerationCoordinator {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "GenerationCoordinatorProvider")
        let settings = SettingsRepository(database: database)
        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])
        let service = SuggestionGenerationService(llmRouter: router)
        return GenerationCoordinator(
            dependencies: GenerationCoordinator.Dependencies(
                suggestionGenerationService: service
            )
        )
    }

    private func makeProviderInput(
        questionText: String,
        providerModel: String = "deepseek-v4"
    ) -> (
        request: GenerationProviderRequest,
        question: DetectedQuestion,
        context: RetrievedContext,
        transcript: String,
        session: InterviewSession,
        cvSummary: String,
        jdSummary: String,
        providerConfiguration: LLMProviderConfiguration
    ) {
        let question = DetectedQuestion(
            id: "coordinator-question-\(UUID().uuidString)",
            sessionID: "coordinator-session",
            transcriptSegmentID: "coordinator-segment",
            questionText: questionText,
            intent: .technical,
            answerStrategy: .directAnswer,
            confidence: 0.96,
            reason: "Coordinator provider execution test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
        let session = InterviewSession(
            id: "coordinator-session",
            title: "Coordinator Provider Test",
            company: nil,
            role: nil,
            startedAt: Date(timeIntervalSince1970: 1_717_171_700),
            endedAt: nil,
            mode: .mock,
            createdAt: Date(timeIntervalSince1970: 1_717_171_700)
        )
        let context = RetrievedContext(
            cvChunks: [
                DocumentChunk(
                    id: "diffusion-context",
                    documentID: "cv-doc",
                    documentType: .cv,
                    chunkIndex: 0,
                    content: "Diffusion policies produced smoother continuous actions than autoregressive policies and were more robust during MuJoCo manipulation.",
                    keywords: ["diffusion", "autoregressive", "continuous", "robust"],
                    sectionTitle: "VLA Project",
                    wordCount: 15,
                    metadataJSON: nil,
                    createdAt: Date()
                )
            ],
            jobDescriptionChunks: [],
            additionalNotesChunks: []
        )
        let transcript = "Interviewer: Earlier background only."
        let cvSummary = "Candidate compared diffusion and autoregressive robot policies."
        let jdSummary = "Robotics role."
        var providerConfiguration = LLMProviderConfiguration.deepSeekDefault(model: providerModel)
        providerConfiguration.name = "DeepSeek"
        let executionContext = GenerationExecutionContext.make(
            session: session,
            question: question,
            generationID: "coordinator-generation-\(question.id)",
            triggerPath: .autoDetect,
            provider: providerConfiguration,
            retrievedContext: context,
            transcriptSnapshot: transcript,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            startedAt: Date(timeIntervalSince1970: 1_717_171_719),
            source: .systemAudio,
            speaker: .interviewer,
            stage: .fullAnswer
        )
        return (
            GenerationProviderRequest(context: executionContext, streamingEnabled: false),
            question,
            context,
            transcript,
            session,
            cvSummary,
            jdSummary,
            providerConfiguration
        )
    }
}

private final class RecordingDelayProvider: DelayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var sleeps: [UInt64] = []

    var recordedSleeps: [UInt64] {
        lock.withLock { sleeps }
    }

    func sleep(nanoseconds: UInt64) async throws {
        lock.withLock { sleeps.append(nanoseconds) }
    }
}

private final class CoordinatorProviderMockClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek

    private let lock = NSLock()
    private let result: Result<String, Error>
    private let modelName: String
    private let providerName: String
    private(set) var lastResponseFormat: LLMResponseFormat?
    private(set) var lastOptions: LLMRequestOptions?
    private var callCount = 0

    var chatCallCount: Int {
        lock.withLock { callCount }
    }

    init(
        result: Result<String, Error>,
        modelName: String = "mock-model",
        providerName: String = "DeepSeek"
    ) {
        self.result = result
        self.modelName = modelName
        self.providerName = providerName
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
        lock.withLock {
            callCount += 1
            lastResponseFormat = responseFormat
            lastOptions = options
        }
        let content = try result.get()
        return LLMChatResult(
            content: content,
            modelName: modelName,
            providerKind: configuration.kind,
            providerName: providerName,
            baseURL: configuration.baseURL,
            latencyMS: 42,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}
