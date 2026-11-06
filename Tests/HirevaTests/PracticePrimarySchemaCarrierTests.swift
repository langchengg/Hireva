import Foundation
import Testing
@testable import Hireva

/// Scripted packets inspect the actual evaluator request and admission contract.
/// They do not prove that any model distinguishes omission from substantive support.
@Suite
@MainActor
struct PracticePrimarySchemaCarrierTests {
    @Test(arguments: Array(0..<8))
    func eachPrimaryFieldMeaningIsVisibleInFrozenInput(_ variant: Int) async throws {
        let chinese = variant & 1 != 0
        let control = variant / 2
        let language = chinese ? "zh" : "en"
        let question: String
        let criteria: [String]
        let answer: String
        let quotes: [String?]
        switch control {
        case 0:
            question = chinese ? "说明你是否已解释追加操作，然后解释追加操作。" : "State whether you have explained the append operation, then explain it."
            criteria = chinese ? ["说明是否已解释追加操作", "解释追加操作"] : ["State whether the append operation is explained", "Explain the append operation"]
            answer = chinese ? "我尚未解释追加操作。" : "I have not explained the append operation."
            // The same disclosure supports status, but supplies no explanation.
            quotes = [answer, nil]
        case 1:
            question = chinese ? "解释追加规则以及修改限制。" : "Explain the append rule and modification limit."
            criteria = chinese ? ["解释如何追加", "说明修改限制"] : ["Explain adding entries", "State the modification limit"]
            let first = chinese ? "新条目通过追加写入。" : "New entries are appended."
            let second = chinese ? "已有条目不能修改。" : "Existing entries cannot be modified."
            answer = first + " " + second; quotes = [first, second]
        case 2:
            question = chinese ? "解释追加规则以及修改限制。" : "Explain the append rule and modification limit."
            criteria = chinese ? ["解释如何追加", "说明修改限制"] : ["Explain adding entries", "State the modification limit"]
            let initial = chinese ? "我前面未解释规则。" : "I did not explain the rule earlier."
            let first = chinese ? "新条目通过追加写入。" : "New entries are appended."
            let second = chinese ? "已有条目不能修改。" : "Existing entries cannot be modified."
            answer = initial + " " + first + " " + second; quotes = [first, second]
        default:
            question = chinese ? "解释持久化确认边界与取舍。" : "Explain the durable acknowledgment boundary and trade-off."
            criteria = chinese ? ["解释确认前持久化", "说明定性取舍"] : ["Explain persistence before acknowledgment", "State the qualitative trade-off"]
            let first = chinese ? "先持久化已接收的工作，再确认接收。" : "Persist accepted work before acknowledging it."
            let second = chinese ? "这增加存储写入，但允许在工作进程故障后恢复。" : "This adds storage writes but permits recovery after worker failure."
            answer = first + " " + second; quotes = [first, second]
        }
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-primary-carrier",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: "synthetic-primary-carrier", questionRevision: 3,
            contextSnapshotID: "synthetic-primary-carrier-context", artifactRevision: 0,
            model: "synthetic-primary-carrier", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: "synthetic-primary-carrier", question: question,
            answer: answer, contextSnapshotID: "synthetic-primary-carrier-context", revision: 3,
            hinted: false, skipped: false, source: "synthetic-contract", task: task)
        let followUp: String? = control == 0 ? (chinese ? "追加操作如何添加新条目？" : "How does the append operation add new entries?") : nil
        let reference = chinese ? "按原问题说明追加规则、限制或定性取舍，不编造经历。" : "Explain the requested rule, limit or qualitative trade-off without inventing experience."
        let primary = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues:
            quotes.enumerated().map { ("r\($0.offset)", $0.element) }), suggestion: chinese ? "核对所述规则。" : "Check the stated rule.",
            followUp: followUp, reason: chinese ? "按所给标准判断覆盖。" : "Coverage follows the supplied criteria.", reference: reference)
        var final = primary; final.reviewOutcome = "accepted"
        let provider = PrimaryCarrierPackets(outputs: try [primary, final].map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        })
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-primary-carrier")
        #expect(feedback.covered.map(\.quote) == quotes.compactMap { $0 })
        #expect(feedback.missing == (control == 0 ? [criteria[1]] : []))
        #expect(feedback.followUp == followUp && feedback.reference == reference)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for (phase, request) in requests.enumerated() {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["question"] == question && input["answer"] == answer)
            #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            let supplied = try #require(input["output_schema"])
            let grounded = try JSONDecoder().decode(LocalJSONValue.self, from: Data(supplied.utf8))
            #expect(grounded == request.responseSchema)
            #expect(request.temperature == 0 && request.numPredict == 1200 && !request.thinkingEnabled)
            #expect(request.modelName == "synthetic-primary-carrier" && request.prompt.utf8.count <= 24000)
            #expect(request.responseSchemaPropertyOrder == ["r0", "r1", "assessments", "reason", "suggestion", "reference", "followUp"] + (phase == 0 ? [] : ["reviewOutcome"]))
        }
        let primaryInput = try JSONDecoder().decode([String: String].self, from: Data(requests[0].prompt.utf8))
        #expect(primaryInput["draft_feedback"] == nil && primaryInput["fixed_output_fields"] == nil)
        #expect(primaryInput["previous_invalid_output"] == nil)
        #expect(requests[0].systemPrompt?.contains("output_schema is the application-owned output contract") == true)
    }
}
private actor PrimaryCarrierPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-primary-carrier"
    nonisolated let displayName = "Finite primary carrier packets"
    private let outputs: [String]
    private var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count && index < 2 else { throw MaterialError.invalid("Unexpected additional primary carrier request.") }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: outputs[index], source: .localQwen, modelName: request.modelName)); continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
