import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
struct OllamaQwenProviderTests {
    @Test
    func localQwenGenerationErrorIncludesSafeDiagnostic() {
        let error = LocalQwenGenerationError(
            category: .alignmentRejectedNonemptyContent,
            diagnostic: "unsupported_personal_claim"
        )

        #expect(error.errorDescription == "Local Qwen request failed: alignment_rejected_nonempty_content (unsupported_personal_claim).")
    }

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
    func ollamaProviderErrorPayloadDoesNotCrossThePresentationBoundary() throws {
        let privateCanary = "CANDIDATE-CV-CANARY-/Users/synthetic-private/cv.txt?token=synthetic-secret"
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)

        do {
            _ = try accumulator.ingest(#"{"error":"\#(privateCanary)"}"#)
            Issue.record("Expected the provider error event to fail")
        } catch let error as OllamaQwenProviderError {
            #expect(error.category == .providerHTTPError)
            #expect(error.errorDescription == "Local Ollama request failed (provider_http_error).")
            #expect(error.localizedDescription.contains(privateCanary) == false)
            #expect(String(describing: error).contains(privateCanary) == false)
        }
    }

    @Test
    func ollamaErrorsCarryOnlyClosedCategoriesAndFixedCopy() {
        let cases: [(OllamaQwenProviderError, String)] = [
            (.modelNotReady, "The selected Ollama model is not installed."),
            (.invalidResponse, "Ollama returned an invalid response (response_schema_mismatch)."),
            (.categorized(.providerHTTPError), "Local Ollama request failed (provider_http_error).")
        ]

        for (error, expectedCopy) in cases {
            #expect(error.localizedDescription == expectedCopy)
            #expect(error.description == expectedCopy)
        }
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
            #expect(error.diagnostic == "unsupported_personal_claim")
            #expect(error.errorDescription?.contains("unsupported_personal_claim") == true)
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

    @Test @MainActor
    func ollamaProspectiveSecurityResponseIsNotRejectedAsPastPersonalClaim() async throws {
        let question = "How would you investigate suspicious privileged access while preserving evidence, and keeping critical business services available?"
        let answer = "I would triage the alert using documented severity and escalation criteria to determine the appropriate containment actions. I would then lead a tabletop exercise to coordinate cross-team incident response while preserving evidence and ensuring critical business services remain available. Finally, I would document all decisions, evidence, and follow-up controls to validate controls and communicate risk effectively."
        let runtime = try makeRuntime(
            evidence: "Triaged identity alerts using documented severity and escalation criteria; facilitated a tabletop exercise covering access revocation and recovery communication; supported evidence preservation, cross-team incident coordination, and follow-up controls.",
            question: question
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Identity alert triage, evidence preservation, and incident coordination.",
            jdSummary: "Cybersecurity Analyst.",
            generationID: runtime.generationID,
            cardID: "prospective-security-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: DiagnosticMockLocalLLMProvider(answer: answer),
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(runtime.appState.currentSuggestion?.sayFirst == answer)
        #expect(runtime.appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(runtime.appState.currentSuggestion?.softFallbackUsed == false)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
    }

    @Test @MainActor
    func ollamaTradeoffRecoveryPromptCorrectsAMissingProspectiveDecision() async throws {
        let question = "How would you communicate a reliability trade off when delivery pressure is high?"
        let rejected = "I would explain the reliability implications clearly and keep the delivery discussion transparent."
        let accepted = "I would make the reliability risk and delivery impact explicit, then recommend a phased release that preserves essential safeguards. I would document the decision and revisit it if the evidence changed."
        let runtime = try makeRuntime(
            evidence: "Built a reliability test harness before production releases and partnered with client and platform teams on a versioned API migration.",
            question: question
        )
        let provider = SequencedDiagnosticMockLocalLLMProvider(
            answers: [rejected, rejected, accepted]
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Reliability testing and cross-team API migration.",
            jdSummary: "Senior Backend Engineer.",
            generationID: runtime.generationID,
            cardID: "prospective-tradeoff-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.prompt.contains("choose, prioritize, recommend, or propose") == true)
        #expect(runtime.appState.currentSuggestion?.sayFirst == accepted)
        #expect(runtime.appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(runtime.appState.currentSuggestion?.isLocal == true)
        #expect(runtime.appState.currentSuggestion?.softFallbackUsed == false)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
    }

    @Test @MainActor
    func ollamaDebuggingRecoveryPromptNamesTheFailureBeforeEvidenceDetails() async throws {
        let question = "What was the hardest failure when you applied that approach to the requirement to build perception pipelines?"
        let rejected = "I isolated rare-lighting false positives through inference profiling and annotation checks."
        let accepted = "I can support rare-lighting false positives as the failure. I isolated them through inference profiling and annotation checks."
        let rejectedAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: rejected,
            sayFirst: rejected,
            stageBCompleted: true
        )
        let acceptedAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: accepted,
            sayFirst: accepted,
            stageBCompleted: true
        )
        #expect(rejectedAlignment.verdict == .mismatched)
        #expect(rejectedAlignment.missingThemes.contains("question topic"))
        #expect(acceptedAlignment.verdict == .aligned)

        let runtime = try makeRuntime(
            evidence: "Built a multi-camera defect-detection prototype on a licensed synthetic image set. Isolated rare-lighting false positives through inference profiling and annotation checks.",
            question: question
        )
        let guidanceNeedle = "Name the failure or challenge explicitly in the first sentence"
        let provider = InstructionConditionedDiagnosticMockLocalLLMProvider(
            requiredInstruction: guidanceNeedle,
            answerWithoutInstruction: rejected,
            answerWithInstruction: accepted
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Multi-camera defect detection and rare-lighting false-positive analysis.",
            jdSummary: "Computer Vision Engineer.",
            generationID: runtime.generationID,
            cardID: "debugging-recovery-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.prompt.contains(guidanceNeedle) == true)
        #expect(runtime.appState.currentSuggestion?.sayFirst == accepted)
        #expect(runtime.appState.ollamaLifecycleEvents.filter {
            $0.name == "answer.alignment.completed" && $0.failureCategory != nil
        }.count == 2)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
    }

    @Test @MainActor
    func ollamaSupportRecoveryPromptRequiresAProspectivePreference() async throws {
        let question = "What support would help you improve faster?"
        let rejected = "I received weekly executive mentoring that accelerated my promotion."
        let accepted = "The support that would help me improve faster is specific feedback against clear role expectations. I would use that feedback to identify the next gap and validate progress."
        let runtime = try makeRuntime(
            evidence: "Built a reliability test harness before production releases and documented failure cases for review.",
            question: question
        )
        let provider = SequencedDiagnosticMockLocalLLMProvider(
            answers: [rejected, rejected, accepted]
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Reliability testing and documented failure cases.",
            jdSummary: "Senior Software Engineer.",
            generationID: runtime.generationID,
            cardID: "prospective-support-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.prompt.contains("future support preference") == true)
        #expect(runtime.appState.currentSuggestion?.sayFirst == accepted)
        #expect(runtime.appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
    }

    @Test @MainActor
    func ollamaWeaknessRecoveryPromptNamesAGroundedDevelopmentArea() async throws {
        let question = "What is your current weakness?"
        let rejected = "I am always working to improve and learn from feedback."
        let accepted = "A weakness I would prioritize is scaling reliability testing across more complex systems. I would address it by extending the documented failure-case tests and validating each change against clear review criteria."
        let runtime = try makeRuntime(
            evidence: "Built a reliability test harness before production releases and documented failure cases for review.",
            question: question
        )
        let provider = SequencedDiagnosticMockLocalLLMProvider(
            answers: [rejected, rejected, accepted]
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Reliability testing and documented failure cases.",
            jdSummary: "Senior Software Engineer.",
            generationID: runtime.generationID,
            cardID: "prospective-weakness-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.prompt.contains("weakness or development area") == true)
        #expect(runtime.appState.currentSuggestion?.sayFirst == accepted)
        #expect(runtime.appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
    }

    @Test @MainActor
    func ollamaProceduralWalkthroughIsNotRejectedAsPastProjectStory() async throws {
        let question = "Walk me through a complete incident response handoff from triage to recovery."
        let answer = "I would start with triage, preserve volatile evidence, coordinate containment with service owners, verify recovery controls, and document the handoff into follow-up remediation."
        let runtime = try makeRuntime(
            evidence: "Triaged identity alerts using documented severity criteria; supported evidence preservation, cross-team containment, recovery communication, and follow-up controls.",
            question: question
        )

        let finished = try await runtime.appState.finishWithLocalQwenAnswer(
            question: runtime.question,
            session: runtime.session,
            transcript: question,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Identity alert triage, evidence preservation, containment, and recovery communication.",
            jdSummary: "Cybersecurity Analyst.",
            generationID: runtime.generationID,
            cardID: "procedural-walkthrough-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: DiagnosticMockLocalLLMProvider(answer: answer),
            fallbackReason: nil,
            interviewContextSnapshot: runtime.snapshot
        )

        #expect(finished)
        #expect(runtime.appState.currentSuggestion?.sayFirst == answer)
        #expect(runtime.appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(runtime.appState.currentSuggestion?.softFallbackUsed == false)
        #expect(runtime.appState.ollamaDiagnostics.alignmentDecision == "aligned")
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

private final class SequencedDiagnosticMockLocalLLMProvider: LocalLLMProvider {
    let id = "sequenced-diagnostic-mock"
    let displayName = "Sequenced Diagnostic Mock"
    private var answers: [String]
    private(set) var requests: [LocalLLMRequest] = []

    init(answers: [String]) {
        self.answers = answers
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
        requests.append(request)
        let answer = answers.isEmpty ? "" : answers.removeFirst()
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: answer, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private final class InstructionConditionedDiagnosticMockLocalLLMProvider: LocalLLMProvider {
    let id = "instruction-conditioned-diagnostic-mock"
    let displayName = "Instruction Conditioned Diagnostic Mock"
    let requiredInstruction: String
    let answerWithoutInstruction: String
    let answerWithInstruction: String
    private(set) var requests: [LocalLLMRequest] = []

    init(
        requiredInstruction: String,
        answerWithoutInstruction: String,
        answerWithInstruction: String
    ) {
        self.requiredInstruction = requiredInstruction
        self.answerWithoutInstruction = answerWithoutInstruction
        self.answerWithInstruction = answerWithInstruction
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
        requests.append(request)
        let answer = request.prompt.contains(requiredInstruction)
            ? answerWithInstruction
            : answerWithoutInstruction
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: answer, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
