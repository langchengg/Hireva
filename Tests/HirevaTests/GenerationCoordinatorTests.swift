import Foundation
import Testing
@testable import Hireva

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
        #expect(result.identity == input.request.identity)
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
        #expect(result.identity == input.request.identity)
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

    @Test
    func stageBFullCardResultReturnsApplyFullCardWithoutAppState() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let sections = makeAlignedStageBSections()
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections)

        let result = coordinator.interpretStageBResult(
            generationID: "generation-2e",
            detectedQuestionID: "question-2e",
            activeGenerationID: "generation-2e",
            questionText: question,
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        #expect(result.decision == .applyFullCard)
        #expect(result.classification == .usableFullCard)
        #expect(result.alignmentResult?.verdict == .aligned)
        #expect(result.safeDiagnostics["stageBDecision"] == "applyFullCard")
    }

    @Test
    func fullCardStageBResultCreatesApplyFullCardApplicationPlan() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let sections = makeAlignedStageBSections()
        let identity = GenerationIdentity(
            acceptedQuestionID: "question-apply",
            generationID: "generation-apply",
            sessionID: "session-apply",
            questionText: question,
            promptPrimaryQuestion: question
        )
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections, identity: identity)
        let result = coordinator.interpretStageBResult(
            generationID: "generation-apply",
            detectedQuestionID: "question-apply",
            activeGenerationID: "generation-apply",
            questionText: question,
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: nil,
            activeGenerationID: "generation-apply",
            activeQuestionID: "question-apply"
        )

        #expect(plan.action == .applyFullCard)
        #expect(plan.shouldPersist)
        #expect(plan.shouldUpdateVisibleCard)
        #expect(plan.safeDiagnostics["stageBApplicationAction"] == "applyFullCard")
        #expect(result.identity == identity)
        #expect(plan.identity == identity)
    }

    @Test
    func stageBTimeoutWithAlignedVisibleAnswerKeepsFirstVisibleAnswer() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let visibleAnswer = "I would say diffusion is more stable because it denoises a continuous action trajectory, while autoregressive step-by-step prediction can accumulate errors and become less robust in manipulation."
        let providerResult = makeStageBProviderResult(
            status: .timedOut,
            sections: nil,
            errorClassification: .timeout,
            errorMessage: "Request timed out after 15.0s"
        )

        let result = coordinator.interpretStageBResult(
            generationID: "generation-timeout",
            detectedQuestionID: "question-timeout",
            activeGenerationID: "generation-timeout",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: visibleAnswer,
            visibleAnswerExists: true
        )

        #expect(result.decision == .keepFirstVisibleAnswer)
        #expect(result.classification == .timedOut)
        #expect(result.fallbackReason == nil)
    }

    @Test
    func timeoutWithAlignedVisibleAnswerCreatesKeepVisibleApplicationPlan() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let visibleAnswer = "I would say diffusion is more stable because it denoises a continuous action trajectory, while autoregressive step-by-step prediction can accumulate errors and become less robust in manipulation."
        let providerResult = makeStageBProviderResult(
            status: .timedOut,
            sections: nil,
            errorClassification: .timeout,
            errorMessage: "Request timed out after 15.0s"
        )
        let result = coordinator.interpretStageBResult(
            generationID: "generation-timeout-plan",
            detectedQuestionID: "question-timeout-plan",
            activeGenerationID: "generation-timeout-plan",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: visibleAnswer,
            visibleAnswerExists: true
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: makeVisibleSuggestion(id: "visible-timeout", questionID: "question-timeout-plan", sayFirst: visibleAnswer),
            activeGenerationID: "generation-timeout-plan",
            activeQuestionID: "question-timeout-plan"
        )

        #expect(plan.action == .keepVisibleFirstAnswer)
        #expect(plan.shouldPersist)
        #expect(plan.shouldUpdateVisibleCard == false)
        #expect(plan.fallbackReason == nil)
    }

    @Test
    func timeoutWithoutValidVisibleAnswerCreatesSemanticFallbackApplicationPlan() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let providerResult = makeStageBProviderResult(
            status: .timedOut,
            sections: nil,
            errorClassification: .timeout,
            errorMessage: "Request timed out after 15.0s"
        )
        let result = coordinator.interpretStageBResult(
            generationID: "generation-timeout-fallback",
            detectedQuestionID: "question-timeout-fallback",
            activeGenerationID: "generation-timeout-fallback",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: "I would discuss my background.",
            visibleAnswerExists: true
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: makeVisibleSuggestion(id: "generic-visible", questionID: "question-timeout-fallback", sayFirst: "I would discuss my background."),
            activeGenerationID: "generation-timeout-fallback",
            activeQuestionID: "question-timeout-fallback"
        )

        #expect(plan.action == .useSemanticFallback)
        #expect(plan.shouldPersist)
        #expect(plan.shouldUpdateVisibleCard)
        #expect(plan.fallbackReason?.contains("timed out") == true)
    }

    @Test
    func stageBProviderFailureReturnsFallbackDecisionWithoutAppState() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let providerResult = makeStageBProviderResult(
            status: .failed,
            sections: nil,
            errorClassification: .network,
            errorMessage: "offline"
        )

        let result = coordinator.interpretStageBResult(
            generationID: "generation-failure",
            detectedQuestionID: "question-failure",
            activeGenerationID: "generation-failure",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        #expect(result.decision == .useSemanticFallback)
        #expect(result.classification == .providerFailure)
        #expect(result.fallbackReason?.contains("provider failed") == true)
    }

    @Test
    func providerFailureCreatesFallbackApplicationPlanWithoutAppState() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let providerResult = makeStageBProviderResult(
            status: .failed,
            sections: nil,
            errorClassification: .network,
            errorMessage: "offline"
        )
        let result = coordinator.interpretStageBResult(
            generationID: "generation-provider-failure",
            detectedQuestionID: "question-provider-failure",
            activeGenerationID: "generation-provider-failure",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: nil,
            activeGenerationID: "generation-provider-failure",
            activeQuestionID: "question-provider-failure"
        )

        #expect(plan.action == .useSemanticFallback)
        #expect(plan.shouldPersist)
        #expect(plan.shouldUpdateVisibleCard)
        #expect(plan.safeDiagnostics["stageBClassification"] == "providerFailure")
    }

    @Test
    func staleStageBGenerationReturnsDiscardStaleResult() {
        let coordinator = GenerationCoordinator()
        let sections = makeAlignedStageBSections()
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections)

        let result = coordinator.interpretStageBResult(
            generationID: "old-generation",
            detectedQuestionID: "old-question",
            activeGenerationID: "new-generation",
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        #expect(result.decision == .discardStaleResult)
        #expect(result.classification == .staleResult)
        #expect(result.alignmentResult == nil)
    }

    @Test
    func staleGenerationCreatesDiscardApplicationPlan() {
        let coordinator = GenerationCoordinator()
        let sections = makeAlignedStageBSections()
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections)
        let result = coordinator.interpretStageBResult(
            generationID: "old-generation",
            detectedQuestionID: "old-question",
            activeGenerationID: "new-generation",
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: nil,
            visibleAnswerExists: false
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: nil,
            activeGenerationID: "new-generation",
            activeQuestionID: "new-question"
        )

        #expect(plan.action == .discardStaleResult)
        #expect(plan.shouldPersist == false)
        #expect(plan.shouldUpdateVisibleCard == false)
    }

    @Test
    func modelComparisonGenericVisibleAnswerRequiresFallbackDecision() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let sections = StreamingSuggestionSections(
            strategy: "General response",
            sayFirst: "I would focus on explaining the project clearly and connect it to my background.",
            keyPoints: [
                "I can describe my experience in robotics.",
                "I would keep the answer concise and practical."
            ],
            followUpReady: [],
            caution: ""
        )
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections)

        let result = coordinator.interpretStageBResult(
            generationID: "generation-generic",
            detectedQuestionID: "question-generic",
            activeGenerationID: "generation-generic",
            questionText: question,
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: sections.sayFirst,
            visibleAnswerExists: true
        )

        #expect(result.decision == .useSemanticFallback)
        #expect(result.classification == .fallbackRequired)
        #expect(result.alignmentResult?.verdict == .mismatched)
    }

    @Test
    func genericModelComparisonVisibleAnswerCreatesFallbackApplicationPlan() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let sections = StreamingSuggestionSections(
            strategy: "General response",
            sayFirst: "I would focus on explaining the project clearly and connect it to my background.",
            keyPoints: [
                "I can describe my experience in robotics.",
                "I would keep the answer concise and practical."
            ],
            followUpReady: [],
            caution: ""
        )
        let providerResult = makeStageBProviderResult(status: .completed, sections: sections)
        let result = coordinator.interpretStageBResult(
            generationID: "generation-generic-plan",
            detectedQuestionID: "question-generic-plan",
            activeGenerationID: "generation-generic-plan",
            questionText: question,
            providerResult: providerResult,
            sections: sections,
            sawStreamingSections: true,
            visibleSayFirst: sections.sayFirst,
            visibleAnswerExists: true
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: makeVisibleSuggestion(id: "visible-generic", questionID: "question-generic-plan", sayFirst: sections.sayFirst),
            activeGenerationID: "generation-generic-plan",
            activeQuestionID: "question-generic-plan"
        )

        #expect(plan.action == .useSemanticFallback)
        #expect(plan.shouldPersist)
        #expect(plan.shouldUpdateVisibleCard)
        #expect(plan.safeDiagnostics["alignmentVerdict"] == "mismatched")
    }

    @Test
    func applicationPlanDiagnosticsRedactRawAPIKey() {
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
        let coordinator = GenerationCoordinator()
        let result = GenerationStageBResult(
            generationID: "generation-\(rawKey)",
            detectedQuestionID: "question-\(rawKey)",
            providerResult: nil,
            decision: .applyFullCard,
            classification: .usableFullCard,
            fallbackReason: nil,
            safeDiagnostics: [
                "provider": "DeepSeek \(rawKey)",
                "model": "deepseek-\(rawKey)"
            ],
            alignmentResult: nil
        )

        let plan = coordinator.makeStageBApplicationPlan(
            from: result,
            visibleSuggestion: nil,
            activeGenerationID: "generation-\(rawKey)",
            activeQuestionID: "question-\(rawKey)"
        )

        #expect(plan.safeDiagnostics.keys.contains { $0.contains(rawKey) } == false)
        #expect(plan.safeDiagnostics.values.contains { $0.contains(rawKey) } == false)
        #expect(plan.generationID.contains(rawKey))
    }

    @Test
    func generationCoordinatorHasNoApplicationSideEffectOwnershipReferences() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/Hireva/Services/GenerationCoordinator.swift")
        let source = try String(contentsOf: sourceURL)
        let forbiddenReferences = [
            "currentSuggestion",
            "currentQuestion",
            "@Published",
            "activeGenerationController",
            "saveSuggestion",
            "SQLite",
            "GRDB",
            "stageBTask",
            "fallbackWatchdog",
            "fullCardWatchdog"
        ]

        for forbidden in forbiddenReferences {
            #expect(source.contains(forbidden) == false)
        }
    }

    @Test
    func stageBNoSectionsKeepsAlignedVisibleAnswer() {
        let coordinator = GenerationCoordinator()
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let visibleAnswer = "I would say diffusion is more stable because it denoises a continuous action trajectory, while autoregressive step-by-step prediction can accumulate errors and become less robust in manipulation."
        let providerResult = makeStageBProviderResult(status: .completed, sections: nil)

        let result = coordinator.interpretStageBResult(
            generationID: "generation-empty",
            detectedQuestionID: "question-empty",
            activeGenerationID: "generation-empty",
            questionText: question,
            providerResult: providerResult,
            sections: nil,
            sawStreamingSections: false,
            visibleSayFirst: visibleAnswer,
            visibleAnswerExists: true
        )

        #expect(result.decision == .keepFirstVisibleAnswer)
        #expect(result.classification == .noSections)
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

    private func makeAlignedStageBSections() -> StreamingSuggestionSections {
        StreamingSuggestionSections(
            strategy: "Direct comparison",
            sayFirst: "I would say diffusion is more stable because it denoises a whole continuous action trajectory, while autoregressive prediction can accumulate errors step by step.",
            keyPoints: [
                "Diffusion models smooth continuous actions.",
                "Autoregressive models can accumulate sequential errors.",
                "That makes diffusion more robust during robotic manipulation."
            ],
            followUpReady: ["I would validate this across more object starts."],
            caution: ""
        )
    }

    private func makeStageBProviderResult(
        status: GenerationProviderStatus,
        sections: StreamingSuggestionSections?,
        errorClassification: GenerationProviderErrorClassification? = nil,
        errorMessage: String? = nil,
        identity: GenerationIdentity? = nil
    ) -> GenerationProviderResult {
        GenerationProviderResult(
            identity: identity,
            sayFirst: sections?.sayFirst ?? "",
            keyPoints: sections?.keyPoints ?? [],
            followUp: sections?.followUpReady ?? [],
            parsedSections: sections,
            latencyMS: status == .completed ? 42 : nil,
            firstTokenMS: nil,
            firstVisibleMS: nil,
            providerID: "deepseek",
            providerName: "DeepSeek",
            providerModel: "mock-model",
            providerKind: .deepSeek,
            safeDiagnostics: ["providerStatus": status.rawValue],
            providerStatus: status,
            errorClassification: errorClassification,
            errorMessage: errorMessage
        )
    }

    private func makeVisibleSuggestion(
        id: String,
        questionID: String,
        sayFirst: String
    ) -> SuggestionCard {
        SuggestionCard(
            id: id,
            sessionID: "coordinator-session",
            questionID: questionID,
            strategy: "Visible first answer",
            sayFirst: sayFirst,
            keyPoints: [],
            followUpReady: [],
            confidence: 0.8,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "mock",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
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
