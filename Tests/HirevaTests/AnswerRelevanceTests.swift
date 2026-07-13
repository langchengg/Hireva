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
                cvSummary: "Candidate has MSc Robotics, LeoRover, VLA and ROS2 experience.",
                jdSummary: "Robotics software team building deployed perception systems.",
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
    func intentSpecificFallbacksDirectlyAnswerNineInterviewQuestions() {
        for fixture in Self.fixtures {
            let question = makeQuestion(fixture.question)
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
            let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: fixture.question,
                answerText: combined
            )

            #expect(alignment.verdict == .aligned || alignment.verdict == .weaklyAligned)
            for expected in fixture.mustContain {
                #expect(combined.localizedCaseInsensitiveContains(expected))
            }
        }
    }

    @Test
    func intentFilteringKeepsRAGSubordinateToQuestion() {
        let context = misleadingContext()

        let candidateQuestionContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .candidateQuestions
        )
        #expect(candidateQuestionContext.cvChunks.isEmpty)
        #expect(candidateQuestionContext.promptText.localizedCaseInsensitiveContains("MSc Robotics") == false)

        let skillContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .skillComfort
        )
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("Python"))
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("ROS2"))
        #expect(skillContext.promptText.localizedCaseInsensitiveContains("C++"))

        let modelContext = AnswerRelevancePolicy.filterContext(
            context,
            intent: .modelComparison
        )
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("diffusion"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("autoregressive"))
        #expect(modelContext.promptText.localizedCaseInsensitiveContains("flow-matching"))
    }

    @Test
    func semanticGuardRejectsMismatchedProviderAnswerAndPreservesFallback() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceGuard")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion("Do you have any questions for us?", sessionID: session.id)
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        var fallbackCard = SuggestionCard(
            id: "candidate-question-fallback",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Local intent fallback",
            sayFirst: fallback.sayFirst,
            keyPoints: fallback.keyPoints,
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
        fallbackCard.questionText = question.questionText
        #expect(appState.applySuggestionIfAlignedForTesting(fallbackCard, question: question, generationID: nil))

        var wrongProviderCard = fallbackCard
        wrongProviderCard.id = "wrong-provider-card"
        wrongProviderCard.sayFirst = "I am currently studying MSc Robotics at the University of Manchester, with a computer science background and robotics experience."
        wrongProviderCard.keyPoints = ["MSc Robotics", "Computer science background"]
        wrongProviderCard.providerName = "DeepSeek"
        wrongProviderCard.sayFirstSource = "deepseek_stream"

        #expect(appState.applySuggestionIfAlignedForTesting(wrongProviderCard, question: question, generationID: nil) == false)
        #expect(appState.currentSuggestion?.id == "candidate-question-fallback")
        #expect(appState.currentSuggestion?.sayFirst == fallback.sayFirst)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("using fallback"))
    }

    @Test
    func diffusionAutoregressivePolicyIntentIsModelComparison() {
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"

        #expect(AnswerRelevancePolicy.intent(for: question) == .modelComparison)
    }

    @Test
    func robotSystemArchitectureQuestionUsesSystemIntegrationFallbackAndAlignment() {
        let questionText = "How did your robotics system connect YOLOv8 detection with localization, navigation, manipulation, and recovery behaviors?"
        let question = makeQuestion(questionText)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging)

        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let answer = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        #expect(answer.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(answer.localizedCaseInsensitiveContains("localisation") || answer.localizedCaseInsensitiveContains("localization"))
        #expect(answer.localizedCaseInsensitiveContains("navigation"))
        #expect(answer.localizedCaseInsensitiveContains("manipulation"))
        #expect(answer.localizedCaseInsensitiveContains("recovery"))

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: answer,
            sayFirst: fallback.sayFirst,
            stageBCompleted: true
        )
        #expect(alignment.verdict == .aligned || alignment.verdict == .weaklyAligned)
    }

    @Test
    func realWorldDifficultyMitigationFallbackAnswersBothHalvesAndPersists() {
        let questionText = "What made real-world execution harder than a clean simulation or demo environment and how did you mitigate those issues?"
        let question = makeQuestion(questionText)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .technicalChallenge)

        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let answer = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        #expect(answer.localizedCaseInsensitiveContains("real-world") || answer.localizedCaseInsensitiveContains("real world"))
        #expect(answer.localizedCaseInsensitiveContains("simulation"))
        #expect(answer.localizedCaseInsensitiveContains("mitigated") || answer.localizedCaseInsensitiveContains("mitigation"))
        #expect(answer.localizedCaseInsensitiveContains("recovery"))

        let card = SuggestionCard(
            id: "real-world-difficulty-fallback",
            sessionID: question.sessionID,
            questionID: question.id,
            strategy: "RAG Template Fallback",
            sayFirst: fallback.sayFirst,
            keyPoints: fallback.keyPoints,
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
        let questionText = "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?"
        let providerAnswer = """
        The hard part was that a clean simulation keeps perception, timing, calibration, and module integration much more controlled. In practice, detections were noisy, localisation could drift, and the navigation-to-manipulation handoff needed recovery behaviour when the target pose was uncertain.
        """

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: providerAnswer,
            sayFirst: providerAnswer,
            stageBCompleted: true
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.reason.localizedCaseInsensitiveContains("real-world/physical-robot grounding"))
    }

    @Test
    func semanticGuardReplacesMismatchedExistingProviderPreviewWithFallback() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "RealWorldPreviewFallback")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerPreview = SuggestionCard(
            id: "provider-preview",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek preview",
            sayFirst: "A clean simulation keeps perception, timing, calibration, and module integration more controlled, while detections can be noisy and recovery is needed.",
            keyPoints: ["Noisy detections", "Calibration drift", "Recovery behaviour"],
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

        #expect(appState.applySuggestionIfAlignedForTesting(finalProviderCard, question: question, generationID: nil) == false)
        let fallback = try #require(appState.currentSuggestion)
        #expect(fallback.id != "provider-preview")
        #expect(fallback.finalVisibleSource == "semantic_intent_fallback")
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("real-world") || fallback.sayFirst.localizedCaseInsensitiveContains("real world"))
        #expect(fallback.alignmentVerdict == .aligned)
    }

    @Test
    func projectComparisonRejectsSayFirstWithoutConcreteVisibleContrast() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ProjectComparisonSayFirst")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Can you explain the difference between your VLA project and your LeoRover project?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerCard = SuggestionCard(
            id: "project-comparison-provider",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek",
            sayFirst: "The main difference is that VLA was focused on learned policy evaluation, while LeoRover was a robotics integration project.",
            keyPoints: [
                "VLA used DROID trajectories in a MuJoCo Franka simulation to compare decoders.",
                "LeoRover used ROS2, YOLOv8, localisation, navigation, manipulation, and recovery on a real robot.",
                "The contrast was learning-policy research in simulation versus real-world perception-to-action deployment."
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
        let fallback = try #require(appState.currentSuggestion)
        #expect(fallback.finalVisibleSource == "semantic_intent_fallback")
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("MuJoCo"))
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("LeoRover"))
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("real-robot") || fallback.sayFirst.localizedCaseInsensitiveContains("real robot"))
        #expect(fallback.alignmentVerdict == .aligned)
    }

    @Test
    func modelComparisonRejectsGenericVisibleSayFirstEvenWhenKeyPointsMatch() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceGenericSayFirst")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var genericSayFirstCard = SuggestionCard(
            id: "generic-diffusion-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Model comparison",
            sayFirst: "I generally work with diffusion-based policies.",
            keyPoints: [
                "Autoregressive policies can suffer from error accumulation over time.",
                "Diffusion models refine the full action sequence, producing smoother continuous actions.",
                "That can make diffusion more robust for robotic manipulation."
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
        #expect(appState.currentSuggestion?.sayFirst != "I generally work with diffusion-based policies.")
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("diffusion") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("autoregressive") == true)
        #expect(appState.currentSuggestion?.alignmentVerdict == .aligned)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("using fallback"))
    }

    @Test
    func diffusionModelComparisonFallbackExplainsContinuousActionsAndAutoregressiveErrorAccumulation() {
        let question = makeQuestion("Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")

        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("diffusion"))
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("autoregressive"))
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("denois"))
        #expect(combined.localizedCaseInsensitiveContains("continuous"))
        #expect(combined.localizedCaseInsensitiveContains("trajectory") || combined.localizedCaseInsensitiveContains("sequence"))
        #expect(combined.localizedCaseInsensitiveContains("step by step"))
        #expect(combined.localizedCaseInsensitiveContains("compound"))
        #expect(combined.localizedCaseInsensitiveContains("error"))
        #expect(combined.localizedCaseInsensitiveContains("smoother"))
        #expect(combined.localizedCaseInsensitiveContains("robust"))
        #expect(combined.localizedCaseInsensitiveContains("manipulation"))
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(fallback.sayFirst))
    }

    @Test
    func decoderComparisonFallbackMentionsMuJoCoVLAAndAllDecoderResults() {
        let question = makeQuestion("What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .decoderComparison)
        #expect(combined.localizedCaseInsensitiveContains("MuJoCo"))
        #expect(combined.localizedCaseInsensitiveContains("VLA"))
        #expect(combined.localizedCaseInsensitiveContains("autoregressive"))
        #expect(combined.localizedCaseInsensitiveContains("diffusion"))
        #expect(combined.localizedCaseInsensitiveContains("flow-matching"))
        #expect(combined.localizedCaseInsensitiveContains("7/10"))
        #expect(combined.localizedCaseInsensitiveContains("1/10"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func perceptionDebuggingFallbackMentionsConcreteDebuggingSteps() {
        let question = makeQuestion("If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .perceptionDebugging)
        #expect(combined.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(combined.localizedCaseInsensitiveContains("frames"))
        #expect(combined.localizedCaseInsensitiveContains("logs"))
        #expect(combined.localizedCaseInsensitiveContains("bounding"))
        #expect(combined.localizedCaseInsensitiveContains("confidence"))
        #expect(combined.localizedCaseInsensitiveContains("calibration"))
        #expect(combined.localizedCaseInsensitiveContains("lighting"))
        #expect(combined.localizedCaseInsensitiveContains("occlusion"))
        #expect(combined.localizedCaseInsensitiveContains("retraining"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func technicalTradeoffFallbackIsConcreteRoboticsAnswer() {
        let question = makeQuestion("What was the biggest technical trade-off you made in your robotics projects?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .technicalTradeoff)
        #expect(combined.localizedCaseInsensitiveContains("trade-off"))
        #expect(combined.localizedCaseInsensitiveContains("robustness"))
        #expect(combined.localizedCaseInsensitiveContains("latency"))
        #expect(combined.localizedCaseInsensitiveContains("complexity"))
        #expect(combined.localizedCaseInsensitiveContains("LeoRover"))
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func systemIntegrationDebuggingFallbackIsStarStyleAndLeoRoverSpecific() {
        let question = makeQuestion("Tell me about a time you had to debug a system integration problem.")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("LeoRover"))
        #expect(combined.localizedCaseInsensitiveContains("ROS2"))
        #expect(combined.localizedCaseInsensitiveContains("perception"))
        #expect(combined.localizedCaseInsensitiveContains("navigation"))
        #expect(combined.localizedCaseInsensitiveContains("manipulation"))
        #expect(combined.localizedCaseInsensitiveContains("logs"))
        #expect(combined.localizedCaseInsensitiveContains("timestamps"))
        #expect(combined.localizedCaseInsensitiveContains("recovery"))
        #expect(combined.localizedCaseInsensitiveContains("lesson"))
        #expect(alignment.verdict == .aligned)
        #expect(alignment.answerIntent == .systemIntegrationDebugging)
    }

    @Test
    func realRobotDebuggingLessonFallbackIsSpecificNotGenericCoaching() {
        let question = makeQuestion("What was the most important lesson you learned from debugging the real robot?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("debugging") || combined.localizedCaseInsensitiveContains("debug"))
        #expect(combined.localizedCaseInsensitiveContains("real robot") || combined.localizedCaseInsensitiveContains("LeoRover"))
        #expect(combined.localizedCaseInsensitiveContains("integration") || combined.localizedCaseInsensitiveContains("handoff"))
        #expect(combined.localizedCaseInsensitiveContains("logs"))
        #expect(combined.localizedCaseInsensitiveContains("timestamps"))
        #expect(combined.localizedCaseInsensitiveContains("recovery") || combined.localizedCaseInsensitiveContains("validation"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Direct answer first") == false)
        #expect(combined.localizedCaseInsensitiveContains("Concrete example from experience") == false)
        #expect(combined.localizedCaseInsensitiveContains("Outcome or lesson learned") == false)
        #expect(alignment.verdict == .aligned)
        #expect(alignment.answerIntent == .systemIntegrationDebugging)
    }

    @Test
    func systemIntegrationIntentFamiliesHandleUnseenParaphrasesWithoutGenericCoaching() {
        let cases: [(String, [String])] = [
            (
                "How did perception become robot action in your LeoRover pipeline?",
                ["target pose", "navigation", "manipulation", "recovery"]
            ),
            (
                "How did the detector output turn into movement and grasping?",
                ["target pose", "navigation", "manipulation", "recovery"]
            ),
            (
                "Can you walk me through the pipeline from object detection to manipulation?",
                ["target pose", "navigation", "manipulation", "recovery"]
            ),
            (
                "How did the perception module influence the robot's next physical action?",
                ["target pose", "navigation", "manipulation", "recovery"]
            ),
            (
                "Before the robot moved, what state did it need to estimate?",
                ["object identity", "location", "reachability", "navigation", "grasp"]
            ),
            (
                "How did you know the robot had enough information to attempt a grasp?",
                ["object identity", "location", "reachability", "navigation", "grasp"]
            ),
            (
                "What did debugging the robot teach you about assumptions in simulation?",
                ["debugging", "real robot", "integration", "logs", "timestamps", "recovery"]
            ),
            (
                "What happened when the system made a wrong perception decision?",
                ["wrong perception", "navigation", "manipulation", "validation", "recovery"]
            )
        ]

        for (text, expectedTerms) in cases {
            let question = makeQuestion(text)
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
            let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: question.questionText,
                answerText: combined,
                sayFirst: fallback.sayFirst
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
            "Why was deployment on physical hardware less predictable than simulation?",
            "What made real robot execution fragile compared with a clean demo?",
            "How did calibration, timing, and noisy perception affect real-world execution?"
        ]

        for text in cases {
            let question = makeQuestion(text)
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
            let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: text,
                answerText: combined,
                sayFirst: fallback.sayFirst
            )

            #expect(AnswerRelevancePolicy.intent(for: text) == .technicalChallenge, "intent for \(text)")
            #expect(combined.localizedCaseInsensitiveContains("real-world") || combined.localizedCaseInsensitiveContains("real world"))
            #expect(combined.localizedCaseInsensitiveContains("simulation") || combined.localizedCaseInsensitiveContains("demo"))
            #expect(alignment.verdict == .aligned, "alignment for \(text): \(alignment.reason)")
            #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(combined))
        }
    }

    @Test
    func visualDetectionToPhysicalActionFallbackIsSpecificNotGenericCoaching() {
        let question = makeQuestion("Can you explain how your robot transformed visual detections into physical actions in the real world")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("visual") || combined.localizedCaseInsensitiveContains("detection"))
        #expect(combined.localizedCaseInsensitiveContains("target pose") || combined.localizedCaseInsensitiveContains("object pose"))
        #expect(combined.localizedCaseInsensitiveContains("navigation"))
        #expect(combined.localizedCaseInsensitiveContains("manipulation") || combined.localizedCaseInsensitiveContains("grasp"))
        #expect(combined.localizedCaseInsensitiveContains("recovery") || combined.localizedCaseInsensitiveContains("retry"))
        #expect(combined.localizedCaseInsensitiveContains("I’d answer this directly") == false)
        #expect(combined.localizedCaseInsensitiveContains("Direct answer first") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func visualDetectionActionRejectsDebuggingReflectionSayFirstEvenWithRelevantKeyPoints() {
        let questionText = "Can you explain how your robot transformed visual detections into physical actions in the real world"
        let wrongSayFirst = "The most important lesson I learned from debugging the real robot was that reliability depends on instrumenting every handoff, not just improving one module."
        let relevantKeyPoints = [
            "Object detections were converted into target poses for the robot pipeline.",
            "Localisation and navigation used the target pose to move into a feasible position.",
            "Manipulation and recovery depended on validation, robot state, and retry behaviour."
        ]
        let combined = ([wrongSayFirst] + relevantKeyPoints).joined(separator: " ")

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: combined,
            sayFirst: wrongSayFirst
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("wrong system-integration subfamily"))
        #expect(alignment.reason.localizedCaseInsensitiveContains("system-integration sayFirst"))
    }

    @Test
    func robotDecisionInformationFallbackIsSpecificNotGenericCoaching() {
        let question = makeQuestion("What information did the robot need before it could decide where to move and what to grasp")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("object identity") || combined.localizedCaseInsensitiveContains("target object"))
        #expect(combined.localizedCaseInsensitiveContains("pose") || combined.localizedCaseInsensitiveContains("location") || combined.localizedCaseInsensitiveContains("position"))
        #expect(combined.localizedCaseInsensitiveContains("distance") || combined.localizedCaseInsensitiveContains("spatial"))
        #expect(combined.localizedCaseInsensitiveContains("reachability") || combined.localizedCaseInsensitiveContains("feasible"))
        #expect(combined.localizedCaseInsensitiveContains("navigation"))
        #expect(combined.localizedCaseInsensitiveContains("grasp"))
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
        #expect(alignment.wrongAnswerIndicators.contains("generic interview coaching"))
    }

    @Test
    func perceptionControlReliabilityFallbackIsSpecificNotGenericCoaching() {
        let question = makeQuestion("How did you combine perception and control, and why was that connection difficult to make reliable")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .systemIntegrationDebugging)
        #expect(combined.localizedCaseInsensitiveContains("perception"))
        #expect(combined.localizedCaseInsensitiveContains("control"))
        #expect(combined.localizedCaseInsensitiveContains("target pose") || combined.localizedCaseInsensitiveContains("action goal"))
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
        #expect(alignment.wrongAnswerIndicators.contains("generic interview coaching"))
    }

    @Test
    func genericCoachingTemplateIsRejectedForRealRobotDebuggingLessonQuestion() {
        let questionText = "What was the most important lesson you learned from debugging the real robot?"
        let generic = "I’d answer this directly, connect it to a concrete robotics example, and keep the focus on what I did, why it mattered, and what I learned. Direct answer first. Concrete example from experience. Outcome or lesson learned."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: questionText, answerText: generic, sayFirst: generic)

        #expect(AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging)
        #expect(alignment.verdict == .mismatched)
        #expect(alignment.wrongAnswerIndicators.contains("generic interview coaching"))
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
            #expect(alignment.wrongAnswerIndicators.contains("generic interview coaching"))
        }
    }

    @Test
    func emptyThemeProfileUsesGenericQualitySafeguardsInsteadOfFailingZeroOfZero() {
        let questionText = "Edited question text"
        let concreteAnswer = "I am comfortable with Python and ROS2 from robotics projects, and I am actively improving C++ for performance-critical robotics systems."
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
        #expect(concreteAlignment.reason.localizedCaseInsensitiveContains("No expected theme profile"))
        #expect(genericAlignment.verdict == .mismatched)
        #expect(genericAlignment.wrongAnswerIndicators.contains("generic interview coaching"))
    }

    @Test
    func genericFallbackIsEmptyPlaceholderNotSuccessfulCoachingContent() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "GenericFallbackRejected")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion("Can you describe your approach to collaboration in projects?", sessionID: session.id)
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
    func interviewerQuestionsFallbackOutputsActualQuestions() {
        let question = makeQuestion("What questions would you ask us about the team or the role before accepting an offer?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined)

        #expect(AnswerRelevancePolicy.intent(for: question.questionText) == .interviewerQuestions)
        #expect(combined.localizedCaseInsensitiveContains("Yes, I’d love") == false)
        #expect(combined.localizedCaseInsensitiveContains("success"))
        #expect(combined.localizedCaseInsensitiveContains("deployment"))
        #expect(combined.localizedCaseInsensitiveContains("team"))
        #expect(combined.localizedCaseInsensitiveContains("ownership"))
        #expect(fallback.sayFirst.filter { $0 == "?" }.count >= 2)
        #expect(alignment.verdict == .aligned)
    }

    @Test
    func interviewerQuestionsRejectsOneVagueQuestionAndUsesFallback() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "InterviewerQuestionQuality")
        let appState = AppState(database: database)
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
        let fallback = try #require(appState.currentSuggestion)
        #expect(fallback.finalVisibleSource == "semantic_intent_fallback")
        #expect(fallback.sayFirst.filter { $0 == "?" }.count >= 2)
        #expect(fallback.alignmentVerdict == .aligned)
    }

    @Test
    func engineeringTeamFitQuestionRequiresWorkflowOrInfrastructureCoverage() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "TeamFitQuestionQuality")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "What would you ask the engineering team to understand whether this robotics role is a good fit?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var providerCard = SuggestionCard(
            id: "team-fit-provider-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "DeepSeek",
            sayFirst: "I would ask what success looks like in the first three months, what deployment challenges the robotics team is facing, and how responsibilities are split across perception, autonomy, and product engineering.",
            keyPoints: ["First three month success", "Deployment challenges", "Team structure and responsibilities", "Simulation and data infrastructure workflow"],
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
        let fallback = try #require(appState.currentSuggestion)
        #expect(fallback.finalVisibleSource == "semantic_intent_fallback")
        #expect(fallback.sayFirst.localizedCaseInsensitiveContains("workflow") || fallback.sayFirst.localizedCaseInsensitiveContains("workflows"))
        #expect(fallback.alignmentVerdict == .aligned)
    }

    @Test
    func leoRoverImprovementFallbackAvoidsVLAThesisRerankerGrounding() {
        let question = makeQuestion("If you had one more month to improve your LeoRover system, what would you improve first?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(questionText: question.questionText, answerText: combined, sayFirst: fallback.sayFirst)

        #expect(combined.localizedCaseInsensitiveContains("LeoRover"))
        #expect(combined.localizedCaseInsensitiveContains("real-robot") || combined.localizedCaseInsensitiveContains("real robot"))
        #expect(combined.localizedCaseInsensitiveContains("lighting"))
        #expect(combined.localizedCaseInsensitiveContains("occlusion"))
        #expect(combined.localizedCaseInsensitiveContains("spatial consistency"))
        #expect(combined.localizedCaseInsensitiveContains("closed-loop") || combined.localizedCaseInsensitiveContains("closed loop"))
        #expect(combined.localizedCaseInsensitiveContains("evaluation"))
        #expect(combined.localizedCaseInsensitiveContains("calibration"))
        #expect(combined.localizedCaseInsensitiveContains("latency"))
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(fallback.sayFirst))
        #expect(combined.localizedCaseInsensitiveContains("semantic-geometric") == false)
        #expect(combined.localizedCaseInsensitiveContains("re-ranker") == false)
        #expect(combined.localizedCaseInsensitiveContains("target-conditioned") == false)
        #expect(combined.localizedCaseInsensitiveContains("VLM grasping") == false)
        #expect(alignment.verdict == .aligned)
    }

    @Test(arguments: [
        "add confidence and spatial c",
        "I would ask the engineering team how they",
        "onto a real physical robot platform—a concrete",
        "I would improve LeoRover robustness with better evaluation"
    ])
    func incompleteVisibleAnswersWithoutFinishedSentenceAreRejected(_ answer: String) {
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(answer) == false)
        #expect(QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(answer) != nil)
    }

    @Test
    func projectComparisonFallbackContainsConcreteDetailsFromBothProjects() {
        let question = makeQuestion("Can you explain the difference between your VLA project and your LeoRover project?")
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let combined = ([fallback.sayFirst] + fallback.keyPoints).joined(separator: " ")

        #expect(combined.localizedCaseInsensitiveContains("MuJoCo") || combined.localizedCaseInsensitiveContains("Franka"))
        #expect(combined.localizedCaseInsensitiveContains("DROID") || combined.localizedCaseInsensitiveContains("decoder") || combined.localizedCaseInsensitiveContains("VLA policy"))
        #expect(combined.localizedCaseInsensitiveContains("ROS2") || combined.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(combined.localizedCaseInsensitiveContains("navigation") || combined.localizedCaseInsensitiveContains("manipulation") || combined.localizedCaseInsensitiveContains("recovery"))
        #expect(combined.localizedCaseInsensitiveContains("simulation"))
        #expect(combined.localizedCaseInsensitiveContains("real robot") || combined.localizedCaseInsensitiveContains("real-robot"))
    }

    @Test
    func projectComparisonRejectsVagueSimulationVersusRobotAnswer() {
        let question = "Can you explain the difference between your VLA project and your LeoRover project?"
        let answer = "The VLA project focused on simulation, while LeoRover was a real robot integration project."
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer
        )

        #expect(alignment.verdict == .mismatched)
        #expect(alignment.reason.localizedCaseInsensitiveContains("concrete"))
    }

    @Test
    func completeVisibleModelComparisonAnswerRemainsAlignedWhenFullCardIsStillExpanding() {
        let question = "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?"
        let sayFirst = "From my experience, diffusion-based policies produce smoother and more robust continuous action sequences through iterative denoising, unlike autoregressive policies which can compound errors step-by-step."
        let combined = """
        \(sayFirst)
        Diffusion models the full continuous action distribution or trajectory.
        Autoregressive and flow-matching variants were less robust in the evaluation.
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
        let question = "Why might a diffusion based policy be more stable for robotic manipulation than an auto rig progressive policy"
        let sayFirst = "I'd say diffusion-based policies produce smoother, more robust action sequences by denoising from a full trajectory distribution, which avoids the compounding error and jerky motions you often see with autoregressive policies, leading to higher success rates in continuous manipulation tasks."

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
        let question = "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy"
        let sayFirst = "I find diffusion-based policies more stable because they denoise the whole action trajectory at once, producing smooth motions instead of step-by-step predictions that tend to accumulate errors and cause jittery behavior in precise tasks."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: sayFirst,
            sayFirst: sayFirst,
            stageBCompleted: false
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.matchedThemes.contains("continuous action distribution"))
        #expect(alignment.matchedThemes.contains("autoregressive / flow-matching comparison"))
    }

    @Test
    func runtimeLeoRoverProjectAnswerAlignsWithProjectWalkthroughQuestion() {
        let question = "could you explain your LeoRover project from end to end"
        let answer = "My LeoRover project was an autonomous object retrieval robot. I built the ROS2 perception pipeline around YOLOv8 object detection, used the output for navigation and localisation, and connected it to manipulation so the real robot could approach and pick up the target object."

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
        let question = "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
        let answer = "The hardest part was dealing with sensor noise and timing mismatches—in a clean demo everything runs perfectly, but on the real robot, small drifts in camera and IMU data would throw off the entire pipeline. I had to recalibrate the sensors, add robust filtering, and rework the coordination between perception, navigation, and manipulation modules, which finally stabilized the system and got our retrieval success rate up to 70%."

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
        let answer = "I’m drawn to Dexory because my work in embodied AI and ROS2 robotics aligns perfectly with your mission to break out of academia and deploy intelligent robots into real logistics environments—I want to help build world-changing solutions that bridge foundation models with practical, scalable behaviour."

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )

        #expect(alignment.verdict == .aligned)
        #expect(alignment.questionIntent == .whyRole)
        #expect(alignment.answerIntent == .whyRole)
        #expect(alignment.matchedThemes.contains("role / team interest"))
        #expect(alignment.matchedThemes.contains("mission / company direction"))
        #expect(alignment.matchedThemes.contains("real-world deployment"))
    }

    @Test
    func semanticGuardRejectsIncompleteSayFirstEvenWhenKeyPointsMatch() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "AnswerRelevanceIncomplete")
        let appState = AppState(database: database)
        let session = try appState.sessionRepository.createSession(mode: .mock)
        let question = makeQuestion(
            "Why might a diffusion-based policy be more stable for robotic manipulation than an autoregressive policy?",
            sessionID: session.id
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.setActiveQuestionForTesting(question)

        var truncatedCard = SuggestionCard(
            id: "incomplete-diffusion-card",
            sessionID: session.id,
            questionID: question.id,
            strategy: "Model comparison",
            sayFirst: "Diffusion-based policies tend to be more",
            keyPoints: [
                "Diffusion produces smoother continuous actions.",
                "It is more robust than an autoregressive policy.",
                "The MuJoCo evaluation reached seven out of ten successful grasps."
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
        #expect(appState.currentSuggestion?.sayFirst != "Diffusion-based policies tend to be more")
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("diffusion") == true)
        #expect(appState.lastAlignmentError.localizedCaseInsensitiveContains("using fallback"))
    }

    private struct Fixture {
        var question: String
        var intent: AnswerRelevanceIntent
        var mustContain: [String]
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            question: "Could you tell me a little bit about yourself and what brought you into robotics?",
            intent: .tellMeAboutYourself,
            mustContain: ["MSc Robotics", "robotics"]
        ),
        Fixture(
            question: "Could you walk me through your LeoRover project?",
            intent: .projectWalkthrough,
            mustContain: ["LeoRover", "ROS2", "YOLOv8", "navigation", "manipulation"]
        ),
        Fixture(
            question: "What was the hardest technical challenge you faced?",
            intent: .technicalChallenge,
            mustContain: ["noisy", "localisation", "real robot"]
        ),
        Fixture(
            question: "How did you handle noisy detections or localisation errors?",
            intent: .errorHandling,
            mustContain: ["filtering", "repeated observations", "recovery"]
        ),
        Fixture(
            question: "Why did the diffusion decoder perform better in your MuJoCo evaluation?",
            intent: .modelComparison,
            mustContain: ["diffusion", "autoregressive", "flow-matching", "smoother", "seven out of ten"]
        ),
        Fixture(
            question: "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            intent: .decoderComparison,
            mustContain: ["MuJoCo", "VLA", "autoregressive", "diffusion", "flow-matching", "7/10"]
        ),
        Fixture(
            question: "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?",
            intent: .perceptionDebugging,
            mustContain: ["YOLOv8", "frames", "bounding", "confidence", "calibration", "retraining"]
        ),
        Fixture(
            question: "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            intent: .datasetAdaptation,
            mustContain: ["DROID", "MuJoCo", "Franka", "trajectory", "coordinate"]
        ),
        Fixture(
            question: "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?",
            intent: .simToRealDebugging,
            mustContain: ["sim-to-real", "observations", "timing", "calibration", "dynamics"]
        ),
        Fixture(
            question: "Can you explain the difference between your VLA project and your LeoRover project?",
            intent: .projectComparison,
            mustContain: ["VLA", "LeoRover", "MuJoCo", "ROS2", "difference"]
        ),
        Fixture(
            question: "What would you change first if you had another month?",
            intent: .improvementPlan,
            mustContain: ["evaluation", "failure cases", "perception"]
        ),
        Fixture(
            question: "What was the biggest technical trade-off you made in your robotics projects?",
            intent: .technicalTradeoff,
            mustContain: ["trade-off", "robustness", "latency", "LeoRover"]
        ),
        Fixture(
            question: "Tell me about a time you had to debug a system integration problem.",
            intent: .systemIntegrationDebugging,
            mustContain: ["system integration", "logs", "timestamps", "recovery"]
        ),
        Fixture(
            question: "Can you explain how your robot transformed visual detections into physical actions in the real world",
            intent: .systemIntegrationDebugging,
            mustContain: ["target pose", "navigation", "manipulation", "recovery"]
        ),
        Fixture(
            question: "What information did the robot need before it could decide where to move and what to grasp",
            intent: .systemIntegrationDebugging,
            mustContain: ["object identity", "location", "reachability", "navigation", "grasp"]
        ),
        Fixture(
            question: "How did you combine perception and control, and why was that connection difficult to make reliable",
            intent: .systemIntegrationDebugging,
            mustContain: ["perception", "control", "target pose", "latency"]
        ),
        Fixture(
            question: "What was the most important lesson you learned from debugging the real robot?",
            intent: .systemIntegrationDebugging,
            mustContain: ["debugging", "real robot", "integration", "logs", "timestamps", "recovery"]
        ),
        Fixture(
            question: "Why do you want to join our team?",
            intent: .whyRole,
            mustContain: ["role", "robotics", "deployment"]
        ),
        Fixture(
            question: "How comfortable are you with Python, C++, and ROS2?",
            intent: .skillComfort,
            mustContain: ["Python", "C++", "ROS2"]
        ),
        Fixture(
            question: "Do you have any questions for us?",
            intent: .candidateQuestions,
            mustContain: ["ask", "team", "deployment"]
        ),
        Fixture(
            question: "What questions would you ask us about the team or the role before accepting an offer?",
            intent: .interviewerQuestions,
            mustContain: ["success", "deployment", "team", "ownership"]
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
                chunk("self", "Education: MSc Robotics at the University of Manchester with a computer science background and robotics interest.", .cv),
                chunk("leorover", "LeoRover autonomous object retrieval robot using ROS2, YOLOv8, target localisation, navigation, and manipulation.", .cv),
                chunk("challenge", "Hardest challenge: noisy perception, localisation instability, timing mismatch, and unpredictable real robot execution.", .cv),
                chunk("noise", "Noisy detections were handled with filtering, repeated observations, stability thresholds, retry, repositioning, and recovery behaviour.", .cv),
                chunk("vla", "VLA MuJoCo evaluation compared diffusion, autoregressive, and flow-matching decoders; diffusion gave smoother continuous actions and seven out of ten successful grasps.", .cv),
                chunk("detector", "YOLOv8 detector debugging used frame logs, bounding boxes, class confidence, calibration checks, lighting and occlusion review, and recovery before retraining.", .cv),
                chunk("tradeoff", "Robotics trade-off: LeoRover prioritized robust filtering, recovery behaviour, ROS2 coordination, and reliable real robot execution over latency and model complexity.", .cv),
                chunk("skills", "Skills: Python, ROS2, C++, robotics projects, control coordination, experiment scripting, and performance-critical robotics systems.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd", "Robotics software team focused on perception, real-world deployment, evaluation, reliability, and success criteria.", .jobDescription)
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
