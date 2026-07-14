import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct QuestionCandidatePipelineTests {
    @Test
    func pipelineAcceptsWhatIsDevelopmentAreaQuestion() throws {
        let question = "What is one area you still need to develop for this research project?"
        let candidate = try #require(QuestionCandidatePipeline.extract(from: question).first)

        #expect(candidate.text == question)
        #expect(QuestionCompletenessGate.isCompleteQuestion(question, isFinal: true))
    }

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
        let text = "c plus plus with s q l and an a p i, from N to end, with a sim to real gap"
        let canonical = ASRCanonicalizer.canonicalizeTerms(text)

        #expect(canonical.localizedCaseInsensitiveContains("C++"))
        #expect(canonical.localizedCaseInsensitiveContains("SQL"))
        #expect(canonical.localizedCaseInsensitiveContains("API"))
        #expect(canonical.localizedCaseInsensitiveContains("from end to end"))
        #expect(canonical.localizedCaseInsensitiveContains("sim-to-real"))
    }

    @Test
    func asrCanonicalizerNormalizesAdditionalRuntimeVariantsBeforeSplitting() {
        let canonical = ASRCanonicalizer.canonicalizeTerms(
            "c plus plus C plus plus with s q l S Q L and a p i A P I in an end to end and sim to real system"
        )

        #expect(canonical.components(separatedBy: "C++").count == 3)
        #expect(canonical.components(separatedBy: "SQL").count == 3)
        #expect(canonical.components(separatedBy: "API").count == 3)
        #expect(canonical.localizedCaseInsensitiveContains("end-to-end"))
        #expect(canonical.localizedCaseInsensitiveContains("sim-to-real"))
    }

    @Test
    func asrCanonicalizerNormalizesVLAProjectVariantsBeforeAndAfterSplitting() {
        let variants = [
            (spoken: "c plus plus", canonical: "C++"),
            (spoken: "s q l", canonical: "SQL"),
            (spoken: "a p i", canonical: "API"),
            (spoken: "sim to real", canonical: "sim-to-real")
        ]

        for variant in variants {
            let canonical = ASRCanonicalizer.canonicalizeTerms("Can you explain the difference between your \(variant.spoken) project and your Beacon project")
            #expect(canonical.localizedCaseInsensitiveContains("\(variant.canonical) project"))
            let candidates = QuestionCandidatePipeline.extract(from: canonical)
            #expect(candidates.first?.text == canonical)
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
            from: "If your inspection detector gives a confident but wrong prediction, how would you debug it?"
        )

        #expect(candidates.map(\.text) == [
            "If your inspection detector gives a confident but wrong prediction, how would you debug it?"
        ])
        #expect(candidates.first?.answerRelevanceIntent == .perceptionDebugging)
        #expect(!candidates.contains { $0.text.localizedCaseInsensitiveContains("would you debug it") && !$0.text.localizedCaseInsensitiveContains("inspection detector") })
        #expect(QuestionCandidatePipeline.extract(from: "would you debug it").isEmpty)
    }

    @Test
    func conditionalSplitRepairKeepsIfClauseAfterAlsoIfBoundary() {
        let transcript = "What did you learn from comparing classifier, regression, and transformer alternatives? Also, if your inspection detector gives a confident but wrong prediction, how would you debug it?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "If your inspection detector gives a confident but wrong prediction, how would you debug it?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.decoderComparison, .perceptionDebugging])
    }

    @Test
    func relatedWhatMadeFollowUpSplitsIntoSeparateCurrentQuestion() {
        let transcript = "How did your billing system connect ingestion with validation, output, and recovery behaviors? What made production execution harder than a clean test environment?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "How did your billing system connect ingestion with validation, output, and recovery behaviors?",
            "What made production execution harder than a clean test environment?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.systemIntegrationDebugging, .technicalChallenge])
    }

    @Test
    func coordinatedCompoundQuestionRemainsOneLogicalCandidate() {
        let question = "How did you diagnose the latency, and how did you prove the database change was safe?"

        let candidates = QuestionCandidatePipeline.extract(from: question)

        #expect(candidates.map(\.text) == [question])
    }

    @Test
    func unpunctuatedCoordinatedCompoundQuestionRemainsOneLogicalCandidate() {
        let question = "How did you validate the forecasting model and how did you guard against leakage?"

        let candidates = QuestionCandidatePipeline.extract(from: question)

        #expect(candidates.map(\.text) == [question])
    }

    @Test
    func prefacedWHQuestionKeepsNestedAuxiliaryTail() {
        let questions = [
            "Before you finish, which single reliability signal would you investigate first and why?",
            "Before the review ends, what customer metric would you monitor and how would you react?"
        ]

        for question in questions {
            #expect(QuestionCandidatePipeline.extract(from: question).map(\.text) == [question])
        }

        #expect(QuestionCandidatePipeline.extract(from: "Could you explain why").isEmpty)
    }

    @Test
    func whatNounPhraseWithFiniteLexicalVerbIsAccepted() {
        let questions = QuestionCandidatePipeline.extract(
            from: "What product management experience best represents how you work?",
            isFinal: true
        )

        #expect(questions.map(\.text) == ["What product management experience best represents how you work?"])
    }

    @Test
    func embeddedWhatNounPhraseStatementIsNotAccepted() {
        let questions = QuestionCandidatePipeline.extract(
            from: "I explained what product management experience best represents how our team works.",
            isFinal: true
        )

        #expect(questions.isEmpty)
    }

    @Test
    func asrPunctuatedCoordinatedQuestionRemainsOneCompoundQuestion() {
        let questions = QuestionCandidatePipeline.extract(
            from: "How did customer evidence change the roadmap? And how did you validate the resulting priority?",
            isFinal: true
        )

        #expect(questions.map(\.text) == [
            "How did customer evidence change the roadmap, and how did you validate the resulting priority?"
        ])
    }

    @Test
    func independentlyPunctuatedQuestionsRemainSeparate() {
        let questions = QuestionCandidatePipeline.extract(
            from: "What did you build? How did you validate it?",
            isFinal: true
        )

        #expect(questions.map(\.text) == ["What did you build?", "How did you validate it?"])
    }

    @Test
    func whereAuxiliaryQuestionIsAccepted() {
        let questions = QuestionCandidatePipeline.extract(
            from: "Where would you need support in this role, especially around technical delivery?",
            isFinal: true
        )

        #expect(questions.map(\.text) == [
            "Where would you need support in this role, especially around technical delivery?"
        ])
    }

    @Test
    func embeddedWhereClauseIsNotAccepted() {
        let questions = QuestionCandidatePipeline.extract(
            from: "The plan explains where you would need support during technical delivery.",
            isFinal: true
        )

        #expect(questions.isEmpty)
    }

    @Test
    func punctuatedPrefacedQuestionStillAllowsIndependentFollowUp() {
        let first = "Before you finish, which reliability signal would you inspect first?"
        let second = "Would you alert the team immediately?"

        #expect(QuestionCandidatePipeline.extract(from: "\(first) \(second)").map(\.text) == [first, second])
    }

    @Test
    func punctuatedHowDidFollowUpRemainsASeparateCandidate() {
        let first = "How did you diagnose the latency?"
        let second = "How did you prove the database change was safe?"

        let candidates = QuestionCandidatePipeline.extract(from: "\(first) \(second)")

        #expect(candidates.map(\.text) == [first, second])
    }

    @Test
    func visualDetectionActionThenWhatInformationQuestionSplitsIntoTwoCandidates() {
        let q1 = "Can you explain how your robot transformed visual detections into physical actions in the real world"
        let q2 = "What information did the robot need before it could decide where to move and what to grasp"
        let candidates = QuestionCandidatePipeline.extract(from: "\(q1) \(q2)")

        #expect(candidates.map(\.text) == [q1, q2])
        #expect(candidates.map(\.answerRelevanceIntent) == [.systemIntegrationDebugging, .systemIntegrationDebugging])
        #expect(!candidates.contains { $0.text.localizedCaseInsensitiveContains("real world what information") })
    }

    @Test
    func inlineBeforeTailInsideWhatInformationQuestionDoesNotSplit() {
        let question = "What information did the robot need before it could decide where to move and what to grasp?"

        #expect(QuestionCandidatePipeline.extract(from: question).map(\.text) == [question])
    }

    @Test
    func unseenQuestionStartFamiliesSplitAndRouteWithoutExactPhraseRules() {
        let transcript = [
            "How did event input influence the system's next control action",
            "What state did the system need to check before billing executed",
            "How did a stale event influence the system's control action",
            "When input validation failed, how did the system control output and recovery action"
        ].joined(separator: " ")

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "How did event input influence the system's next control action",
            "What state did the system need to check before billing executed",
            "How did a stale event influence the system's control action",
            "When input validation failed, how did the system control output and recovery action"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .systemIntegrationDebugging,
            .systemIntegrationDebugging,
            .systemIntegrationDebugging,
            .systemIntegrationDebugging
        ])
    }

    @Test
    func dependentTemporalClauseStaysAttachedToWhQuestionWithoutExactPhraseRule() {
        let questions = [
            "Which subsystem became least reliable when the platform moved from test into production deployment",
            "What component caused the hardest failure after the demo environment stopped matching production deployment"
        ]

        for question in questions {
            let candidates = QuestionCandidatePipeline.extract(from: question)
            #expect(candidates.map(\.text) == [question])
            #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: question).accepted)
            #expect(candidates.first?.answerRelevanceIntent != .generic)
        }
    }

    @Test
    func knownFragilityQuestionIsRegressionFixtureNotProductionSpecialCase() {
        let question = "Which part of the delivery pipeline was most fragile when moving from a clean test environment to production execution?"
        let candidates = QuestionCandidatePipeline.extract(from: question)

        #expect(candidates.map(\.text) == [question])
        #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: question).accepted)
        #expect(candidates.first?.answerRelevanceIntent != .generic)
    }

    @Test
    func longRuntimeTranscriptSplitsIntoNineIndependentQuestions() {
        let transcript = "Hi, thanks for joining. Could you tell me a little bit about yourself and what brought you into platform engineering? Could you walk me through your Atlas migration project? What was the hardest technical challenge you faced? How did you handle noisy monitoring alerts? Why did the transformer model perform better than the regression model? What would you change first if you had another month? Why do you want to join our team? How comfortable with s q l and a p i tooling would you say you are? Do you have any questions for us?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "Could you tell me a little bit about yourself and what brought you into platform engineering?",
            "Could you walk me through your Atlas migration project?",
            "What was the hardest technical challenge you faced?",
            "How did you handle noisy monitoring alerts?",
            "Why did the transformer model perform better than the regression model?",
            "What would you change first if you had another month?",
            "Why do you want to join our team?",
            "How comfortable with SQL and API tooling would you say you are?",
            "Do you have any questions for us?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .tellMeAboutYourself,
            .projectWalkthrough,
            .technicalChallenge,
            .errorHandling,
            .modelComparison,
            .improvementPlan,
            .whyRole,
            .skillComfort,
            .candidateQuestions
        ])
    }

    @Test
    func temporalAnswerClausesAreRejectedButTemporalQuestionsRemainValid() {
        let answerLikeTranscript = "The system used repeated observations and only acted when the target was stable enough"
        let temporalQuestion = "When localization failed, how did recovery behavior decide whether to retry"

        #expect(QuestionCandidatePipeline.extract(from: answerLikeTranscript).isEmpty)
        #expect(QuestionCompletenessGate.isIncompleteFragment("when the target was stable enough"))
        #expect(QuestionCompletenessGate.isCompleteQuestion(temporalQuestion, isFinal: true))
        #expect(QuestionCandidatePipeline.extract(from: temporalQuestion).map(\.text) == [temporalQuestion])
    }

    @Test
    func dependentBeforeFollowUpPreservesAntecedentContext() {
        let question = "Before the robot moved toward the object, what safety or confidence checks did it need to pass?"
        let unpunctuated = "Before the robot moved toward the object what safety or confidence checks did it need to pass"

        #expect(QuestionCandidatePipeline.extract(from: question).map(\.text) == [question])
        #expect(QuestionCandidatePipeline.extract(from: unpunctuated).map(\.text) == [
            "Before the robot moved toward the object, what safety or confidence checks did it need to pass?"
        ])
    }

    @Test
    func embeddedAuxiliaryTailStaysAttachedToLeadingWhClause() {
        let questions = [
            "Which failure cases would you prioritise first when moving that method onto the real robot?",
            "Which part of the project could I contribute to most strongly during the first year?",
            "Which failure cases would you prioritize in semantic, and geometric grasp re ranking, and how would you debug them on the real robot?"
        ]

        for question in questions {
            #expect(QuestionCandidatePipeline.extract(from: question).map(\.text) == [question])
        }
    }

    @Test
    func directCopularQuestionKeepsConnectedHowAreYouTail() {
        let text = "What is your current grasp research, and how are you evaluating semantic and geometric re-ranking?"

        let candidates = QuestionCandidatePipeline.extract(from: text, isFinal: true)

        #expect(candidates.count == 1)
        #expect(candidates.first?.text == text)
    }

    @Test
    func dependentSincePrefaceStaysAttachedToQuestion() {
        let question = "Since you have not yet worked directly with tactile hardware, how would you close that skills gap during the first six months of the PhD?"

        #expect(QuestionCandidatePipeline.extract(from: question).map(\.text) == [question])
    }

    @Test
    func beforeInterviewerPrefaceDoesNotBecomeQuestionCandidate() {
        let candidates = QuestionCandidatePipeline.extract(
            from: "Before I ask the next question, let me explain a little bit about what this role involves. We work with deployed platforms, APIs, and reliability in production. With that context, why do you want this role given your previous platform experience?"
        )

        #expect(candidates.map(\.text) == [
            "Why do you want this role given your previous platform experience?"
        ])
        #expect(candidates.first?.answerRelevanceIntent == .whyRole)
    }

    @Test
    func compoundPerceptionControlQuestionIsNotSplitAtRelatedWhyTail() {
        let question = "How did you combine perception and control, and why was that connection difficult to make reliable?"
        let candidates = QuestionCandidatePipeline.extract(from: question)

        #expect(candidates.map(\.text) == [question])
        #expect(candidates.first?.answerRelevanceIntent == .systemIntegrationDebugging)
    }

    @Test
    func realScreenshotUnpunctuatedArchitectureTranscriptCanonicalizesAndExtracts() throws {
        let candidates = QuestionCandidatePipeline.extract(
            from: "How did your billing system connect a p i input with validation output and recovery behaviors what made real world execution harder than a clean test environment and how did you mitigate those issues"
        )
        let candidate = try #require(candidates.first)

        #expect(candidates.count == 2)
        #expect(candidate.text.localizedCaseInsensitiveContains("API input"))
        #expect(candidate.text.localizedCaseInsensitiveContains("validation"))
        #expect(candidate.text.localizedCaseInsensitiveContains("output"))
        #expect(candidate.text.localizedCaseInsensitiveContains("billing"))
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
        let transcript = "How did your billing system connect API input with validation and output? What questions would you ask us about the team before accepting an offer?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "How did your billing system connect API input with validation and output?",
            "What questions would you ask us about the team before accepting an offer?"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [.systemIntegrationDebugging, .interviewerQuestions])
    }

    @Test
    func mokoAndSeemToRealCanonicalizeInFullQuestion() {
        let candidates = QuestionCandidatePipeline.extract(
            from: "How would you diagnose a sim to real gap if your policy works in simulation but fails in production?"
        )

        #expect(candidates.map(\.text) == [
            "How would you diagnose a sim-to-real gap if your policy works in simulation but fails in production?"
        ])
        #expect(candidates.first?.answerRelevanceIntent == .simToRealDebugging)
    }

    @Test
    func observedMergedBTraceExtractsFourUsefulQuestionsAndRejectsBadInterviewerFragment() {
        let transcript = "What questions would you ask us about that. Tell me about a time you had. What did you learn from comparing classifier, regression, and transformer alternatives? Tell me about a time you had to debug a system integration problem. What questions would you ask us about the team or the role before accepting an offer? How would you diagnose a sim to real gap if your policy works in simulation but fails in production?"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(!candidates.contains { $0.text == "What questions would you ask us about that" })
        #expect(candidates.map(\.text) == [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "Tell me about a time you had to debug a system integration problem",
            "What questions would you ask us about the team or the role before accepting an offer?",
            "How would you diagnose a sim-to-real gap if your policy works in simulation but fails in production?"
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
        let transcript = "What would you ask the engineering team to understand whether this role is a good fit if you had one more month to improve your Atlas system what would you improve first"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What would you ask the engineering team to understand whether this role is a good fit",
            "If you had one more month to improve your Atlas system what would you improve first"
        ])
        #expect(candidates.map(\.answerRelevanceIntent) == [
            .interviewerQuestions,
            .improvementPlan
        ])
        #expect(candidates.map(\.intent) == [
            .companyFit,
            .behavioral
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
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "How did you adapt the legacy event dataset into the new warehouse format?",
            "If the inspection detector gives a confident but wrong prediction, how would you debug it?",
            "How would you diagnose a sim to real gap if a policy works in simulation but fails in production?",
            "Can you explain the difference between the Atlas project and the Beacon project?",
            "What was the biggest technical trade-off you made between latency and accuracy?",
            "Tell me about a time you had to debug a system integration problem.",
            "What questions would you ask us about the team or the role before accepting an offer?"
        ].joined(separator: " ")

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "What did you learn from comparing classifier, regression, and transformer alternatives?",
            "How did you adapt the legacy event dataset into the new warehouse format?",
            "If the inspection detector gives a confident but wrong prediction, how would you debug it?",
            "How would you diagnose a sim-to-real gap if a policy works in simulation but fails in production?",
            "Can you explain the difference between the Atlas project and the Beacon project?",
            "What was the biggest technical trade-off you made between latency and accuracy?",
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
            SemanticDuplicateKeyBuilder.key(for: "How comfortable are you with c plus plus?") ==
            SemanticDuplicateKeyBuilder.key(for: "How comfortable are you with C++?")
        )
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "How would you diagnose a sim to real gap?") ==
            SemanticDuplicateKeyBuilder.key(for: "How would you diagnose a sim-to-real gap?")
        )
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "How did the a p i handle retries?") ==
            SemanticDuplicateKeyBuilder.key(for: "How did the API handle retries?")
        )
        #expect(
            SemanticDuplicateKeyBuilder.key(for: "Why was the auto regressive model less stable?") ==
            SemanticDuplicateKeyBuilder.key(for: "Why was the autoregressive model less stable?")
        )
    }

    @Test
    func unpunctuatedConversationalBoundaryPreservesAllNineQuestions() {
        let transcript = "Hi thanks for joining today first could you tell me a little bit about yourself and what brought you into robotics great thanks could you walk me through your Leah Rover project what was the hardest technical challenge you faced how did you handle noisy detections or localization error errors why did the diffusion decoder perform better in your Mouko evaluation what would you change first if you had another month why do you want to join our team how comfortable are you with python C and Rose two do you have any questions for us"

        let candidates = QuestionCandidatePipeline.extract(from: transcript)

        #expect(candidates.map(\.text) == [
            "Could you tell me a little bit about yourself and what brought you into robotics",
            "Could you walk me through your Leah Rover project",
            "What was the hardest technical challenge you faced",
            "How did you handle noisy detections or localization error errors",
            "Why did the diffusion decoder perform better in your Mouko evaluation",
            "What would you change first if you had another month",
            "Why do you want to join our team",
            "How comfortable are you with python C and Rose two",
            "Do you have any questions for us"
        ])
        #expect(Set(candidates.map(\.duplicateKey)).count == 9)
    }
}
