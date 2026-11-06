import Foundation
import Testing
@testable import Hireva

struct PersonalConditionClarificationTests {
    @Test(arguments: [
        "I would ask the hiring manager to specify the exact relocation requirement.",
        "I would ask HR whether visa sponsorship is offered without assuming a policy.",
        "I would ask the employer which notice period applies to the role.",
        "I would ask the hiring manager to specify the exact relocation requirement, such as the required duration, cost coverage, or timing, since the job description is currently vague on this point.",
        "I would clarify whether relocation is required and ask about the available support.",
        "I would clarify whether relocation is required and ask about visa support.",
        "我会向雇主了解是否要求搬迁。",
        "我会询问雇主是否提供签证支持。",
        "我会请雇主说明岗位搬迁要求。"
    ])
    func proposedEmployerQuestionsDoNotInventCandidateConditions(_ answer: String) {
        let result = AnswerClaimValidator().validate(answer: answer, candidateEvidence: [],
            opportunityEvidence: [], domainKnowledge: [])
        #expect(result.unsupportedClaims.isEmpty)
        #expect(result.supportingCandidateEvidenceIDs.isEmpty)
    }

    @Test(arguments: [
        "I can relocate immediately.",
        "I would relocate next month.",
        "I would ask for a salary of £80,000.",
        "I would ask for visa sponsorship.",
        "I would ask to relocate to London.",
        "I prefer remote work.",
        "I would ask the employer about relocation, but I will relocate next month.",
        "I would ask about visa support, and I need sponsorship.",
        "I would ask the employer about relocation, and I am ready to relocate immediately.",
        "I would ask about relocation because I need visa sponsorship.",
        "I would ask about the salary range, and I would prefer a salary of £80,000.",
        "I would ask about visa support, but I do not need sponsorship.",
        "I would ask about visa support, but I'd need sponsorship.",
        "I would ask HR what relocation support is available and request visa sponsorship.",
        "I would ask HR to clarify the visa policy and request sponsorship.",
        "I would ask HR what relocation support is available or request visa sponsorship.",
        "I would ask HR what relocation support is available and if needed request visa sponsorship.",
        "I would ask about work authorization, and I am authorized to work here.",
        "I would ask HR about relocation and need visa sponsorship.",
        "I would ask the employer about relocation then relocate next month.",
        "我偏好远程工作。",
        "我会向雇主说明签证需求。",
        "我会请雇主说明岗位搬迁要求，并申请签证支持。",
        "我会询问搬迁情况，但我可以立即搬迁。",
        "我会请招聘经理说明搬迁要求，不过我愿意下月搬迁。",
        "我会询问签证政策，但我需要雇主提供签证担保。",
        "我会询问签证政策，但我不需要签证担保。",
        "我会询问工作许可要求，但我已经拥有这里的工作许可。",
        "我会向雇主了解是否要求搬迁，然后需要签证支持。",
        "我会向雇主了解是否要求搬迁，然后搬迁。",
        "I would ask about relocation, and I confirmed the relocation support in my previous job.",
        "我会询问搬迁要求，而且我曾完成跨国搬迁。"
    ])
    func questionsCannotExemptIndependentPersonalConditions(_ answer: String) {
        let result = AnswerClaimValidator().validate(answer: answer, candidateEvidence: [],
            opportunityEvidence: [], domainKnowledge: [])
        #expect(!result.unsupportedClaims.isEmpty)
        #expect(result.supportingCandidateEvidenceIDs.isEmpty)
    }

    @Test(arguments: [
        "I'd measure the degree of parallelism before choosing the worker count.",
        "I’d measure the degree of parallelism before choosing the worker count.",
        "I would clarify relocation requirements and measure the degree of parallelism before choosing the worker count.",
        "We would relocate the cached data to another storage node."
    ])
    func technicalPlansDoNotAssertCandidateQualifications(_ answer: String) {
        let result = AnswerClaimValidator().validate(answer: answer, candidateEvidence: [],
            opportunityEvidence: [], domainKnowledge: [])
        #expect(result.unsupportedClaims.isEmpty)
    }

    @Test
    func candidateConditionsNeedTheirOwnSource() {
        for statement in ["I can relocate immediately.", "I am authorized to work here."] {
            let source = ProfileEvidence(id: "synthetic-condition", statement: statement,
                sourceDocumentID: "synthetic-source", sourceChunkID: nil, sourceSpan: statement,
                confidence: 1, evidenceType: .experience, explicitness: .explicit)
            let validator = AnswerClaimValidator()
            let supported = validator.validate(answer: statement, candidateEvidence: [source],
                opportunityEvidence: [], domainKnowledge: [])
            #expect(supported.unsupportedClaims.isEmpty)
            #expect(supported.supportingCandidateEvidenceIDs == [source.id])
            let external = validator.validate(answer: statement, candidateEvidence: [],
                opportunityEvidence: [source], domainKnowledge: [statement])
            #expect(!external.unsupportedClaims.isEmpty)
            #expect(external.supportingCandidateEvidenceIDs.isEmpty)
        }
    }

    @Test
    func localAnswerBoundaryRetainsNeutralPolicyQuestionsWithoutPersonalEvidence() {
        let question = DetectedQuestion(id: "policy-question", sessionID: "synthetic-session",
            transcriptSegmentID: nil,
            questionText: "How should an applicant clarify a relocation requirement missing from a job description?",
            intent: .salaryVisa, answerStrategy: .clarifyFirst, confidence: 1, reason: nil,
            shouldTrigger: true, questionComplete: true, modelName: "synthetic",
            promptVersion: "test", rawJSON: nil, createdAt: Date(timeIntervalSince1970: 1))
        let answer = "I would ask the hiring manager to specify whether relocation is required, which location and timing apply, and what support is offered. I would keep the policy unconfirmed until the employer responds."
        let result = LocalQwenAnswerValidationResult.validate(answer, question: question,
            interviewContextSnapshot: nil)
        #expect(result.accepted)
    }
}
