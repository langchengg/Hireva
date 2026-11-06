import Foundation
import Testing
@testable import Hireva

/// Captures actual router requests and identities. Scripted responses prove the
/// protocol contract; only the separate frozen local-model runs measure quality.
@Suite
struct RouterFactDependenceRequestTests {
    @Test(arguments: ["en", "zh"])
    func selfDescriptionRetainsFactDependenceIndependentlyOfTaskClassification(_ language: String) async throws {
        let question = language == "en"
            ? "Describe the skills you can currently bring to the team."
            : "说明你目前能为团队提供哪些能力。"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .motivation, evidence: .required, basis: .candidateRecord)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .required && result.usesCandidateEvidence)
    }

    @Test(arguments: ["en", "zh"])
    func prospectivePersonalPreferenceRemainsDifferentFromAProposedMethod(_ language: String) async throws {
        let question = language == "en"
            ? "Which working schedule would you personally prefer, and why?"
            : "你本人会更倾向于哪种工作时间安排，为什么？"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .arrangements, evidence: .required, basis: .candidateRecord)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .required && result.basis == .candidateRecord)
    }

    @Test(arguments: ["en", "zh"])
    func missingPastReferentDoesNotReplaceEvidenceKindWithNotRequired(_ language: String) async throws {
        let question = language == "en"
            ? "What did you personally decide during the event we mean?"
            : "所指的那次事件中，你本人当时作了什么决定？"
        let clarification = language == "en" ? "Which event is meant?" : "具体指哪次事件？"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .unknown, evidence: .required, basis: .candidateRecord, clarification: clarification)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.task == .unknown && result.personalEvidence == .required)
        #expect(result.clarification == clarification && result.relation == .independent)
        #expect(result.parentQuestionID == nil && result.parentAnswerText == nil)
    }

    @Test(arguments: ["en", "zh"])
    func externalAdverseStateStillAllowsAMethodWithoutCandidateHistory(_ language: String) async throws {
        let question = language == "en"
            ? "A greenhouse sensor reports impossible temperatures. What checks would a proposed diagnosis perform?"
            : "温室传感器报告了不合理的温度，拟定的诊断方法应检查哪些条件？"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .systemDesign, evidence: .notRequired, basis: .generalKnowledge)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .notRequired && !result.usesCandidateEvidence)
        #expect(result.basis == .generalKnowledge)
    }

    @Test(arguments: ["en", "zh"])
    func scenarioChoicesDoNotConvertAGeneralAnswerBasisToTheGeneralKnowledgeTask(_ language: String) async throws {
        let question = language == "en"
            ? "For a proposed evacuation warning service, how should its components handle delayed signals?"
            : "为拟建的疏散预警服务设计组件时，应如何处理延迟信号？"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .systemDesign, evidence: .notRequired, basis: .generalKnowledge)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.task == .systemDesign && result.basis == .generalKnowledge)
        #expect(result.personalEvidence == .notRequired && !result.usesCandidateEvidence)
    }

    @Test(arguments: ["en", "zh"])
    func scientificValidityCanUseGeneralFactsWithoutBecomingAPureConceptQuestion(_ language: String) async throws {
        let question = language == "en"
            ? "How should a proposed investigation state uncertainty when its observations are dependent?"
            : "拟开展的研究中，观测之间存在依赖时，应如何表述推断的不确定性？"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .research, evidence: .notRequired, basis: .generalKnowledge)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.task == .research && result.basis == .generalKnowledge)
        #expect(result.personalEvidence == .notRequired && !result.usesCandidateEvidence)
    }

    @Test
    func explicitlyOptionalIllustrationKeepsTheOptionalContract() async throws {
        let (input, result, requests) = try await resolve(
            question: "Explain how to compare transport plans; you may optionally illustrate with a personal example.",
            language: "en", task: .generalKnowledge, evidence: .optional, basis: .mixed)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .optional && result.basis == .mixed)
        #expect(result.usesCandidateEvidence)
    }

    @Test
    func currentFictionalArtifactNeverBecomesAnActualCandidateRecord() async throws {
        let artifact = "Fictional exercise: a caretaker found a stuck door and called the facility manager."
        let provider = FactDependenceTransport(outputs: [try wire(task: .generalKnowledge,
            evidence: .notRequired, basis: .providedArtifact)])
        let input = InterviewRoutingInput(question: "In the attached fictional exercise, what did the caretaker decide?",
            questionID: UUID().uuidString, revision: 5, contextSnapshotID: "synthetic-fiction",
            artifactRevision: 3, artifact: artifact, language: "en")
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-fact-contract")
        let request = try #require(await provider.requests.first)
        try assertRequest(request)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any])
        #expect(payload["artifact"] as? String == artifact)
        #expect(result.artifactRevision == 3 && result.questionRevision == 5)
        #expect(result.personalEvidence == .notRequired && !result.usesCandidateEvidence)
        #expect(result.modelRequests == 1 && result.modelEvidenceReviews == 0)
    }

    @Test(arguments: [
        "What notice period would you need to give before starting a new position?",
        "What notice period currently applies to you?",
        "What notice period would you need to give your employer before starting this job?",
        "Which working schedule do you personally prefer?",
        "This role has two office days each week. Would that schedule work for you?",
        "Do you need any adjustments for the next interview?",
        "Before accepting an offer, which working arrangements would you want clarified?",
        "If we offered you this job, what notice period would you need to give?",
        "If the position involved night shifts, would that schedule work for you?",
        "如果希望你下个月入职，你目前有哪些时间限制？",
        "你目前有哪些入职日期上的限制？",
        "你是否愿意搬到另一个城市工作？",
        "如果收到录用意向，你希望有多久考虑？",
        "你本人更倾向于哪种工作时间安排？"
    ])
    func explicitCurrentEmploymentFactsSurviveANegativeModelWire(_ question: String) async throws {
        let language = question.contains("你") ? "zh" : "en"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .arrangements, evidence: .notRequired, basis: .generalKnowledge)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .required && result.basis == .candidateRecord)
        #expect(result.modelPersonalEvidence == .notRequired && result.task == .arrangements)
        #expect(result.relation == .independent && result.clarification.isEmpty)
    }

    @Test(arguments: [
        "Explain notice periods and start dates in an employment contract.",
        "As the employer, how would you design a notice-period policy?",
        "Which working arrangements should any applicant clarify before accepting an offer?",
        "A fictional applicant has four weeks of notice. When could they start?",
        "Suppose you were a fictional applicant: what notice period would you need?",
        "Translate \"Would you need adjustments for the interview?\" without answering it.",
        "Which schedule would you design for the interview booking system?",
        "What notice period would you need to give in this role-play exercise?",
        "如何为通用雇佣合同设定通知期和入职流程？",
        "你会如何比较通用工作安排的优缺点？",
        "你希望如何设计工作排班系统？",
        "翻译‘你是否愿意搬到另一个城市工作’，不要回答引号中的问题。",
        "假设你扮演虚构求职者，你目前有哪些入职时间限制？",
        "If you were the employer, what notice period would you need to give staff?",
        "Which working arrangements would you need to compare to design a policy for all employees?",
        "Which working arrangements would you want to design for an external company's policy?",
        "Which working schedule would you prefer when designing a policy for all employees?",
        "你希望考虑哪些工作安排因素来制定通用排班政策？",
        "What notice period would you need to specify when drafting a generic employment contract for an employer?",
        "Would you need support staff to explain a generic employment policy?",
        "What notice period would you need to give staff when drafting a generic employment contract for an employer?",
        "When designing a generic employment policy, which working arrangements would you prefer for staff?"
    ])
    func employmentMethodsAndExerciseActorsRemainNonPersonal(_ question: String) async throws {
        let language = question.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } ? "zh" : "en"
        let (input, result, requests) = try await resolve(question: question, language: language,
            task: .arrangements, evidence: .notRequired, basis: .generalKnowledge)
        try assertCommon(input: input, result: result, requests: requests)
        #expect(result.personalEvidence == .notRequired && result.basis == .generalKnowledge)
        #expect(!result.usesCandidateEvidence)
    }

    @Test(arguments: ["optional", "artifact", "fictionalParent", "selectedTask", "overlong"])
    func currentEmploymentBoundaryPreservesExistingScopeExclusions(_ scope: String) async throws {
        let optional = scope == "optional"
        let task: InterviewTaskKind = scope == "selectedTask" ? .generalKnowledge : .arrangements
        let evidence: PersonalEvidenceRequirement = optional ? .optional : .notRequired
        let basis: QuestionAnswerBasis = optional ? .mixed : (scope == "artifact" ? .providedArtifact : .generalKnowledge)
        let provider = FactDependenceTransport(outputs: [try wire(task: task, evidence: evidence, basis: basis)])
        let input = InterviewRoutingInput(
            question: "What notice period would you need to give before starting this job?" + (scope == "overlong" ? String(repeating: " ", count: 512) : ""),
            questionID: UUID().uuidString,
            artifact: scope == "artifact" ? "Supplied exercise: you is a fictional applicant." : nil,
            previousQuestion: scope == "fictionalParent" ? "Role-play a fictional applicant discussing a job offer." : nil,
            selectedTask: scope == "selectedTask" ? .arrangements : nil, language: "en")
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-fact-contract")
        #expect(result.personalEvidence == evidence && result.basis == basis)
        #expect(result.modelPersonalEvidence == evidence && result.modelRequests == 1)
        #expect(result.modelEvidenceReviews == 0 && result.modelFormatRepairs == 0)
    }

    @Test(arguments: ["Do you need any adjustments for the interview?", "如果希望你下个月入职，你目前有哪些时间限制？"])
    func firstNegativeEmploymentWireKeepsOneRequestAndRawAudit(_ question: String) async throws {
        let provider = FactDependenceTransport(outputs: [try wire(task: .arrangements,
            evidence: .notRequired, basis: .generalKnowledge)])
        let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString),
            provider: provider, model: "synthetic-fact-contract")
        #expect(result.personalEvidence == .required && result.basis == .candidateRecord)
        #expect(result.modelPersonalEvidence == .notRequired && result.modelRequests == 1)
        #expect(result.modelEvidenceReviews == 0 && result.modelFormatRepairs == 0 && result.failure == nil)
        #expect(await provider.requests.count == 1)
    }

    private func resolve(question: String, language: String, task: InterviewTaskKind,
                         evidence: PersonalEvidenceRequirement, basis: QuestionAnswerBasis,
                         clarification: String = "") async throws -> (InterviewRoutingInput, InterviewQuestionDecision, [LocalLLMRequest]) {
        let first = try wire(task: task, evidence: .uncertain, basis: .unknown, clarification: clarification)
        let second = try wire(task: task, evidence: evidence, basis: basis)
        let provider = FactDependenceTransport(outputs: [first, second])
        let input = InterviewRoutingInput(question: question, questionID: UUID().uuidString,
            revision: 7, contextSnapshotID: "synthetic-fact-context", artifactRevision: 2, language: language)
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-fact-contract")
        return (input, result, await provider.requests)
    }

    private func assertCommon(input: InterviewRoutingInput, result: InterviewQuestionDecision,
                              requests: [LocalLLMRequest]) throws {
        try #require(requests.count == 2)
        for request in requests { try assertRequest(request) }
        #expect(requests[0].prompt == requests[1].prompt)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(requests[0].prompt.utf8)) as? [String: Any])
        #expect(payload["question"] as? String == input.question)
        #expect(payload["language"] as? String == input.language && payload["hasParent"] as? Bool == false)
        #expect(payload["artifact"] == nil && payload["previousQuestion"] == nil && payload["previousAnswer"] == nil)
        #expect(result.questionID == input.questionID && result.questionRevision == input.revision)
        #expect(result.contextSnapshotID == input.contextSnapshotID && result.artifactRevision == input.artifactRevision)
        #expect(result.language == input.language && result.model == "synthetic-fact-contract")
        #expect(result.modelRequests == 2 && result.modelEvidenceReviews == 1 && result.modelFormatRepairs == 0)
        #expect(result.failure == nil && InterviewQuestionRouter.timeoutSeconds == 8)
        let firstSystem = try #require(requests[0].systemPrompt)
        #expect(firstSystem.contains("the overall project may still be ongoing"))
        #expect(firstSystem.contains("including a new change to an owned project"))
        let factRule = try #require(firstSystem.range(of: "Determine two independent properties: the requested operation (task), and the facts a truthful answer must assert (personalEvidence/basis)."))
        let taskRules = try #require(firstSystem.range(of: "\ntask: motivation ="))
        #expect(factRule.lowerBound < taskRules.lowerBound)
        let review = try #require(requests[1].systemPrompt)
        #expect(review.contains("Frozen task="))
    }

    private func assertRequest(_ request: LocalLLMRequest) throws {
        let system = try #require(request.systemPrompt)
        #expect(system.contains("Determine two independent properties: the requested operation (task), and the facts a truthful answer must assert (personalEvidence/basis)."))
        #expect(system.contains("generalKnowledge as an answer basis does not imply generalKnowledge as the task."))
        #expect(system.contains("A proposal choice justified by the exercise's requirements is a method decision, not a report of the candidate's personal preference or history."))
        #expect(system.contains("Actual personal career or employment preferences remain personal even when phrased prospectively or conditionally."))
        #expect(system.contains("A proposed procedure or demonstration on an external/current exercise is not a report of past experience."))
        #expect(system.contains("If a personal illustration is explicitly optional, keep optional rather than required or notRequired."))
        #expect(system.contains("An unidentified event does not make an explicitly past personal answer general: retain required and clarify the referent."))
        #expect(request.temperature == 0 && request.numPredict == 260 && !request.thinkingEnabled)
        #expect(request.responseSchema == InterviewQuestionRouter.Wire.schema)
    }

    private func wire(task: InterviewTaskKind, evidence: PersonalEvidenceRequirement,
                      basis: QuestionAnswerBasis, clarification: String = "") throws -> String {
        String(decoding: try JSONEncoder().encode(InterviewQuestionRouter.Wire(task: task,
            personalEvidence: evidence, basis: basis, relation: .independent, clarification: clarification)), as: UTF8.self)
    }
}

private actor FactDependenceTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-fact-contract"
    nonisolated let displayName = "Synthetic fact contract"
    private let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected additional fact-contract request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
