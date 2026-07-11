import Foundation
import GRDB
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct QuestionAnswerAlignmentTests {
    @Test
    func technicalChallengeAcceptsHarderBecauseUncertaintyAnswer() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What made production execution harder than the test environment?",
            answerText: "Production execution was harder because timing and input uncertainty changed together, so I mitigated the risk with logs, validation gates, and recovery behavior.",
            stageBCompleted: true
        )

        #expect(alignment.verdict == .aligned)
    }

    @Test
    func technicalChallengeAcceptsConcreteEngineeringActionsWithoutDebugKeyword() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Tell me about the most technically difficult project you worked on.",
            answerText: "The hardest project was a distributed service with severe database latency. I built a bounded processing pipeline, tuned the slow queries, and introduced load controls that reduced failures under peak traffic.",
            stageBCompleted: true
        )

        #expect(alignment.verdict == .aligned)
    }

    @Test
    func reliabilityQuestionAcceptsMonitoringCalibrationAndFeedbackActions() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How would you improve the reliability of tactile manipulation on a real robot?",
            answerText: "For tactile manipulation, I would add force feedback, calibrate contact thresholds, monitor slip signals, and adjust grip control before each robot deployment so recovery remains predictable.",
            stageBCompleted: true
        )

        #expect(alignment.verdict == .aligned)
    }

    @Test
    func oneQuestionOneAnswerBindsSuggestionToDetectedQuestion() async throws {
        let client = AlignmentLLMClient()
        let (appState, database, session) = try makeAppState(client: client)
        let question = try saveQuestion(
            "Why do you want to join our team?",
            sessionID: session.id,
            repository: appState.suggestionRepository,
            suffix: "role"
        )

        appState.setActiveQuestionForTesting(question)
        var alignedCard = SuggestionCard(
            id: "one-question-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Role motivation",
            sayFirst: "I want to join because this role connects with my robotics, AI, and perception experience, and it aligns with my interest in real robot deployment.",
            keyPoints: ["Robotics and AI fit", "Real-world deployment", "Engineering growth"],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "alignment-test",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        alignedCard.questionText = question.questionText
        alignedCard.generationID = "generation-one-question"
        alignedCard.triggerPath = .autoDetect

        let accepted = appState.applySuggestionIfAlignedForTesting(
            alignedCard,
            question: question,
            generationID: alignedCard.generationID
        )
        #expect(accepted)

        let card = try #require(appState.currentSuggestion)
        #expect(card.detectedQuestionID == question.id)
        #expect(card.questionText == question.questionText)
        #expect(card.generationID == "generation-one-question")
        #expect(card.triggerPath == .autoDetect)
        #expect(card.sayFirst.localizedCaseInsensitiveContains("robotics"))

        try appState.suggestionRepository.saveSuggestionCard(card)
        let stored = try suggestionAlignmentRows(database: database)
        let storedCard = try #require(stored.first)
        #expect(stored.count == 1)
        #expect(storedCard.detectedQuestionID == question.id)
        #expect(storedCard.detectedQuestionID == storedCard.joinedQuestionID)
        #expect(storedCard.suggestionQuestion == question.questionText)
    }

    @Test
    func twoConsecutiveQuestionsKeepLateFirstAnswerOutOfSecondUI() async throws {
        let client = AlignmentLLMClient()
        client.blockNextStageB()
        let (appState, database, session) = try makeAppState(client: client)
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000

        let first = try saveQuestion("Could you tell me about yourself?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "self")
        let second = try saveQuestion("What was the hardest technical challenge in your LeoRover project?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "challenge")

        defer {
            client.releaseBlockedStageB()
            appState.cancelStageBTask()
        }

        try await appState.generateSuggestion(
            for: first,
            session: session,
            transcript: first.questionText,
            autoGenerated: true
        )
        do {
            try await waitUntil(label: "first Stage B stream to start", timeout: 20.0) {
                client.blockedStageBStarted
            }
        } catch {
            let activeQuestion = appState.activeQuestionID ?? "nil"
            let activeGeneration = appState.currentGenerationID ?? "nil"
            let stageBActive = appState.stageBTaskActive
            let tasks = appState.activeTaskSummary
            let mockSummary = client.invocationSummary
            Issue.record("Stage B start diagnostics: \(mockSummary); activeQuestion=\(activeQuestion); activeGeneration=\(activeGeneration); stageBActive=\(stageBActive); tasks=\(tasks)")
            throw error
        }
        #expect(appState.activeQuestionID == first.id)

        try await appState.generateSuggestion(
            for: second,
            session: session,
            transcript: second.questionText,
            autoGenerated: true
        )

        try await waitUntil(label: "second question answer binding", timeout: 20.0) {
            appState.currentSuggestion?.detectedQuestionID == second.id &&
            appState.currentQABinding.bindingStatus == .matched
        }
        client.releaseBlockedStageB()
        try await waitUntil(label: "blocked first Stage B stream to finish", timeout: 8.0) {
            client.blockedStageBFinished
        }

        let visible = try #require(appState.currentSuggestion)
        #expect(visible.detectedQuestionID == second.id)
        #expect(visible.questionText == second.questionText)
        #expect(!visible.sayFirst.localizedCaseInsensitiveContains("MSc Robotics"))
        #expect(!visible.sayFirst.localizedCaseInsensitiveContains("University of Manchester"))
        #expect(appState.staleAnswerDiscardCount >= 1 || appState.cancelledGenerationCount >= 1)

        try await Task.sleep(nanoseconds: 120_000_000)
        let rows = try suggestionAlignmentRows(database: database)
        #expect(rows.allSatisfy { $0.detectedQuestionID == $0.joinedQuestionID })
        #expect(rows.allSatisfy { $0.suggestionQuestion == $0.detectedQuestion })
        if rows.contains(where: { $0.detectedQuestionID == first.id }) {
            #expect(rows.contains { $0.detectedQuestionID == first.id && $0.suggestionQuestion == first.questionText })
        }
        if rows.contains(where: { $0.detectedQuestionID == second.id }) {
            #expect(rows.contains { $0.detectedQuestionID == second.id && $0.suggestionQuestion == second.questionText })
        }
    }

    @Test
    func rapidThreeQuestionSequenceLeavesOnlyLatestQuestionBoundToUI() async throws {
        let client = AlignmentLLMClient()
        client.stageADelayByQuestionKeyword = [
            "about yourself": 700_000_000,
            "LeoRover": 700_000_000
        ]
        let (appState, _, session) = try makeAppState(client: client)
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 800_000_000

        let first = try saveQuestion("Tell me about yourself", sessionID: session.id, repository: appState.suggestionRepository, suffix: "self")
        let second = try saveQuestion("Walk me through your LeoRover project", sessionID: session.id, repository: appState.suggestionRepository, suffix: "project")
        let third = try saveQuestion("Why do you want this role?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "role")

        let firstTask = Task { try await appState.generateSuggestion(for: first, session: session, transcript: first.questionText, autoGenerated: true) }
        try await waitUntil(timeout: 8.0) { appState.activeQuestionID == first.id }
        let secondTask = Task { try await appState.generateSuggestion(for: second, session: session, transcript: second.questionText, autoGenerated: true) }
        try await waitUntil(timeout: 8.0) { appState.activeQuestionID == second.id }
        let thirdTask = Task { try await appState.generateSuggestion(for: third, session: session, transcript: third.questionText, autoGenerated: true) }
        defer {
            firstTask.cancel()
            secondTask.cancel()
            thirdTask.cancel()
        }

        try await waitUntil(timeout: 8.0) {
            appState.activeQuestionID == third.id &&
            appState.currentSuggestion?.detectedQuestionID == third.id &&
            appState.currentQABinding.bindingStatus == .matched
        }

        #expect(appState.currentSuggestion?.questionText == third.questionText)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("MSc Robotics") != true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("LeoRover") != true)
        #expect(appState.currentQABinding.bindingStatus == .matched)
        #expect(appState.staleAnswerDiscardCount >= 1 || appState.cancelledGenerationCount >= 1)
    }

    @Test
    func longTranscriptMultiQuestionExtractionBindsLatestSuggestionToLatestQuestion() async throws {
        let (appState, database, session) = try makeAppState(client: AlignmentLLMClient())
        let candidates = QuestionCandidatePipeline.extract(from: Self.longQuestionOnlyTranscript, isFinal: true)
        #expect(candidates.count == 5)
        let latest = try #require(candidates.last)
        let latestQuestion = try saveQuestion(latest.text, sessionID: session.id, repository: appState.suggestionRepository, suffix: "long-latest")
        appState.setActiveQuestionForTesting(latestQuestion)
        var card = SuggestionCard(
            id: "long-latest-card",
            sessionID: session.id,
            questionID: latestQuestion.id,
            strategy: "Interviewer questions",
            sayFirst: "What would success look like? How is the team structured? Which constraints matter most?",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "test",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        card.questionText = latestQuestion.questionText
        #expect(appState.applySuggestionIfAlignedForTesting(card, question: latestQuestion, generationID: nil))
        try appState.suggestionRepository.saveSuggestionCard(try #require(appState.currentSuggestion))
        let rows = try suggestionAlignmentRows(database: database)
        #expect(rows.count == 1)
        #expect(rows[0].detectedQuestionID == latestQuestion.id)
        #expect(rows[0].suggestionQuestion == latestQuestion.questionText)
    }

    @Test
    func dbRoundtripPersistsDetectedQuestionBindingAndQuestionSnapshot() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionAnswerAlignmentDB")
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Alignment DB")
        let question = try saveQuestion(
            "How did you handle noisy detections or localisation errors?",
            sessionID: session.id,
            repository: suggestions,
            suffix: "noise"
        )
        let card = SuggestionCard(
            id: "alignment-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Technical explanation",
            sayFirst: "I handled noisy detections by filtering repeated observations and only acting when the target was stable.",
            keyPoints: ["Filtering", "Repeated observations", "Recovery behaviour"],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "mock",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )

        try suggestions.saveSuggestionCard(card)

        let rows = try suggestionAlignmentRows(database: database)
        #expect(rows.count == 1)
        #expect(rows[0].detectedQuestionID == question.id)
        #expect(rows[0].joinedQuestionID == question.id)
        #expect(rows[0].suggestionQuestion == question.questionText)
        #expect(rows[0].detectedQuestion == question.questionText)
        #expect(try orphanAutoDetectSuggestionCount(database: database) == 0)
    }

    @Test
    func uiBindingGuardRejectsSuggestionForDifferentQuestion() throws {
        let (appState, _, session) = try makeAppState(client: AlignmentLLMClient())
        let first = try saveQuestion("Could you tell me about yourself?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "self")
        let second = try saveQuestion("Why do you want this role?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "role")
        appState.lastDetectedQuestion = second
        appState.setActiveQuestionForTesting(second)

        let wrongCard = SuggestionCard(
            id: "wrong-card",
            sessionID: session.id,
            questionID: first.id,
            strategy: "Self introduction",
            sayFirst: "I am currently studying MSc Robotics at the University of Manchester.",
            keyPoints: ["MSc Robotics"],
            followUpReady: [],
            confidence: 0.8,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "mock",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date(),
            questionText: first.questionText
        )

        let accepted = appState.applySuggestionIfAlignedForTesting(wrongCard, question: second, generationID: nil)

        #expect(accepted == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.currentQABinding.bindingStatus == .mismatched)
        #expect(appState.answerQuestionMismatchCount == 1)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("question"))
    }

    @Test
    func contentRelevanceEvaluatorFlagsAlignedAndMismatchedAnswers() {
        let roleAligned = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Why do you want to join our team?",
            answerText: "I want to join because the role connects robotics, AI, perception, real robot deployment, and engineering growth."
        )
        #expect(roleAligned.verdict == .aligned)

        let roleMismatched = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Why do you want this role?",
            answerText: "The hardest technical challenge was noisy localisation and timing mismatch on the robot."
        )
        #expect(roleMismatched.verdict == .mismatched)

        let candidateQuestionMismatched = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Do you have any questions for us?",
            answerText: "I am currently studying MSc Robotics at the University of Manchester, with a computer science background."
        )
        #expect(candidateQuestionMismatched.verdict == .mismatched)
    }

    @Test
    func newRuntimeQuestionAnswersAlignWithSpecificIntents() {
        let decoder = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            answerText: "In the MuJoCo VLA Franka simulation, I learned that diffusion performed best at about 7/10 successful grasps, while autoregressive and flow-matching were weaker at around 1/10. The lesson was that architecture choice matters for continuous action trajectory generation because diffusion was smoother and autoregressive errors accumulated."
        )
        #expect(decoder.verdict == .aligned)
        #expect(decoder.questionIntent == .decoderComparison)
        #expect(decoder.answerIntent == .decoderComparison)

        let perception = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?",
            answerText: "I would reproduce the exact LeoRover frames from the YOLOv8 detector, inspect logs, bounding boxes, classes and confidence for the confident but wrong prediction, then check calibration, lighting, occlusion, motion blur, and spatial or temporal consistency before adding recovery validation or retraining."
        )
        #expect(perception.verdict == .aligned)
        #expect(perception.questionIntent == .perceptionDebugging)
        #expect(perception.answerIntent == .perceptionDebugging)

        let tradeoff = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What was the biggest technical trade-off you made in your robotics projects?",
            answerText: "The biggest trade-off was robustness versus latency and complexity. In LeoRover I chose practical filtering, recovery, and ROS2 coordination first, because reliable real robot execution mattered more than a simpler demo, and I learned to prioritize dependable system behaviour."
        )
        #expect(tradeoff.verdict == .aligned)
        #expect(tradeoff.questionIntent == .technicalTradeoff)
        #expect(tradeoff.answerIntent == .technicalTradeoff)

        let dataset = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            answerText: "I treated the DROID real-robot trajectories as demonstrations, mapped the actions and observations into the MuJoCo Franka simulator format, checked coordinate frames and timing consistency, and validated the simulated behavior before training or evaluation."
        )
        #expect(dataset.verdict == .aligned)
        #expect(dataset.questionIntent == .datasetAdaptation)
        #expect(dataset.answerIntent == .datasetAdaptation)

        let simToReal = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?",
            answerText: "I would compare simulator and real robot observations, action scaling, timing, calibration, and contact dynamics, inspect failure videos and logs, then isolate whether the root cause is perception, control, dynamics mismatch, or distribution shift before retraining."
        )
        #expect(simToReal.verdict == .aligned)
        #expect(simToReal.questionIntent == .simToRealDebugging)
        #expect(simToReal.answerIntent == .simToRealDebugging)

        let projectComparison = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Can you explain the difference between your VLA project and your LeoRover project?",
            answerText: "The VLA project was a MuJoCo Franka learning-policy evaluation around action decoders, while LeoRover was a real robot ROS2 integration project with YOLOv8 perception, navigation, localisation, and manipulation. The main difference was policy evaluation versus deployed system integration."
        )
        #expect(projectComparison.verdict == .aligned)
        #expect(projectComparison.questionIntent == .projectComparison)
        #expect(projectComparison.answerIntent == .projectComparison)
    }

    @Test
    func wrongAnswerRejectionCatchesSpecificRuntimeConfusions() {
        let tradeoffWrong = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What was the biggest technical trade-off you made in your robotics projects?",
            answerText: "I built a data pipeline that processed 10,000 records and optimized ETL throughput for a database workload."
        )
        #expect(tradeoffWrong.verdict == .mismatched)
        #expect(tradeoffWrong.missingThemes.contains("question topic"))

        let decoderGeneric = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            answerText: "Diffusion is generally smoother than autoregressive methods for robotics because it can be robust."
        )
        #expect(decoderGeneric.verdict == .aligned)

        let incompleteQuestion = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "what did you learn",
            answerText: "I learned that diffusion performed best in the MuJoCo VLA setup."
        )
        #expect(incompleteQuestion.verdict == .mismatched)
        #expect(incompleteQuestion.reason.localizedCaseInsensitiveContains("incomplete question"))
    }

    @Test
    func decoderComparisonAlignmentLeavesFactualSupportToGroundingValidator() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            answerText: "In my MuJoCo VLA project, I compared autoregressive, diffusion, and flow-matching decoders and found that diffusion models provided the best trade-off between trajectory diversity and smoothness, while flow-matching offered faster sampling with comparable quality."
        )

        #expect(alignment.questionIntent == .decoderComparison)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func systemIntegrationDebuggingAnswerAlignsWithOwnIntent() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Tell me about a time you had to debug a system integration problem.",
            answerText: "One system integration issue was on LeoRover, where the ROS2 perception, navigation, and manipulation modules had timing mismatches. I reproduced the failure, checked logs and timestamps, isolated the handoff, added recovery behaviour, and learned that integration reliability matters as much as model accuracy."
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .systemIntegrationDebugging)
        #expect(alignment.answerIntent == .systemIntegrationDebugging)
    }

    @Test
    func localizationManipulationHandoffRequiresSnapshotBoundFallback() {
        let question = "How did localization influence manipulation, and why was that handoff difficult to make reliable?"
        #expect(IntentRouter.answerIntent(for: question) == .systemIntegrationDebugging)

        let detectedQuestion = DetectedQuestion(
            id: "localization-manipulation-handoff",
            sessionID: "alignment-test-session",
            transcriptSegmentID: nil,
            questionText: question,
            intent: .technical,
            answerStrategy: .technicalExplanation,
            confidence: 0.93,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date(),
            ingressIdentity: nil
        )
        let fallback = ProjectGroundedFallbackPolicy.fallbackAnswer(for: detectedQuestion)
        #expect(fallback.sayFirst.isEmpty)
        #expect(fallback.keyPoints.isEmpty)
    }

    @Test
    func interviewerQuestionsRequireActualUsefulQuestions() {
        let aligned = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What questions would you ask us about the team or the role before accepting an offer?",
            answerText: "I would ask what would success look like in the first three months, what deployment challenges the team is facing, how the team is structured across perception and autonomy, what data or simulation infrastructure is used, and how much ownership I would have over production workflows."
        )
        #expect(aligned.verdict == .aligned)
        #expect(aligned.questionIntent == .interviewerQuestions)
        #expect(aligned.answerIntent == .interviewerQuestions)

        let vague = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What questions would you ask us about the team or the role before accepting an offer?",
            answerText: "Yes, I'd love to ask a question."
        )
        #expect(vague.verdict == .mismatched)
    }

    @Test
    func leoRoverImprovementRejectsWrongProjectRerankerGrounding() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "If you had one more month to improve your LeoRover system, what would you improve first?",
            answerText: "I would improve the target-conditioned semantic-geometric re-ranker from my VLM grasping thesis, because the grasp scorer could better rerank candidates before policy execution."
        )

        #expect(alignment.questionIntent == .improvementPlan)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.reason.localizedCaseInsensitiveContains("missing"))
    }

    @Test
    func villaProjectQuestionCanonicalizesAndAlignsAsProjectComparison() {
        let question = "Can you explain the difference between your VLA project and your LeoRover project"
        let answer = "The VLA project was a MuJoCo Franka learning-policy evaluation using DROID trajectories and decoder comparisons, while LeoRover was a real robot ROS2 integration project with YOLOv8 perception, navigation, localisation, and manipulation. The difference is learned policy research in simulation versus deployed robotic system integration."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(AnswerRelevancePolicy.intent(for: question) == .projectComparison)
        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .projectComparison)
    }

    private static let longQuestionOnlyTranscript = "Could you tell me a little bit about yourself? Could you walk me through your platform project? What was the hardest technical challenge you faced? Why do you want to join our team? Do you have any questions for us?"

    private func makeAppState(client: AlignmentLLMClient) throws -> (AppState, AppDatabase, InterviewSession) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionAnswerAlignment")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: AlignmentContextRetrievalService()
        )
        let fixtureStatements = [
            "Studied a synthetic technical degree with a software and applied systems background",
            "Built a synthetic autonomous system project using perception, planning, and execution components",
            "Debugged a difficult integration issue involving noisy inputs, state estimation, and timing",
            "Compared autoregressive, diffusion, and flow-matching approaches in a simulation evaluation",
            "Used Python and a robot middleware framework in synthetic coursework",
            "Improved evaluation by testing more failure cases and recovery behavior"
            ,"I am studying MSc Robotics at the University of Manchester, with a computer science background and a focus on perception, manipulation, and AI"
            ,"The hardest technical challenge was integrating modules on the real robot, where noisy perception, localisation instability, and timing mismatch made execution unpredictable"
            ,"My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8, navigation, target localisation, and manipulation"
            ,"I handled noisy detections by filtering repeated observations, using stability thresholds, and adding recovery behaviour such as retrying or repositioning"
            ,"The diffusion decoder performed better because it produced smoother actions for continuous action distributions and was more robust, reaching seven out of ten successful grasps"
            ,"I am comfortable with Python and ROS2 from robotics projects, and I am improving C++ for performance-critical robotics systems"
            ,"I built a platform project that connected API processing, data storage, and recovery, then validated latency and failure handling"
            ,"In the LeoRover fixture project, the hardest technical challenge was integrating modules on the real robot, where noisy perception, localisation instability, and timing mismatch made execution unpredictable"
            ,"In the LeoRover fixture project, the hardest technical challenge was integrating modules on the real robot. I isolated timing mismatches with logs, then added validation checks at each handoff"
        ]
        let fixtureEvidence = fixtureStatements.enumerated().map { index, statement in
            ProfileEvidence(
                id: "alignment-evidence-\(index)",
                statement: statement,
                sourceDocumentID: "alignment-fixture",
                sourceChunkID: "alignment-chunk-\(index)",
                sourceSpan: statement,
                confidence: 1,
                evidenceType: index == 0 ? .education : .project,
                explicitness: .explicit
            )
        }
        try appState.interviewContextRepository.saveCandidateProfile(CandidateProfile(
            id: "alignment-profile",
            displayName: "Synthetic Alignment Candidate",
            sourceDocumentIDs: ["alignment-fixture"],
            education: [fixtureEvidence[0]],
            experience: [],
            projects: Array(fixtureEvidence.dropFirst()),
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date()
        ))
        appState.refreshAll()
        appState.selectCandidateProfile("alignment-profile")
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 2_000_000_000
        let session = try appState.createContextBoundSession(mode: .microphone)
        appState.currentSession = session
        return (appState, database, session)
    }

    private func saveQuestion(
        _ text: String,
        sessionID: String,
        repository: SuggestionRepository,
        suffix: String
    ) throws -> DetectedQuestion {
        let question = DetectedQuestion(
            id: "alignment-\(suffix)-\(UUID().uuidString)",
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: text,
            intent: intent(for: text),
            answerStrategy: strategy(for: text),
            confidence: 0.95,
            reason: "Alignment test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "alignment-test",
            promptVersion: "test",
            createdAt: Date()
        )
        try repository.saveDetectedQuestion(question)
        return question
    }

    private func intent(for text: String) -> QuestionIntent {
        let lower = text.lowercased()
        if lower.contains("project") || lower.contains("leorover") {
            return .projectDeepDive
        }
        if lower.contains("technical") || lower.contains("detections") || lower.contains("diffusion") || lower.contains("python") {
            return .technical
        }
        if lower.contains("role") || lower.contains("team") || lower.contains("questions for us") {
            return .companyFit
        }
        return .behavioral
    }

    private func strategy(for text: String) -> AnswerStrategy {
        let intent = intent(for: text)
        switch intent {
        case .projectDeepDive:
            return .projectWalkthrough
        case .technical:
            return .technicalExplanation
        case .behavioral:
            return .starStory
        case .companyFit:
            return .directAnswer
        case .coding, .salaryVisa, .smallTalk, .instruction, .unclear:
            return .directAnswer
        }
    }

    nonisolated private func waitUntil(
        label: String = "QA alignment state",
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let pollIntervalNanoseconds: UInt64 = 25_000_000
        let deadline = Date().addingTimeInterval(timeout)
        while !(await predicate()) {
            if Date() >= deadline {
                throw NSError(
                    domain: "QuestionAnswerAlignmentTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(label)."]
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}

private struct SuggestionAlignmentSQLRow {
    var detectedQuestionID: String?
    var joinedQuestionID: String?
    var detectedQuestion: String?
    var suggestionQuestion: String?
    var answerPreview: String
}

private func suggestionAlignmentRows(database: AppDatabase) throws -> [SuggestionAlignmentSQLRow] {
    try database.dbQueue.read { db in
        try Row.fetchAll(
            db,
            sql: """
            SELECT
              s.detected_question_id,
              dq.id AS question_id,
              dq.question_text AS detected_question,
              s.question_text AS suggestion_question,
              substr(s.say_first, 1, 220) AS answer_preview
            FROM suggestion_cards s
            LEFT JOIN detected_questions dq
              ON s.detected_question_id = dq.id
            ORDER BY s.created_at ASC
            """
        ).map { row in
            SuggestionAlignmentSQLRow(
                detectedQuestionID: row["detected_question_id"],
                joinedQuestionID: row["question_id"],
                detectedQuestion: row["detected_question"],
                suggestionQuestion: row["suggestion_question"],
                answerPreview: row["answer_preview"]
            )
        }
    }
}

private func orphanAutoDetectSuggestionCount(database: AppDatabase) throws -> Int {
    try database.dbQueue.read { db in
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM suggestion_cards s
            LEFT JOIN detected_questions dq
              ON s.detected_question_id = dq.id
            WHERE s.trigger_path = 'auto_detect'
              AND dq.id IS NULL
            """
        ) ?? 0
    }
}

private final class AlignmentLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    var stageADelayByQuestionKeyword = [String: UInt64]()
    var stageBDelayByQuestionKeyword = [String: UInt64]()
    private let blockedStageBGate = OneShotAsyncGate()
    private let blockedStageBStateLock = NSLock()
    private var blockNextStageBStream = false
    private var blockedStageBStartedStorage = false
    private var blockedStageBFinishedStorage = false
    private var stageAStreamInvocationCount = 0
    private var stageBStreamInvocationCount = 0
    private var chatInvocationCount = 0

    var invocationSummary: String {
        blockedStageBStateLock.lock()
        defer { blockedStageBStateLock.unlock() }
        return "stageAStreams=\(stageAStreamInvocationCount), stageBStreams=\(stageBStreamInvocationCount), chats=\(chatInvocationCount), blockArmed=\(blockNextStageBStream)"
    }

    var blockedStageBStarted: Bool {
        blockedStageBStateLock.lock()
        defer { blockedStageBStateLock.unlock() }
        return blockedStageBStartedStorage
    }

    var blockedStageBFinished: Bool {
        blockedStageBStateLock.lock()
        defer { blockedStageBStateLock.unlock() }
        return blockedStageBFinishedStorage
    }

    func blockNextStageB() {
        blockedStageBStateLock.lock()
        blockNextStageBStream = true
        blockedStageBStartedStorage = false
        blockedStageBFinishedStorage = false
        blockedStageBStateLock.unlock()
    }

    func releaseBlockedStageB() {
        blockedStageBGate.open()
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Mock OK", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        recordChatInvocation()
        let question = questionText(from: messages)
        if let delay = delay(for: question, in: stageBDelayByQuestionKeyword) {
            try await Task.sleep(nanoseconds: delay)
        }
        let content = jsonAnswer(for: question)
        return LLMChatResult(content: content, modelName: "alignment-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let question = questionText(from: messages)
        let isStageB = prompt.contains("Return plain text sections only")
        recordStreamInvocation(isStageB: isStageB)
        let delay = delay(for: question, in: isStageB ? stageBDelayByQuestionKeyword : stageADelayByQuestionKeyword) ?? 0
        let shouldBlockStageB = isStageB && claimBlockedStageB()
        return AsyncThrowingStream { continuation in
            let task = Task {
                if shouldBlockStageB {
                    markBlockedStageBStarted()
                    await blockedStageBGate.wait()
                    markBlockedStageBFinished()
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                if isStageB {
                    for token in sectionAnswer(for: question) {
                        if Task.isCancelled { break }
                        continuation.yield(token)
                    }
                } else {
                    for token in sayFirst(for: question).split(separator: " ", omittingEmptySubsequences: false) {
                        if Task.isCancelled { break }
                        continuation.yield(String(token) + " ")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    private func delay(for question: String, in delays: [String: UInt64]) -> UInt64? {
        delays.first { question.localizedCaseInsensitiveContains($0.key) }?.value
    }

    private func claimBlockedStageB() -> Bool {
        blockedStageBStateLock.lock()
        defer { blockedStageBStateLock.unlock() }
        guard blockNextStageBStream else { return false }
        blockNextStageBStream = false
        return true
    }

    private func recordStreamInvocation(isStageB: Bool) {
        blockedStageBStateLock.lock()
        if isStageB {
            stageBStreamInvocationCount += 1
        } else {
            stageAStreamInvocationCount += 1
        }
        blockedStageBStateLock.unlock()
    }

    private func recordChatInvocation() {
        blockedStageBStateLock.lock()
        chatInvocationCount += 1
        blockedStageBStateLock.unlock()
    }

    private func markBlockedStageBStarted() {
        blockedStageBStateLock.lock()
        blockedStageBStartedStorage = true
        blockedStageBStateLock.unlock()
    }

    private func markBlockedStageBFinished() {
        blockedStageBStateLock.lock()
        blockedStageBFinishedStorage = true
        blockedStageBStateLock.unlock()
    }

    private func questionText(from messages: [LLMChatMessage]) -> String {
        let prompt = messages.map(\.content).joined(separator: "\n")
        if let range = prompt.range(of: #"CURRENT QUESTION TO ANSWER:\s*\n"([^"]+)""#, options: [.regularExpression, .caseInsensitive]) {
            return String(prompt[range])
                .replacingOccurrences(of: "CURRENT QUESTION TO ANSWER:", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = prompt.range(of: #"\[Question\]\s*\n(.+?)(\n\n|\z)"#, options: [.regularExpression, .caseInsensitive]) {
            return String(prompt[range])
                .replacingOccurrences(of: "[Question]", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = prompt.range(of: #"Detected question:\s*\n(.+?)(\n\n|\z)"#, options: [.regularExpression, .caseInsensitive]) {
            return String(prompt[range])
                .replacingOccurrences(of: "Detected question:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompt
    }

    private func jsonAnswer(for question: String) -> String {
        let sayFirst = sayFirst(for: question)
        return """
        {
          "strategy": "Aligned answer",
          "say_first": "\(sayFirst)",
          "key_points": ["\(keyPoint(for: question))", "Keep it specific to this question"],
          "follow_up_ready": ["I can add more detail if useful."],
          "confidence": 0.88,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
    }

    private func sectionAnswer(for question: String) -> [String] {
        [
            "STRATEGY:\nAligned answer\n",
            "SAY_FIRST:\n\(sayFirst(for: question))\n",
            "KEY_POINTS:\n",
            "- \(keyPoint(for: question))\n",
            "- Keep it specific to this question\n",
            "FOLLOW_UP_READY:\n",
            "- I can add more detail if useful.\n",
            "CAUTION:\nNone\n"
        ]
    }

    private func sayFirst(for question: String) -> String {
        let lower = question.lowercased()
        if lower.contains("about yourself") || lower.contains("tell me about yourself") {
            return "I am studying MSc Robotics at the University of Manchester, with a computer science background and a focus on perception, manipulation, and AI."
        }
        if lower.contains("hardest technical challenge") {
            return "In the LeoRover fixture project, the hardest technical challenge was integrating modules on the real robot. I isolated timing mismatches with logs, then added validation checks at each handoff."
        }
        if lower.contains("platform project") {
            return "I built a platform project that connected API processing, data storage, and recovery, then validated latency and failure handling."
        }
        if lower.contains("leorover") || lower.contains("walk me through") {
            return "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8, navigation, target localisation, and manipulation."
        }
        if lower.contains("noisy detections") || lower.contains("localisation") || lower.contains("localization") {
            return "I handled noisy detections by filtering repeated observations, using stability thresholds, and adding recovery behaviour such as retrying or repositioning."
        }
        if lower.contains("diffusion") {
            return "The diffusion decoder performed better because it produced smoother actions for continuous action distributions and was more robust, reaching seven out of ten successful grasps."
        }
        if lower.contains("another month") || lower.contains("change first") {
            return "I would improve the evaluation pipeline first, testing more objects, initial positions, failure cases, perception robustness, visual grounding, and grasp reranking."
        }
        if lower.contains("join our team") || lower.contains("want this role") || lower.contains("want to join") {
            return "I want this role because it connects robotics, AI, perception, real robot deployment, engineering growth, and deployed systems."
        }
        if lower.contains("python") || lower.contains("ros2") || lower.contains("c++") {
            return "I am comfortable with Python and ROS2 from robotics projects, and I am improving C++ for performance-critical robotics systems."
        }
        if lower.contains("questions for us") || lower.contains("questions for you") {
            return "I would ask what success looks like in the first three months, what deployment challenges the robotics team is facing, how the team is structured across perception and autonomy, and how much ownership I would have over production workflows."
        }
        return "I would answer this question directly and keep the response specific to the interviewer prompt."
    }

    private func keyPoint(for question: String) -> String {
        String(sayFirst(for: question).prefix(80))
    }
}

private final class OneShotAsyncGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }
}

private final class AlignmentContextRetrievalService: ContextRetrievalService {
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
