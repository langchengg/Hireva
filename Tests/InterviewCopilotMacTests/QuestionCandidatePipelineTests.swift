import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct QuestionCandidatePipelineTests {
    @Test
    func repeatedQuestionAtNewSourceSpanRemainsASeparateCandidate() {
        let question = "What was the hardest technical challenge in making the real robot work reliably?"
        let transcript = "\(question) The interviewer asks it again. \(question)"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.count == 2)
        #expect(candidates.map(\.duplicateKey).allSatisfy { $0 == SemanticDuplicateKeyBuilder.key(for: question) })
        #expect(Set(candidates.map(\.sourceStartUTF16)).count == 2)
    }

    @Test
    func asrCanonicalizerNormalizesKnownRuntimeVariants() {
        let text = "Muja Cove with flowmatching on a layover using yellow of aid detection and YOLO eight, from N to end, and a seem to real gap"
        let canonical = ASRCanonicalizer.canonicalizeTerms(text)

        #expect(canonical.localizedCaseInsensitiveContains("MuJoCo"))
        #expect(canonical.localizedCaseInsensitiveContains("flow-matching"))
        #expect(canonical.localizedCaseInsensitiveContains("LeoRover"))
        #expect(canonical.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(canonical.localizedCaseInsensitiveContains("from end to end"))
        #expect(canonical.localizedCaseInsensitiveContains("sim-to-real"))
    }

    @Test
    func asrCanonicalizerNormalizesAdditionalRuntimeVariantsBeforeSplitting() {
        let canonical = ASRCanonicalizer.canonicalizeTerms(
            "Muji Mooji Mugi Mu G Mouko Moko MoCo Muko Moco Mojave Muja Cove with yo love eight on the layover and a sim real issue and how did mitigate those issues"
        )

        #expect(canonical.components(separatedBy: "MuJoCo").count >= 12)
        #expect(canonical.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(canonical.localizedCaseInsensitiveContains("LeoRover"))
        #expect(canonical.localizedCaseInsensitiveContains("sim-to-real"))
        #expect(canonical.localizedCaseInsensitiveContains("and how did you mitigate those issues"))
    }

    @Test
    func asrCanonicalizerNormalizesVLAProjectVariantsBeforeAndAfterSplitting() {
        let variants = [
            "villa project",
            "Vila project",
            "V L A project",
            "VLA project"
        ]

        for variant in variants {
            let canonical = ASRCanonicalizer.canonicalizeTerms("Can you explain the difference between your \(variant) and your LeoRover project")
            #expect(canonical.localizedCaseInsensitiveContains("VLA project"))
            let candidates = QuestionCandidatePipeline.extract(from: canonical)
            #expect(candidates.first?.text == "Can you explain the difference between your VLA project and your LeoRover project")
            #expect(candidates.first?.answerRelevanceIntent == .projectComparison)
        }
    }

    @Test
    func completenessGateRejectsDanglingQuestionFragments() {
        let fragments = [
            "what did you learn",
            "what did you learn from comp",
            "what did you learn from it?",
            "what questions would you ask us about the",
            "what questions would you ask us about that",
            "how would you diagnose a seem",
            "would you debug it",
            "how would you debug it",
            "what would you do",
            "which part was most fragile",
            "how would you diagnose it",
            "how would you solve it",
            "can you explain the difference",
            "what was the biggest technical trade-off",
            "tell me about a time you had"
        ]

        for fragment in fragments {
            #expect(QuestionCompletenessGate.isIncompleteFragment(fragment), "Expected incomplete fragment: \(fragment)")
            #expect(SystemAudioQuestionExtractor.extract(from: fragment).isEmpty, "Expected no extraction for: \(fragment)")
            #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: fragment).accepted == false, "Expected runtime guard rejection for: \(fragment)")
        }
    }

    @Test
    func conditionalPerceptionQuestionPreservesAntecedentAndRejectsTailOnlyCandidate() {
        let candidates = QuestionCandidatePipeline.extract(
            from: "If your yo love eight detector gives a confident but wrong prediction on the layover, how would you debug it?"
        )

        #expect(candidates.map(\.text) == [
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?"
        ])
        #expect(candidates.first?.answerRelevanceIntent == .perceptionDebugging)
        #expect(!candidates.contains { $0.text.localizedCaseInsensitiveContains("would you debug it") && !$0.text.localizedCaseInsensitiveContains("YOLOv8") })
        #expect(QuestionCandidatePipeline.extract(from: "would you debug it").isEmpty)
    }

    @Test
    func conditionalSplitRepairKeepsIfClauseAfterAlsoIfBoundary() {
        let transcript = "What did you learn from comparing autoregressive diffusion and flow matching decoders in your MuJoCo VLA project? Also, if your detector gives a confident but wrong prediction, how would you debug it?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.decoderComparison, .perceptionDebugging])
    }

    @Test
    func relatedWhatMadeFollowUpSplitsIntoSeparateCurrentQuestion() {
        let transcript = "How did your layover system connect YOLOv8 detection with localization, navigation, manipulation, and recovery behaviors? What made real-world execution on the layover harder than a clean simulation or demo environment?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "How did your LeoRover system connect YOLOv8 detection with localization, navigation, manipulation, and recovery behaviors?",
            "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.systemIntegrationDebugging, .technicalChallenge])
    }

    @Test
    func realScreenshotUnpunctuatedArchitectureTranscriptCanonicalizesAndExtracts() throws {
        let candidates = QuestionCandidatePipeline.extract(
            from: "How did your robotic system connect yellow of aid detection with localization navigation manipulation and recovery behaviors what made real world execution harder than a clean simulation or demo environment and how did mitigate those issues"
        )
        let candidate = try #require(candidates.first)

        #expect(candidates.count == 2)
        #expect(candidate.text.localizedCaseInsensitiveContains("YOLOv8 detection"))
        #expect(candidate.text.localizedCaseInsensitiveContains("localization"))
        #expect(candidate.text.localizedCaseInsensitiveContains("navigation"))
        #expect(candidate.text.localizedCaseInsensitiveContains("manipulation"))
        #expect(candidate.text.localizedCaseInsensitiveContains("recovery"))
        #expect(candidate.answerRelevanceIntent == .systemIntegrationDebugging)
        let mitigationCandidate = try #require(candidates.last)
        let normalizedMitigationCandidate = mitigationCandidate.text
            .replacingOccurrences(of: "-", with: " ")
        #expect(normalizedMitigationCandidate.localizedCaseInsensitiveContains("What made real world execution harder"))
        #expect(mitigationCandidate.text.localizedCaseInsensitiveContains("how did you mitigate those issues"))
        #expect(mitigationCandidate.answerRelevanceIntent == .technicalChallenge)
    }

    @Test
    func standaloneWhatMadeRealWorldExecutionQuestionIsAccepted() throws {
        let candidate = try #require(QuestionCandidatePipeline.extract(
            from: "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?"
        ).first)

        #expect(candidate.text == "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?")
        #expect(candidate.answerRelevanceIntent == .technicalChallenge)
    }

    @Test
    func unrelatedPunctuatedQuestionsSplitIntoSeparateCandidates() {
        let transcript = "How did your LeoRover system connect YOLOv8 detection with localization and navigation? What questions would you ask us about the team before accepting an offer?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "How did your LeoRover system connect YOLOv8 detection with localization and navigation?",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.projectWalkthrough, .interviewerQuestions])
    }

    @Test
    func mokoAndSeemToRealCanonicalizeInFullQuestion() {
        let candidates = QuestionCandidatePipeline.extract(
            from: "How would you diagnose a seem to real gap if your policy works in Muji but fails on a real robot?"
        )

        #expect(candidates.map(\.text) == [
            "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?"
        ])
        #expect(candidates.first?.answerRelevanceIntent == .simToRealDebugging)
    }

    @Test
    func observedMergedBTraceExtractsFourUsefulQuestionsAndRejectsBadInterviewerFragment() {
        let transcript = "What questions would you ask us about that tell me about a time you had tell me about a time you had what did you learn from comparing auto regressive diffusion and flow tell me about a time you had to debug a system integration problem what questions would you ask us about the team or the role before accepting an offer how would you diagnose a seem to real gap if your policy works in Muji but fails on a real robot"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(!candidates.contains { $0.text == "What questions would you ask us about that" })
        #expect(candidates.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            "Tell me about a time you had to debug a system integration problem",
            "What questions would you ask us about the team or the role before accepting an offer?",
            "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .decoderComparison,
            .systemIntegrationDebugging,
            .interviewerQuestions,
            .simToRealDebugging
        ])
    }

    @Test
    func engineeringTeamFitThenLeoRoverImprovementSplitsIntoTwoCandidates() {
        let transcript = "What would you ask the engineering team to understand whether this role is a good fit if you had one more month to improve your Lero system what would you improve first"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What would you ask the engineering team to understand whether this role is a good fit",
            "If you had one more month to improve your LeoRover system what would you improve first"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .interviewerQuestions,
            .improvementPlan
        ])
        #expect(candidates.map(\.intent) == [
            .companyFit,
            .projectDeepDive
        ])
    }

    @Test
    func leoRoverOneMoreMonthRoutesToImprovementBeforeProjectWalkthrough() throws {
        let candidate = try #require(QuestionCandidatePipeline.extract(
            from: "If you had one more month to improve your LeoRover system, what would you improve first?"
        ).first)

        #expect(candidate.answerRelevanceIntent == .improvementPlan)
        #expect(candidate.text == "If you had one more month to improve your LeoRover system, what would you improve first?")
    }

    @Test
    func partialDuplicateLeoRoverImprovementQuestionIsRejectedAsIncomplete() {
        let transcript = [
            "If you had one more month to improve your LeoRover system, what would you improve first?",
            "If you had one more month to improve your LeoRover"
        ].joined(separator: " ")

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "If you had one more month to improve your LeoRover system, what would you improve first?"
        ])
        #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: "If you had one more month to improve your LeoRover").accepted == false)
        #expect(QuestionCompletenessGate.isIncompleteFragment("If you had one more month to improve your LeoRover"))
    }

    @Test
    func pipelineAcceptsCompleteEightQuestionRuntimeSequenceWithSpecificIntents() {
        let transcript = [
            "What did you learn from comparing autoregressive, diffusion, and flowmatching decoders in your Muja Cove VLA project?",
            "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            "If your YOLO eight detector gives a confident but wrong prediction on the layover, how would you debug it?",
            "How would you diagnose a seem to real gap if your policy works in MuJoCo but fails on a real robot?",
            "Can you explain the difference between your VLA project and your LeoRover project?",
            "What was the biggest technical trade-off you made in your robotics projects?",
            "Tell me about a time you had to debug a system integration problem.",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ].joined(separator: " ")

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What did you learn from comparing autoregressive, diffusion, and flow-matching decoders in your MuJoCo VLA project?",
            "How did you adapt DROID real-robot trajectories into your MuJoCo Franka simulation?",
            "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?",
            "How would you diagnose a sim-to-real gap if your policy works in MuJoCo but fails on a real robot?",
            "Can you explain the difference between your VLA project and your LeoRover project?",
            "What was the biggest technical trade-off you made in your robotics projects?",
            "Tell me about a time you had to debug a system integration problem",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .decoderComparison,
            .datasetAdaptation,
            .perceptionDebugging,
            .simToRealDebugging,
            .projectComparison,
            .technicalTradeoff,
            .systemIntegrationDebugging,
            .interviewerQuestions
        ])
        #expect(Set(candidates.map(\.duplicateKey)).count == 8)
    }

    @Test
    func semanticDuplicateKeysNormalizeASRVariantsPerQuestion() {
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "Why might a diffusion based policy be more stable than an auto rig progressive policy?") ==
            SemanticDuplicateKeyBuilder.key(for: "Why might a diffusion-based policy be more stable than an autoregressive policy?")
        )
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "How would you diagnose a seem to real gap?") ==
            SemanticDuplicateKeyBuilder.key(for: "How would you diagnose a sim-to-real gap?")
        )
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "If your YOLO eight detector is wrong on the layover, how would you debug it?") ==
            SemanticDuplicateKeyBuilder.key(for: "If your YOLOv8 detector is wrong on the LeoRover, how would you debug it?")
        )
    }
}
