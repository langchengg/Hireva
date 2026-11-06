import Foundation
import os
import Testing
@testable import Hireva

@Suite(.serialized)
struct OllamaQwenProviderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_TECHNICAL_ANSWER_DIAGNOSTIC"] == "1"), .timeLimit(.minutes(2)))
    @MainActor func installedModelTechnicalAnswerDiagnosticUsesActualProductRequest() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["HIREVA_ANSWER_DIAGNOSTIC_MODEL"])
        try #require(["qwen3.5:4b", "qwen3-vl:4b-instruct-q4_K_M", "gemma4:26b", "qwen3.5:9b-q4_K_M"].contains(model))
        let artifacts = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"]))
        let questionText: String
        let variant = ProcessInfo.processInfo.environment["HIREVA_ANSWER_DIAGNOSTIC_VARIANT"] ?? "original"
        switch variant {
        case "original", "fallback": questionText = "Explain database transaction atomicity and what happens when an operation fails before commit"
        case "statement": questionText = "What does transaction atomicity guarantee, and does a failed statement necessarily cancel every earlier statement in that transaction?"
        case "wrapper": questionText = "An application explicitly catches every failed statement and rolls back its current database transaction. What remains after one operation fails before commit?"
        case "rollback": questionText = "Inside an explicit SQLite transaction a successful insert is followed by INSERT OR ROLLBACK causing a UNIQUE conflict. What happens to the prior insert and the transaction?"
        case "abort": questionText = "Inside an explicit SQLite transaction, a successful insert is followed by a default INSERT with a UNIQUE constraint failure under ABORT. Does the earlier insert remain, and is the transaction still active?"
        case "fail": questionText = "In SQLite, UPDATE OR FAIL changes earlier rows and then hits a UNIQUE conflict. Are the earlier changes in that statement undone, and are later rows processed?"
        case "quoted": questionText = "Someone says 'any failed SQLite statement automatically rolls back the whole transaction'. Is that claim correct for a default UNIQUE conflict under ABORT in an explicit transaction?"
        case "cache": questionText = "Does calling a cache disk-backed guarantee that cached data will survive a restart? Explain the relevant condition."
        case "personal-follow-up", "personal-independent": questionText = "In your database learning prototype, how did you test transaction rollback?"
        case "personal-comparison": questionText = "In your database learning prototype, which concurrency and indexing topic did you compare?"
        case "personal-missing-results", "personal-results-positive", "personal-results-negative": questionText = "What rollback outcomes or measurements did you observe in your database learning prototype?"
        case "personal-multiple-parts": questionText = "What did you build, and how did you test transaction rollback in it?"
        default: throw MaterialError.invalid("Unknown frozen technical-answer diagnostic variant.")
        }
        let realtimeBudget = ProcessInfo.processInfo.environment["HIREVA_DIAGNOSTIC_REALTIME_BUDGET"]
        if let realtimeBudget {
            try #require(["control", "trim"].contains(realtimeBudget))
        }
        var evidenceStatement = "I built a small database learning prototype. I tested transaction rollback with deliberately injected failures. I compared concurrent updates and index trade offs in the prototype."
        if variant == "personal-results-positive" {
            evidenceStatement += " I observed that the inserted test record remained after the injected failure."
        } else if variant == "personal-results-negative" {
            evidenceStatement += " I did not observe a rollback outcome; I recorded no outcome measurements."
        }
        let runtime = try makeRuntime(evidence: evidenceStatement, question: questionText)
        var question = runtime.question
        if realtimeBudget != nil {
            question.intent = .unclear
            question.answerStrategy = .directAnswer
        }
        let personal = variant.hasPrefix("personal-")
        let followsTechnicalAnswer = variant == "personal-follow-up"
        let kind: InterviewTaskKind = variant == "personal-comparison" ? .project : (personal ? .coding : .generalKnowledge)
        var task = InterviewTaskDescriptor(question: question.questionText, kind: kind, language: "en")
        let routingFailed = variant == "fallback"
        task.apply(.init(task: routingFailed ? .unknown : kind,
            personalEvidence: routingFailed ? .uncertain : (personal ? .required : .notRequired),
            basis: routingFailed ? .unknown : (personal ? .candidateRecord : .generalKnowledge),
            relation: followsTechnicalAnswer ? .followUp : .independent,
            parentQuestionID: followsTechnicalAnswer ? "synthetic-technical-parent" : nil,
            parentQuestionText: followsTechnicalAnswer ? "Explain database transaction atomicity and what happens when an operation fails before commit" : nil,
            parentAnswerText: followsTechnicalAnswer ? "Atomicity means that either all changes in a transaction are applied or none are, but if an operation fails before commit, the result depends on the specific database's error handling policy." : nil,
            source: routingFailed ? "safeFallback" : "diagnostic-frozen-decision",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: routingFailed ? "Please clarify the reference or missing constraints." : "", questionID: question.id,
            questionRevision: 0, contextSnapshotID: runtime.snapshot.id, artifactRevision: 0, model: model,
            failure: routingFailed ? "timeout" : nil, latencyMS: routingFailed ? 8050 : 0))
        question.taskDescriptor = task
        var selectedContext = RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
        if let notePath = ProcessInfo.processInfo.environment["HIREVA_DIAGNOSTIC_TECHNICAL_NOTES_PATH"] {
            let notes = try String(contentsOfFile: notePath, encoding: .utf8)
            try #require(!notes.isEmpty && notes.utf8.count <= 4000)
            // Developer-selected topic material tests the real request path;
            // this input is neither test gold nor candidate biography.
            selectedContext.additionalNotesChunks = [.init(id: "diagnostic-topic-source", documentID: "diagnostic-topic-document",
                documentType: .additionalNotes, chunkIndex: 0, content: notes,
                keywords: TextChunker.keywords(in: notes), sectionTitle: "Technical topic material",
                wordCount: notes.split(whereSeparator: \.isWhitespace).count, metadataJSON: nil, createdAt: Date())]
        }
        if realtimeBudget == "trim" {
            selectedContext = RealtimePromptBudgeter.trim(selectedContext, question: question.questionText,
                intent: question.intent, strategy: question.answerStrategy)
        }
        let base = model == "qwen3.5:9b-q4_K_M"
            ? OllamaQwenProvider(baseURL: URL(string: "http://127.0.0.1:11535")!) : OllamaQwenProvider()
        let capture = SyntheticCaptureProvider(suffix: "technical-answer", base: base, artifactDirectory: artifacts)
        do {
            let finished = try await runtime.appState.finishWithLocalQwenAnswer(question: question, session: runtime.session,
                transcript: question.questionText, context: selectedContext, retrievedChunks: [],
                cvSummary: "", jdSummary: "", generationID: runtime.generationID, cardID: "technical-diagnostic-card",
                requestStart: Date(), triggerPath: .autoDetect, source: .systemAudio, speaker: .interviewer,
                localProvider: capture, modelName: model, fallbackReason: nil, interviewContextSnapshot: runtime.snapshot)
            #expect(finished)
            let card = try #require(runtime.appState.currentSuggestion)
            try JSONEncoder().encode(card).write(to: artifacts.appendingPathComponent("product-card.json"))
            #expect(capture.base.lastGenerationDiagnostics.transportRequestCount <= 4)
            // Mechanical product admission is not independent technical accuracy or a GUI render.
            await runtime.appState.shutdownForTesting()
            await capture.cancelAndJoinCaptures()
        } catch {
            await runtime.appState.shutdownForTesting()
            await capture.cancelAndJoinCaptures()
            throw error
        }
    }

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

    @Test(arguments: [false, true]) @MainActor
    func ollamaNonEmptyAlignmentRejectionIsNotReportedAsProviderEmpty(unknownTask: Bool) async throws {
        let runtime = try makeRuntime(
            evidence: "Implemented Kotlin REST services and PostgreSQL query tuning to improve API reliability.",
            question: unknownTask ? "Explain database transaction atomicity and what happens when an operation fails before commit" : "Tell me about the most technically difficult project you worked on."
        )
        let provider = SequencedDiagnosticMockLocalLLMProvider(
            answers: Array(repeating: "I published a medical imaging paper after leading a clinical deployment.", count: 4)
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
        #expect(provider.requests.count == 4)
        for request in provider.requests.suffix(2) {
            #expect(request.responseSchema == (unknownTask ? nil : LocalQwenAnswerParser.scopedResponseSchema))
            #expect(request.prompt.hasSuffix(unknownTask
                ? "Use the frozen answer language and output only the final spoken answer. General explanations do not need a first-person opening."
                : "Answer the current question now:\n\"\(runtime.question.questionText)\""))
        }
        if unknownTask {
            let policy = InterviewTaskDescriptor(question: runtime.question.questionText).answerPromptPolicy
            #expect(runtime.question.taskDescriptor == nil)
            let requests = provider.requests
            try #require(requests.count == 4)
            #expect(requests[0].prompt.contains(policy))
            #expect(requests[2].systemPrompt?.contains(policy) == true)
            #expect(requests[3].systemPrompt?.contains(policy) == true)
        }
        let compact = try #require(provider.requests.first { $0.prompt.contains("Candidate/project summary:") })
        #expect(compact.prompt.contains("For general technical tasks, no CV is required."))
        #expect(!compact.prompt.contains("State relevant assumptions and limitations; no CV is required."))
        #expect(compact.prompt.contains("State past personal experience only when it is explicit"))
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
        let wire = String(decoding: try JSONEncoder().encode(["scoped_claim": answer, "say_first": answer]), as: UTF8.self)
        #expect(runtime.appState.ollamaDiagnostics.rawContentCharacters == wire.count)
        #expect(runtime.appState.ollamaDiagnostics.parsedContentCharacters == answer.count)
        #expect(runtime.appState.ollamaDiagnostics.sectionParserResult == "scoped_json_answer")
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
        #expect(runtime.appState.currentSuggestion?.confidence == nil)
        #expect(runtime.appState.currentSuggestion?.riskLevel == nil)
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
        let output = try TestSupport.scriptedLocalAnswer(answer, request: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: output, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private final class SequencedDiagnosticMockLocalLLMProvider: LocalLLMProvider, Sendable {
    let id = "sequenced-diagnostic-mock"
    let displayName = "Sequenced Diagnostic Mock"
    private struct State: Sendable {
        var answers: [String]
        var requests: [LocalLLMRequest] = []
    }
    private let state: OSAllocatedUnfairLock<State>
    var requests: [LocalLLMRequest] { state.withLock { $0.requests } }

    init(answers: [String]) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers))
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
        let answer = state.withLock { state in
            state.requests.append(request)
            return state.answers.isEmpty ? "" : state.answers.removeFirst()
        }
        let output = try TestSupport.scriptedLocalAnswer(answer, request: request)
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: output, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
