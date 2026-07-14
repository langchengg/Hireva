import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct QuestionDetectionTests {
    @Test
    func leaderRoverASRVariantNormalizesToLeoRoverProjectIntent() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you walk me through your a p i project")

        #expect(questions.count == 1)
        #expect(questions.first?.text == "Could you walk me through your API project")
        #expect(questions.first?.intent == .projectDeepDive)
        #expect(questions.first?.answerStrategy == .projectWalkthrough)
    }

    @Test
    func leroEndToEndNormalizesToCanonicalLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you walk me through your Atlas project from N to end")

        #expect(questions.map(\.text) == ["Could you walk me through your Atlas project from end-to-end"])
        #expect(questions.first?.intent == .projectDeepDive)
    }

    @Test
    func trailingNextQuestionStarterIsTrimmedFromLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you walk me through your Atlas project end-to-end and what you")

        #expect(questions.map(\.text) == ["Could you walk me through your Atlas project end-to-end"])
        #expect(questions.first?.text.localizedCaseInsensitiveContains("what you") == false)
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
        let questions = SystemAudioQuestionExtractor.extract(from: "which system component made the deployment handoff least reliable after the test environment stopped matching production")

        #expect(questions.map(\.text) == [
            "Which system component made the deployment handoff least reliable after the test environment stopped matching production"
        ])
        #expect(questions.first?.intent == .technical)
        #expect(questions.first?.answerStrategy == .technicalExplanation)
    }

    @Test
    func repeatedPrefixFragilePipelineQuestionIsCanonicalized() {
        let question = "When you moved from a clean demo to production execution, which part of the pipeline was most fragile?"
        let repeatedPrefix = "\(question) \(question)"
        let canonical = QuestionCanonicalizer.truncateRepeatedFragilePipelineTail(repeatedPrefix)
        let questions = SystemAudioQuestionExtractor.extract(from: canonical)

        #expect(questions.map(\.text) == [
            question
        ])
        #expect(SystemAudioQuestionExtractor.duplicateKey(for: canonical) == SystemAudioQuestionExtractor.duplicateKey(for: question))
    }

    @Test
    func mergedTechnicalAndWhyRoleTranscriptSplitsIntoTwoQuestions() {
        let transcript = "which system component made the deployment handoff least reliable after the test environment stopped matching production why do you want to join our team why do you want to join our team why"

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "Which system component made the deployment handoff least reliable after the test environment stopped matching production",
            "Why do you want to join our team"
        ])
        #expect(questions.map(\.intent) == [.technical, .companyFit])
    }

    @Test
    func semanticLeoRoverVariantsAreDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("could you walk me through the Atlas migration project") == false)
        #expect(appState.isDuplicateAutoQuestion("walk me through your Atlas migration project") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func diffusionASRVariantsAreDuplicateSuppressed() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)

        #expect(appState.isDuplicateAutoQuestion("How comfortable are you with c plus plus and s q l") == false)
        #expect(appState.isDuplicateAutoQuestion("How comfortable are you with C++ and SQL") == true)
        #expect(appState.duplicateSuppressionCount == 1)
    }

    @Test
    func mujocoDecoderComparisonASRVariantsNormalizeToCanonicalQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(
            from: "What did you learn from comparing classifier regression and transformer alternatives"
        )

        #expect(questions.map(\.text) == [
            "What did you learn from comparing classifier regression and transformer alternatives"
        ])
        #expect(questions.first?.intent == .technical)
        #expect(AnswerRelevancePolicy.intent(for: questions.first?.text ?? "") == .decoderComparison)
    }

    @Test
    func mergedDecoderAndDetectorDebuggingQuestionSplitsIntoTwoCanonicalQuestions() {
        let transcript = "What did you learn from comparing classifier, regression, and transformer alternatives? Also, if your inspection detector gives a confident but wrong prediction, how would you debug it?"

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "If your inspection detector gives a confident but wrong prediction, how would you debug it?"
        ])
        #expect(questions.map(\.intent) == [.technical, .technical])
    }

    @Test
    func yoloAndLeoRoverASRVariantsNormalizeToPerceptionDebuggingQuestion() {
        let canonical = SystemAudioQuestionExtractor.canonicalizeQuestionText(
            "If your a p i detector gives a confident but wrong prediction, how would you debug it?"
        )
        let questions = SystemAudioQuestionExtractor.extract(
            from: "If your a p i detector gives a confident but wrong prediction, how would you debug it?"
        )

        #expect(canonical == "If your API detector gives a confident but wrong prediction, how would you debug it?")
        #expect(questions.map(\.text) == [
            "If your API detector gives a confident but wrong prediction, how would you debug it?"
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
            from: "What was the biggest technical trade-off you made between latency and accuracy?"
        )
        let interviewerQuestions = SystemAudioQuestionExtractor.extract(
            from: "What questions would you ask us about the team or the role before accepting an offer?"
        )

        #expect(tradeoff.map(\.text) == [
            "What was the biggest technical trade-off you made between latency and accuracy?"
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
    func cumulativeASRSegmentRemainsDuplicateAfterCooldownButNewSegmentCanRepeat() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "QuestionDetectionTests")
        let appState = AppState(database: database)
        let question = "What was the hardest technical challenge in making the real robot work reliably?"
        let firstSeenAt = Date(timeIntervalSince1970: 1_000)

        #expect(appState.isDuplicateAutoQuestion(
            question,
            transcriptSegmentID: "cumulative-segment",
            now: firstSeenAt
        ) == false)
        #expect(appState.isDuplicateAutoQuestion(
            question,
            transcriptSegmentID: "cumulative-segment",
            now: firstSeenAt.addingTimeInterval(120)
        ) == true)
        #expect(appState.isDuplicateAutoQuestion(
            question,
            transcriptSegmentID: "explicit-repeat-segment",
            now: firstSeenAt.addingTimeInterval(120)
        ) == false)
    }

    @Test
    func mixedFourQuestionSequenceKeepsFourFinalQuestionsOnly() {
        let transcript = [
            "Why did the transformer model perform better than the regression model?",
            "Could you walk me through your Atlas migration project?",
            "When you moved from a clean test to production execution, which part of the pipeline was most fragile?",
            "Why do you want to join our team?"
        ].joined(separator: " ")

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "Why did the transformer model perform better than the regression model?",
            "Could you walk me through your Atlas migration project?",
            "When you moved from a clean test to production execution, which part of the pipeline was most fragile?",
            "Why do you want to join our team?"
        ])
        #expect(questions.map(\.intent) == [.technical, .projectDeepDive, .technical, .companyFit])
        #expect(questions.allSatisfy { !SystemAudioQuestionExtractor.isIncompleteQuestionFragment($0.text) })
    }

    @Test
    func newEightQuestionRuntimeStyleSequenceExtractsCleanUniqueQuestions() {
        let transcript = [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "How did you adapt the legacy event dataset into the new warehouse format?",
            "If the inspection detector gives a confident but wrong prediction, how would you debug it?",
            "How would you diagnose a sim to real gap if a policy works in simulation but fails in production?",
            "Can you explain the difference between the Atlas project and the Beacon project?",
            "What was the biggest technical trade-off you made between latency and accuracy?",
            "Tell me about a time you had to debug a system integration problem.",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ].joined(separator: " ")

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.map(\.text) == [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "How did you adapt the legacy event dataset into the new warehouse format?",
            "If the inspection detector gives a confident but wrong prediction, how would you debug it?",
            "How would you diagnose a sim-to-real gap if a policy works in simulation but fails in production?",
            "Can you explain the difference between the Atlas project and the Beacon project?",
            "What was the biggest technical trade-off you made between latency and accuracy?",
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
