import Foundation
import Testing
@testable import Hireva

/// Current production entry-point contracts with explicit synthetic packets.
/// Neither source notices nor a scripted accepted string prove model truth.
@Suite
@MainActor
struct PracticePhaseAuthorityRequestTests {
    @Test(arguments: SourceLimitedAssessmentScenario.allCases)
    func bothPhasesSeparateSubmittedAnswerAssessmentFromPersonalReferencePermission(scenario: SourceLimitedAssessmentScenario) async throws {
        let chinese = scenario.chinese
        let first = chinese ? "我记录了各方提出的约束。" : "I wrote down the competing constraints."
        let second = chinese ? "小组同意使用这份约束清单。" : "The group agreed to use the list."
        let future = chinese ? "另一项复核计划在下周进行。" : "A separate review is scheduled next week."
        let answer = first + (scenario.withGap ? "" : " " + second) + " " + future
        let question = chinese ? "描述一次协调决定、你的行动和已观察到的结果。" : "Describe a coordination decision, your action and the observed outcome."
        let criteria = chinese ? ["个人行动", "已经观察到的结果"] : ["Personal action", "Observed outcome"]
        let language = chinese ? "zh" : "en"
        let requirement: PersonalEvidenceRequirement = scenario.uncertain ? .uncertain : .required
        let task = makeTask(question: question, kind: .behavioral, requirement: requirement,
            basis: scenario.uncertain ? .unknown : .candidateRecord, language: language, criteria: criteria)
        let attempt = makeAttempt(question: question, answer: answer, task: task)
        let canonical = sourceNotice(chinese: chinese)
        let firstReason = "PROVISIONAL_REASON: the submitted answer requires independent quote review."
        let firstSuggestion = "PROVISIONAL_SUGGESTION: check which stated criterion is missing."
        let firstWire = ["r0": first, "r1": scenario.withGap ? "" : second,
            "followUp": scenario.withGap ? (chinese ? "目前已知什么结果，如果没有，请说明尚无结果？" : "What outcome is known so far, if any, or is there no outcome yet?") : "",
            "reason": firstReason, "suggestion": firstSuggestion,
            "reference": "UNTRUSTED_PRIMARY_REFERENCE: an unconfirmed completed accomplishment."]
        let finalWire = ["r0": first, "r1": scenario.withGap ? "" : second,
            "followUp": firstWire["followUp"]!,
            "reason": scenario.withGap ? (chinese ? "行动已说明；尚未说明已观察到的结果。" : "The action is stated; an observed outcome is not stated.") : (chinese ? "两个标准均已在回答中说明。" : "Both supplied criteria are stated in the answer."),
            "suggestion": scenario.withGap ? (chinese ? "补充目前已知的结果；尚无结果也可以如实说明。" : "Add only what is known so far; it is valid to state that there is no outcome yet.") : (chinese ? "没有缺失的评价标准。" : "No rubric gap remains."),
            "reference": "", "reviewOutcome": "accepted"]
        let declaredIDs: Set<String> = scenario.withGap ? ["r0"] : ["r0", "r1"]
        let provider = PhaseAuthorityPacketProvider(packets: [
            try scriptedPracticePacket(firstWire, fulfilledIDs: declaredIDs),
            try scriptedPracticePacket(finalWire, fulfilledIDs: declaredIDs)
        ])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-authority-contract")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let inputs = try requests.map { try JSONDecoder().decode([String: String].self, from: Data($0.prompt.utf8)) }
        for (request, input) in zip(requests, inputs) {
            #expect(input["question"] == question && input["answer"] == answer)
            #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(input["assessment_basis"] == "submitted_answer_and_frozen_rubric")
            #expect(input["reference_authority"] == "application_source_notice")
            #expect(input["application_reference_notice"] == nil)
            #expect(try field("reference", in: request)["const"] == .string(""))
            #expect(request.systemPrompt?.contains("reference_authority controls ONLY the reference field") == true)
        }
        // Both phases retain frozen source restrictions; the final phase
        // receives no earlier model reference, prose or derived gap judgments.
        #expect(inputs[1]["draft_feedback"] == nil)
        #expect(inputs[1]["draft_first_missing_rubric_id"] == nil && inputs[1]["draft_first_missing_rubric_criterion"] == nil)
        #expect(!requests[1].prompt.contains(firstReason) && !requests[1].prompt.contains(firstSuggestion))
        for id in ["r0", "r1"] {
            let criterionField = try field(id, in: requests[1])
            #expect(Set(criterionField.keys) == ["type", "description"])
            #expect(criterionField["type"] == .string("string"))
            guard case .string(let description)? = criterionField["description"] else {
                Issue.record("Final criterion field has no explanatory annotation.")
                continue
            }
            #expect(!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(inputs[1]["output_schema"]).utf8)) == requests[1].responseSchema)
        #expect(feedback.covered.map(\.quote) == (scenario.withGap ? [first] : [first, second]))
        #expect(feedback.missing == (scenario.withGap ? [criteria[1]] : []))
        #expect(feedback.followUp == (scenario.withGap ? finalWire["followUp"] : nil))
        #expect(feedback.reference == canonical && feedback.reason == finalWire["reason"])
        #expect(requests.allSatisfy { $0.modelName == "synthetic-authority-contract" && $0.temperature == 0 && $0.numPredict == 1200 && !$0.thinkingEnabled })
    }

    @Test(arguments: SourceLimitedAssessmentScenario.allCases, [false, true])
    func sourceLimitedWireReferenceStaysEmptyWhileApplicationFeedbackKeepsItsNotice(scenario: SourceLimitedAssessmentScenario, noticeInAnswer: Bool) async throws {
        let chinese = scenario.chinese
        let language = chinese ? "zh" : "en"
        let first = chinese ? "我记录了各方提出的约束。" : "I wrote down the competing constraints."
        let second = chinese ? "小组同意使用这份约束清单。" : "The group agreed to use the list."
        let question = chinese ? "描述一次协调决定、你的行动和已观察到的结果。" : "Describe a coordination decision, your action and the observed outcome."
        let criteria = chinese ? ["个人行动", "已经观察到的结果"] : ["Personal action", "Observed outcome"]
        let task = makeTask(question: question, kind: .behavioral,
            requirement: scenario.uncertain ? .uncertain : .required,
            basis: scenario.uncertain ? .unknown : .candidateRecord, language: language, criteria: criteria)
        let canonical = sourceNotice(chinese: chinese)
        let answer = first + (scenario.withGap ? "" : " " + second) + (noticeInAnswer ? " " + canonical : "")
        let attempt = makeAttempt(question: question, answer: answer, task: task)
        let followUp = scenario.withGap
            ? (chinese ? "目前已知什么结果，如果没有，请说明尚无结果？" : "What outcome is known so far, if any, or is there no outcome yet?") : ""
        let primary = ["r0": first, "r1": scenario.withGap ? "" : second, "followUp": followUp,
            "reason": chinese ? "行动已经说明。" : "The action is stated.",
            "suggestion": chinese ? "仅补充尚未说明的结果。" : "Add only an unstated outcome.", "reference": ""]
        var final = primary
        final["reviewOutcome"] = "accepted"
        let fulfilledIDs: Set<String> = scenario.withGap ? ["r0"] : ["r0", "r1"]
        let provider = PhaseAuthorityPacketProvider(packets: [
            try scriptedPracticePacket(primary, fulfilledIDs: fulfilledIDs),
            try scriptedPracticePacket(final, fulfilledIDs: fulfilledIDs)
        ])
        var feedback: PracticeFeedback?
        var failure: String?
        do {
            feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-authority-contract")
        } catch { failure = error.localizedDescription }

        // Inspect the actual requests even when current admission rejects the
        // empty wire field; otherwise the model-input regression stays hidden.
        let requests = await provider.recorded()
        #expect(requests.count == 2)
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["question"] == question && input["answer"] == answer)
            #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(input["assessment_basis"] == "submitted_answer_and_frozen_rubric")
            #expect(input["reference_authority"] == "application_source_notice")
            #expect(input["application_reference_notice"] == nil)
            // Identical prose supplied by the user remains answer data. Only
            // the application-generated copies are removed from the request.
            #expect(request.prompt.contains(canonical) == noticeInAnswer)
            #expect(input.filter { $0.key != "answer" }.values.allSatisfy { !$0.contains(canonical) })
            #expect(!(request.systemPrompt ?? "").contains(canonical))
            let schema = try #require(request.responseSchema)
            let embedded = try JSONDecoder().decode(LocalJSONValue.self,
                from: Data(try #require(input["output_schema"]).utf8))
            #expect(embedded == schema)
            #expect(try field("reference", in: request)["const"] == .string(""))
            #expect(!String(decoding: try JSONEncoder().encode(schema), as: UTF8.self).contains(canonical))
            #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
        }
        #expect(failure == nil, "Fixed empty wire reference must retain application feedback: \(failure ?? "")")
        let admitted = try #require(feedback)
        #expect(admitted.reference == canonical && admitted.referenceOrigin == .applicationSourceNotice)
        #expect(admitted.covered.map(\.quote) == (scenario.withGap ? [first] : [first, second]))
        #expect(admitted.missing == (scenario.withGap ? [criteria[1]] : []))
        #expect(admitted.followUp == (scenario.withGap ? followUp : nil))
    }

    @Test(arguments: ["canonical", "arbitrary", "whitespace"], [false, true])
    func sourceLimitedNonemptyWireReferenceCannotEnterPublicationOrQuestionRepair(kind: String, missingFollowUp: Bool) async throws {
        let question = "Describe an action and what is known about its outcome."
        let quote = "I wrote down the competing constraints."
        let task = makeTask(question: question, kind: .behavioral, requirement: .required,
            basis: .candidateRecord, language: "en", criteria: ["Personal action", "Observed outcome"])
        let primary = ["r0": quote, "r1": "", "followUp": "What outcome is known so far, if any?",
            "reason": "The action is stated; no outcome is stated.",
            "suggestion": "State only the outcome known so far, if any.", "reference": ""]
        var final = primary
        final["reviewOutcome"] = "accepted"
        final["followUp"] = missingFollowUp ? "" : primary["followUp"]
        switch kind {
        case "canonical": final["reference"] = sourceNotice(chinese: false)
        case "whitespace": final["reference"] = " \n\t"
        default: final["reference"] = "An arbitrary model-authored reference."
        }
        let provider = PhaseAuthorityPacketProvider(packets: [
            try scriptedPracticePacket(primary, fulfilledIDs: ["r0"]),
            try scriptedPracticePacket(final, fulfilledIDs: ["r0"])
        ])
        do {
            _ = try await PracticeController.evaluate(
                attempt: makeAttempt(question: question, answer: quote, task: task), task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-authority-contract")
            Issue.record("A nonempty fixed wire reference cannot be normalized into accepted feedback.")
        } catch {
            #expect(error.localizedDescription.contains("source-limited reference"))
        }
        #expect(await provider.recorded().count == 2,
            "An invalid fixed reference must be rejected before the optional question-only repair.")
    }

    @Test(arguments: EditableReferenceScenario.allCases)
    func generalReferenceIsIndependentWhileSupportedPersonalDraftIsRetained(scenario: EditableReferenceScenario) async throws {
        let general = scenario == .general
        let requirement: PersonalEvidenceRequirement = general ? .notRequired : scenario == .mixedOptional ? .optional : .required
        let basis: QuestionAnswerBasis = general ? .generalKnowledge : scenario == .mixedOptional ? .mixed : .candidateRecord
        let question = general ? "Explain a finite work queue and its capacity limit." : "Explain a coordination decision and the constraints you recorded."
        let quote = general ? "A finite queue has a capacity limit." : "I wrote down the competing constraints."
        let task = makeTask(question: question, kind: general ? .generalKnowledge : .behavioral,
            requirement: requirement, basis: basis, language: "en", criteria: ["Stated explanation"])
        let source = ProfileEvidence(id: "synthetic-source", statement: quote,
            sourceDocumentID: "synthetic-document", sourceChunkID: nil, sourceSpan: quote,
            confidence: 1, evidenceType: .experience, explicitness: .userConfirmed)
        let primary = ["r0": quote, "followUp": "", "reason": "PROVISIONAL_REASON",
            "suggestion": "PROVISIONAL_SUGGESTION", "reference": "PROVISIONAL_EDITABLE_REFERENCE"]
        let final = ["r0": quote, "followUp": "", "reason": "The supplied criterion is stated.",
            "suggestion": "No rubric gap remains.",
            "reference": general ? "A finite queue bounds retained work; specify how admission behaves at capacity." : "Explain the constraints and separate known actions from any unobserved result.",
            "reviewOutcome": "accepted"]
        let provider = PhaseAuthorityPacketProvider(packets: [
            try scriptedPracticePacket(primary, fulfilledIDs: ["r0"]),
            try scriptedPracticePacket(final, fulfilledIDs: ["r0"])
        ])
        let feedback = try await PracticeController.evaluate(attempt: makeAttempt(question: question, answer: quote, task: task),
            task: task, attachment: nil, evidence: [source], provider: provider, model: "synthetic-authority-contract")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["application_reference_notice"] == nil && input["reference_authority"] == nil && input["assessment_basis"] == nil)
            #expect(input["source_evidence"] == (general ? "" : source.statementForPrompt))
            #expect(try field("reference", in: request)["const"] == nil)
        }
        let finalInput = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(finalInput["draft_feedback"] == nil && finalInput["draft_first_missing_rubric_id"] == nil)
        #expect(!requests[1].prompt.contains("PROVISIONAL_EDITABLE_REFERENCE"))
        #expect(feedback.reference == final["reference"] && feedback.covered.map(\.quote) == [quote])
    }

    @Test(arguments: PhaseAuthorityFailure.allCases)
    func sourceNoticeCannotCreateAReviewDispositionOrBypassExactFrozenFields(failure: PhaseAuthorityFailure) async throws {
        let question = "Describe a coordination decision and what is known about its outcome."
        let quote = "I wrote down the competing constraints."
        let task = makeTask(question: question, kind: .behavioral, requirement: .required,
            basis: .candidateRecord, language: "en", criteria: ["Personal action", "Observed outcome"])
        let primary = ["r0": quote, "r1": "", "followUp": "What outcome is known so far, if any?",
            "reason": "The action is stated; the outcome is not stated.",
            "suggestion": "State the known outcome, or that there is no outcome yet.", "reference": ""]
        var final = try JSONDecoder().decode(PracticeEvaluationPayload.self, from:
            Data(try scriptedPracticePacket(primary, fulfilledIDs: ["r0"]).utf8))
        final.reviewOutcome = "accepted"
        switch failure {
        case .rejected: final.reviewOutcome = "rejected"
        case .missingDisposition: final.reviewOutcome = nil
        case .foreignRevisionQuote: final.coverage["r0"] = .some("I completed the subsequent review in a later answer.")
        case .unsupportedQuote: final.coverage["r0"] = .some("I completed the planned review.")
        case .changedNotice: final.reference = "I completed the planned review and achieved an unreported result."
        }
        let provider = PhaseAuthorityPacketProvider(packets: [
            try scriptedPracticePacket(primary, fulfilledIDs: ["r0"]),
            String(decoding: try JSONEncoder().encode(final), as: UTF8.self)
        ])
        do {
            _ = try await PracticeController.evaluate(attempt: makeAttempt(question: question, answer: quote, task: task),
                task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-authority-contract")
            Issue.record("An application source restriction must not convert rejected/unverified/mutated feedback into acceptance.")
        } catch {
            switch failure {
            case .rejected, .missingDisposition: #expect(error.localizedDescription.contains("Semantic review rejected"))
            case .foreignRevisionQuote: #expect(error.localizedDescription.contains("quote/rubric"))
            case .changedNotice: #expect(error.localizedDescription.contains("source-limited reference"))
            case .unsupportedQuote: #expect(error.localizedDescription.contains("quote/rubric"))
            }
        }
        #expect(await provider.recorded().count == 2)
    }

    @Test
    func invalidPrimaryStillGetsFreshReviewWithTheFrozenSourceNotice() async throws {
        let question = "Describe a coordination decision and what is known about its outcome."
        let quote = "I wrote down the competing constraints."
        let task = makeTask(question: question, kind: .behavioral, requirement: .required,
            basis: .candidateRecord, language: "en", criteria: ["Personal action", "Observed outcome"])
        let canonical = sourceNotice(chinese: false)
        let final = ["r0": quote, "r1": "", "followUp": "What outcome is known so far, if any?",
            "reason": "The action is stated; an outcome is not stated.",
            "suggestion": "State the known outcome, or that there is no outcome yet.",
            "reference": "", "reviewOutcome": "accepted"]
        let declaredFinal = try scriptedPracticePacket(final, fulfilledIDs: ["r0"])
        var malformed = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(declaredFinal.utf8))
        malformed.removeValue(forKey: "reason")
        malformed.removeValue(forKey: "reviewOutcome")
        let provider = PhaseAuthorityPacketProvider(packets: [
            String(decoding: try JSONEncoder().encode(malformed), as: UTF8.self), declaredFinal
        ])
        let feedback = try await PracticeController.evaluate(attempt: makeAttempt(question: question, answer: quote, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-authority-contract")
        #expect(feedback.reference == canonical && feedback.referenceOrigin == .applicationSourceNotice)
        #expect(feedback.covered.map(\.quote) == [quote] && feedback.missing == [task.criteria[1]])
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["application_reference_notice"] == nil)
            #expect(try field("reference", in: request)["const"] == .string(""))
        }
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(input["draft_feedback"] == nil && input["previous_invalid_output"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8)) == requests[1].responseSchema)
        #expect(requests[1].systemPrompt?.contains("Independently critique the complete original answer") == true)
    }

    private func makeTask(question: String, kind: InterviewTaskKind, requirement: PersonalEvidenceRequirement,
                          basis: QuestionAnswerBasis, language: String, criteria: [String]) -> InterviewTaskDescriptor {
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: requirement, basis: basis,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil,
            parentAnswerText: nil, source: "phase-authority-contract", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-authority", questionRevision: 3,
            contextSnapshotID: "synthetic-context", artifactRevision: 0, model: "synthetic-authority-contract",
            failure: nil, latencyMS: 0))
        task.criteria = criteria
        return task
    }
    private func makeAttempt(question: String, answer: String, task: InterviewTaskDescriptor) -> PracticeAttempt {
        .init(questionID: "synthetic-authority", question: question, answer: answer,
            contextSnapshotID: "synthetic-context", revision: 3, hinted: false, skipped: false,
            source: "synthetic-contract", task: task)
    }
    private func field(_ name: String, in request: LocalLLMRequest) throws -> [String: LocalJSONValue] {
        guard case .object(let schema)? = request.responseSchema,
              case .object(let fields)? = schema["properties"],
              case .object(let field)? = fields[name] else {
            throw MaterialError.invalid("Actual request has no expected field contract.")
        }
        return field
    }
    private func sourceNotice(chinese: Bool) -> String {
        chinese
            ? "个人参考答案暂不可生成：请提供并确认相关事实。可继续练习；按评价标准补充真实经历，缺失结果或数字留空。"
            : "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
    }
}

enum SourceLimitedAssessmentScenario: String, CaseIterable, Sendable {
    case requiredGapEN, requiredCompleteEN, requiredGapZH, requiredCompleteZH
    case uncertainGapEN, uncertainCompleteEN, uncertainGapZH, uncertainCompleteZH
    var chinese: Bool { rawValue.hasSuffix("ZH") }
    var withGap: Bool { rawValue.contains("Gap") }
    var uncertain: Bool { rawValue.hasPrefix("uncertain") }
}
enum EditableReferenceScenario: CaseIterable, Sendable { case general, personalSupported, mixedOptional }
enum PhaseAuthorityFailure: CaseIterable, Sendable { case rejected, missingDisposition, foreignRevisionQuote, unsupportedQuote, changedNotice }

private actor PhaseAuthorityPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-phase-authority"
    nonisolated let displayName = "Explicit synthetic authority packets"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra assessment request.") }
        // Disposition is an explicit adversarial/success packet. It is never
        // inferred from whether a transport schema contains reviewOutcome.
        let wire = packets[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: wire, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
