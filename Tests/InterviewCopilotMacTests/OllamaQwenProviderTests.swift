import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct OllamaQwenProviderTests {
    @Test
    func ollamaChatStreamReadsMessageContent() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)

        #expect(try accumulator.ingest(#"{"message":{"role":"assistant","content":"I improved "},"done":false}"#) == "I improved ")
        #expect(try accumulator.ingest(#"{"message":{"role":"assistant","content":"service reliability."},"done":false}"#) == "service reliability.")
        _ = try accumulator.ingest(#"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#)

        let result = try accumulator.finish(requireDone: true)
        #expect(result.content == "I improved service reliability.")
        #expect(result.diagnostics.responseSchema == .chatMessageContent)
        #expect(result.diagnostics.chunksReceived == 3)
        #expect(result.diagnostics.contentChunksReceived == 2)
        #expect(result.diagnostics.streamCompleted)
    }

    @Test
    func ollamaGenerateStreamReadsResponseField() throws {
        var accumulator = OllamaResponseAccumulator(schema: .generateResponse)

        _ = try accumulator.ingest(#"{"response":"I tuned PostgreSQL ","done":false}"#)
        _ = try accumulator.ingest(#"{"response":"queries.","done":false}"#)
        _ = try accumulator.ingest(#"{"response":"","done":true,"done_reason":"stop"}"#)

        let result = try accumulator.finish(requireDone: true)
        #expect(result.content == "I tuned PostgreSQL queries.")
        #expect(result.diagnostics.responseSchema == .generateResponse)
    }

    @Test
    func ollamaDoneChunkDoesNotEraseAccumulatedContent() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)

        _ = try accumulator.ingest(#"{"message":{"role":"assistant","content":"I used Kafka."},"done":false}"#)
        _ = try accumulator.ingest(#"{"done":true,"done_reason":"stop"}"#)

        let result = try accumulator.finish(requireDone: true)
        #expect(result.content == "I used Kafka.")
        #expect(result.diagnostics.rawContentCharacters == 13)
    }

    @Test
    func ollamaEmptyIntermediateChunksAndBlankLinesAreIgnored() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)

        #expect(try accumulator.ingest("") == nil)
        #expect(try accumulator.ingest("   ") == nil)
        #expect(try accumulator.ingest(#"{"message":{"role":"assistant","content":""},"done":false}"#) == nil)
        #expect(try accumulator.ingest(#"{"message":{"role":"assistant","content":"I improved latency."},"done":true}"#) == "I improved latency.")

        let result = try accumulator.finish(requireDone: true)
        #expect(result.content == "I improved latency.")
        #expect(result.diagnostics.chunksReceived == 2)
        #expect(result.diagnostics.contentChunksReceived == 1)
    }

    @Test
    func ollamaMalformedLineDoesNotDiscardFollowingContent() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)

        #expect(try accumulator.ingest("{not-json") == nil)
        _ = try accumulator.ingest(#"{"message":{"role":"assistant","content":"I recovered safely."},"done":true}"#)

        let result = try accumulator.finish(requireDone: true)
        #expect(result.content == "I recovered safely.")
        #expect(result.diagnostics.malformedEvents == 1)
        #expect(result.diagnostics.finalErrorCategory == nil)
    }

    @Test
    func ollamaProviderHTTPErrorIsCategorized() {
        let category = OllamaFailureCategory.classify(
            URLError(.badServerResponse),
            httpStatusCode: 503
        )
        #expect(category == .providerHTTPError)
    }

    @Test
    func ollamaCancellationAndTimeoutAreDistinct() {
        #expect(OllamaFailureCategory.classify(CancellationError()) == .requestCancelled)
        #expect(OllamaFailureCategory.classify(URLError(.cancelled)) == .requestCancelled)
        #expect(OllamaFailureCategory.classify(URLError(.timedOut)) == .requestTimedOut)
    }

    @Test
    func ollamaReasoningOnlyResponseIsExplicitlyCategorized() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)
        _ = try accumulator.ingest(#"{"message":{"role":"assistant","content":"","thinking":"private reasoning"},"done":true}"#)

        do {
            _ = try accumulator.finish(requireDone: true)
            Issue.record("Expected reasoning-only response to fail")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .reasoningReceivedWithoutFinalAnswer)
        }
        #expect(accumulator.currentDiagnostics.reasoningCharacters == "private reasoning".count)
        #expect(accumulator.currentDiagnostics.rawContentCharacters == 0)
    }

    @Test
    func ollamaTrulyEmptyResponseIsProviderEmpty() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)
        _ = try accumulator.ingest(#"{"message":{"role":"assistant","content":""},"done":true}"#)

        do {
            _ = try accumulator.finish(requireDone: true)
            Issue.record("Expected an empty provider response")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .providerReturnedNoContent)
        }
    }

    @Test
    func ollamaSchemaMismatchIsNotProviderEmpty() throws {
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)
        _ = try accumulator.ingest(#"{"response":"I came from generate.","done":true}"#)

        do {
            _ = try accumulator.finish(requireDone: true)
            Issue.record("Expected a schema mismatch")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .responseSchemaMismatch)
        }
    }

    @Test
    func ollamaDirectAnswerWithoutHeadingsRemainsVisible() {
        let parsed = LocalQwenAnswerParser.parse(
            "I improved service reliability by tuning PostgreSQL queries and validating the change under load."
        )

        #expect(parsed.sayFirst == "I improved service reliability by tuning PostgreSQL queries and validating the change under load.")
        #expect(parsed.sectionParserResult == "direct_answer")
        #expect(parsed.failureCategory == nil)
    }

    @Test
    func ollamaSectionParserRejectionIsNotProviderEmpty() {
        let parsed = LocalQwenAnswerParser.parse("{}[]\\")

        #expect(parsed.sayFirst.isEmpty)
        #expect(parsed.failureCategory == .answerSectionParserRejectedContent)
    }

    @Test
    func ollamaAlignmentRejectionIsNotProviderEmpty() {
        let result = LocalQwenAnswerValidationResult.rejected(
            category: .alignmentRejectedNonemptyContent,
            diagnostic: "mismatched"
        )

        #expect(!result.accepted)
        #expect(result.failureCategory == .alignmentRejectedNonemptyContent)
        #expect(result.failureCategory != .providerReturnedNoContent)
    }

    @Test
    func ollamaStaleOwnershipCategoriesRemainDistinct() {
        #expect(OllamaFailureCategory.staleGeneration != .providerReturnedNoContent)
        #expect(OllamaFailureCategory.staleContextSnapshot != .providerReturnedNoContent)
    }

    @Test @MainActor
    func ollamaNonEmptyAlignmentRejectionIsNotReportedAsProviderEmpty() async throws {
        let runtime = try makeRuntime(
            evidence: "Implemented Kotlin REST services and PostgreSQL query tuning to improve API reliability.",
            question: "Tell me about the most technically difficult project you worked on."
        )
        let provider = DiagnosticMockLocalLLMProvider(
            answer: "I published a medical imaging paper after leading a clinical deployment."
        )

        do {
            _ = try await runtime.appState.finishWithLocalQwenAnswer(
                question: runtime.question,
                session: runtime.session,
                transcript: runtime.question.questionText,
                context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
                retrievedChunks: [],
                cvSummary: "Kotlin REST services and PostgreSQL reliability.",
                jdSummary: "Senior Backend Engineer.",
                generationID: runtime.generationID,
                cardID: "rejected-card",
                requestStart: Date(),
                triggerPath: .autoDetect,
                source: .systemAudio,
                speaker: .interviewer,
                localProvider: provider,
                fallbackReason: nil,
                interviewContextSnapshot: runtime.snapshot
            )
            Issue.record("Expected a non-empty alignment rejection")
        } catch let error as LocalQwenGenerationError {
            #expect(error.category == .alignmentRejectedNonemptyContent)
        }

        #expect(runtime.appState.ollamaDiagnostics.rawContentCharacters > 0)
        #expect(runtime.appState.ollamaDiagnostics.finalErrorCategory == .alignmentRejectedNonemptyContent)
        #expect(runtime.appState.ollamaDiagnostics.finalErrorCategory != .providerReturnedNoContent)
    }

    @Test @MainActor
    func ollamaStaleSnapshotCannotClearCurrentAnswer() async throws {
        let runtime = try makeRuntime(
            evidence: "Implemented Kotlin REST services and PostgreSQL query tuning to improve API reliability.",
            question: "Tell me about the most technically difficult project you worked on."
        )
        runtime.appState.activeContextSnapshot = InterviewContextSnapshot(
            id: "newer-context-snapshot",
            sessionID: "newer-session",
            candidateProfileID: "newer-profile",
            candidateProfileVersion: 1,
            opportunityContextID: nil,
            opportunityContextVersion: nil,
            domainProfileID: InterviewDomainID.general.rawValue,
            candidateEvidence: [],
            opportunityEvidence: [],
            createdAt: Date()
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: runtime.question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Kotlin REST services and PostgreSQL reliability.",
            jdSummary: "Senior Backend Engineer.",
            generationID: runtime.generationID,
            cardID: "stale-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: DiagnosticMockLocalLLMProvider(
                answer: "I improved API reliability by tuning PostgreSQL queries in a Kotlin REST service."
            ),
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(!finished)
        #expect(runtime.appState.currentSuggestion == nil)
        #expect(runtime.appState.ollamaDiagnostics.contextSnapshotMatched == false)
        #expect(runtime.appState.ollamaDiagnostics.finalErrorCategory == .staleContextSnapshot)
    }

    @Test @MainActor
    func ollamaSuccessfulAnswerPublishesSafeDiagnostics() async throws {
        let answer = "The most technically difficult project I worked on was a Kotlin REST service where I implemented PostgreSQL query tuning and improved API reliability."
        let runtime = try makeRuntime(
            evidence: answer,
            question: "Tell me about the most technically difficult project you worked on."
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: runtime.question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Kotlin REST services and PostgreSQL reliability.",
            jdSummary: "Senior Backend Engineer.",
            generationID: runtime.generationID,
            cardID: "success-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: DiagnosticMockLocalLLMProvider(answer: answer),
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(runtime.appState.ollamaDiagnostics.rawContentCharacters == answer.count)
        #expect(runtime.appState.ollamaDiagnostics.parsedContentCharacters == answer.count)
        #expect(runtime.appState.ollamaDiagnostics.sectionParserResult == "direct_answer")
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
        #expect(runtime.appState.ollamaDiagnostics.contextSnapshotMatched == true)
        #expect(runtime.appState.ollamaDiagnostics.finalErrorCategory == nil)
        #expect(runtime.appState.ollamaLifecycleEvents.contains { $0.name == "ollama.first_content" })
        #expect(runtime.appState.ollamaLifecycleEvents.contains { $0.name == "answer.ui.rendered" })
    }

    @MainActor
    private func makeRuntime(
        evidence statement: String,
        question questionText: String
    ) throws -> (
        appState: AppState,
        session: InterviewSession,
        question: DetectedQuestion,
        generationID: String,
        snapshot: InterviewContextSnapshot
    ) {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        let evidence = ProfileEvidence(
            id: "qwen-diagnostic-evidence",
            statement: statement,
            sourceDocumentID: "qwen-diagnostic-document",
            sourceChunkID: "qwen-diagnostic-chunk",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: .project,
            explicitness: .explicit
        )
        let profile = CandidateProfile(
            id: "qwen-diagnostic-profile",
            displayName: "Synthetic Diagnostic Candidate",
            sourceDocumentIDs: ["qwen-diagnostic-document"],
            education: [],
            experience: [],
            projects: [evidence],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date()
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        appState.refreshAll()
        appState.selectCandidateProfile(profile.id)
        let session = try appState.createContextBoundSession(mode: .mock)
        appState.currentSession = session
        let snapshot = try #require(try appState.interviewContextRepository.snapshot(id: session.contextSnapshotID ?? ""))
        let question = DetectedQuestion(
            id: "qwen-diagnostic-question",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: questionText,
            intent: .technical,
            answerStrategy: .projectWalkthrough,
            confidence: 1,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        let generationID = "qwen-diagnostic-generation"
        appState.activateGeneration(
            question: question,
            generationID: generationID,
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )
        return (appState, session, question, generationID, snapshot)
    }
}

private final class DiagnosticMockLocalLLMProvider: LocalLLMProvider {
    let id = "diagnostic-mock"
    let displayName = "Diagnostic Mock"
    let answer: String

    init(answer: String) {
        self.answer = answer
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        LocalLLMHealth(
            ollamaRunning: true,
            selectedModel: modelName,
            modelInstalled: true,
            providerSource: .ollamaQwen,
            lastError: nil
        )
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: answer, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
