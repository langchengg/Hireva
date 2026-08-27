import Testing
@testable import Hireva

@Suite(.serialized)
struct DomainNeutralizationTests {
    @Test
    func intentRoutingUsesQuestionShapeInsteadOfKnownProjectNames() {
        #expect(
            IntentRouter.answerIntent(
                for: "What was your personal contribution to the event-processing service?"
            ) == .projectWalkthrough
        )
        #expect(
            IntentRouter.answerIntent(
                for: "What is the difference between the event service and the deployment service?"
            ) == .projectComparison
        )
        #expect(
            IntentRouter.answerIntent(
                for: "How would you contrast the analytics initiative with the incident-response initiative?"
            ) == .projectComparison
        )
        #expect(
            IntentRouter.answerIntent(
                for: "How does your event-processing work complement your deployment service experience?"
            ) == .projectComparison
        )
        #expect(
            IntentRouter.answerIntent(
                for: "How does one service call another during recovery?"
            ) != .projectComparison
        )
    }

    @Test
    func compatibilityRubricRoutesGenericInterviewForms() {
        let cases: [(String, PhDQuestionIntent)] = [
            ("Before joining the service team, what background prepared you for this work?", .preMScBackground),
            ("Did you build event-processing services before, or is this area new to you?", .llmVlmExperience),
            ("Is there a plan to deliver the analytics work after evaluation?", .publicationPlan),
            ("How does your experience fit this service role?", .skillFit),
            ("What role does monitoring feedback play in the event-processing service?", .tactileRole),
            ("The analytics signal conflicts with persisted state. How should the service respond?", .tactileSlipResponse),
            ("Have you used the processing framework in practice, or is your knowledge from reading?", .tactileExperience),
            ("How would you close that skills gap during the first three months?", .tactileLearningPlan),
            ("Have you operated a physical system before?", .realRobotExperience),
            ("Describe the service architecture from ingestion through persistence and recovery.", .robotArchitecture),
            ("Were you using the framework, or calling the client library directly?", .rosControl),
            ("Which failure cases would you prioritise when evaluating that analytics method?", .graspResearch),
        ]

        for (question, expectedIntent) in cases {
            #expect(PhDInterviewRubricPolicy.intent(for: question) == expectedIntent)
            #expect(PhDInterviewRubricPolicy.rubric(for: question) != nil)
            #expect(!PhDInterviewRubricPolicy.promptGuidance(for: question).isEmpty)
        }
    }

    @Test
    func compatibilityRubricChecksGenericEvidenceAndRecoveryShape() {
        let roleQuestion = "What role does monitoring feedback play in the event-processing service?"
        let roleAnswer = "I would use monitoring feedback as an input to control recovery decisions when batch outcomes alone are insufficient."
        let responseQuestion = "The analytics signal conflicts with persisted state. How should the service respond?"
        let responseAnswer = "I would confirm the conflicting signal, stop processing safely, inspect the input, and recover through a validated fallback."
        let weakResponse = "I would handle it carefully."

        #expect(PhDInterviewRubricPolicy.evaluate(question: roleQuestion, answer: roleAnswer).passed)
        #expect(PhDInterviewRubricPolicy.evaluate(question: responseQuestion, answer: responseAnswer).passed)
        #expect(!PhDInterviewRubricPolicy.evaluate(question: responseQuestion, answer: weakResponse).passed)

        for question in [roleQuestion, responseQuestion] {
            let guidance = PhDInterviewRubricPolicy.promptGuidance(for: question).lowercased()
            for forbidden in ["pre msc", "tactile", "robot arm", "grasp", "publication", "llm", "vlm", "ros"] {
                #expect(!guidance.contains(forbidden))
            }
        }
    }

    @Test
    func domainProfilesDoNotInjectFactsOutsideSelectedEvidence() {
        for domainID in InterviewDomainID.allCases {
            let profile = InterviewDomainProfile.profile(for: domainID)
            #expect(profile.domainKnowledge.isEmpty)
            #expect(profile.honestyConstraints.contains("Do not state a personal achievement without candidate evidence."))
            #expect(profile.honestyConstraints.contains("Treat opportunity requirements as targets, not completed achievements."))
        }

        let robotics = InterviewDomainProfile.profile(for: .roboticsResearch)
        #expect(robotics.commonTerminology == ["perception", "control", "manipulation", "sensing"])
        #expect(robotics.answerQualityCriteria.contains("evidence-based claims"))
    }
}
