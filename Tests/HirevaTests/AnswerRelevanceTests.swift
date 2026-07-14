import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct AnswerRelevanceTests {
    @Test
    func promptsPutFrozenQuestionBeforeContextForAllInterviewQuestions() {
        for fixture in Self.fixtures {
            let question = makeQuestion(fixture.question)
            let context = misleadingContext()
            let snapshot = AnswerRelevancePolicy.promptSnapshot(
                question: question,
                context: context,
                transcriptContext: "Interviewer: previous unrelated question about background.",
                cvSummary: "Candidate has platform delivery and model evaluation experience.",
                jdSummary: "Engineering team building reliable production systems.",
                stage: .firstAnswer
            )

            #expect(snapshot.questionTextSnapshot == fixture.question)
            #expect(snapshot.questionIntent == fixture.intent)
            #expect(snapshot.prompt.hasPrefix("""
            CURRENT QUESTION TO ANSWER:
            "\(fixture.question)"
            """))
            #expect(snapshot.prompt.range(of: "CURRENT QUESTION TO ANSWER:")!.lowerBound < snapshot.prompt.range(of: "RELEVANT CONTEXT:")!.lowerBound)
            #expect(snapshot.prompt.contains("Answer this exact question directly in first person."))
            #expect(snapshot.prompt.contains(fixture.intent.rawValue))
        }
    }

    @Test
    func ungroundedLegacyFallbacksStayEmptyForSpecificInterviewIntents() {
        for fixture in Self.fixtures {
            let question = makeQuestion(fixture.question)
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)

            #expect(fallback.sayFirst.isEmpty)
            #expect(fallback.keyPoints.isEmpty)
        }
    }

    @Test
    func supportedFixtureAnswersRemainAlignedForSpecificInterviewIntents() {
        for fixture in Self.fixtures {
            let combined = fixture.answer
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: fixture.question,
                answerText: combined,
                sayFirst: combined,
                stageBCompleted: true
            )

            #expect(alignment.verdict == .aligned, "\(alignment.reason) for \(fixture.question)")
            for expected in fixture.mustContain {
                #expect(combined.localizedCaseInsensitiveContains(expected))
            }
        }
    }

    @Test
    func runtimeASRVariantsRouteToSpecificAnswerIntents() {
        #expect(AnswerRelevancePolicy.intent(
            for: "Why might a diffusion based policy be more stable than an auto regressive policy?"
        ) == .modelComparison)
        #expect(AnswerRelevancePolicy.intent(
            for: "Could you explain your migration project from end-to-end?"
        ) == .projectWalkthrough)
        #expect(AnswerRelevancePolicy.intent(
            for: "When production execution started, which part of the pipeline was most fragile?"
        ) == .technicalChallenge)
    }

    @Test
    func profileIndependentInterviewerQuestionFallbackDoesNotRequireCandidateFacts() {
        let snapshotID = "profile-independent-snapshot"
        let result = DynamicInterviewContextEngine().profileSafeFallback(
            question: "What would you ask the engineering team to decide whether the role is a good fit?",
            domainProfile: InterviewDomainProfile.profile(for: .general),
            candidateProfile: nil,
            opportunityContext: nil,
            contextSnapshotID: snapshotID
        )
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: "What would you ask the engineering team to decide whether the role is a good fit?",
            answerText: result.answer,
            sayFirst: result.answer,
            stageBCompleted: true
        )

        #expect(result.status == GroundedAnswerStatus.grounded)
        #expect(result.contextSnapshotID == snapshotID)
        #expect(result.candidateEvidenceIDs.isEmpty)
        #expect(result.unsupportedClaims.isEmpty)
        #expect(result.answer.filter { $0 == "?" }.count == 3)
        #expect(alignment.verdict == AnswerAlignmentVerdict.aligned)
    }

    @Test
    func intentFilteringKeepsRAGSubordinateToQuestion() {
        let context = misleadingContext()

        let candidateQuestionContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .candidateQuestions
        )
        #expect(candidateQuestionContext.cvChunks.count == 3)
        #expect(candidateQuestionContext.jobDescriptionChunks.map(\.id) == ["jd-evaluation", "jd-team"])

        let skillContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .skillComfort
        )
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("SQL"))
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("API"))

        let modelContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .modelComparison
        )
        #expect(modelContext.cvChunks.map(\.id) == ["model-comparison"])
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("transformer"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("regression"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("incident") == false)
    }

    @Test
    func semanticGuardRejectsMismatchedProviderAnswerAndPreservesAcceptedCard() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceGuard")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion("Do you have any questions for us?", sessionID: session.id)
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var acceptedCard = SuggestionCard(
            id: "candidate-question-fallback",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Context-grounded provider answer",
            sayFirst: "What does success look like for this team in the first six months?",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.7,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "local",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        acceptedCard.questionText = question.questionText
        #expect(appState.applySuggestionIfAlignedForTesting(acceptedCard, question: question, generationID: nil))

        var wrongProviderCard = acceptedCard
        wrongProviderCard.id = "wrong-provider-card"
        wrongProviderCard.sayFirst = "I have a software engineering background and built the Atlas migration service."
        wrongProviderCard.keyPoints = ["Software engineering", "Atlas migration"]
        wrongProviderCard.providerName = "DeepSeek"
        wrongProviderCard.sayFirstSource = "deepseek_stream"

        #expect(appState.applySuggestionIfAlignedForTesting(wrongProviderCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion?.id == "candidate-question-fallback")
        #expect(appState.currentSuggestion?.sayFirst == acceptedCard.sayFirst)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("using fallback"))
    }

    @Test
    func diffusionAutoregressivePolicyIntentIsModelComparison() {
        let question = "Why did the transformer model perform better than the regression model?"

        #expect(AnswerRelevancePolicy.intent(for: question) == .modelComparison)
    }

    @Test
    func syntheticSystemArchitectureAnswerAlignsWithSystemIntegrationIntent() {
        let questionText = "How did the system architecture connect ingestion to billing output?"

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging)

        let answer = "The system architecture connected ingestion to billing through a queue interface, and I instrumented traces and validation checks to make that output reliable."
        #expect(answer.localizedCaseInsensitiveContains("ingestion"))
        #expect(answer.localizedCaseInsensitiveContains("billing"))
        #expect(answer.localizedCaseInsensitiveContains("interface"))
        #expect(answer.localizedCaseInsensitiveContains("validation"))

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )
        #expect(alignment.verdict == .aligned || alignment.verdict == .weaklyAligned)
    }

    @Test
    func syntheticTechnicalChallengeCardAnswersBothHalvesAndPassesPersistenceGuard() {
        let questionText = "What made production deployment harder than a clean test environment and how did you mitigate those failures?"
        let question = makeQuestion(questionText)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .technicalChallenge)

        let answer = "Production deployment was difficult because traffic variability exposed a latency failure, so I instrumented the service, isolated the bottleneck, and mitigated it with queue backpressure and recovery tests."
        #expect(answer.localizedCaseInsensitiveContains("production"))
        #expect(answer.localizedCaseInsensitiveContains("failure"))
        #expect(answer.localizedCaseInsensitiveContains("mitigated"))
        #expect(answer.localizedCaseInsensitiveContains("recovery"))

        let card = SuggestionCard(
            id: "real-world-difficulty-fallback",
            sessionID: question.sessionID,
            questionID: question.id,
            strategy: "RAG Template Fallback",
            sayFirst: answer,
            keyPoints: ["Traffic variability", "Queue backpressure", "Recovery tests"],
            followUpReady: [],
            confidence: 0.5,
            caution: "Fast fallback shown; DeepSeek failed.",
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "rag-fallback",
            promptVersion: "fallback-v1",
            providerKind: nil,
            providerName: "RAG Template Fallback",
            providerBaseURL: "",
            latencyMS: 0,
            isLocal: true,
            rawJSON: nil,
            createdAt: Date(),
            questionText: questionText,
            questionIntent: .technicalChallenge,
            promptQuestionText: questionText,
            promptPrimaryQuestion: questionText,
            sayFirstSource: "rag_template_fallback",
            stageATimedOut: true,
            stageBCompleted: false,
            stageBStatus: "timed_out",
            finalVisibleSource: "rag_template_fallback"
        )

        let result = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card)
        #expect(result.accepted)
    }

    @Test
    func realWorldExecutionQuestionRejectsSimulationOnlyAnswerWithoutRealRobotGrounding() {
        let questionText = "What made production deployment harder than a clean test environment?"
        let providerAnswer = """
        The test harness was deterministic, so I changed its mock configuration and reran the isolated unit checks successfully.
        """

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: providerAnswer,
            sayFirst: providerAnswer,
            stageBCompleted: true
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.missingThemes.contains("challenge"))
    }

    @Test
    func semanticGuardPreservesAlignedProviderPreviewWhenFinalProviderCardMismatches() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "RealWorldPreviewFallback")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "What made production deployment harder than a clean test environment?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerPreview = SuggestionCard(
            id: "provider-preview",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek preview",
            sayFirst: "Production deployment was difficult because traffic variability exposed a latency failure, so I instrumented the service and added recovery tests.",
            keyPoints: ["Traffic variability", "Latency failure", "Recovery tests"],
            followUpReady: [],
            confidence: 0.7,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        providerPreview.questionText = question.questionText
        providerPreview.promptPrimaryQuestion = question.questionText
        providerPreview.stageBCompleted = true
        providerPreview.finalVisibleSource = "deepseek_stream"
        appState.currentSuggestion = providerPreview

        var finalProviderCard = providerPreview
        finalProviderCard.id = "provider-final"
        finalProviderCard.sayFirst = "The test harness was deterministic, so I changed its mock configuration and reran isolated unit checks."
        finalProviderCard.keyPoints = ["Mock configuration", "Unit checks"]

        #expect(appState.applySuggestionIfAlignedForTesting(finalProviderCard, question: question, generationID: nil) == false)
        let preserved = try #require(appState.currentSuggestion)
        #expect(preserved.id == "provider-preview")
        #expect(preserved.finalVisibleSource == "deepseek_stream")
        #expect(preserved.sayFirst.localizedCaseInsensitiveContains("production"))
        #expect(appState.lastAlignmentError.isEmpty == false)
    }

    @Test
    func projectComparisonRejectsSayFirstWithoutConcreteVisibleContrast() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ProjectComparisonSayFirst")
        let appState = AppState(database: database)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Can you explain the difference between the Atlas project and the Beacon project?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerCard = SuggestionCard(
            id: "project-comparison-provider",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek",
            sayFirst: "Atlas and Beacon were useful engineering efforts.",
            keyPoints: [
                "Atlas involved historical records.",
                "Beacon involved live events."
            ],
            followUpReady: [],
            confidence: 0.8,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        providerCard.questionText = question.questionText
        providerCard.promptPrimaryQuestion = question.questionText
        providerCard.stageBCompleted = true
        providerCard.finalVisibleSource = "deepseek_stream"

        #expect(appState.applySuggestionIfAlignedForTesting(providerCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("no displayable fallback"))
    }

    @Test
    func modelComparisonRejectsGenericVisibleSayFirstEvenWhenKeyPointsMatch() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceGenericSayFirst")
        let appState = AppState(database: database)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Why did the transformer model perform better than the regression model?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var genericSayFirstCard = SuggestionCard(
            id: "generic-diffusion-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Model comparison",
            sayFirst: "I generally work with predictive models.",
            keyPoints: [
                "Transformer and regression were evaluated later.",
                "The full results include latency and accuracy."
            ],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        genericSayFirstCard.questionText = question.questionText
        genericSayFirstCard.sayFirstSource = "deepseek_section_stream"
        genericSayFirstCard.stageBCompleted = false

        #expect(appState.applySuggestionIfAlignedForTesting(genericSayFirstCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("no displayable fallback"))
    }

    @Test
    func syntheticModelComparisonAnswerExplainsSequenceContextAndErrorAccumulation() {
        let question = makeQuestion("Why did the transformer model perform better than the regression model?")
        let answer = "The transformer performed better than regression because it represented long-range sequence dependencies, while regression was faster but accumulated prediction error over time."

        #expect(answer.localizedCaseInsensitiveContains("transformer"))
        #expect(answer.localizedCaseInsensitiveContains("regression"))
        #expect(answer.localizedCaseInsensitiveContains("sequence"))
        #expect(answer.localizedCaseInsensitiveContains("error"))
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: answer).verdict == .aligned)
    }

    @Test
    func syntheticDecoderComparisonAnswerContrastsAllAlternatives() {
        let question = makeQuestion("What did you learn from comparing classifier, regression, and transformer alternatives?")
        let combined = "I compared classifier, regression, and transformer alternatives: the classifier was simplest, regression was fastest, while the transformer handled sequence context best."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .decoderComparison)
        #expect(combined.localizedCaseInsensitiveContains("classifier"))
        #expect(combined.localizedCaseInsensitiveContains("regression"))
        #expect(combined.localizedCaseInsensitiveContains("transformer"))
        #expect(combined.localizedCaseInsensitiveContains("simplest"))
        #expect(combined.localizedCaseInsensitiveContains("fastest"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func syntheticPerceptionDebuggingAnswerContainsConcreteSteps() {
        let question = makeQuestion("If the inspection detector gives a confident but wrong prediction, how would you debug it?")
        let combined = "I would reproduce the detector prediction, inspect traces and labels, isolate preprocessing errors, fix the input guard, and validate it with a regression test."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .perceptionDebugging)
        #expect(combined.localizedCaseInsensitiveContains("detector"))
        #expect(combined.localizedCaseInsensitiveContains("traces"))
        #expect(combined.localizedCaseInsensitiveContains("labels"))
        #expect(combined.localizedCaseInsensitiveContains("preprocessing"))
        #expect(combined.localizedCaseInsensitiveContains("validate"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func syntheticTechnicalTradeoffAnswerMakesAConcreteChoice() {
        let question = makeQuestion("What was the biggest technical trade-off you made between latency and accuracy?")
        let combined = "I balanced latency versus accuracy and chose the smaller model because it met the quality threshold while reducing response time and operational complexity."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .technicalTradeoff)
        #expect(combined.localizedCaseInsensitiveContains("balanced"))
        #expect(combined.localizedCaseInsensitiveContains("latency"))
        #expect(combined.localizedCaseInsensitiveContains("complexity"))
        #expect(combined.localizedCaseInsensitiveContains("chose"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func syntheticSystemIntegrationAnswerIsSpecificAndDiagnostic() {
        let question = makeQuestion("Tell me about a time you had to debug a system integration problem.")
        let combined = "The system integration failed at the payments interface, so I inspected logs and timestamps, isolated a schema mismatch, and added contract validation and recovery tests; the lesson was to verify every boundary."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("payments"))
        #expect(combined.localizedCaseInsensitiveContains("interface"))
        #expect(combined.localizedCaseInsensitiveContains("logs"))
        #expect(combined.localizedCaseInsensitiveContains("timestamps"))
        #expect(combined.localizedCaseInsensitiveContains("recovery"))
        #expect(combined.localizedCaseInsensitiveContains("lesson"))
        #expect(alignment.verdict == .aligned)
        #expect(alignment.answerIntent == .systemIntegrationDebugging)
    }

    @Test
    func syntheticDebuggingLessonIsSpecificNotGenericCoaching() {
        let question = makeQuestion("What was the most important lesson you learned from debugging the production system?")
        let combined = "Debugging the production system taught me to instrument every integration boundary, correlate logs and timestamps, isolate failures, and validate recovery with fault-injection tests."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .technicalChallenge)
        #expect(combined.localizedCaseInsensitiveContains("debugging") || combined.localizedCaseInsensitiveContains("debug"))
        #expect(combined.localizedCaseInsensitiveContains("production system"))
        #expect(combined.localizedCaseInsensitiveContains("integration") || combined.localizedCaseInsensitiveContains("handoff"))
        #expect(combined.localizedCaseInsensitiveContains("logs"))
        #expect(combined.localizedCaseInsensitiveContains("timestamps"))
        #expect(combined.localizedCaseInsensitiveContains("recovery") || combined.localizedCaseInsensitiveContains("validation"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Direct answer first") == false)
        #expect(combined.localizedCaseInsensitiveContains("Concrete example from experience") == false)
        #expect(combined.localizedCaseInsensitiveContains("Outcome or lesson learned") == false)
        #expect(alignment.verdict == .aligned)
        #expect(alignment.answerIntent == .technicalChallenge)
    }

    @Test
    func incidentTriageReflectionDoesNotRequireAnUnrelatedSystemBoundary() {
        let questionText = "What did real incident triage teach you about priority teasing endpoint and identity alerts?"
        let answer = "Incident triage taught me to prioritise endpoint and identity alerts using documented severity and escalation criteria, while preserving audit history and checking that critical alerts remained visible."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .generic)
        #expect(alignment.verdict == .aligned, "\(alignment.reason)")
        #expect(!alignment.missingThemes.contains("system boundary"))
    }

    @Test
    func systemIntegrationIntentFamiliesHandleUnseenParaphrasesWithoutGenericCoaching() {
        let cases: [(String, String, [String])] = [
            (
                "How did event input become a control action in your billing pipeline?",
                "Event input became a billing control action through a validated pipeline interface, and I added monitoring and recovery checks.",
                ["event input", "billing", "interface", "recovery"]
            ),
            (
                "How did detection output turn into a physical sorting action?",
                "Detection output set the sorting target, then the control system validated state and used a retry guard before the physical action.",
                ["detection", "sorting", "control", "retry"]
            ),
            (
                "Can you walk me through the pipeline from anomaly detection to incident action?",
                "The pipeline passed anomaly detection into an incident-action interface, where I validated severity, monitored state, and added recovery tests.",
                ["pipeline", "detection", "interface", "recovery"]
            ),
            (
                "How did the perception module influence the sorting system's next physical action?",
                "The perception module set the sorting target, and I validated the control handoff with confidence checks, monitoring, and a retry action.",
                ["perception", "sorting", "control", "retry"]
            ),
            (
                "Before the billing system acted, what state did it need to check?",
                "Before the billing system acted, it checked account state and invoice data, validated the input, and guarded execution with an idempotency key.",
                ["billing", "account state", "invoice", "validated"]
            ),
            (
                "What information did the system require before it executed a payment action?",
                "The system required an account identifier, invoice state, authorization, and a validated idempotency key before it executed the payment action.",
                ["account", "invoice", "authorization", "validated"]
            ),
            (
                "What did debugging a failed pipeline handoff teach you about integration assumptions?",
                "Debugging the failed pipeline handoff taught me to instrument integration boundaries, correlate logs and timestamps, isolate failures, and verify recovery tests.",
                ["pipeline", "integration", "logs", "recovery"]
            ),
            (
                "What happened when a wrong event crossed the pipeline into an action?",
                "A wrong event crossed the pipeline interface into an action, so I traced the input, added validation thresholds, and introduced a recovery guard.",
                ["wrong event", "pipeline", "validation", "recovery"]
            )
        ]

        for (text, combined, expectedTerms) in cases {
            let question = makeQuestion(text)
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: question.questionText,
                answerText: combined,
                sayFirst: combined
            )

            #expect(AnswerRelevancePolicy.intent(for: text) == .systemIntegrationDebugging, "intent for \(text)")
            #expect(alignment.verdict == .aligned, "alignment for \(text): \(alignment.reason)")
            #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(combined), "generic fallback for \(text)")
            for term in expectedTerms {
                #expect(combined.localizedCaseInsensitiveContains(term), "missing \(term) for \(text)")
            }
        }
    }

    @Test
    func realWorldExecutionIntentFamilyHandlesParaphrases() {
        let cases = [
            "Why was production deployment unreliable compared with simulation?",
            "What made real-world operation difficult compared with a clean demo?",
            "How did timing and traffic variability make real-world deployment unreliable?"
        ]

        for text in cases {
            let combined = "Compared with simulation or a clean demo, real-world production execution was difficult because noisy input and timing exposed a latency failure, so I instrumented the service, isolated it, and mitigated it with recovery tests."
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: text,
                answerText: combined,
                sayFirst: combined
            )

            #expect(AnswerRelevancePolicy.intent(for: text) == .technicalChallenge, "intent for \(text)")
            #expect(combined.localizedCaseInsensitiveContains("real-world") || combined.localizedCaseInsensitiveContains("real world"))
            #expect(combined.localizedCaseInsensitiveContains("simulation") || combined.localizedCaseInsensitiveContains("demo"))
            #expect(alignment.verdict == .aligned, "alignment for \(text): \(alignment.reason)")
            #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(combined))
        }
    }

    @Test
    func syntheticVisualDetectionToPhysicalActionAnswerIsSpecificNotGenericCoaching() {
        let question = makeQuestion("Can you explain how visual detection transformed into a physical sorting action")
        let combined = "Visual detection produced a target state for the sorting system; I validated the control handoff, monitored confidence, and added a retry guard before each physical action."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("visual") || combined.localizedCaseInsensitiveContains("detection"))
        #expect(combined.localizedCaseInsensitiveContains("target state"))
        #expect(combined.localizedCaseInsensitiveContains("sorting"))
        #expect(combined.localizedCaseInsensitiveContains("control"))
        #expect(combined.localizedCaseInsensitiveContains("recovery") || combined.localizedCaseInsensitiveContains("retry"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Direct answer first") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func visualDetectionActionRejectsDebuggingReflectionSayFirstEvenWithRelevantKeyPoints() {
        let questionText = "Can you explain how visual detection transformed into a physical sorting action"
        let wrongSayFirst = "A strong answer should connect it to your background and use the STAR method."
        let relevantKeyPoints = [
            "Visual detections were converted into a sorting target.",
            "The control system used the target to select a physical action.",
            "Validation and recovery depended on current state and retry behaviour."
        ]
        let combined = ([wrongSayFirst] + relevantKeyPoints).joined(separator: " ")

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: combined,
            sayFirst: wrongSayFirst
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("a strong answer"))
        #expect(alignment.reason.localizedCaseInsensitiveContains("generic coaching"))
    }

    @Test
    func syntheticSystemDecisionInformationAnswerIsSpecificNotGenericCoaching() {
        let question = makeQuestion("What information did the system need before it could execute the billing action")
        let combined = "Before the billing action, the system checked account identity, invoice state, authorization, and execution feasibility, then validated the input and guarded the action with an idempotency key."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("account identity"))
        #expect(combined.localizedCaseInsensitiveContains("invoice state"))
        #expect(combined.localizedCaseInsensitiveContains("authorization"))
        #expect(combined.localizedCaseInsensitiveContains("feasibility"))
        #expect(combined.localizedCaseInsensitiveContains("validated"))
        #expect(combined.localizedCaseInsensitiveContains("billing"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Concrete example from experience") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func genericCoachingTemplateIsRejectedForVisualActionQuestions() {
        let questionText = "Can you explain how your robot transformed visual detections into physical actions in the real world"
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned. Direct answer first. Concrete example from experience. Outcome or lesson learned."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: questionText, answerText: generic, sayFirst: generic)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("connect it to"))
    }

    @Test
    func syntheticInputControlReliabilityAnswerIsSpecificNotGenericCoaching() {
        let question = makeQuestion("How did you combine event input and control output, and why was that handoff difficult to make reliable")
        let combined = "Event input set the control target, but stale state made the handoff unreliable, so I instrumented timestamps, measured latency, and validated output checks."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("event input"))
        #expect(combined.localizedCaseInsensitiveContains("control"))
        #expect(combined.localizedCaseInsensitiveContains("target"))
        #expect(combined.localizedCaseInsensitiveContains("latency") || combined.localizedCaseInsensitiveContains("calibration") || combined.localizedCaseInsensitiveContains("timing"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Outcome or lesson learned") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func genericCoachingTemplateIsRejectedForPerceptionControlReliabilityQuestion() {
        let questionText = "How did you combine perception and control, and why was that connection difficult to make reliable"
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned. Direct answer first. Concrete example from experience. Outcome or lesson learned."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: questionText, answerText: generic, sayFirst: generic)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("connect it to"))
    }

    @Test
    func genericCoachingTemplateIsRejectedForRealRobotDebuggingLessonQuestion() {
        let questionText = "What was the most important lesson you learned from debugging the production system?"
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned. Direct answer first. Concrete example from experience. Outcome or lesson learned."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: questionText, answerText: generic, sayFirst: generic)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .technicalChallenge)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("connect it to"))
    }

    @Test
    func genericCoachingTemplateIsRejectedAcrossIntentFamilies() {
        let questions = [
            "How did the perception module influence the robot's next physical action?",
            "Before the robot moved, what state did it need to estimate?",
            "Why was deployment on physical hardware less predictable than simulation?",
            "What did debugging the robot teach you about assumptions in simulation?",
            "Can you describe your approach to collaboration in projects?"
        ]
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned. Direct answer first. Concrete example from experience. Outcome or lesson learned."

        for questionText in questions {
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: questionText,
                answerText: generic,
                sayFirst: generic
            )

            #expect(alignment.verdict == .mismatched, "generic template accepted for \(questionText)")
            #expect(alignment.wrongAnswerIndicators.contains("connect it to"))
        }
    }

    @Test
    func emptyThemeProfileUsesGenericQualitySafeguardsInsteadOfFailingZeroOfZero() {
        let questionText = "What principles guide your engineering decisions?"
        let concreteAnswer = "I prioritize measurable user impact, reversible decisions, and explicit validation before broad rollout."
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned."

        let concreteAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: concreteAnswer,
            sayFirst: concreteAnswer
        )
        let genericAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: generic,
            sayFirst: generic
        )

        #expect(concreteAlignment.verdict == .aligned)
        #expect(concreteAlignment.reason.localizedCaseInsensitiveContains("expected response structure"))
        #expect(genericAlignment.verdict == .mismatched)
        #expect(genericAlignment.wrongAnswerIndicators.contains("connect it to"))
    }

    @Test
    func genericFallbackIsEmptyPlaceholderNotSuccessfulCoachingContent() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "GenericFallbackRejected")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion("How do you approach collaboration with colleagues?", sessionID: session.id)
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .generic)
        #expect(fallback.sayFirst.isEmpty)
        #expect(fallback.keyPoints.isEmpty)

        var providerCard = SuggestionCard(
            id: "generic-provider-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek",
            sayFirst: "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned.",
            keyPoints: ["Direct answer first.", "Concrete example from experience.", "Outcome or lesson learned."],
            followUpReady: [],
            confidence: 0.7,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        providerCard.questionText = question.questionText
        providerCard.promptPrimaryQuestion = question.questionText
        providerCard.stageBCompleted = true

        #expect(appState.applySuggestionIfAlignedForTesting(providerCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.visibleAssistantRenderState.hasAnswerText == false)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("generic coaching") ||
            appState.lastAlignmentError.localizedCaseInsensitiveContains("Semantic fallback did not align"))
    }

    @Test
    func syntheticInterviewerQuestionsAnswerOutputsActualQuestions() {
        let question = makeQuestion("What questions would you ask us about the team or the role before accepting an offer?")
        let combined = "How is success measured in the first six months? Which deployment constraints shape the workflow? Who owns production incidents across the team?"
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .interviewerQuestions)
        #expect(combined.localizedCaseInsensitiveContains("Yes, I’d love") == false)
        #expect(combined.localizedCaseInsensitiveContains("success"))
        #expect(combined.localizedCaseInsensitiveContains("deployment"))
        #expect(combined.localizedCaseInsensitiveContains("team"))
        #expect(combined.localizedCaseInsensitiveContains("owns"))
        #expect(combined.filter { $0 == "?" }.count >= 3)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func interviewerQuestionsRejectsOneVagueQuestionWhenNoGroundedFallbackExists() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "InterviewerQuestionQuality")
        let appState = AppState(database: database)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "What would you ask the engineering team to understand whether this role is a good fit?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var card = SuggestionCard(
            id: "single-interviewer-question",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Provider answer",
            sayFirst: "I'd ask what success looks like for real-world deployment given the team's ownership structure.",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        card.questionText = question.questionText
        card.promptPrimaryQuestion = question.questionText
        card.stageBCompleted = true

        #expect(appState.applySuggestionIfAlignedForTesting(card, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("no displayable fallback"))
    }

    @Test
    func engineeringTeamFitQuestionRequiresWorkflowOrInfrastructureCoverage() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "TeamFitQuestionQuality")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "What would you ask the engineering team to understand whether this platform role is a good fit?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerCard = SuggestionCard(
            id: "team-fit-provider-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek",
            sayFirst: "How is success measured in the first three months? Which infrastructure constraints shape the delivery workflow? Who owns production incidents across the engineering team?",
            keyPoints: ["First three month success", "Infrastructure constraints", "Team ownership", "Delivery workflow"],
            followUpReady: [],
            confidence: 0.8,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        providerCard.questionText = question.questionText
        providerCard.promptPrimaryQuestion = question.questionText
        providerCard.stageBCompleted = true
        providerCard.finalVisibleSource = "deepseek_stream"

        #expect(appState.applySuggestionIfAlignedForTesting(providerCard, question: question, generationID: nil))
        let accepted = try #require(appState.currentSuggestion)
        #expect(accepted.finalVisibleSource == "deepseek_stream")
        #expect(accepted.sayFirst.localizedCaseInsensitiveContains("workflow"))
        #expect(accepted.alignmentVerdict == .aligned)
    }

    @Test
    func syntheticAtlasImprovementAnswerAvoidsUnrelatedProjectGrounding() {
        let question = makeQuestion("If you had one more month to improve the Atlas system, what would you improve first?")
        let combined = "My first priority for the Atlas system would be to add failure-case tests, instrument latency, evaluate data consistency, and validate the improvement against a production baseline."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined, sayFirst: combined)

        #expect(combined.localizedCaseInsensitiveContains("Atlas"))
        #expect(combined.localizedCaseInsensitiveContains("failure-case"))
        #expect(combined.localizedCaseInsensitiveContains("instrument"))
        #expect(combined.localizedCaseInsensitiveContains("latency"))
        #expect(combined.localizedCaseInsensitiveContains("evaluation") || combined.localizedCaseInsensitiveContains("evaluate"))
        #expect(combined.localizedCaseInsensitiveContains("validate"))
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(combined))
        #expect(combined.localizedCaseInsensitiveContains("semantic-geometric") == false)
        #expect(combined.localizedCaseInsensitiveContains("re-ranker") == false)
        #expect(combined.localizedCaseInsensitiveContains("target-conditioned") == false)
        #expect(combined.localizedCaseInsensitiveContains("VLM grasping") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test(arguments: [
        "add confidence and spatial c",
        "I would ask the engineering team how they",
        "onto a production platform—a concrete",
        "I would improve Atlas robustness with better evaluation"
    ])
    func incompleteVisibleAnswersWithoutFinishedSentenceAreRejected(_ answer: String) {
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(answer) == false)
        #expect(QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(answer) != nil)
    }

    @Test
    func syntheticProjectComparisonAnswerContainsConcreteDetailsFromBothProjects() {
        let combined = "The Atlas project migrated historical records, while the Beacon project monitored live events; both required validation but had different latency constraints."

        #expect(combined.localizedCaseInsensitiveContains("Atlas"))
        #expect(combined.localizedCaseInsensitiveContains("historical records"))
        #expect(combined.localizedCaseInsensitiveContains("Beacon"))
        #expect(combined.localizedCaseInsensitiveContains("live events"))
        #expect(combined.localizedCaseInsensitiveContains("while"))
        #expect(combined.localizedCaseInsensitiveContains("different"))
    }

    @Test
    func projectComparisonRejectsVagueSimulationVersusRobotAnswer() {
        let question = "Can you explain the difference between the Atlas project and the Beacon project?"
        let answer = "The Atlas project and the Beacon project were useful engineering efforts."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.missingThemes.contains("explicit contrast"))
    }

    @Test
    func completeVisibleModelComparisonAnswerRemainsAlignedWhenFullCardIsStillExpanding() {
        let question = "Why did the transformer model perform better than the regression model?"
        let sayFirst = "The transformer performed better than regression because it represented long-range sequence dependencies, while regression was faster but lost context."
        let combined = """
        \(sayFirst)
        The transformer improved accuracy on long sequences.
        Regression remained cheaper to operate at low latency.
        """

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: combined,
            sayFirst: sayFirst,
            stageBCompleted: false
        )

        #expect(alignment.verdict == .aligned)
    }

    @Test
    func runtimeDiffusionAnswerWithASRNoisyAutoregressiveWordingStillAligns() {
        let question = "Why did the transformer model perform better than the regression model"
        let sayFirst = "The transformer performed better than regression because it retained long-range context, while regression was faster but accumulated sequence error."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: sayFirst,
            sayFirst: sayFirst,
            stageBCompleted: false
        )

        #expect(alignment.verdict == .aligned)
    }

    @Test
    func runtimeNaturalDiffusionAnswerAlignsWithoutCannedSuccessMetric() {
        let question = "Why did the transformer model perform better than the regression model"
        let sayFirst = "The transformer performed better than regression because it retained sequence context, whereas regression was simpler and faster but lost long-range dependencies."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: sayFirst,
            sayFirst: sayFirst,
            stageBCompleted: false
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.matchedThemes.contains("comparison"))
        #expect(alignment.matchedThemes.contains("compared alternatives"))
    }

    @Test
    func runtimeLeoRoverProjectAnswerAlignsWithProjectWalkthroughQuestion() {
        let question = "could you walk me through your Atlas migration project end-to-end"
        let answer = "In the Atlas migration project, I designed the mapping pipeline, implemented validation checks, and delivered a staged rollout that reduced failed records."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )
        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .projectWalkthrough)
        #expect(alignment.answerIntent == .projectWalkthrough)
    }

    @Test
    func runtimeFragilePipelineAnswerAlignsWithTechnicalChallengeQuestion() {
        let question = "When you moved from clean testing to production execution, which technical constraint was most difficult?"
        let answer = "The hardest production challenge was schema variability and timing mismatch; I instrumented failures, isolated incompatible records, and built a validated normalization step that stabilized the pipeline."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )
        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .technicalChallenge)
        #expect(alignment.answerIntent == .technicalChallenge)
    }

    @Test
    func runtimeDexoryWhyRoleAnswerAlignsWithJoinTeamQuestion() {
        let question = "why do you want to join our team"
        let answer = "I want to join the team because this platform role aligns with my experience building reliable services, and the organisation owns measurable production outcomes."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .whyRole)
        #expect(alignment.answerIntent == .whyRole)
        #expect(alignment.matchedThemes.contains("motivation"))
        #expect(alignment.matchedThemes.contains("target relevance"))
    }

    @Test
    func semanticGuardRejectsIncompleteSayFirstEvenWhenKeyPointsMatch() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceIncomplete")
        let appState = AppState(database: database)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Why did the transformer model perform better than the regression model?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var truncatedCard = SuggestionCard(
            id: "incomplete-model-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Model comparison",
            sayFirst: "The transformer performed better than regression because",
            keyPoints: [
                "The transformer retained long-range sequence context.",
                "Regression was faster but lost context.",
                "The evaluation compared accuracy and latency."
            ],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "deepseek",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        truncatedCard.questionText = question.questionText

        #expect(appState.applySuggestionIfAlignedForTesting(truncatedCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("no displayable fallback"))
    }

    private struct Fixture {
        var question: String
        var intent: AnswerRelevanceIntent
        var answer: String
        var mustContain: [String]
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            question: "Could you tell me a little bit about yourself and what brought you into platform engineering?",
            intent: .tellMeAboutYourself,
            answer: "My background is in software engineering, where I built the Atlas migration service, learned to validate production changes, and now focus on reliable platforms.",
            mustContain: ["background", "Atlas", "reliable"]
        ),
        Fixture(
            question: "Could you walk me through your Atlas migration project?",
            intent: .projectWalkthrough,
            answer: "In the Atlas migration project, I designed the mapping pipeline, implemented validation checks, and delivered a staged rollout that reduced failed records.",
            mustContain: ["Atlas", "implemented", "delivered"]
        ),
        Fixture(
            question: "What was the hardest technical challenge you faced?",
            intent: .technicalChallenge,
            answer: "The hardest challenge was schema variability in production; I instrumented failures, isolated incompatible records, and built a validated normalization step.",
            mustContain: ["challenge", "production", "isolated"]
        ),
        Fixture(
            question: "How did you handle noisy monitoring alerts?",
            intent: .errorHandling,
            answer: "I measured duplicate alerts against a baseline, inspected traces, tuned the severity criteria, and validated that critical incidents remained visible.",
            mustContain: ["duplicate", "traces", "validated"]
        ),
        Fixture(
            question: "Why did the transformer model perform better than the regression model?",
            intent: .modelComparison,
            answer: "The transformer performed better than regression because it represented long-range dependencies, while regression was faster but missed sequence context.",
            mustContain: ["transformer", "regression", "while"]
        ),
        Fixture(
            question: "What did you learn from comparing classifier, regression, and transformer alternatives?",
            intent: .decoderComparison,
            answer: "I compared classifier, regression, and transformer alternatives: the classifier was simplest, regression was fastest, while the transformer handled sequence context best.",
            mustContain: ["classifier", "regression", "transformer"]
        ),
        Fixture(
            question: "If the inspection detector gives a confident but wrong prediction, how would you debug it?",
            intent: .perceptionDebugging,
            answer: "I would reproduce the detector prediction, inspect traces and labels, isolate preprocessing errors, fix the guard, and validate it with a regression test.",
            mustContain: ["detector", "inspect", "validate"]
        ),
        Fixture(
            question: "How did you adapt the legacy event dataset into the new warehouse format?",
            intent: .datasetAdaptation,
            answer: "I mapped and converted the legacy event dataset into normalized warehouse records, then validated row counts and tested representative samples.",
            mustContain: ["mapped", "normalized", "validated"]
        ),
        Fixture(
            question: "How would you diagnose a sim-to-real gap if a policy works in simulation but fails in production?",
            intent: .simToRealDebugging,
            answer: "I would compare simulation with the production environment, isolate configuration and latency differences, calibrate the inputs, and verify each change under deployment traffic.",
            mustContain: ["simulation", "production", "isolate"]
        ),
        Fixture(
            question: "Can you explain the difference between the Atlas project and the Beacon project?",
            intent: .projectComparison,
            answer: "The Atlas project migrated historical records, while the Beacon project monitored live events; both required validation but had different latency constraints.",
            mustContain: ["Atlas", "Beacon", "while"]
        ),
        Fixture(
            question: "What would you change first if you had another month?",
            intent: .improvementPlan,
            answer: "With another month, my first priority would be to add failure-case tests, instrument the highest-risk path, and validate the improvement against a measurable baseline.",
            mustContain: ["first", "tests", "validate"]
        ),
        Fixture(
            question: "What was the biggest technical trade-off you made between latency and accuracy?",
            intent: .technicalTradeoff,
            answer: "I balanced latency versus accuracy and chose the smaller model because it met the quality threshold while reducing response time.",
            mustContain: ["latency", "accuracy", "chose"]
        ),
        Fixture(
            question: "Tell me about a time you had to debug a system integration problem.",
            intent: .systemIntegrationDebugging,
            answer: "The system integration failed at the payments interface, so I inspected logs, isolated a schema mismatch, and added contract validation and recovery tests.",
            mustContain: ["integration", "logs", "validation"]
        ),
        Fixture(
            question: "Can you explain how visual detection transformed into a physical sorting action",
            intent: .systemIntegrationDebugging,
            answer: "Visual detection produced a target state for the sorting system; I validated the control handoff, monitored confidence, and added a retry guard before each physical action.",
            mustContain: ["detection", "control", "retry"]
        ),
        Fixture(
            question: "What information did the system need before it could execute the billing action",
            intent: .systemIntegrationDebugging,
            answer: "Before the billing action, the system checked account state and invoice data, then validated the input and guarded execution with an idempotency key.",
            mustContain: ["account", "invoice", "validated"]
        ),
        Fixture(
            question: "How did you combine event input and control output, and why was that handoff difficult to make reliable",
            intent: .systemIntegrationDebugging,
            answer: "Event input set the control target, but stale state made the handoff unreliable, so I instrumented timestamps, measured latency, and validated output checks.",
            mustContain: ["input", "control", "latency"]
        ),
        Fixture(
            question: "What was the most important lesson you learned from debugging the production system?",
            intent: .technicalChallenge,
            answer: "Debugging the production system taught me to instrument every interface, correlate logs and timestamps, isolate failures, and verify recovery with fault-injection tests.",
            mustContain: ["production", "logs", "recovery"]
        ),
        Fixture(
            question: "Why do you want to join our team?",
            intent: .whyRole,
            answer: "I want to join the team because the role aligns with my platform experience and the organisation owns measurable production outcomes.",
            mustContain: ["role", "team", "production"]
        ),
        Fixture(
            question: "What is your experience with SQL and API tooling?",
            intent: .skillComfort,
            answer: "I am comfortable with SQL and API tooling because I have used both in production, while my experience with advanced query tuning is still developing.",
            mustContain: ["SQL", "API", "used"]
        ),
        Fixture(
            question: "Do you have any questions for us?",
            intent: .candidateQuestions,
            answer: "What does success look like for this team in the first six months?",
            mustContain: ["success", "team", "?"]
        ),
        Fixture(
            question: "What questions would you ask us about the team or the role before accepting an offer?",
            intent: .interviewerQuestions,
            answer: "How is success measured in the first six months? Which constraints shape the delivery workflow? Which role has ownership of production incidents across the team?",
            mustContain: ["success", "constraints", "ownership"]
        )
    ]

    private func makeQuestion(_ text: String, sessionID: String = "answer-relevance-session") -> DetectedQuestion {
        DetectedQuestion(
            id: "answer-relevance-\(UUID().uuidString)",
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: text,
            intent: .unclear,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Answer relevance fixture",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    private func misleadingContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [
                chunk("project", "Implemented the Atlas migration project and delivered a validated rollout.", .cv),
                chunk("incident", "Debugged an Atlas incident, isolated a queue failure, and improved recovery reliability.", .cv),
                chunk("model-comparison", "Compared transformer and regression models using evaluation metrics and documented the trade-off.", .cv),
                chunk("skills", "Used SQL and API tooling in production and documented current skill limits.", .cv),
                chunk("motivation", "My platform experience, project work, skills, and goal align with reliable delivery.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd-evaluation", "The role owns evaluation, performance constraints, and production reliability.", .jobDescription),
                chunk("jd-skills", "Required skill: SQL; preferred experience with API platforms.", .jobDescription),
                chunk("jd-team", "The team defines success, ownership, responsibilities, and operational constraints.", .jobDescription)
            ]
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
