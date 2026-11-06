import Foundation
import Testing
@testable import Hireva

/// Actual evaluator regression from a captured synthetic revised-answer failure.
/// Scripted repair packets prove request/publication contracts, not model quality.
@MainActor
struct PracticeFirstGapFinalizationTests {
    @Test(arguments: ["en", "zh"])
    func nonemptyQuestionForCoveredCriterionIsReplacedUsingFrozenFirstGap(language: String) async throws {
        let chinese = language == "zh"
        let question = chinese ? "讲一次真实分歧、你的行动、结果，以及学到的经验。" : "Describe a real disagreement, your action, outcome and lesson."
        let setting = chinese ? "在规划会议上我们对方案意见不一致。" : "At a planning meeting we disagreed about the approach."
        let action = chinese ? "我列出两个方案的风险。" : "I listed the risks of both options."
        let lesson = chinese ? "我学到应该先明确比较标准。" : "I learned to agree the comparison criteria first."
        let answer = [setting, action, chinese ? "我们计划下周测试。" : "We plan to test next week.", lesson].joined(separator: " ")
        var task = InterviewTaskDescriptor(question: question, kind: .behavioral, language: language)
        task.apply(.init(task: .behavioral, personalEvidence: .required, basis: .candidateRecord,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-frozen-decision", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-first-gap", questionRevision: 1,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-first-gap-model", failure: nil, latencyMS: 0))
        task.criteria = ["Situation / 情境", "Personal action / 个人行动", "Result / 结果", "Reflection / 反思"]
        let attempt = PracticeAttempt(questionID: "synthetic-first-gap", question: question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: true, skipped: false, source: "synthetic-test", task: task)
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(setting), "r1": .some(action), "r2": .none, "r3": .some(lesson)],
            suggestion: chinese ? "补充实际结果。" : "Add an actual outcome.",
            followUp: chinese ? "会议的背景与争论点是什么？" : "What was the meeting's background and disagreement?",
            reason: chinese ? "只说了计划，未提供实际结果。" : "The answer gives a plan, without an observed outcome.",
            reference: InterviewQuestionDecision.missingPersonalEvidenceNotice(language: language))
        var finalized = first
        let applicationReference = try first.feedback(task: task).validated(answer: answer, task: task, evidence: []).reference
        // The model leaves the source-limited wire field empty; the
        // application supplies its canonical notice after admission.
        finalized.reference = ""
        finalized.followUp = chinese ? "分歧之后实际发生了什么，或者目前还没有结果？" : "What actually happened after the disagreement, or has no outcome happened yet?"
        finalized.reviewOutcome = "accepted"
        let provider = FirstGapFinalizationTransport(outputs: [try wire(first), try wire(finalized)])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-first-gap-model")
        #expect(feedback.followUp == finalized.followUp)
        #expect(feedback.reference == applicationReference)
        #expect(feedback.covered.map(\.quote) == [setting, action, lesson])
        #expect(feedback.missing == [task.criteria[2]])
        let requests = await provider.requests
        #expect(requests.count == 2)
        let finalRequest = try #require(requests.last)
        let input = try JSONDecoder().decode([String: String].self, from: Data(finalRequest.prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil)
        #expect(input["draft_first_missing_rubric_criterion"] == nil)
        #expect(input["rubric"] == task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        // The fresh reviewer receives the complete original inputs, not an
        // earlier map or derived gap. Its declared final assessment owns r2.
        #expect(input["draft_feedback"] == nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(finalRequest.responseSchema))) as? [String: Any]
        let fields = try #require(object?["properties"] as? [String: [String: Any]])
        #expect(fields["reference"]?["const"] as? String == "")
        #expect((fields["followUp"]?["description"] as? String)?.contains("else if assessments.r2.fulfillment != \"met\": target r2: \(task.criteria[2])") == true)
        #expect(input["question"] == question && input["answer"] == answer)
        #expect(input["previous_invalid_output"] == nil)
        #expect(requests.allSatisfy { $0.modelName == "synthetic-first-gap-model" && $0.numPredict == 1200 })
    }

    private func wire(_ value: PracticeEvaluationPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private actor FirstGapFinalizationTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-first-gap-finalization"
    nonisolated let displayName = "Synthetic first-gap finalization"
    let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra finalization request.") }
        return AsyncThrowingStream { c in
            c.yield(.init(text: outputs[index], source: .localQwen, modelName: request.modelName))
            c.finish()
        }
    }
}
