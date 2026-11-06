import Foundation
import Testing
@testable import Hireva

/// Real evaluator request protocol only. Explicit scripted final packets do not
/// establish local-model truth, semantic review quality or completed GUI tests.
@Suite
@MainActor
struct PracticeFrozenCriticRequestTests {
    @Test(arguments: FrozenCriticScenario.allCases)
    func criticRequestPreservesFrozenConstraintsAcrossFeedbackScopes(scenario: FrozenCriticScenario) async throws {
        let chinese = scenario.chinese
        let question = scenario.personal
            ? (chinese ? "描述一次会议中你的行动，以及目前已知的结果。" : "Describe your action in a meeting and the outcome known so far.")
            : (chinese ? "解释不变量，以及拟用规则的适用范围。" : "Explain an invariant and the scope of a proposed rule.")
        let firstQuote = scenario.personal
            ? (chinese ? "我在会议中记录了不同方案。" : "I recorded the alternatives during the meeting.")
            : (chinese ? "不变量是每次允许的转换都保持的性质。" : "An invariant is a property preserved by every admitted transition.")
        let secondQuote = chinese ? "该规则仅适用于允许的转换。" : "The rule applies only to admitted transitions."
        let future = chinese ? "另一项复核计划在下周进行。" : "A separate review is planned next week."
        let answer = firstQuote + (scenario.personal ? " " + future : scenario.withGap ? "" : " " + secondQuote)
        let language = chinese ? "zh" : "en"
        let criteria = scenario.personal
            ? (chinese ? ["个人行动", "已观察结果"] : ["Personal action", "Observed outcome"])
            : (chinese ? ["解释不变量", "说明范围"] : ["Explain invariant", "State scope"])
        let kind: InterviewTaskKind = scenario.personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: scenario.personal ? .required : .notRequired,
            basis: scenario.personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-ordered-critic", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-ordered-critic", questionRevision: 2,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-ordered-critic", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: "synthetic-ordered-critic", question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let canonical = PracticeFeedback.sourceLimitedReference(language: language)
        let primary = ["r0": firstQuote, "r1": scenario.withGap ? "" : secondQuote,
            "followUp": "", "reason": "PROVISIONAL_REASON", "suggestion": "PROVISIONAL_SUGGESTION",
            "reference": scenario.personal ? "" : "An implementation name always proves the required system result."]
        let final = ["r0": firstQuote, "r1": scenario.withGap ? "" : secondQuote,
            "followUp": scenario.withGap
                ? (scenario.personal
                    ? (chinese ? "目前已知或观察到了什么结果，如果没有，可以说明尚无结果吗？" : "What outcome is known or observed so far, if any, or is there no outcome yet?")
                    : (chinese ? "拟用规则适用于哪些状态或转换？" : "Which states or transitions does the proposed rule apply to?")) : "",
            "reason": scenario.withGap ? (chinese ? "第一项已说明；第二项仍未说明。" : "The first criterion is stated; the second remains unstated.") : (chinese ? "两项均已说明。" : "Both criteria are stated."),
            "suggestion": scenario.withGap ? (chinese ? "仅补充题目要求的缺失信息。" : "Add only the missing information requested by the question.") : (chinese ? "不需要补充额外个人经历。" : "No additional personal experience is required."),
            "reference": scenario.personal ? "" : (chinese ? "定义该性质及其约束的状态或转换；适用范围取决于这些条件。" : "Define the property and the admitted states or transitions; its scope depends on those conditions."),
            "reviewOutcome": "accepted"]
        let provider = FrozenCriticPacketProvider(packets: [
            try scriptedPracticePacket(primary, fulfilledIDs: scenario.withGap ? ["r0"] : ["r0", "r1"]),
            try scriptedPracticePacket(final, fulfilledIDs: scenario.withGap ? ["r0"] : ["r0", "r1"])])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-ordered-critic")
        #expect(feedback.covered.map(\.quote) == (scenario.withGap ? [firstQuote] : [firstQuote, secondQuote]))
        #expect(feedback.missing == (scenario.withGap ? [criteria[1]] : []))
        #expect(feedback.reason == final["reason"] && feedback.reference == (scenario.personal ? canonical : final["reference"]))
        #expect(feedback.followUp == (scenario.withGap ? final["followUp"] : nil))
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let inputs = try requests.map { try JSONDecoder().decode([String: String].self, from: Data($0.prompt.utf8)) }
        for (request, input) in zip(requests, inputs) {
            #expect(input["question"] == question && input["answer"] == answer)
            #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
            #expect(request.modelName == "synthetic-ordered-critic" && request.prompt.utf8.count <= 24000)
            if scenario.personal {
                #expect(input["application_reference_notice"] == nil)
                #expect(input["assessment_basis"] == "submitted_answer_and_frozen_rubric")
                #expect(input["reference_authority"] == "application_source_notice")
            }
        }
        #expect(requests[0].responseSchema == PracticeEvaluationPayload.schema(criteria: criteria,
            sourceLimitedReference: scenario.personal ? "" : nil))
        #expect(inputs[0]["draft_feedback"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(inputs[0]["output_schema"]).utf8)) == requests[0].responseSchema)
        let reviewerInput = inputs[1]
        #expect(reviewerInput["draft_feedback"] == nil)
        #expect(reviewerInput["draft_first_missing_rubric_id"] == nil)
        #expect(reviewerInput["draft_first_missing_rubric_criterion"] == nil)
        #expect(!requests[1].prompt.contains("PROVISIONAL_REASON") && !requests[1].prompt.contains("PROVISIONAL_SUGGESTION"))
        if !scenario.personal { #expect(!requests[1].prompt.contains(try #require(primary["reference"]))) }
        let schema = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(reviewerInput["output_schema"]).utf8))
        #expect(schema == requests[1].responseSchema)
        guard case .object(let object) = schema, case .object(let fields)? = object["properties"] else {
            Issue.record("The actual reviewer must keep the existing schema."); return
        }
        for key in ["r0", "r1"] {
            guard case .object(let field)? = fields[key] else {
                Issue.record("Final quote/question fields must stay editable strings."); return
            }
            #expect(field["type"] == .string("string"))
            #expect(Set(field.keys) == Set(["type", "description"]))
            if case .string(let description)? = field["description"] { #expect(!description.isEmpty) }
            else { Issue.record("Expected a string annotation, not an output constraint.") }
        }
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (scenario.personal
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string")])))
        #expect(Set(fields.keys) == Set(["r0", "r1", "assessments", "followUp", "reason", "suggestion", "reference", "reviewOutcome"]))
        let system = try #require(requests[1].systemPrompt)
        #expect(system.contains("Independently critique the complete original answer against the frozen question, rubric, source_evidence and attachment"))
        #expect(!(try #require(requests[0].systemPrompt)).contains("Independently critique the complete original answer"))
        #expect(system.contains("they are unverified drafts, not assessment authority"))
        #expect(system.contains("never presuppose a stated future activity already happened"))
        #expect(system.contains("local mechanisms do not establish unconditional physical properties or whole-system outcomes"))
        #expect(system.contains("Acceptance is not independent fact certification"))
        if scenario.personal {
            #expect(system.contains("reference_authority controls ONLY the reference field"))
            #expect(system.contains("Missing sources cannot verify biographical truth, but do not invalidate literal answer quotes"))
        } else { #expect(system.contains("This question does not require personal history")) }
    }
}

enum FrozenCriticScenario: CaseIterable, Sendable {
    case generalCompleteEN, generalGapEN, generalCompleteZH, generalGapZH, personalFutureGapEN, personalFutureGapZH
    var chinese: Bool { self == .generalCompleteZH || self == .generalGapZH || self == .personalFutureGapZH }
    var personal: Bool { self == .personalFutureGapEN || self == .personalFutureGapZH }
    var withGap: Bool { personal || self == .generalGapEN || self == .generalGapZH }
}
private actor FrozenCriticPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-ordered-critic"
    nonisolated let displayName = "Explicit synthetic ordered critic packets"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra ordered review request.") }
        let wire = packets[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
