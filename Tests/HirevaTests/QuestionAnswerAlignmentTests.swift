import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
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
    func securityMonitoringImprovementPlanPassesAlignmentAndGrounding() {
        let question = "What would your first 30 days of security monitoring improvement look like?"
        let answer = "I would start by triaging synthetic endpoint and identity alerts using documented severity and escalation criteria to identify credible indicators across endpoint, identity, and cloud sources. My first priority is to validate security controls and identify repeatable improvements after these incidents, leveraging my experience in incident triage and access review. Success would be validated by successfully investigating credible indicators and implementing improvements that reduce residual incident risk."
        let candidateEvidence = [
            ProfileEvidence(
                id: "monitoring-skill",
                statement: "Security monitoring, incident triage, vulnerability assessment, Python, SQL, access review, and audit documentation.",
                sourceDocumentID: "synthetic-resume",
                sourceChunkID: "monitoring-skill-chunk",
                sourceSpan: nil,
                confidence: 1,
                evidenceType: .skill,
                explicitness: .explicit
            ),
            ProfileEvidence(
                id: "alert-triage-experience",
                statement: "Triaged synthetic endpoint and identity alerts using documented severity and escalation criteria.",
                sourceDocumentID: "synthetic-resume",
                sourceChunkID: "alert-triage-chunk",
                sourceSpan: nil,
                confidence: 1,
                evidenceType: .experience,
                explicitness: .explicit
            )
        ]

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )
        let grounding = AnswerClaimValidator().validate(
            answer: answer,
            candidateEvidence: candidateEvidence,
            opportunityEvidence: [],
            domainKnowledge: InterviewDomainProfile.profile(for: .cybersecurity).domainKnowledge
        )

        #expect(alignment.verdict == .aligned, "Alignment error: \(alignment.reason)")
        #expect(grounding.unsupportedClaims.isEmpty, "Unsupported claims: \(grounding.unsupportedClaims)")
    }

    @Test
    func improvementPlanAcceptsEstablishDefineAndInvestigateActions() {
        let question = "What would your first 30 days of security monitoring improvement look like?"
        let answer = "I would focus my first 30 days on establishing a baseline of security events across endpoints, identity, and cloud sources to identify credible indicators, leveraging my Python and SQL skills for defensible data analysis. My priority is to define clear monitoring criteria and validation methods for these events, ensuring I can effectively investigate credible threats without inventing specific metrics or tools. Success will be validated by my ability to consistently identify and investigate credible indicators within these defined parameters."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(alignment.questionIntent == .improvementPlan)
        #expect(alignment.verdict == .aligned, "Alignment error: \(alignment.reason)")
        #expect(alignment.matchedThemes.contains("concrete action"))
    }

    @Test
    func reliabilityQuestionAcceptsMonitoringCalibrationAndFeedbackActions() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How would you improve the reliability of queue processing under production load?",
            answerText: "For queue processing, I would add backlog feedback, calibrate retry thresholds, monitor saturation signals, and adjust concurrency before each synthetic load test so recovery remains predictable.",
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
            sayFirst: "For this synthetic candidate, I want to join this team because the role connects with distributed systems and reliability experience, and it aligns with my interest in dependable production services.",
            keyPoints: ["Distributed systems fit", "Dependable deployment", "Engineering growth"],
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
        #expect(card.sayFirst.localizedCaseInsensitiveContains("distributed systems"))

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
        let second = try saveQuestion("What was the hardest technical challenge in your synthetic event-processing project?", sessionID: session.id, repository: appState.suggestionRepository, suffix: "challenge")

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
        #expect(!visible.sayFirst.localizedCaseInsensitiveContains("software systems certificate"))
        #expect(!visible.sayFirst.localizedCaseInsensitiveContains("Example Technical Institute"))
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
            "event-processing": 700_000_000
        ]
        let (appState, _, session) = try makeAppState(client: client)
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 800_000_000

        let first = try saveQuestion("Tell me about yourself", sessionID: session.id, repository: appState.suggestionRepository, suffix: "self")
        let second = try saveQuestion("Walk me through your synthetic event-processing project", sessionID: session.id, repository: appState.suggestionRepository, suffix: "project")
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
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("software systems certificate") != true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("event-processing project") != true)
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
            "How did you handle noisy events or routing errors?",
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
            sayFirst: "The synthetic candidate completed a software systems certificate at Example Technical Institute.",
            keyPoints: ["Synthetic software systems certificate"],
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
            answerText: "For this synthetic candidate, I want to join this team because the role connects distributed systems, reliability, production deployment, and engineering growth."
        )
        #expect(roleAligned.verdict == .aligned)

        let roleMismatched = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Why do you want this role?",
            answerText: "The hardest technical challenge was noisy event input and timing mismatch in the ingestion pipeline."
        )
        #expect(roleMismatched.verdict == .mismatched)

        let candidateQuestionMismatched = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Do you have any questions for us?",
            answerText: "The synthetic candidate completed a software systems certificate at Example Technical Institute, with a computing background."
        )
        #expect(candidateQuestionMismatched.verdict == .mismatched)
    }

    @Test
    func prospectiveTradeoffRecommendationCountsAsAnExplicitDecision() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How would you communicate a reliability trade off when delivery pressure is high?",
            answerText: "I would present the reliability risk and delivery impact clearly, then propose a phased release that balances speed with stability. I would document the decision and recommend prioritizing the safeguards that prevent service interruption."
        )

        #expect(alignment.questionIntent == .technicalTradeoff)
        #expect(alignment.verdict == .aligned)
        #expect(!alignment.missingThemes.contains("decision"))
    }

    @Test
    func newRuntimeQuestionAnswersAlignWithSpecificIntents() {
        let decoder = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your synthetic sequence-model project?",
            answerText: "In the synthetic sequence-model evaluation, diffusion succeeded in seven out of ten sample trials, while autoregressive and flow-matching variants succeeded in one out of ten. The lesson was that architecture choice matters for continuous forecast generation because diffusion outputs were smoother and autoregressive errors accumulated."
        )
        #expect(decoder.verdict == .aligned)
        #expect(decoder.questionIntent == .decoderComparison)
        #expect(decoder.answerIntent == .decoderComparison)

        let perception = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "If your synthetic anomaly detector gives a confident but wrong classification in the sample event pipeline, how would you debug it?",
            answerText: "I would reproduce the exact synthetic events from the anomaly detector, inspect logs, classes, features, and confidence for the wrong classification, then check calibration, schema drift, missing values, input skew, and temporal consistency before adding recovery validation or retraining."
        )
        #expect(perception.verdict == .aligned)
        #expect(perception.questionIntent == .perceptionDebugging)
        #expect(perception.answerIntent == .perceptionDebugging)

        let tradeoff = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What was the biggest technical trade-off you made in your synthetic event-processing project?",
            answerText: "The biggest trade-off was robustness versus latency and complexity. In the synthetic service, I chose practical filtering, recovery, and message-bus coordination first because dependable production execution mattered more than a simpler demo, and I learned to prioritize reliable system behaviour."
        )
        #expect(tradeoff.verdict == .aligned)
        #expect(tradeoff.questionIntent == .technicalTradeoff)
        #expect(tradeoff.answerIntent == .technicalTradeoff)

        let dataset = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How did you adapt archived event records into your deterministic staging simulator?",
            answerText: "I treated the archived event records as synthetic demonstrations, mapped fields and outcomes into the staging simulator format, checked schema and timing consistency, and validated the simulated behaviour before model training or evaluation."
        )
        #expect(dataset.verdict == .aligned)
        #expect(dataset.questionIntent == .datasetAdaptation)
        #expect(dataset.answerIntent == .datasetAdaptation)

        let simToReal = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "How would you diagnose a simulation to production gap if your routing policy works in a deterministic simulator but fails in staging?",
            answerText: "For this synthetic scenario, I would compare simulation and production inputs, output scaling, timing, configuration, and workload dynamics, inspect failure traces and logs, then isolate whether the root cause is input processing, routing, environment mismatch, or distribution shift before retraining."
        )
        #expect(simToReal.verdict == .aligned)
        #expect(simToReal.questionIntent == .simToRealDebugging)
        #expect(simToReal.answerIntent == .simToRealDebugging)

        let projectComparison = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Can you explain the difference between your synthetic sequence-model project and your synthetic event-processing project?",
            answerText: "The synthetic sequence-model project evaluated decoder architectures, while the synthetic event-processing project integrated ingestion, validation, routing, persistence, and recovery in a deployed service. The main difference was model evaluation versus production system integration."
        )
        #expect(projectComparison.verdict == .aligned)
        #expect(projectComparison.questionIntent == .projectComparison)
        #expect(projectComparison.answerIntent == .projectComparison)
    }

    @Test
    func wrongAnswerRejectionCatchesSpecificRuntimeConfusions() {
        let tradeoffWrong = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What was the biggest technical trade-off you made in your synthetic event-processing project?",
            answerText: "For a fictional brochure, I balanced typography against colour contrast and selected the larger type."
        )
        #expect(tradeoffWrong.verdict == .mismatched)
        #expect(tradeoffWrong.missingThemes.contains("question topic"))

        let decoderGeneric = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your synthetic sequence-model project?",
            answerText: "Diffusion is generally smoother than autoregressive methods for sequence prediction because it can be robust."
        )
        #expect(decoderGeneric.verdict == .aligned)

        let incompleteQuestion = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "what did you learn",
            answerText: "I learned that diffusion performed best in the synthetic sequence-model setup."
        )
        #expect(incompleteQuestion.verdict == .mismatched)
        #expect(incompleteQuestion.reason.localizedCaseInsensitiveContains("incomplete question"))
    }

    @Test
    func decoderComparisonAlignmentLeavesFactualSupportToGroundingValidator() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your synthetic sequence-model project?",
            answerText: "In the synthetic sequence-model project, I compared autoregressive, diffusion, and flow-matching decoders and found that diffusion models provided the best trade-off between forecast diversity and smoothness, while flow-matching offered faster sampling with comparable quality."
        )

        #expect(alignment.questionIntent == .decoderComparison)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func systemIntegrationDebuggingAnswerAlignsWithOwnIntent() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "Tell me about a time you had to debug a system integration problem.",
            answerText: "One synthetic system integration issue joined ingestion, validation, routing, and persistence modules that had timing mismatches. I reproduced the failure, checked logs and timestamps, isolated the handoff, added recovery behaviour, and learned that integration reliability matters as much as component accuracy."
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .systemIntegrationDebugging)
        #expect(alignment.answerIntent == .systemIntegrationDebugging)
    }

    @Test
    func noisyAlertRiskQuestionRoutesToErrorHandlingAndAcceptsValidatedMitigation() {
        let question = "Describe a noisy alert problem and how you reduced noise without hiding risk."
        let answer = "I inspected the alert history, measured duplicate phishing alerts, tuned the matching threshold, and validated that critical alerts remained visible while duplicate noise decreased."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(alignment.questionIntent == .errorHandling)
        #expect(alignment.verdict == .aligned, "Alignment error: \(alignment.reason)")
    }

    @Test
    func noisyAlertRiskQuestionAcceptsTuningWithPreservedAuditEvidence() {
        let question = "Describe a noisy alert problem and how you reduced noise without hiding risk."
        let answer = "I reduced phishing-alert review time by 22 percent by tuning duplicate indicators and preserving audit history. I used documented severity criteria so critical risks remained visible."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(alignment.questionIntent == .errorHandling)
        #expect(alignment.verdict == .aligned, "Alignment error: \(alignment.reason)")
    }

    @Test
    func inputValidationOutputHandoffRequiresSnapshotBoundFallback() {
        let question = "How did input validation influence pipeline output, and why was that handoff difficult to make reliable?"
        #expect(IntentRouter.answerIntent(for: question) == .systemIntegrationDebugging)

        let detectedQuestion = DetectedQuestion(
            id: "input-validation-output-handoff",
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
            answerText: "I would ask what success would look like in the first three months, what deployment challenges the synthetic team is facing, how the team is structured across service and platform groups, what data or staging infrastructure is used, and how much ownership I would have over production workflows."
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
    func eventProcessingImprovementRejectsWrongProjectRerankerGrounding() {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "If you had one more month to improve your synthetic event-processing service, what would you improve first?",
            answerText: "My first priority would be to validate colour contrast and document the results for a fictional brochure layout."
        )

        #expect(alignment.questionIntent == .improvementPlan)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.reason.localizedCaseInsensitiveContains("missing"))
    }

    @Test
    func firstThirtyDaysImprovementQuestionUsesPlanIntentAndAcceptsFutureActions() {
        let question = "What would your first 30 days of security monitoring improvement look like?"
        let answer = "I would make security monitoring improvement my first priority by reviewing alert quality and validating control gaps. I would measure success through timely investigation, preserved evidence, reduced repeat risk, and proportionate escalation."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(IntentRouter.answerIntent(for: question) == .improvementPlan)
        #expect(alignment.questionIntent == .improvementPlan)
        #expect(alignment.verdict == .aligned, "Alignment error: \(alignment.reason)")
    }

    @Test
    func syntheticProjectQuestionCanonicalizesAndAlignsAsProjectComparison() {
        let question = "Can you explain the difference between your synthetic sequence-model project and your synthetic event-processing project"
        let answer = "The synthetic sequence-model project evaluated decoder architectures using generated records, while the synthetic event-processing project integrated ingestion, validation, routing, persistence, and recovery. The difference is model research in a simulator versus deployed software system integration."
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
            "Built a synthetic event-processing project using ingestion, routing, and persistence components",
            "Debugged a synthetic integration issue involving noisy events, routing state, and timing",
            "Compared autoregressive, diffusion, and flow-matching approaches in a simulation evaluation",
            "Used Python and a message-bus framework in synthetic coursework",
            "Improved evaluation by testing more failure cases and recovery behavior"
            ,"The synthetic candidate completed a software systems certificate at Example Technical Institute, with a computing background and a focus on distributed services and reliability"
            ,"The hardest technical challenge was integrating modules in a production-like service, where noisy events, routing instability, and timing mismatch made execution unpredictable"
            ,"The synthetic event-processing project used a message bus, validation, routing, persistence, and recovery"
            ,"The synthetic candidate handled noisy events by filtering repeated observations, using stability thresholds, and adding recovery behaviour such as retrying or quarantining records"
            ,"The diffusion decoder performed better because it produced smoother forecasts for continuous distributions and was more robust, succeeding in seven out of ten synthetic trials"
            ,"The synthetic candidate is comfortable with Python and SQL from service projects and is improving C++ for performance-critical systems"
            ,"I built a platform project that connected API processing, data storage, and recovery, then validated latency and failure handling"
            ,"In the synthetic event-processing project, the hardest technical challenge was integrating modules in a production-like service, where noisy events, routing instability, and timing mismatch made execution unpredictable"
            ,"In the synthetic event-processing project, the hardest technical challenge was integrating modules in a production-like service. The candidate isolated timing mismatches with logs, then added validation checks at each handoff"
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
        if lower.contains("project") || lower.contains("event-processing") {
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
            return "The synthetic candidate completed a software systems certificate at Example Technical Institute, with a computing background and a focus on distributed services and reliability."
        }
        if lower.contains("hardest technical challenge") {
            return "In the synthetic event-processing project, the hardest technical challenge was integrating modules in a production-like service. The candidate isolated timing mismatches with logs, then added validation checks at each handoff."
        }
        if lower.contains("platform project") {
            return "I built a platform project that connected API processing, data storage, and recovery, then validated latency and failure handling."
        }
        if lower.contains("event-processing") || lower.contains("walk me through") {
            return "The synthetic event-processing project used a message bus, validation, routing, persistence, and recovery."
        }
        if lower.contains("noisy events") || lower.contains("routing errors") {
            return "The synthetic candidate handled noisy events by filtering repeated observations, using stability thresholds, and adding recovery behaviour such as retrying or quarantining records."
        }
        if lower.contains("diffusion") {
            return "The diffusion decoder performed better because it produced smoother forecasts for continuous distributions and was more robust, succeeding in seven out of ten synthetic trials."
        }
        if lower.contains("another month") || lower.contains("change first") {
            return "The synthetic candidate would improve the evaluation pipeline first, testing more event types, initial states, failure cases, input robustness, schema validation, and recovery prioritisation."
        }
        if lower.contains("join our team") || lower.contains("want this role") || lower.contains("want to join") {
            return "For this synthetic candidate, I want this role because it connects distributed systems and reliability experience with this team's production deployment responsibilities and my engineering growth goals."
        }
        if lower.contains("python") || lower.contains("sql") || lower.contains("c++") {
            return "The synthetic candidate is comfortable with Python and SQL from service projects and is improving C++ for performance-critical systems."
        }
        if lower.contains("questions for us") || lower.contains("questions for you") {
            return "The synthetic candidate would ask what success looks like in the first three months, what deployment challenges the team is facing, how the team is structured across service and platform groups, and how much ownership the role has over production workflows."
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
