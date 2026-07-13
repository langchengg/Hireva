import Foundation
import Testing
@testable import Hireva

@Suite
struct GenerationExecutionContextTests {
    @Test
    func contextPreservesQuestionAndGenerationIdentity() {
        let question = makeQuestion("Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?")
        let session = makeSession()
        let acceptedAt = Date(timeIntervalSince1970: 1_717_171_719)
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "Interviewer: Could you walk me through LeoRover?",
            cvSummary: "Candidate has robotics policy experience.",
            jdSummary: "Robotics team.",
            stage: .firstAnswer
        )

        let context = GenerationExecutionContext(
            session: session,
            question: question,
            generationID: "generation-context-1",
            triggerPath: .autoDetect,
            providerID: "deepseek",
            providerModel: "deepseek-chat",
            retrievedContext: promptSnapshot.ragContextSnapshot,
            promptSnapshot: promptSnapshot,
            transcriptSnapshot: "Interviewer: Could you walk me through LeoRover?",
            startedAt: acceptedAt,
            source: .systemAudio,
            speaker: .interviewer
        )

        #expect(context.session.id == session.id)
        #expect(context.question.id == question.id)
        #expect(context.detectedQuestionID == question.id)
        #expect(context.generationID == "generation-context-1")
        #expect(context.triggerPath == .autoDetect)
        #expect(context.startedAt == acceptedAt)
        #expect(context.identity.acceptedQuestionID == question.id)
        #expect(context.identity.sessionID == session.id)
        #expect(context.identity.questionText == question.questionText)
        #expect(context.identity.normalizedQuestionText == SemanticDuplicateKeyBuilder.key(for: question.questionText))
        #expect(context.identity.questionIntent == AnswerRelevancePolicy.intent(for: question.questionText))
        #expect(context.identity.promptPrimaryQuestion == question.questionText)
    }

    @Test
    func providerRequestPreservesPromptPrimaryQuestionAndRedactsSecrets() {
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
        let context = makeExecutionContext(
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            transcript: "Interviewer: Previous background contained \(rawKey)",
            cvSummary: "Candidate summary \(rawKey)",
            jdSummary: "Role summary \(rawKey)",
            providerID: "deepseek-main",
            providerModel: "deepseek-v4"
        )

        let request = GenerationProviderRequest(context: context, streamingEnabled: true)

        #expect(request.promptPrimaryQuestion == context.promptSnapshot.questionTextSnapshot)
        #expect(request.promptPrimaryQuestion == context.question.questionText)
        #expect(request.prompt.contains(rawKey) == false)
        #expect(request.safeDiagnostics.values.contains(rawKey) == false)
        #expect(request.providerID == "deepseek-main")
        #expect(request.model == "deepseek-v4")
        #expect(request.streamingEnabled)
        #expect(request.identity == context.identity)
    }

    @Test
    func diffusionProviderRequestContainsModelComparisonGuidance() {
        let context = makeExecutionContext(
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        )

        let request = GenerationProviderRequest(context: context, streamingEnabled: true)

        #expect(request.prompt.localizedCaseInsensitiveContains("diffusion vs autoregressive vs flow-matching"))
        #expect(request.prompt.localizedCaseInsensitiveContains("smoother continuous actions"))
        #expect(request.prompt.localizedCaseInsensitiveContains("CURRENT QUESTION TO ANSWER"))
        #expect(request.promptPrimaryQuestion == context.question.questionText)
    }

    @Test
    func whyRoleProviderRequestContainsRoleTeamGuidance() {
        let context = makeExecutionContext(
            questionText: "Why do you want to join our team?",
            transcript: "Interviewer: Tell me about yourself."
        )

        let request = GenerationProviderRequest(context: context, streamingEnabled: false)

        #expect(request.prompt.localizedCaseInsensitiveContains("role/team alignment"))
        #expect(request.prompt.localizedCaseInsensitiveContains("real-world deployment interest"))
        #expect(request.prompt.localizedCaseInsensitiveContains("Why do you want to join our team?"))
        #expect(request.streamingEnabled == false)
    }

    @Test
    func previousTranscriptStaysBackgroundOnly() {
        let context = makeExecutionContext(
            questionText: "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            transcript: "Interviewer: Which part of the LeoRover pipeline was most fragile when moving from a clean demo to real robot execution?"
        )
        let request = GenerationProviderRequest(context: context, streamingEnabled: true)

        #expect(context.promptSnapshot.previousQuestionIncluded == false)
        #expect(context.promptSnapshot.promptContainsPreviousQuestion == false)
        #expect(request.prompt.localizedCaseInsensitiveContains("Previous transcript is background only and must not change the question."))
        #expect(request.prompt.localizedCaseInsensitiveContains("Which part of the LeoRover pipeline was most fragile") == false)
    }

    @MainActor
    @Test
    func conversionDoesNotMutateAppState() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "GenerationExecutionContext")
        let appState = AppState(database: database)
        let initialQuestionID = appState.activeQuestionID
        let initialSuggestionID = appState.currentSuggestion?.id
        let context = makeExecutionContext(
            questionText: "Why do you want to join our team?",
            providerID: appState.activeRealtimeProvider?.id.uuidString ?? "deepseek",
            providerModel: appState.activeRealtimeProvider?.model ?? "deepseek-v4"
        )

        _ = GenerationProviderRequest(context: context, streamingEnabled: true)

        #expect(appState.activeQuestionID == initialQuestionID)
        #expect(appState.currentSuggestion?.id == initialSuggestionID)
        #expect(appState.currentGenerationID == nil)
    }

    @Test
    func providerResultCapturesSectionsLatencyStatusAndErrorClassification() {
        let sections = StreamingSuggestionSections(
            strategy: "Direct answer",
            sayFirst: "I would answer directly.",
            keyPoints: ["Point one"],
            followUpReady: ["Follow-up"],
            caution: ""
        )

        let result = GenerationProviderResult(
            sayFirst: sections.sayFirst,
            keyPoints: sections.keyPoints,
            followUp: sections.followUpReady,
            parsedSections: sections,
            latencyMS: 123,
            firstTokenMS: 40,
            firstVisibleMS: 80,
            providerID: "deepseek",
            providerName: "DeepSeek",
            providerModel: "deepseek-chat",
            providerKind: .deepSeek,
            safeDiagnostics: ["model": "deepseek-chat"],
            providerStatus: .completed,
            errorClassification: nil
        )

        #expect(result.sayFirst == sections.sayFirst)
        #expect(result.keyPoints == ["Point one"])
        #expect(result.followUp == ["Follow-up"])
        #expect(result.latencyMS == 123)
        #expect(result.providerID == "deepseek")
        #expect(result.providerName == "DeepSeek")
        #expect(result.providerModel == "deepseek-chat")
        #expect(result.providerKind == .deepSeek)
        #expect(result.safeDiagnostics["model"] == "deepseek-chat")
        #expect(result.providerStatus == .completed)
        #expect(result.errorClassification == nil)
    }

    @Test
    func providerResultRedactsSecretsFromDiagnosticsAndVisibleFields() {
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"

        let result = GenerationProviderResult(
            sayFirst: "Answer with \(rawKey)",
            keyPoints: ["Point with \(rawKey)"],
            followUp: ["Follow-up with \(rawKey)"],
            parsedSections: StreamingSuggestionSections(
                strategy: "Strategy with \(rawKey)",
                sayFirst: "Section answer with \(rawKey)",
                keyPoints: ["Section point with \(rawKey)"],
                followUpReady: ["Section follow-up with \(rawKey)"],
                caution: "Caution with \(rawKey)"
            ),
            latencyMS: 10,
            firstTokenMS: nil,
            firstVisibleMS: nil,
            providerID: "provider-\(rawKey)",
            providerName: "DeepSeek \(rawKey)",
            providerModel: "model-\(rawKey)",
            providerKind: .deepSeek,
            safeDiagnostics: ["apiKey": rawKey],
            providerStatus: .failed,
            errorClassification: .provider,
            errorMessage: "Failed with \(rawKey)"
        )

        #expect(result.sayFirst.contains(rawKey) == false)
        #expect(result.keyPoints.joined().contains(rawKey) == false)
        #expect(result.followUp.joined().contains(rawKey) == false)
        #expect(result.parsedSections?.sayFirst.contains(rawKey) == false)
        #expect(result.providerID.contains(rawKey) == false)
        #expect(result.providerName.contains(rawKey) == false)
        #expect(result.providerModel.contains(rawKey) == false)
        #expect(result.safeDiagnostics.values.contains { $0.contains(rawKey) } == false)
        #expect(result.errorMessage?.contains(rawKey) == false)
    }

    private func makeExecutionContext(
        questionText: String,
        transcript: String = "Interviewer: Could you walk me through LeoRover?",
        cvSummary: String = "Candidate has robotics, VLA, diffusion, autoregressive, and MuJoCo experience.",
        jdSummary: String = "Robotics team focused on reliable deployed systems.",
        providerID: String = "deepseek",
        providerModel: String = "deepseek-chat"
    ) -> GenerationExecutionContext {
        let question = makeQuestion(questionText)
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: transcript,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: .firstAnswer
        )
        return GenerationExecutionContext(
            session: makeSession(),
            question: question,
            generationID: "generation-\(question.id)",
            triggerPath: .autoDetect,
            providerID: providerID,
            providerModel: providerModel,
            retrievedContext: promptSnapshot.ragContextSnapshot,
            promptSnapshot: promptSnapshot,
            transcriptSnapshot: transcript,
            startedAt: Date(timeIntervalSince1970: 1_717_171_719),
            source: .systemAudio,
            speaker: .interviewer
        )
    }

    private func makeQuestion(_ text: String) -> DetectedQuestion {
        DetectedQuestion(
            id: "generation-context-\(UUID().uuidString)",
            sessionID: "generation-context-session",
            transcriptSegmentID: "generation-context-segment",
            questionText: text,
            intent: .unclear,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Generation context test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    private func makeSession() -> InterviewSession {
        InterviewSession(
            id: "generation-context-session",
            title: "Generation Context Test",
            company: nil,
            role: nil,
            startedAt: Date(timeIntervalSince1970: 1_717_171_700),
            endedAt: nil,
            mode: .mock,
            createdAt: Date(timeIntervalSince1970: 1_717_171_700)
        )
    }

    private func mixedContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [
                chunk("diffusion", "VLA MuJoCo evaluation compared diffusion, autoregressive, and flow-matching decoders; diffusion produced smoother continuous actions and seven out of ten successful grasps.", .cv),
                chunk("fragility", "The pipeline was most fragile when moving from a clean demo to real robot execution because noisy perception and timing mismatch caused failures.", .cv),
                chunk("role", "Robotics perception, manipulation, deployment, and engineering systems experience.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd-role", "Robotics software team focused on perception, real-world deployment, evaluation, reliability, and success criteria.", .jobDescription)
            ],
            additionalNotesChunks: []
        )
    }

    private func chunk(_ id: String, _ content: String, _ type: DocumentType) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "\(type.rawValue)-doc",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: TextChunker.tokenize(content),
            sectionTitle: id,
            wordCount: content.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date()
        )
    }
}
