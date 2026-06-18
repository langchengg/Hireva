import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct QuestionDetectionTests {
    @Test
    func leaderRoverASRVariantNormalizesToLeoRoverProjectIntent() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you explain your leader Rover")

        #expect(questions.count == 1)
        #expect(questions.first?.text == "Could you explain your LeoRover project")
        #expect(questions.first?.intent == .projectDeepDive)
        #expect(questions.first?.answerStrategy == .projectWalkthrough)
    }

    @Test
    func leroEndToEndNormalizesToCanonicalLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you explain your Lero project from N to end")

        #expect(questions.map(\.text) == ["Could you explain your LeoRover project from end to end"])
        #expect(questions.first?.intent == .projectDeepDive)
    }

    @Test
    func trailingNextQuestionStarterIsTrimmedFromLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you explain your LeoRover project from end to end when you")

        #expect(questions.map(\.text) == ["Could you explain your LeoRover project from end to end"])
        #expect(questions.first?.text.localizedCaseInsensitiveContains("when you") == false)
    }

    @Test
    func incompleteWhenMovedFromFragmentIsRejected() {
        let questions = SystemAudioQuestionExtractor.extract(from: "when you moved from")

        #expect(questions.isEmpty)
        #expect(SystemAudioQuestionExtractor.isIncompleteQuestionFragment("when you moved from"))
    }

    @Test
    func incompleteFragilePipelineWhichPartFragmentIsRejected() {
        let questions = SystemAudioQuestionExtractor.extract(from: "when you moved from a clean demo to real robot execution which part")

        #expect(questions.isEmpty)
        #expect(SystemAudioQuestionExtractor.isIncompleteQuestionFragment("when you moved from a clean demo to real robot execution which part"))
    }

    @Test
    func completeFragilePipelineQuestionIsCanonicalizedAndAccepted() {
        let questions = SystemAudioQuestionExtractor.extract(from: "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile")

        #expect(questions.map(\.text) == [
            "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
        ])
        #expect(questions.first?.intent == .technical)
        #expect(questions.first?.answerStrategy == .technicalExplanation)
    }

    @Test
    func repeatedPrefixFragilePipelineQuestionIsCanonicalized() {
        let repeatedPrefix = "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile when you moved from a clean de"

        let questions = SystemAudioQuestionExtractor.extract(from: repeatedPrefix)

        #expect(questions.map(\.text) == [
            "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
        ])
        #expect(SystemAudioQuestionExtractor.duplicateKey(for: repeatedPrefix) == SystemAudioQuestionExtractor.duplicateKey(for: "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"))
    }

    @Test
    func mergedTechnicalAndWhyRoleTranscriptSplitsIntoTwoQuestions() {
        let transcript = "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile why do you want to join our team why do you want to join our team why"

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?",
            "Why do you want to join our team"
        ])
        #expect(questions.map(\.intent) == [.technical, .companyFit])
    }

    @Test
    func semanticLeoRoverVariantsAreDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("could you explain your Leo Rover") == false)
        #expect(appState.isDuplicateAutoQuestion("could you explain your Lero project from N to end") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func diffusionASRVariantsAreDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("Why might a diffusion based policy be more stable for robotic manipulation than an auto rig progressive policy") == false)
        #expect(appState.isDuplicateAutoQuestion("Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func mujocoDecoderComparisonASRVariantsNormalizeToCanonicalQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(
            from: "What did you learn from comparing auto regressive diffusion and flow matching decoders in your Mojave project"
        )

        #expect(questions.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?"
        ])
        #expect(questions.first?.intent == .technical)
        #expect(AnswerRelevancePolicy.intent(for: questions.first?.text ?? "") == .decoderComparison)
    }

    @Test
    func mergedDecoderAndDetectorDebuggingQuestionSplitsIntoTwoCanonicalQuestions() {
        let transcript = "What did you learn from comparing autoregressive diffusion and flow matching decoders in your Muja Cove project? Also, if your detector gives a confident but wrong prediction, how would you debug it?"

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?"
        ])
        #expect(questions.map(\.intent) == [.technical, .technical])
    }

    @Test
    func yoloAndLeoRoverASRVariantsNormalizeToPerceptionDebuggingQuestion() {
        let canonical = SystemAudioQuestionExtractor.canonicalizeQuestionText(
            "how would you debug it if your Yolo eight detector gives a confident but wrong prediction on the layover"
        )
        let questions = SystemAudioQuestionExtractor.extract(
            from: "If your yo love eight detector gives a confident but wrong prediction on the layover, how would you debug it?"
        )

        #expect(canonical == "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?")
        #expect(questions.map(\.text) == [
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?"
        ])
        #expect(AnswerRelevancePolicy.intent(for: questions.first?.text ?? "") == .perceptionDebugging)
    }

    @Test
    func incompleteTradeoffAndInterviewerQuestionFragmentsAreRejected() {
        #expect(SystemAudioQuestionExtractor.extract(from: "what was the biggest").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "what was the biggest technical").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "what was the biggest technical trade-off").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "tell me about a").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "tell me about a time").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "tell me about a time you").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "can you explain the difference").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "how did you adapt").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "how would you diagnose").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "would you ask us").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "what questions would you ask").isEmpty)
        #expect(SystemAudioQuestionExtractor.extract(from: "what questions would you ask us").isEmpty)
    }

    @Test
    func tradeoffAndInterviewerQuestionCompleteFormsAreAccepted() {
        let tradeoff = SystemAudioQuestionExtractor.extract(
            from: "what was the biggest technical trade-off you made in your robotics projects what"
        )
        let interviewerQuestions = SystemAudioQuestionExtractor.extract(
            from: "What questions would you ask us about the team or the role before accepting an offer?"
        )

        #expect(tradeoff.map(\.text) == [
            "What was the biggest technical trade-off you made in your robotics projects?"
        ])
        #expect(AnswerRelevancePolicy.intent(for: tradeoff.first?.text ?? "") == .technicalTradeoff)
        #expect(interviewerQuestions.map(\.text) == [
            "What questions would you ask us about the team or the role before accepting an offer?"
        ])
        #expect(AnswerRelevancePolicy.intent(for: interviewerQuestions.first?.text ?? "") == .interviewerQuestions)
    }

    @Test
    func completeSystemIntegrationDebuggingQuestionIsAccepted() {
        let questions = SystemAudioQuestionExtractor.extract(
            from: "Tell me about a time you had to debug a system integration problem."
        )

        #expect(questions.map(\.text) == [
            "Tell me about a time you had to debug a system integration problem"
        ])
        #expect(AnswerRelevancePolicy.intent(for: questions.first?.text ?? "") == .systemIntegrationDebugging)
    }

    @Test
    func leoRoverShortAndFullWalkthroughVariantsAreDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("could you explain your LeoRover project") == false)
        #expect(appState.isDuplicateAutoQuestion("could you explain your LeoRover project from end to end") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func repeatedPrefixFragilePipelineVariantIsDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?") == false)
        #expect(appState.isDuplicateAutoQuestion("when you moved from a clean demo to real robot execution which part of the pipeline was most fragile when you moved from a clean de") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func mixedFourQuestionSequenceKeepsFourFinalQuestionsOnly() {
        let transcript = [
            "Why might a diffusion based policy be more stable for robotic manipulation than an auto rig progressive policy",
            "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
            "could you explain your LeoRover project",
            "could you explain your LeoRover project from end to end when you",
            "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile",
            "why do you want to join our team"
        ].joined(separator: " ")

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "Why might a diffusion policy be more stable for robotic manipulation than an autoregressive policy",
            "Could you explain your LeoRover project from end to end",
            "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?",
            "Why do you want to join our team"
        ])
        #expect(questions.map(\.intent) == [.technical, .projectDeepDive, .technical, .companyFit])
        #expect(questions.allSatisfy { !$0.text.localizedCaseInsensitiveContains("from end to end when you") })
    }

    @Test
    func newEightQuestionRuntimeStyleSequenceExtractsCleanUniqueQuestions() {
        let transcript = [
            "What did you learn from comparing autoregressive, diffusion, and flow matching decoders in your MuJoCo VLA project?",
            "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            "If your YOLO eight detector gives a confident but wrong prediction on the layover, how would you debug it?",
            "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?",
            "Can you explain the difference between your VLA project and your LeoRover project?",
            "What was the biggest technical trade-off you made in your robotics projects?",
            "Tell me about a time you had to debug a system integration problem.",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ].joined(separator: " ")

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?",
            "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?",
            "Can you explain the difference between your VLA project and your LeoRover project?",
            "What was the biggest technical trade-off you made in your robotics projects?",
            "Tell me about a time you had to debug a system integration problem",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ])
        #expect(Set(questions.map(\.text)).count == 8)
        #expect(questions.allSatisfy { !$0.text.localizedCaseInsensitiveContains("Also, if") })
        #expect(questions.allSatisfy { !SystemAudioQuestionExtractor.isIncompleteQuestionFragment($0.text) })
        #expect(questions.map { AnswerRelevancePolicy.intent(for: $0.text) } == [
            .decoderComparison,
            .datasetAdaptation,
            .perceptionDebugging,
            .simToRealDebugging,
            .projectComparison,
            .technicalTradeoff,
            .systemIntegrationDebugging,
            .interviewerQuestions
        ])
    }
}
