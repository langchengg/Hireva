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
        #expect(questions.first?.text == "could you explain your LeoRover project")
        #expect(questions.first?.intent == .projectDeepDive)
        #expect(questions.first?.answerStrategy == .projectWalkthrough)
    }

    @Test
    func leroEndToEndNormalizesToCanonicalLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you explain your Lero project from N to end")

        #expect(questions.map(\.text) == ["could you explain your LeoRover project from end to end"])
        #expect(questions.first?.intent == .projectDeepDive)
    }

    @Test
    func trailingNextQuestionStarterIsTrimmedFromLeoRoverQuestion() {
        let questions = SystemAudioQuestionExtractor.extract(from: "could you explain your LeoRover project from end to end when you")

        #expect(questions.map(\.text) == ["could you explain your LeoRover project from end to end"])
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
            "why do you want to join our team"
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
            "could you explain your LeoRover project from end to end",
            "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?",
            "why do you want to join our team"
        ])
        #expect(questions.map(\.intent) == [.technical, .projectDeepDive, .technical, .companyFit])
        #expect(questions.allSatisfy { !$0.text.localizedCaseInsensitiveContains("from end to end when you") })
    }
}
