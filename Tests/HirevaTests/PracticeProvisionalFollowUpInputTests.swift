import Foundation
import Testing
@testable import Hireva

/// Actual evaluate/request/admission contracts with finite transport packets.
/// Provisional question input is untrusted; scripted packets prove no model quality.
@Suite
@MainActor
struct PracticeProvisionalFollowUpInputTests {
    @Test(arguments: ProvisionalFollowUpScenario.allCases, ["en", "zh"])
    func provisionalQuestionIsExcludedWhileFinalMapOwnsPublication(scenario: ProvisionalFollowUpScenario, language: String) async throws {
        let fixture = try makeFixture(scenario: scenario, language: language)
        let provider = ProvisionalFollowUpPackets(packets: [fixture.primaryWire, fixture.finalWire])
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-provisional-followup")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(input["draft_feedback"] == nil)
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_first_missing_rubric_criterion"] == nil)
        #expect(!requests[1].prompt.contains("PROVISIONAL_REASON") && !requests[1].prompt.contains("PROVISIONAL_SUGGESTION"))
        #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
        #expect(input["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        guard case .object(let schema)? = requests[1].responseSchema,
              case .object(let fields)? = schema["properties"],
              case .object(let followUp)? = fields["followUp"] else {
            Issue.record("Independent review must have an editable followUp field."); return
        }
        #expect(followUp["type"] == .string("string") && followUp["const"] == nil && followUp["enum"] == nil)
        let fixed = try JSONDecoder().decode([String].self, from: Data(try #require(input["fixed_output_fields"]).utf8))
        #expect(!fixed.contains("followUp"))
        let finalMissing = fixture.task.criteria.enumerated().compactMap { fixture.final["r\($0.offset)"] == "" ? $0.element : nil }
        #expect(feedback.missing == finalMissing)
        #expect(feedback.covered.map(\.quote) == fixture.task.criteria.indices.compactMap {
            let quote = fixture.final["r\($0)"]; return quote == "" ? nil : quote
        })
        #expect(feedback.followUp == (finalMissing.isEmpty ? nil : fixture.final["followUp"]))
        #expect(feedback.followUp != fixture.primary["followUp"])
        #expect(requests.allSatisfy { $0.modelName == "synthetic-provisional-followup" && $0.temperature == 0 &&
            $0.numPredict == 1200 && !$0.thinkingEnabled && $0.prompt.utf8.count <= 24000 })
    }

    @Test(arguments: ["en", "zh"])
    func excludedDraftQuestionCannotRescueBlankAcceptedFinal(language: String) async throws {
        let fixture = try makeFixture(scenario: .sameGap, language: language)
        var invalid = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.finalWire.utf8))
        invalid["followUp"] = .string("")
        let provider = ProvisionalFollowUpPackets(packets: [fixture.primaryWire,
            String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self), "{\"followUp\":\"\"}"])
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-provisional-followup")
            Issue.record("A retained provisional question cannot become fallback accepted feedback.")
        } catch { #expect(error.localizedDescription.contains("no targeted follow-up")) }
        #expect(await provider.recorded().count == 3)
        #expect(fixture.attempt.feedback == nil)
    }

    private func makeFixture(scenario: ProvisionalFollowUpScenario, language: String) throws -> ProvisionalFollowUpFixture {
        let chinese = language == "zh"
        let question = chinese ? "解释队列如何接收工作，以及容量边界。" : "Explain queue admission and its capacity boundary."
        let first = chinese ? "队列接收获准的工作。" : "The queue receives admitted work."
        let second = chinese ? "达到容量时拒绝新工作。" : "At capacity, it rejects new work."
        let completeAnswer = scenario == .completeOptional || scenario == .resolvedGap
        let answer = first + (completeAnswer ? " " + second : "")
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-provisional-followup", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-provisional-followup", questionRevision: 3,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-provisional-followup", failure: nil, latencyMS: 0))
        task.criteria = chinese ? ["解释接收机制", "说明容量边界"] : ["Explain admission", "State capacity boundary"]
        let primaryQuestion = scenario == .completeOptional ? (chinese ? "可以增加示意图吗？" : "Can you add a diagram?")
            : scenario == .shiftedGap ? (chinese ? "工作如何进入队列？" : "How does work enter the queue?")
            : scenario == .blankDraftGap ? "" : (chinese ? "容量有什么限制？" : "What capacity limit applies?")
        let reference = chinese ? "说明准入规则和容量已满时的处理。" : "Describe admission and the policy at capacity."
        let primary = ["r0": scenario == .shiftedGap ? "" : first,
            "r1": scenario == .completeOptional ? second : "", "followUp": primaryQuestion,
            "reason": "PROVISIONAL_REASON", "suggestion": "PROVISIONAL_SUGGESTION", "reference": reference]
        let finalQuestion = completeAnswer ? "" : (chinese ? "容量已满时如何处理新的工作？" : "How is new work handled at capacity?")
        let final = ["r0": first, "r1": completeAnswer ? second : "", "followUp": finalQuestion,
            "reason": chinese ? (completeAnswer ? "已说明两项要求。" : "未说明容量边界。")
                : (completeAnswer ? "Both requested elements are stated." : "The capacity boundary is not stated."),
            "suggestion": chinese ? (completeAnswer ? "无需补充。" : "只补充容量边界。")
                : (completeAnswer ? "No rubric gap remains." : "State only the requested capacity boundary."),
            "reference": reference, "reviewOutcome": "accepted"]
        return .init(attempt: .init(questionID: "synthetic-provisional-followup", question: question, answer: answer,
            contextSnapshotID: nil, revision: 3, hinted: false, skipped: false, source: "synthetic-packets", task: task),
            task: task, primary: primary, final: final,
            primaryWire: try scriptedPracticePacket(primary, fulfilledIDs: scenario == .completeOptional ? ["r0", "r1"] : scenario == .shiftedGap ? [] : ["r0"]),
            finalWire: try scriptedPracticePacket(final, fulfilledIDs: completeAnswer ? ["r0", "r1"] : ["r0"]))
    }
}

enum ProvisionalFollowUpScenario: CaseIterable, Sendable { case sameGap, completeOptional, shiftedGap, resolvedGap, blankDraftGap }
private struct ProvisionalFollowUpFixture {
    let attempt: PracticeAttempt
    let task: InterviewTaskDescriptor
    let primary: [String: String]
    let final: [String: String]
    let primaryWire: String
    let finalWire: String
}
private actor ProvisionalFollowUpPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-provisional-followup"
    nonisolated let displayName = "Finite provisional question packets"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < packets.count && index < 3 else { throw MaterialError.invalid("Unexpected extra provisional question request.") }
        let text = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: text, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
