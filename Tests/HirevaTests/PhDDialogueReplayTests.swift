import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct PhDDialogueReplayTests {
    @Test
    func dialoguePolicyKeepsLongCumulativeQuestionsAndRespectsMicrophoneOptIn() {
        let cumulative = TranscriptSegment(
            id: "cumulative-panel",
            sessionID: "test",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Please describe your prior work in computer vision and explain how it prepared you for this project."
        )
        let cumulativeDecision = InterviewDialogueTriggerPolicy.evaluate(
            segment: cumulative,
            phase: .interviewerQuestions,
            listeningMode: .panelQuestionsOnly,
            candidatePresentationMode: .suppressAnswers,
            candidateAsksPanelMode: .suppressAnswers,
            allowCandidateQuestionDetection: false
        )
        #expect(cumulativeDecision.shouldEvaluateQuestion)

        let panelInvitation = TranscriptSegment(
            id: "panel-invitation",
            sessionID: "test",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Do you have any questions for us?"
        )
        let invitationDecision = InterviewDialogueTriggerPolicy.evaluate(
            segment: panelInvitation,
            phase: .interviewerQuestions,
            listeningMode: .panelQuestionsOnly,
            candidatePresentationMode: .suppressAnswers,
            candidateAsksPanelMode: .suppressAnswers,
            allowCandidateQuestionDetection: false
        )
        #expect(!invitationDecision.shouldEvaluateQuestion)
        #expect(invitationDecision.decision == .transitionToCandidateQuestions)

        let microphoneQuestion = TranscriptSegment(
            id: "candidate-microphone",
            sessionID: "test",
            source: .microphone,
            speaker: .candidate,
            text: "Could you explain the expected first-year milestones?"
        )
        let disabledDecision = InterviewDialogueTriggerPolicy.evaluate(
            segment: microphoneQuestion,
            phase: .unknown,
            listeningMode: .panelQuestionsOnly,
            candidatePresentationMode: .suppressAnswers,
            candidateAsksPanelMode: .suppressAnswers,
            allowCandidateQuestionDetection: false
        )
        let enabledDecision = InterviewDialogueTriggerPolicy.evaluate(
            segment: microphoneQuestion,
            phase: .unknown,
            listeningMode: .panelQuestionsOnly,
            candidatePresentationMode: .suppressAnswers,
            candidateAsksPanelMode: .suppressAnswers,
            allowCandidateQuestionDetection: true
        )
        #expect(!disabledDecision.shouldEvaluateQuestion)
        #expect(!enabledDecision.shouldEvaluateQuestion)
        #expect(enabledDecision.turnType == .candidateAnswer)

        let presentationDecision = InterviewDialogueTriggerPolicy.evaluate(
            segment: microphoneQuestion,
            phase: .candidatePresentation,
            listeningMode: .panelQuestionsOnly,
            candidatePresentationMode: .suppressAnswers,
            candidateAsksPanelMode: .suppressAnswers,
            allowCandidateQuestionDetection: true
        )
        #expect(!presentationDecision.shouldEvaluateQuestion)
        #expect(presentationDecision.decision == .suppressCandidatePresentation)
    }

    @Test
    func indirectWhatIsClauseIsNotExtractedAndUnrelatedQuestionTailIsNotMerged() {
        #expect(QuestionCandidatePipeline.extract(from: "I explained what is needed for deployment and then described the validation plan.").isEmpty)

        let questions = QuestionCandidatePipeline.extract(
            from: "What did you do before the current project? Were you using the service framework for the later integration work?"
        )
        #expect(questions.count == 2)
    }

    @Test
    func representativePanelQuestionsPassTheSingleQuestionRuntimeGuard() {
        let questions = [
            "What did you do before the current project? What was your background and which systems were you involved with?",
            "Sorry, perhaps I was unclear. Prior to this project, what was your technical background and engineering experience?",
            "Did you do any projects with event streaming, or is that capability new to you?",
            "Is there a plan to release the work after the current evaluation?",
            "How does your skill set and experience fit this project?",
            "What role does schema validation play in event ingestion?",
            "Have you had experience with event streaming, or is that knowledge from reading?",
            "Have you operated a production system before?",
            "Which systems have you operated, and what architectures did you use?",
            "Were you using the service framework, or were you talking directly to the HTTP library?",
        ]

        for question in questions {
            let extracted = QuestionCandidatePipeline.extract(from: question)
            let guardResult = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: question)
            #expect(extracted.count == 1, "Expected one question for: \(question); got \(extracted.map(\.text))")
            #expect(guardResult.accepted, "Runtime guard rejected: \(question); \(guardResult.diagnostic)")
        }
    }

    @Test
    func syntheticAcceptanceQuestionPhrasingsMapToCompatibilityRubrics() {
        let cases: [(String, PhDQuestionIntent)] = [
            ("Before joining the current project, which parts of your technical background best prepared you for this work?", .preMScBackground),
            ("Prior to this project, which parts of your earlier engineering experience prepared you for the work?", .preMScBackground),
            ("Which evaluation risks would you prioritise when validating that method before release?", .graspResearch),
            ("Since you have not yet worked directly with the event-stream framework, how would you close that skills gap during the first six months?", .tactileLearningPlan),
            ("Imagine the validator predicts an acceptable record, but the audit service reports an unexpected failure. How should the system respond?", .tactileSlipResponse),
            ("Describe the system architecture you used, from ingestion through validation to storage execution.", .robotArchitecture),
            ("Which failure cases would you prioritise first when validating that method for production?", .graspResearch)
        ]

        for (question, expected) in cases {
            #expect(PhDInterviewRubricPolicy.intent(for: question) == expected)
            #expect(PhDInterviewRubricPolicy.rubric(for: question) != nil)
            #expect(!PhDInterviewRubricPolicy.promptGuidance(for: question).isEmpty)
        }
    }

    @Test
    func honestyRubricsRejectWeakAnswersAndUnsupportedSyntheticClaims() {
        let backgroundQuestion = "Before joining the current project, which parts of your technical background prepared you for this work?"
        let backgroundAnswer = "I am motivated and interested in the work."
        let observedQuestion = "Prior to this project, which parts of your earlier background prepared you for the work?"
        let observedAnswer = "My background is relevant."
        let clarificationQuestion = "Did you already have hands-on experience with event streaming, or was your knowledge mainly from reading?"
        let clarificationAnswer = "I am experienced."
        let conflictingSignalQuestion = "Imagine the validator predicts an acceptable record, but the audit service reports an unexpected failure. How should the system respond?"
        let incompleteRecoveryAnswer = "I would immediately retry the request."
        let learningQuestion = "Since you have not yet worked directly with the event-stream framework, how would you close that skills gap during the first six months?"
        let incompleteLearningAnswer = "I would read the documentation."
        let unsupportedFrameworkAnswer = "I operated a proprietary stream-processing cluster for five years and calibrated it against customer traffic."
        let completeLearningPlan = "I would first study the framework, then build a small prototype and baseline with synthetic events, measure delivery and error behavior, and validate milestones before expanding the scope."
        let inventedMetricAnswer = "I designed the event service and demonstrated a 99.99% success rate for customer traffic."
        let inventedCompletedValidationAnswer = "I designed an event-ranking pipeline, integrated it into production, and demonstrated improved reliability across every failure case."
        let inventedCustomerOutcomeAnswer = "I validated the method with customer records and eliminated all delivery failures."
        let inventedScaleAnswer = "I built a service that processed one million live requests per second with no errors."
        let inventedLatencyAnswer = "I built the full architecture and reduced end-to-end latency to two milliseconds in production."

        #expect(!PhDInterviewRubricPolicy.evaluate(question: backgroundQuestion, answer: backgroundAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: observedQuestion, answer: observedAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: clarificationQuestion, answer: clarificationAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: conflictingSignalQuestion, answer: incompleteRecoveryAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: learningQuestion, answer: incompleteLearningAnswer).passed)
        let validator = AnswerClaimValidator()
        #expect(!validator.validate(answer: unsupportedFrameworkAnswer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        #expect(PhDInterviewRubricPolicy.evaluate(question: learningQuestion, answer: completeLearningPlan).passed)
        for unsupportedAnswer in [inventedMetricAnswer, inventedCompletedValidationAnswer, inventedCustomerOutcomeAnswer, inventedScaleAnswer, inventedLatencyAnswer] {
            #expect(!validator.validate(answer: unsupportedAnswer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
    }

    @Test
    func recoveryGuidanceRequiresEvidenceForWeakContextQuestions() {
        let cases = [
            "Before joining the current project, which parts of your technical background prepared you for this work?",
            "Since you have not worked directly with the event-stream framework, how would you close that skills gap?",
            "Describe the system architecture you used from ingestion through validation to storage execution.",
            "Which evaluation risks would you prioritise first when validating that method for production?"
        ]

        for question in cases {
            let guidance = PhDInterviewRubricPolicy.promptGuidance(for: question)
            #expect(guidance.localizedCaseInsensitiveContains("Personal claims require selected candidate evidence"))
            #expect(!guidance.localizedCaseInsensitiveContains("Example Systems Organisation"))
        }

        let evaluationGuidance = PhDInterviewRubricPolicy.promptGuidance(
            for: "Which evaluation risks would you prioritise first when validating that method for production?"
        )
        #expect(evaluationGuidance.localizedCaseInsensitiveContains("Do not invent metrics"))
    }

    @Test
    func groundedSyntheticParaphrasesPassCompatibilityRubric() {
        let cases = [
            (
                "Describe the system architecture you used, from ingestion through validation to storage execution.",
                "I used a modular system architecture where the ingestion component passes a validated record through an explicit interface to storage and notification. I trace each handoff and test recovery when validation or execution fails."
            ),
            (
                "Which evaluation risks would you prioritize first when validating that method for production?",
                "I would prioritize schema and duplicate-delivery failure modes, test the method against fixed synthetic cases, validate recovery metrics, and document limitations before any production decision."
            ),
            (
                "Imagine the validator predicts an acceptable record, but the audit service reports an unexpected failure. How should the system respond?",
                "I would confirm both signals, stop the unsafe write, adjust the processing path, validate the record again, and use a safe fallback if the conflict remains."
            ),
            (
                "Since you have not yet worked directly with the event-stream framework, how would you close that skills gap during the first six months?",
                "I would acknowledge the gap, first study the framework, build a small prototype and baseline with synthetic events, measure delivery and failure behavior, then validate milestones before expanding the scope."
            )
        ]

        for (question, answer) in cases {
            #expect(PhDInterviewRubricPolicy.evaluate(question: question, answer: answer).passed)
        }
        for (question, answer) in cases.prefix(2) {
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question, answerText: answer)
            #expect(alignment.verdict == .aligned, "Question: \(question); reason: \(alignment.reason)")
        }
    }

    @Test
    func presentationAndSetupAreSuppressed() async throws {
        let harness = try makeHarness()
        let turns = [
            PhDReplayTurn(0, "Panel A", .interviewer, .logistics, "You can start when you are ready."),
            PhDReplayTurn(1, "Candidate", .candidate, .candidatePresentation, "My presentation explains a synthetic event pipeline from ingestion to validated storage."),
            PhDReplayTurn(2, "Candidate", .candidate, .candidatePresentation, "Can you see my slide? I will now describe the evaluation."),
        ]

        for turn in turns {
            await harness.replay(turn)
        }

        #expect(harness.appState.detectedQuestionsInSessionCount == 0)
        #expect(harness.appState.currentSuggestion == nil)
        #expect(harness.appState.lastTriggerDecision == InterviewTriggerDecision.suppressCandidatePresentation.rawValue)
        #expect(harness.appState.lastSuppressionReason == "candidate presentation is not an interviewer question")
    }

    @Test
    func firstInterviewerQuestionTriggersLocalQwenAnswer() async throws {
        let harness = try makeHarness()
        let result = try await harness.replayQuestion(
            PhDReplayTurn(
                10,
                "Panel B",
                .interviewer,
                .interviewerQuestions,
                "What did you do before the current project, and what was your technical background?"
            ),
            expectedQuestionNeedle: "background",
            expectedIntent: .preMScBackground
        )

        #expect(result.answerSource == AnswerSource.ollamaQwen.rawValue)
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("software engineering"))
        #expect(result.answer.localizedCaseInsensitiveContains("before the current project"))
        #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(result.answer))
    }

    @Test
    func clarifiedEarlierBackgroundQuestionSupersedesWithoutStaleAnswer() async throws {
        let harness = try makeHarness()
        let first = try await harness.replayQuestion(
            PhDReplayTurn(20, "Panel B", .interviewer, .interviewerQuestions, "What did you do before the current project, and what was your background?"),
            expectedQuestionNeedle: "before the current project",
            expectedIntent: .preMScBackground
        )
        let firstQuestionID = try #require(harness.appState.activeQuestionID)

        let clarification = try await harness.replayQuestion(
            PhDReplayTurn(21, "Panel B", .interviewer, .interviewerQuestions, "Sorry, perhaps I was unclear. What technical background did you have prior to this project, and what engineering experience prepared you?"),
            expectedQuestionNeedle: "prior to this project",
            expectedIntent: .preMScBackground
        )

        let clarifiedQuestionID = try #require(harness.appState.activeQuestionID)
        #expect(clarifiedQuestionID != firstQuestionID)
        #expect(clarification.answer.localizedCaseInsensitiveContains("before the current project"))
        #expect(clarification.answer.localizedCaseInsensitiveContains("software engineering"))
        #expect(clarification.questionID == clarifiedQuestionID)
        #expect(first.questionID == firstQuestionID)
        #expect(harness.appState.currentSuggestion?.detectedQuestionID == clarifiedQuestionID)
        #expect(harness.appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("prior to this project") == true)
        #expect(harness.appState.liveSuggestionHistory.contains { $0.detectedQuestionID == firstQuestionID })
    }

    @Test
    func capabilityExperienceAnswerPreservesHonesty() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(30, "Panel B", .interviewer, .interviewerQuestions, "Did you do any projects with event streaming, or is that capability new to you?"),
            expectedQuestionNeedle: "event streaming",
            expectedIntent: .llmVlmExperience
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("newer"))
        #expect(result.answer.localizedCaseInsensitiveContains("foundation"))
        #expect(!result.answer.localizedCaseInsensitiveContains("years of production"))
    }

    @Test
    func releasePlanAnswerIsCautious() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(40, "Panel B", .interviewer, .interviewerQuestions, "Is there a plan to release the work after the current evaluation?"),
            expectedQuestionNeedle: "release",
            expectedIntent: .publicationPlan
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("possible"))
        #expect(result.answer.localizedCaseInsensitiveContains("stakeholder review"))
        #expect(!result.answer.localizedCaseInsensitiveContains("will definitely release"))
    }

    @Test
    func skillFitAnswerUsesConcreteProjectEvidence() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(50, "Panel A", .interviewer, .interviewerQuestions, "How does your skill set and experience fit this project?"),
            expectedQuestionNeedle: "fit this project",
            expectedIntent: .skillFit
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("event-intake"))
        #expect(result.answer.localizedCaseInsensitiveContains("validation"))
        #expect(!result.answer.localizedCaseInsensitiveContains("hardworking"))
    }

    @Test
    func schemaValidationRoleAnswerExplainsFeedbackAndLimits() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(60, "Panel A", .interviewer, .interviewerQuestions, "What role does schema validation play in event ingestion?"),
            expectedQuestionNeedle: "schema validation",
            expectedIntent: .tactileRole
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("feedback"))
        #expect(result.answer.localizedCaseInsensitiveContains("insufficient alone"))
    }

    @Test
    func eventStreamingExperienceAnswerDoesNotInventProductionWork() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(70, "Panel A", .interviewer, .interviewerQuestions, "Have you had experience with event streaming, or is that knowledge from reading?"),
            expectedQuestionNeedle: "experience with event streaming",
            expectedIntent: .tactileExperience
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("reading"))
        #expect(result.answer.localizedCaseInsensitiveContains("hands-on"))
        #expect(!result.answer.localizedCaseInsensitiveContains("production cluster"))
    }

    @Test
    func systemFrameworkFollowUpsKeepFrameworkDistinctFromHTTPAPI() async throws {
        let harness = try makeHarness()
        let production = try await harness.replayQuestion(
            PhDReplayTurn(80, "Panel B", .interviewer, .interviewerQuestions, "Have you operated a production system before?"),
            expectedQuestionNeedle: "production system",
            expectedIntent: .realRobotExperience
        )
        let architecture = try await harness.replayQuestion(
            PhDReplayTurn(81, "Panel B", .interviewer, .interviewerQuestions, "Describe the system architecture you used for the event service, from ingestion through storage."),
            expectedQuestionNeedle: "system architecture",
            expectedIntent: .robotArchitecture
        )
        let framework = try await harness.replayQuestion(
            PhDReplayTurn(82, "Panel B", .interviewer, .interviewerQuestions, "Were you using the service framework, or were you talking directly to the HTTP library?"),
            expectedQuestionNeedle: "service framework",
            expectedIntent: .rosControl
        )

        #expect(production.quality.passed)
        #expect(architecture.quality.passed)
        #expect(framework.quality.passed)
        #expect(architecture.answer.localizedCaseInsensitiveContains("modular system architecture"))
        #expect(!architecture.answer.localizedCaseInsensitiveContains("customer deployment"))
        #expect(framework.answer.localizedCaseInsensitiveContains("service framework"))
        #expect(framework.answer.localizedCaseInsensitiveContains("HTTP API"))
    }

    @Test
    func candidateQuestionsToPanelAreClassifiedAndDoNotOverwriteCurrentAnswer() async throws {
        let harness = try makeHarness()
        let interviewer = try await harness.replayQuestion(
            PhDReplayTurn(90, "Panel A", .interviewer, .interviewerQuestions, "How does your skill set and experience fit this project?"),
            expectedQuestionNeedle: "fit this project",
            expectedIntent: .skillFit
        )
        let currentQuestionID = interviewer.questionID
        let currentAnswer = interviewer.answer
        await harness.replay(
            PhDReplayTurn(
                99,
                "Panel A",
                .interviewer,
                .candidateQuestionsToPanel,
                "Do you have any questions for us?"
            )
        )
        #expect(harness.appState.resolvedInterviewSessionPhase == .candidateQuestions)
        let candidateQuestions = [
            "What is the first stage I should focus on in the first month?",
            "Which service framework and test environments will be used in this project?",
            "Will I work directly with the release pipeline?",
            "Based on my background, where could I make a strong contribution?",
            "What do you think will be the biggest technical challenge in this project?",
            "What will success look like at the end of the initial delivery phase?",
        ]

        for (offset, text) in candidateQuestions.enumerated() {
            await harness.replay(PhDReplayTurn(100 + offset, "Candidate", .candidate, .candidateQuestionsToPanel, text))
            #expect(harness.appState.lastTriggerDecision == InterviewTriggerDecision.candidateQuestionToPanel.rawValue)
            #expect(harness.appState.lastSuppressionReason == "candidate question is directed to the panel")
        }

        #expect(harness.appState.candidateQuestionsToPanelCount == candidateQuestions.count)
        #expect(harness.appState.activeQuestionID == currentQuestionID)
        #expect(harness.appState.currentSuggestion?.sayFirst == currentAnswer)
        #expect(harness.appState.detectedQuestionsInSessionCount == 1)
    }

    @Test
    func fullDialogueReplayOutputsStableReportAndSourceMetrics() async throws {
        let harness = try makeHarness()
        await harness.replay(PhDReplayTurn(200, "Panel A", .interviewer, .logistics, "You can start when ready."))
        await harness.replay(PhDReplayTurn(201, "Candidate", .candidate, .candidatePresentation, "I will present the ingestion and validation approach."))

        let cases: [(PhDReplayTurn, String, PhDQuestionIntent)] = [
            (PhDReplayTurn(210, "Panel B", .interviewer, .interviewerQuestions, "What did you do before the current project, and what was your background?"), "before the current project", .preMScBackground),
            (PhDReplayTurn(211, "Panel B", .interviewer, .interviewerQuestions, "What technical background did you have prior to this project, and what engineering experience prepared you?"), "prior to this project", .preMScBackground),
            (PhDReplayTurn(212, "Panel B", .interviewer, .interviewerQuestions, "Did you do any projects with event streaming, or is that capability new to you?"), "event streaming", .llmVlmExperience),
            (PhDReplayTurn(213, "Panel B", .interviewer, .interviewerQuestions, "Is there a plan to release the work after the current evaluation?"), "release", .publicationPlan),
            (PhDReplayTurn(214, "Panel A", .interviewer, .interviewerQuestions, "How does your skill set and experience fit this project?"), "fit this project", .skillFit),
            (PhDReplayTurn(215, "Panel A", .interviewer, .interviewerQuestions, "What role does schema validation play in event ingestion?"), "schema validation", .tactileRole),
            (PhDReplayTurn(216, "Panel A", .interviewer, .interviewerQuestions, "Have you had experience with event streaming, or is that knowledge from reading?"), "experience with event streaming", .tactileExperience),
            (PhDReplayTurn(217, "Panel B", .interviewer, .interviewerQuestions, "Have you operated a production system before?"), "production system", .realRobotExperience),
            (PhDReplayTurn(218, "Panel B", .interviewer, .interviewerQuestions, "Describe the system architecture you used for the event service, from ingestion through storage."), "system architecture", .robotArchitecture),
            (PhDReplayTurn(219, "Panel B", .interviewer, .interviewerQuestions, "Were you using the service framework, or were you talking directly to the HTTP library?"), "service framework", .rosControl),
        ]

        print("| Turn | Speaker Role | Text Excerpt | Should Trigger | Detected Question | Answer Source | Result |")
        var results: [PhDReplayResult] = []
        for item in cases {
            results.append(try await harness.replayQuestion(item.0, expectedQuestionNeedle: item.1, expectedIntent: item.2))
        }

        let questionBeforeCandidateTurns = harness.appState.activeQuestionID
        await harness.replay(
            PhDReplayTurn(
                229,
                "Panel A",
                .interviewer,
                .candidateQuestionsToPanel,
                "Do you have any questions for us?"
            )
        )
        let candidateQuestions = [
            "What should I focus on in the first month?",
            "Which framework and test environments will be used?",
            "Will I work directly with the release pipeline?",
            "Where could I contribute most strongly?",
            "What is the largest technical challenge?",
            "What will success look like at the end?",
        ]
        for (offset, text) in candidateQuestions.enumerated() {
            await harness.replay(PhDReplayTurn(230 + offset, "Candidate", .candidate, .candidateQuestionsToPanel, text))
        }

        let missed = cases.count - results.count
        let falsePositives = harness.appState.detectedQuestionsInSessionCount - results.count
        let merged = cases.filter { QuestionCandidatePipeline.extract(from: $0.0.text).count != 1 }.count
        let generic = results.filter(\.quality.genericTemplate).count
        let wrongSources = results.filter { $0.answerSource != AnswerSource.ollamaQwen.rawValue }.count
        let maxAccepted = results.map(\.acceptedLatencyMS).max() ?? 0
        let maxVisible = results.map(\.visibleLatencyMS).max() ?? 0
        print("missed_interviewer_questions=\(missed) false_positive_candidate_speech=\(falsePositives) merged_questions=\(merged) stale_answer_ownership_errors=\(harness.appState.staleAnswerDiscardCount) generic_template_answers=\(generic) source_metadata_errors=\(wrongSources) max_question_accepted_ms=\(maxAccepted) max_answer_visible_ms=\(maxVisible)")

        #expect(missed == 0)
        #expect(falsePositives == 0)
        #expect(merged == 0)
        #expect(generic == 0)
        #expect(wrongSources == 0)
        #expect(harness.appState.staleAnswerDiscardCount == 0)
        #expect(harness.appState.activeQuestionID == questionBeforeCandidateTurns)
        #expect(harness.appState.candidateQuestionsToPanelCount == candidateQuestions.count)
        #expect(maxAccepted <= 1_500)
        #expect(maxVisible <= 5_000)
    }

    private func makeHarness() throws -> PhDReplayHarness {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "PhDDialogueReplayTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let detector = PhDReplayDetectionClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: detector])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: PhDReplayEmptyContextService()
        )
        appState.answerProviderModeOverride = .localQwenPrimary
        appState.localLLMProviderOverride = PhDReplayLocalQwenProvider()
        let fixtureStatements = [
            "Before the current project, I completed a software engineering programme and built transferable programming, database, and API skills",
            "I am newer to event streaming; earlier service work gave me a foundation, and the current synthetic project provides limited hands-on practice",
            "I bring event ingestion, schema validation, deterministic replay, SQLite persistence, and failure-recovery experience",
            "I know enterprise event streaming mostly from reading rather than hands-on production work",
            "I used a service framework for coordination and used HTTP APIs for lower-level requests where appropriate",
            "I operated an isolated staging service with a modular ingestion, validation, storage, and notification architecture",
            "I have staging-system experience while keeping that evidence distinct from unsupported production operation"
        ]
        let fixtureEvidence = fixtureStatements.enumerated().map { index, statement in
            ProfileEvidence(
                id: "phd-replay-evidence-\(index)",
                statement: statement,
                sourceDocumentID: "phd-replay-fixture",
                sourceChunkID: "phd-replay-chunk-\(index)",
                sourceSpan: statement,
                confidence: 1,
                evidenceType: index == 0 ? .education : .experience,
                explicitness: .explicit
            )
        }
        try appState.interviewContextRepository.saveCandidateProfile(CandidateProfile(
            id: "phd-replay-profile",
            displayName: "Synthetic Systems Candidate",
            sourceDocumentIDs: ["phd-replay-fixture"],
            education: [fixtureEvidence[0]],
            experience: Array(fixtureEvidence.dropFirst()),
            projects: [],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [ProfileEvidence(
                id: "phd-replay-framework-gap",
                statement: "Enterprise event streaming is a declared learning area rather than completed production experience",
                sourceDocumentID: "phd-replay-fixture",
                sourceChunkID: "phd-replay-gap-chunk",
                sourceSpan: "Enterprise event streaming is a declared learning area rather than completed production experience",
                confidence: 1,
                evidenceType: .declaredGap,
                explicitness: .userConfirmed
            )],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date()
        ))
        appState.refreshAll()
        appState.selectCandidateProfile("phd-replay-profile")
        appState.selectInterviewDomain(.general)
        appState.detectionDebounceSeconds = 0.01
        appState.delayProvider = MockDelayProvider()

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)

        let session = try appState.createContextBoundSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return PhDReplayHarness(appState: appState, session: session)
    }
}

private struct PhDReplayTurn {
    let turnIndex: Int
    let speakerLabel: String
    let speakerRole: SpeakerRole
    let phase: InterviewPhase
    let text: String
    let isFinal: Bool
    let source = "replay_phd_transcript"

    init(
        _ turnIndex: Int,
        _ speakerLabel: String,
        _ speakerRole: SpeakerRole,
        _ phase: InterviewPhase,
        _ text: String,
        isFinal: Bool = true
    ) {
        self.turnIndex = turnIndex
        self.speakerLabel = speakerLabel
        self.speakerRole = speakerRole
        self.phase = phase
        self.text = text
        self.isFinal = isFinal
    }
}

private struct PhDReplayResult {
    let turn: PhDReplayTurn
    let questionID: String
    let generationID: String
    let detectedQuestion: String
    let answer: String
    let answerSource: String
    let quality: PhDAnswerQualityResult
    let acceptedLatencyMS: Int
    let visibleLatencyMS: Int
}

@MainActor
private final class PhDReplayHarness {
    let appState: AppState
    let session: InterviewSession

    init(appState: AppState, session: InterviewSession) {
        self.appState = appState
        self.session = session
    }

    func replay(_ turn: PhDReplayTurn) async {
        let segment = TranscriptSegment(
            id: "phd-replay-\(turn.turnIndex)",
            sessionID: session.id,
            source: .systemAudio,
            speaker: turn.speakerRole,
            text: turn.text,
            createdAt: Date(),
            confidence: 0.98,
            asrSource: .localParakeetASR,
            asrFinalizationReason: turn.isFinal ? "final" : "partial",
            recognitionTaskID: "phd-replay-task-\(turn.turnIndex)",
            recognitionEventSequence: turn.turnIndex,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: (turn.text as NSString).length,
            recognitionIsFinal: turn.isFinal
        )
        await appState.handleTranscriptSegment(segment)
    }

    func replayQuestion(
        _ turn: PhDReplayTurn,
        expectedQuestionNeedle: String,
        expectedIntent: PhDQuestionIntent
    ) async throws -> PhDReplayResult {
        let startedAt = Date()
        let previousQuestionID = appState.activeQuestionID
        await replay(turn)
        try await waitUntil(timeout: 12) {
            guard let question = self.appState.lastDetectedQuestion else { return false }
            return question.id != previousQuestionID &&
                question.questionText.localizedCaseInsensitiveContains(expectedQuestionNeedle) &&
                self.appState.activeQuestionID == question.id &&
                self.appState.activeGenerationID != nil
        }
        let acceptedAt = Date()
        let questionID = try #require(appState.activeQuestionID)
        let generationID = try #require(appState.activeGenerationID)
        try await waitUntil(timeout: 12) {
            guard let card = self.appState.currentSuggestion else { return false }
            return card.detectedQuestionID == questionID &&
                card.generationID == generationID &&
                card.finalVisibleSource == AnswerSource.ollamaQwen.rawValue &&
                !self.appState.currentSpinnerVisible
        }
        let visibleAt = Date()
        let card = try #require(appState.currentSuggestion)
        let detected = try #require(appState.lastDetectedQuestion)
        let quality = PhDInterviewRubricPolicy.evaluate(question: detected.questionText, answer: card.sayFirst)
        try await waitUntil(timeout: 2) {
            (try? self.appState.transcriptRepository.segmentByID("phd-replay-\(turn.turnIndex)")) != nil
        }
        try await waitUntil(timeout: 2) {
            (try? self.appState.suggestionRepository.suggestions(sessionID: self.session.id).contains { $0.generationID == generationID }) == true
        }
        let persistedSegment = try #require(try appState.transcriptRepository.segmentByID("phd-replay-\(turn.turnIndex)"))
        let persistedCard = try #require(try appState.suggestionRepository.suggestions(sessionID: session.id).first { $0.generationID == generationID })

        #expect(PhDInterviewRubricPolicy.intent(for: detected.questionText) == expectedIntent)
        #expect(appState.lastTriggerDecision == InterviewTriggerDecision.triggerAnswer.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.speakerRole == SpeakerRole.interviewer.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.selectedSessionMode == InterviewSessionMode.auto.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.resolvedSessionPhase == DialogueSessionPhase.panelQuestions.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.detectedSpeakerRole == DialogueTurnRole.interviewer.rawValue)
        #expect([
            DialogueTurnType.substantiveQuestion.rawValue,
            DialogueTurnType.clarificationQuestion.rawValue,
        ].contains(appState.lastTranscriptQuestionGenerationTrace.detectedTurnType))
        #expect(appState.lastTranscriptQuestionGenerationTrace.asrSource == ASRSource.localParakeetASR.rawValue)
        #expect(card.isLocal)
        #expect(card.softFallbackUsed == false)
        #expect(card.sayFirstSource == AnswerSource.ollamaQwen.rawValue)
        #expect(persistedSegment.asrSource == .localParakeetASR)
        #expect(persistedCard.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(persistedCard.isLocal)

        let result = PhDReplayResult(
            turn: turn,
            questionID: questionID,
            generationID: generationID,
            detectedQuestion: detected.questionText,
            answer: card.sayFirst,
            answerSource: card.finalVisibleSource ?? "",
            quality: quality,
            acceptedLatencyMS: Int(acceptedAt.timeIntervalSince(startedAt) * 1_000),
            visibleLatencyMS: Int(visibleAt.timeIntervalSince(startedAt) * 1_000)
        )
        print("| \(turn.turnIndex) | \(turn.speakerRole.rawValue) | \(safeExcerpt(turn.text)) | yes | \(safeExcerpt(detected.questionText)) | \(result.answerSource) | \(quality.passed ? "PASS" : "FAIL") |")
        return result
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let state = "lastQuestion=\(safeExcerpt(appState.lastDetectedQuestion?.questionText ?? "nil")) activeQuestion=\(appState.activeQuestionID ?? "nil") currentCard=\(safeExcerpt(appState.currentSuggestion?.questionText ?? "nil")) blocked=\(appState.lastTranscriptQuestionGenerationTrace.generationBlockedReason) pending=\(appState.pendingAcceptedQuestions.count) ui=\(appState.generationUIState.displayName) failure=\(appState.currentGenerationTelemetry.failureReason ?? "nil") providerError=\(appState.currentGenerationTelemetry.providerError ?? "nil") providerOp=\(appState.lastProviderOperation) mismatch=\(safeExcerpt(appState.currentSuspectedMismatchReason))"
        throw NSError(domain: "PhDDialogueReplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for replay state. \(state)"])
    }

    private func safeExcerpt(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "|", with: "/")
        return String(collapsed.prefix(72))
    }
}

private final class PhDReplayLocalQwenProvider: LocalLLMProvider {
    let id = "phd_replay_qwen"
    let displayName = "Synthetic Replay Qwen"

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        LocalLLMHealth(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .ollamaQwen, lastError: nil)
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(modelID: modelName, totalBytes: nil))
            continuation.finish()
        }
    }

    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let answer = answer(for: request.prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(LLMToken(text: answer, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }

    private func answer(for prompt: String) -> String {
        let lower = currentQuestion(in: prompt).lowercased()
        if lower.contains("prior to this project") || lower.contains("before the current project") {
            return "Before the current project, I completed a software engineering programme and built programming, database, and API skills; that earlier background led me into event-processing work."
        }
        if lower.contains("event streaming") && lower.contains("new") {
            return "I am newer to event streaming; my earlier service work gave me a foundation, and the current synthetic project provides limited hands-on experience without implying production expertise."
        }
        if lower.contains("plan to release") || lower.contains("release the work") {
            return "A release is possible if the evaluation results meet documented criteria and stakeholder review approves the scope, but I would not present that future outcome as guaranteed."
        }
        if lower.contains("skill set") && lower.contains("fit this project") {
            return "My project evidence covers event-intake integration, schema validation, deterministic replay, and recovery testing, which are relevant to this work; enterprise event streaming remains a gap I would develop deliberately."
        }
        if lower.contains("what role does schema validation") {
            return "I use schema validation as feedback on incoming data: it checks each input signal before the service makes a storage decision, adapts the processing path for invalid records, and is insufficient alone without semantic and recovery checks."
        }
        if lower.contains("experience with event streaming") {
            return "My documented project evidence includes limited hands-on synthetic event replay, while enterprise event streaming is mostly from reading; I would state that scope and gap rather than invent production experience."
        }
        if lower.contains("service framework") || lower.contains("http library") {
            return "I used the service framework to coordinate the processing pipeline and an HTTP API library for individual requests; explicit interfaces, trace logging, and tests kept the library boundary observable."
        }
        if lower.contains("which systems") || lower.contains("system architecture") {
            return "I used a modular system architecture with ingestion, validation, storage, and notification components connected by explicit interfaces; trace-based validation and recovery tests covered each execution handoff."
        }
        if lower.contains("operated a production system") {
            return "I have not operated a customer production system; I operated an isolated staging service, where my role covered validation and failure testing within that limited scope."
        }
        return "Before the current project, I completed a software engineering programme and built programming, database, and API skills; that earlier background led me into event-processing work."
    }

    private func currentQuestion(in prompt: String) -> String {
        let markers = ["CURRENT QUESTION TO ANSWER:", "Current interview question:", "Question:"]
        for marker in markers {
            guard let range = prompt.range(of: marker, options: .caseInsensitive) else { continue }
            let tail = prompt[range.upperBound...]
            if let line = tail.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return line.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return prompt
    }
}

private final class PhDReplayDetectionClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek

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
        let latest = prompt.components(separatedBy: "Interviewer:").last?
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = """
        {"should_trigger":true,"question_complete":true,"question_text":\(json(latest)),"intent":"technical","answer_strategy":"direct_answer","confidence":0.95,"reason":"Complete panel question."}
        """
        return LLMChatResult(content: content, modelName: "phd-replay-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 1, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }

    private func json(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let value = String(data: data, encoding: .utf8) else { return "\"\"" }
        return value
    }
}

private final class PhDReplayEmptyContextService: ContextRetrievalService {
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
