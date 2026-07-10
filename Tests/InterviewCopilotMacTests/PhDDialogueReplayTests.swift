import Foundation
import Testing
@testable import InterviewCopilotMac

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
            text: "Please describe your prior work in computer vision and explain how it prepared you for this project. At the end, do you have any questions for us?"
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
            from: "What did you do before Manchester? Were you using ROS for the later robot-control work?"
        )
        #expect(questions.count == 2)
    }

    @Test
    func representativePanelQuestionsPassTheSingleQuestionRuntimeGuard() {
        let questions = [
            "What did you do before Manchester? Were you with robotics, or what was your background and what projects were you involved with?",
            "Sorry, perhaps I was unclear. Prior to your MSc in Manchester, what is your background and what is your engineering experience?",
            "Did you do any projects with LLMs or VLMs, or is this new to you from this year?",
            "Is there a plan to publish the work you have been doing during the MSc?",
            "How does your skill set and experience fit this project?",
            "What role does tactile sensing play in robot tool manipulation?",
            "Have you had any experience with tactile sensing, or is this just from your reading?",
            "You have controlled a real robot before, right?",
            "Which robots have you controlled, and what architectures did you use?",
            "Were you using ROS, or were you directly talking to the Python library?",
        ]

        for question in questions {
            let extracted = QuestionCandidatePipeline.extract(from: question)
            let guardResult = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: question)
            #expect(extracted.count == 1, "Expected one question for: \(question); got \(extracted.map(\.text))")
            #expect(guardResult.accepted, "Runtime guard rejected: \(question); \(guardResult.diagnostic)")
        }
    }

    @Test
    func realAcceptanceQuestionPhrasingsMapToPhDRubrics() {
        let cases: [(String, PhDQuestionIntent)] = [
            ("Before starting the Robotics Masters programme, which parts of your technical background best prepared you for research in embodied artificial intelligence?", .preMScBackground),
            ("Before starting the robotics master's program, which parts of your technical background best prepared you for research in embodied artificial intelligence?", .preMScBackground),
            ("Which part of your current grasping research gives the strongest evidence that you could make an effective contribution to this PhD?", .graspResearch),
            ("Since you have not yet worked directly with tactile hardware, how would you close that skills gap during the first six months of the PhD?", .tactileLearningPlan),
            ("Imagine that the camera predicts a stable grasp, but the tactile sensor reports that the object is slipping. How should the robot respond?", .tactileSlipResponse),
            ("Describe the control architecture you used on the robot arm, from the perception result through ROS2 to physical motion execution.", .robotArchitecture),
            ("Which failure cases would you prioritise first when moving that method onto the real robot?", .graspResearch)
        ]

        for (question, expected) in cases {
            #expect(PhDInterviewRubricPolicy.intent(for: question) == expected)
            #expect(PhDInterviewRubricPolicy.rubric(for: question) != nil)
            #expect(!PhDInterviewRubricPolicy.promptGuidance(for: question).isEmpty)
        }
    }

    @Test
    func phdHonestyRubricsRejectObservedBackgroundAndTactileOverclaims() {
        let backgroundQuestion = "Before starting the Robotics Masters programme, which parts of your technical background best prepared you for embodied AI research?"
        let backgroundAnswer = "My computer science and deep-learning work on vision-language-action models before my MSc prepared me for embodied AI."
        let observedQuestion = "Before starting the robotics master's program, which parts of your technical background best prepared you for research in embodied artificial intelligence?"
        let observedAnswer = "My background in robotics and ROS2 gave me the practical foundation to bridge vision-language models with real-world robotic manipulation."
        let clarificationQuestion = "Did you already have hands-on experience with physical robots before the MSc, or was your earlier work mainly software and machine learning?"
        let clarificationAnswer = "My earlier work was primarily software and machine learning, focused on developing vision-language-action models for robotic manipulation and real-robot grasp re-ranking."
        let slipQuestion = "Imagine that the camera predicts a stable grasp, but the tactile sensor reports that the object is slipping. How should the robot respond?"
        let slipAnswer = "I would immediately abort the current motion and apply a corrective force to re-establish contact. This closed-loop adaptation ensures the robot does not lose the object."
        let tactileQuestion = "Since you have not yet worked directly with tactile hardware, how would you close that skills gap during the first six months?"
        let tactileAnswer = "I would read about tactile perception and build a simulation framework before any physical hardware, focusing on theoretical manipulation and ROS2."
        let contaminatedTactileAnswer = "I would read the literature, then run controlled contact experiments on my existing LeoRover platform to calibrate camera and IMU inputs before developing a perception loop."
        let noCalibrationTactilePlan = "I would study tactile sensor literature, work with the lab on controlled contact and slip experiments, process the acquired data, and integrate it into a small ROS2 manipulation loop under supervisor guidance."
        let inventedMetricAnswer = "I designed a semantic-geometric re-ranker and demonstrated a 70% retrieval success rate on the real robot."
        let inventedCompletedValidationAnswer = "I designed a target-conditioned semantic and geometric re-ranking pipeline for grasp candidates using detector confidence, target overlap, collision, and clearance. I integrated it into a real-robot pipeline and demonstrated improved failure-case reliability."
        let inventedValidatedOnRobotsAnswer = "I use semantic and geometric re-ranking for grasp candidates with detector confidence, target overlap, collision, and clearance. I have validated these methods against execution failure cases on real robots."
        let inventedValidationOutcome = "I prioritize semantic grounding failures for the referred target, then geometric collision and clearance failures in grasp candidates. My re-ranking pipeline uses detector confidence and target overlap, which significantly improved reliability during real-robot validation."
        let inventedLatencyAnswer = "I built a ROS2 architecture where perception outputs a target pose to the planner and arm controller, with execution feedback and recovery that reduced end-to-end latency to 200 ms."

        #expect(!PhDInterviewRubricPolicy.evaluate(question: backgroundQuestion, answer: backgroundAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: observedQuestion, answer: observedAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: clarificationQuestion, answer: clarificationAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: slipQuestion, answer: slipAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: tactileQuestion, answer: tactileAnswer).passed)
        let validator = AnswerClaimValidator()
        #expect(!validator.validate(answer: contaminatedTactileAnswer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        #expect(PhDInterviewRubricPolicy.evaluate(question: tactileQuestion, answer: noCalibrationTactilePlan).passed)
        for unsupportedAnswer in [inventedMetricAnswer, inventedCompletedValidationAnswer, inventedValidatedOnRobotsAnswer, inventedValidationOutcome, inventedLatencyAnswer] {
            #expect(!validator.validate(answer: unsupportedAnswer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
    }

    @Test
    func phdRecoveryGuidanceProvidesVerifiedFactsForWeakContextQuestions() {
        let cases = [
            "Before starting the Robotics Masters programme, which parts of your technical background prepared you for embodied AI?",
            "Since you have not yet worked directly with tactile hardware, how would you close that skills gap?",
            "Describe the control architecture you used on the robot arm through ROS2 to physical motion execution.",
            "Which failure cases would you prioritise first when moving that grasp re-ranking method onto the real robot?"
        ]

        for question in cases {
            let guidance = PhDInterviewRubricPolicy.promptGuidance(for: question)
            #expect(guidance.localizedCaseInsensitiveContains("Personal claims require selected candidate evidence"))
            #expect(!guidance.localizedCaseInsensitiveContains("Dexory"))
        }

        let graspGuidance = PhDInterviewRubricPolicy.promptGuidance(
            for: "Which failure cases would you prioritise first when moving that method onto the real robot?"
        )
        #expect(graspGuidance.localizedCaseInsensitiveContains("Do not invent metrics"))
    }

    @Test
    func observedGroundedQwenParaphrasesPassSpecializedPhDRubric() {
        let cases = [
            (
                "Describe the control architecture you used on the robot arm, from the perception result through ROS2 to physical motion execution.",
                "I used a ROS2-based control architecture where perception outputs a target pose, which I passed to the planning and arm-control components for execution. The system continuously validates the motion through feedback loops and implements recovery strategies if timing or localization errors occur."
            ),
            (
                "Which failure cases would you prioritize first when moving that method onto the real robot?",
                "I would prioritize grounding errors and calibration mismatches first because they undermine semantic and geometric re-ranking of grasp candidates for the referred target. I would then test collision or clearance failures and validate execution recovery on the real robot."
            ),
            (
                "Imagine that the camera predicts a stable grasp, but the tactile sensor reports that the object is slipping. How should the robot respond?",
                "I would confirm the slip signal, cautiously adjust grip force, and reposition or regrasp if contact remains unstable. I would replan through the closed loop and stop safely if recovery could not stabilize the object."
            ),
            (
                "Since you have not yet worked directly with tactile hardware, how would you close that skills gap during the first six months?",
                "I would acknowledge that gap, study the sensor principles, calibrate tactile sensors, and run controlled contact and slip experiments with data acquisition and signal processing. I would then integrate the observations into a small ROS2 manipulation loop with guidance from the lab before scaling up."
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
            PhDReplayTurn(1, "Candidate", .candidate, .candidatePresentation, "My presentation explains a language-guided manipulation pipeline from perception to action."),
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
                "What did you do before Manchester? Were you with robotics, or what was your background and what projects were you involved with?"
            ),
            expectedQuestionNeedle: "background",
            expectedIntent: .preMScBackground
        )

        #expect(result.answerSource == AnswerSource.ollamaQwen.rawValue)
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("computer science"))
        #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(result.answer))
    }

    @Test
    func clarifiedPreMScQuestionSupersedesWithoutStaleAnswer() async throws {
        let harness = try makeHarness()
        let first = try await harness.replayQuestion(
            PhDReplayTurn(20, "Panel B", .interviewer, .interviewerQuestions, "What did you do before Manchester, and what was your background?"),
            expectedQuestionNeedle: "before Manchester",
            expectedIntent: .preMScBackground
        )
        let firstQuestionID = try #require(harness.appState.activeQuestionID)

        let clarification = try await harness.replayQuestion(
            PhDReplayTurn(21, "Panel B", .interviewer, .interviewerQuestions, "Sorry, perhaps I was unclear. Prior to your MSc in Manchester, what is your background and what is your engineering experience?"),
            expectedQuestionNeedle: "Prior to your MSc",
            expectedIntent: .preMScBackground
        )

        let clarifiedQuestionID = try #require(harness.appState.activeQuestionID)
        #expect(clarifiedQuestionID != firstQuestionID)
        #expect(clarification.answer.localizedCaseInsensitiveContains("before my MSc"))
        #expect(clarification.answer.localizedCaseInsensitiveContains("computer science"))
        #expect(clarification.questionID == clarifiedQuestionID)
        #expect(first.questionID == firstQuestionID)
        #expect(harness.appState.currentSuggestion?.detectedQuestionID == clarifiedQuestionID)
        #expect(harness.appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("prior to your MSc") == true)
        #expect(harness.appState.liveSuggestionHistory.contains { $0.detectedQuestionID == firstQuestionID })
    }

    @Test
    func llmVlmExperienceAnswerPreservesHonesty() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(30, "Panel B", .interviewer, .interviewerQuestions, "Did you do any projects with LLMs or VLMs, or is this new to you from this year?"),
            expectedQuestionNeedle: "LLMs or VLMs",
            expectedIntent: .llmVlmExperience
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("newer"))
        #expect(result.answer.localizedCaseInsensitiveContains("NLP"))
        #expect(!result.answer.localizedCaseInsensitiveContains("years of VLM"))
    }

    @Test
    func publicationPlanAnswerIsCautious() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(40, "Panel B", .interviewer, .interviewerQuestions, "Is there a plan to publish the work you have been doing during the MSc?"),
            expectedQuestionNeedle: "publish",
            expectedIntent: .publicationPlan
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("possible"))
        #expect(!result.answer.localizedCaseInsensitiveContains("will definitely publish"))
    }

    @Test
    func skillFitAnswerUsesConcreteProjectEvidence() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(50, "Panel A", .interviewer, .interviewerQuestions, "How does your skill set and experience fit this project?"),
            expectedQuestionNeedle: "fit this project",
            expectedIntent: .skillFit
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("perception"))
        #expect(result.answer.localizedCaseInsensitiveContains("ROS2"))
        #expect(!result.answer.localizedCaseInsensitiveContains("hardworking"))
    }

    @Test
    func tactileRoleAnswerExplainsClosedLoopFeedback() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(60, "Panel A", .interviewer, .interviewerQuestions, "What role does tactile sensing play in robot tool manipulation?"),
            expectedQuestionNeedle: "tactile sensing",
            expectedIntent: .tactileRole
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("slip"))
        #expect(result.answer.localizedCaseInsensitiveContains("vision alone"))
    }

    @Test
    func tactileExperienceAnswerDoesNotInventHandsOnWork() async throws {
        let result = try await makeHarness().replayQuestion(
            PhDReplayTurn(70, "Panel A", .interviewer, .interviewerQuestions, "Have you had any experience with tactile sensing, or is this just from your reading?"),
            expectedQuestionNeedle: "experience with tactile",
            expectedIntent: .tactileExperience
        )
        #expect(result.quality.passed)
        #expect(result.answer.localizedCaseInsensitiveContains("reading"))
        #expect(result.answer.localizedCaseInsensitiveContains("hands-on"))
        #expect(!result.answer.localizedCaseInsensitiveContains("extensive hands-on"))
    }

    @Test
    func robotControlFollowUpsKeepRos2DistinctFromPythonApi() async throws {
        let harness = try makeHarness()
        let realRobot = try await harness.replayQuestion(
            PhDReplayTurn(80, "Panel B", .interviewer, .interviewerQuestions, "You have controlled a real robot before, right?"),
            expectedQuestionNeedle: "real robot",
            expectedIntent: .realRobotExperience
        )
        let platform = try await harness.replayQuestion(
            PhDReplayTurn(81, "Panel B", .interviewer, .interviewerQuestions, "Which robots have you controlled, and what architectures did you use?"),
            expectedQuestionNeedle: "Which robots",
            expectedIntent: .robotArchitecture
        )
        let ros = try await harness.replayQuestion(
            PhDReplayTurn(82, "Panel B", .interviewer, .interviewerQuestions, "Were you using ROS, or were you directly talking to the Python library?"),
            expectedQuestionNeedle: "using ROS",
            expectedIntent: .rosControl
        )

        #expect(realRobot.quality.passed)
        #expect(platform.quality.passed)
        #expect(ros.quality.passed)
        #expect(platform.answer.localizedCaseInsensitiveContains("ROS2"))
        #expect(!platform.answer.localizedCaseInsensitiveContains("Raspberry"))
        #expect(ros.answer.localizedCaseInsensitiveContains("ROS2"))
        #expect(ros.answer.localizedCaseInsensitiveContains("Python API"))
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
            "What is the first stage I should focus on in the first year?",
            "What robot platform and tactile sensors will be used in this project?",
            "Will I work directly with the hardware?",
            "Based on my background, where could I make a strong contribution?",
            "What do you think will be the biggest technical challenge in this PhD project?",
            "What will success look like at the end of the PhD?",
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
        await harness.replay(PhDReplayTurn(201, "Candidate", .candidate, .candidatePresentation, "I will present the perception and manipulation approach."))

        let cases: [(PhDReplayTurn, String, PhDQuestionIntent)] = [
            (PhDReplayTurn(210, "Panel B", .interviewer, .interviewerQuestions, "What did you do before Manchester, and what was your background?"), "before Manchester", .preMScBackground),
            (PhDReplayTurn(211, "Panel B", .interviewer, .interviewerQuestions, "Prior to your MSc in Manchester, what is your background and engineering experience?"), "Prior to your MSc", .preMScBackground),
            (PhDReplayTurn(212, "Panel B", .interviewer, .interviewerQuestions, "Did you do any projects with LLMs or VLMs, or is this new to you from this year?"), "LLMs or VLMs", .llmVlmExperience),
            (PhDReplayTurn(213, "Panel B", .interviewer, .interviewerQuestions, "Is there a plan to publish the work you have been doing during the MSc?"), "publish", .publicationPlan),
            (PhDReplayTurn(214, "Panel A", .interviewer, .interviewerQuestions, "How does your skill set and experience fit this project?"), "fit this project", .skillFit),
            (PhDReplayTurn(215, "Panel A", .interviewer, .interviewerQuestions, "What role does tactile sensing play in robot tool manipulation?"), "tactile sensing", .tactileRole),
            (PhDReplayTurn(216, "Panel A", .interviewer, .interviewerQuestions, "Have you had any experience with tactile sensing, or is this just from your reading?"), "experience with tactile", .tactileExperience),
            (PhDReplayTurn(217, "Panel B", .interviewer, .interviewerQuestions, "You have controlled a real robot before, right?"), "real robot", .realRobotExperience),
            (PhDReplayTurn(218, "Panel B", .interviewer, .interviewerQuestions, "Which robots have you controlled, and what architectures did you use?"), "Which robots", .robotArchitecture),
            (PhDReplayTurn(219, "Panel B", .interviewer, .interviewerQuestions, "Were you using ROS, or were you directly talking to the Python library?"), "using ROS", .rosControl),
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
            "What should I focus on in the first year?",
            "What robot and tactile sensors will be used?",
            "Will I work directly with the hardware?",
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
            "Before my MSc, I completed a bachelor's in computer science and built transferable programming, deep-learning, and NLP skills",
            "I am newer to LLM and VLM robotics this year; my earlier deep-learning and NLP work gave me a foundation, and my MSc provided current VLM and robotics exposure",
            "I bring robot perception, language-guided manipulation, visual grounding, grasp selection, and ROS2 integration experience",
            "I know tactile sensing mostly from reading rather than hands-on hardware work",
            "I used ROS2 as the system framework and used Python APIs for lower-level commands where appropriate",
            "I have controlled a small real robot arm using a ROS2 perception and manipulation architecture",
            "I have controlled a real robot arm, while keeping that work distinct from my current dissertation"
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
            displayName: "Synthetic Robotics PhD Candidate",
            sourceDocumentIDs: ["phd-replay-fixture"],
            education: [fixtureEvidence[0]],
            experience: Array(fixtureEvidence.dropFirst()),
            projects: [],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [ProfileEvidence(
                id: "phd-replay-tactile-gap",
                statement: "Tactile hardware is a declared learning area rather than completed hands-on experience",
                sourceDocumentID: "phd-replay-fixture",
                sourceChunkID: "phd-replay-gap-chunk",
                sourceSpan: "Tactile hardware is a declared learning area rather than completed hands-on experience",
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
        appState.selectInterviewDomain(.roboticsResearch)
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
    let displayName = "PhD Replay Qwen"

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
        if lower.contains("prior to your msc") {
            return "Before my MSc, I completed a bachelor's in computer science and built transferable programming, deep-learning, and NLP skills; I did not have extensive robotics experience before that degree."
        }
        if lower.contains("llms or vlms") {
            return "I am newer to LLM and VLM robotics this year; my earlier deep-learning and NLP work gave me a foundation, and my MSc provided current VLM and robotics exposure."
        }
        if lower.contains("plan to publish") || lower.contains("publish the work") {
            return "I am currently focused on the dissertation and benchmarking; publication is possible if the results are strong and align with my supervisor's research, but I would not promise it before that evaluation."
        }
        if lower.contains("skill set") && lower.contains("fit this project") {
            return "I bring robot perception, language-guided manipulation, visual grounding, grasp selection, and ROS2 integration experience; tactile sensing and world-action models are growth areas I would develop during the PhD."
        }
        if lower.contains("what role does tactile") {
            return "I see tactile sensing as closed-loop feedback after contact: location, force, slip, pressure distribution, and material properties let the robot adapt tool manipulation in real time when vision alone is insufficient."
        }
        if lower.contains("experience with tactile") {
            return "I know tactile sensing mostly from reading rather than hands-on hardware work; I would transfer my perception, manipulation, and ROS2 experience while learning the sensors experimentally during the PhD."
        }
        if lower.contains("using ros") || lower.contains("python library") {
            return "I used ROS2 as the system framework and used Python APIs for lower-level commands where appropriate, so the Python library sat inside the ROS2 control pipeline rather than replacing it."
        }
        if lower.contains("which robots") {
            return "I have controlled a small real robot arm using a ROS2 perception and manipulation architecture; I would verify the exact platform label rather than repeat an uncertain ASR name."
        }
        if lower.contains("controlled a real robot") {
            return "I have controlled a real robot arm, while keeping that work distinct from my current dissertation; my role covered the perception-to-manipulation pipeline and physical testing."
        }
        return "Before my MSc, I completed a bachelor's in computer science and worked with deep learning and NLP; my robotics experience developed later through the MSc, so I would not overclaim earlier robotics work."
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
