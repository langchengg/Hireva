import Foundation
import Testing
@testable import Hireva

/// Actual requests preserve the independently selected feedback language.
/// Scripted replies are protocol evidence only, not real-model language quality.
@Suite
@MainActor
struct PracticeFeedbackLanguageRequestTests {
    @Test(arguments: ["reason", "suggestion", "followUp", "reference", "personalReason"])
    func entirelyEnglishProseCannotSatisfyFrozenChineseOutputLanguage(_ field: String) throws {
        var task = InterviewTaskDescriptor(question: "解释添加条目及修改限制。", kind: .generalKnowledge, language: "zh")
        task.requiresPersonalEvidence = field == "personalReason"
        task.criteria = ["添加条目", "修改限制"]
        var feedback = PracticeFeedback(covered: [.init(criterion: task.criteria[0], quote: "New entries are appended.")],
            missing: [task.criteria[1]], suggestions: ["说明修改限制。"], followUp: "已有条目允许哪些修改？",
            reason: "已说明添加条目，尚缺修改限制。", reference: "只追加记录允许新增条目，不允许修改已有条目。")
        switch field {
        case "reason", "personalReason": feedback.reason = "The modification limit is missing."
        case "suggestion": feedback.suggestions = ["Explain the modification limit."]
        case "followUp": feedback.followUp = "What modifications are allowed?"
        default:
            task.requiresPersonalEvidence = false
            task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
                relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
                source: "synthetic-language-admission", routerVersion: InterviewQuestionRouter.version, language: "zh",
                clarification: "", questionID: "language", questionRevision: 1, contextSnapshotID: nil,
                artifactRevision: 0, model: "synthetic", failure: nil, latencyMS: 0))
            task.criteria = ["添加条目", "修改限制"]
            feedback.reference = "An append-only record adds entries without modifying existing entries."
        }
        #expect(throws: (any Error).self) {
            try feedback.validated(answer: "New entries are appended.", task: task, evidence: [])
        }
    }

    @Test(arguments: [0, 1, 2])
    func feedbackLanguageCanDifferFromQuestionWithoutTranslatingFrozenQuotes(_ option: Int) async throws {
        let questionLanguage = ["en", "en", "zh"][option]
        let selectedFeedbackLanguage: String? = [nil, "zh", "en"][option]
        let expectedFeedbackLanguage = ["en", "zh", "en"][option]
        let question = questionLanguage == "en"
            ? "Explain an append-only ledger and its modification limit."
            : "解释只追加记录账本的机制和修改限制。"
        let answer = "A ledger appends new entries."
        let criteria = ["Explain adding records / 解释如何添加记录", "Modification limit / 修改限制"]
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: questionLanguage)
        let questionID = UUID().uuidString
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-feedback-language",
            routerVersion: InterviewQuestionRouter.version, language: questionLanguage, clarification: "",
            questionID: questionID, questionRevision: 1, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-feedback-language", failure: nil, latencyMS: 0))
        task.criteria = criteria
        task.explanationLanguage = selectedFeedbackLanguage
        let attempt = PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: false, skipped: false,
            source: "synthetic-feedback-language", task: task)
        let followUp = expectedFeedbackLanguage == "en" ? "What changes are permitted to existing entries?" : "已有记录允许哪些修改？"
        let reason = expectedFeedbackLanguage == "en" ? "The answer does not explain permitted changes." : "回答没有说明允许哪些修改。"
        let suggestion = expectedFeedbackLanguage == "en" ? "Explain the permitted modifications." : "说明允许的修改。"
        let reference = questionLanguage == "en" ? "An append-only ledger adds records without changing existing entries." : "只追加账本添加新记录，而不更改已有记录。"
        let initial = ["r0": answer, "r1": "", "followUp": followUp,
                       "reason": reason, "suggestion": suggestion, "reference": reference]
        let text = try scriptedPracticePacket(initial, fulfilledIDs: ["r0"])
        let provider = LanguageRequestTransport(initial: text, followUp: followUp, reason: reason, suggestion: suggestion, reference: reference)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-feedback-language")
        #expect(feedback.covered.map(\.quote) == [answer])
        #expect(feedback.missing == [criteria[1]])
        #expect(feedback.followUp == followUp)
        #expect(feedback.reference == reference)
        let requests = await provider.requests
        #expect(requests.count == 2)
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["feedback_language"] == expectedFeedbackLanguage)
            #expect(input["reference_language"] == questionLanguage)
            let system = try #require(request.systemPrompt)
            #expect(system.contains("Output-language rule: followUp, reason and suggestion use \(expectedFeedbackLanguage); reference uses \(questionLanguage)"))
            #expect(system.contains("Rubric text and application instructions may be bilingual and do not change these output languages"))
            #expect(system.contains("Keep quoted answer substrings unchanged, including their original language"))
            #expect(request.numPredict == 1200)
            #expect(request.temperature == 0)
        }
        let repair = try #require(requests.last)
        let input = try JSONDecoder().decode([String: String].self, from: Data(repair.prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil)
        #expect(input["draft_first_missing_rubric_criterion"] == nil)
        #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(input["draft_feedback"] == nil)
        #expect(input["question"] == question && input["answer"] == answer)
        #expect(input["previous_invalid_output"] == nil)
        #expect(repair.systemPrompt?.contains("reason/suggestion remain candidate-facing") == true)
        #expect(repair.systemPrompt?.contains("not schema or review mechanics") == true)
        #expect(repair.systemPrompt?.contains("never presuppose a stated future activity already happened") == true)
    }
}

private actor LanguageRequestTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-feedback-language"
    nonisolated let displayName = "Synthetic feedback language request"
    private let initial: String
    private let followUp: String
    private let reason: String
    private let suggestion: String
    private let reference: String
    private(set) var requests: [LocalLLMRequest] = []
    init(initial: String, followUp: String, reason: String, suggestion: String, reference: String) {
        self.initial = initial; self.followUp = followUp; self.reason = reason; self.suggestion = suggestion; self.reference = reference
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
              providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        guard index < 2 else { throw MaterialError.invalid("Unexpected third evaluation request.") }
        requests.append(request)
        let output: String
        if index == 0 { output = initial }
        else {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            guard input["draft_feedback"] == nil, input["editable_output_fields"] != nil,
                  input["previous_invalid_output"] == nil else {
                throw MaterialError.invalid("The declared final language packet belongs to independent review.")
            }
            let schema = try JSONEncoder().encode(request.responseSchema)
            let object = try JSONSerialization.jsonObject(with: schema) as? [String: Any]
            guard let fields = object?["properties"] as? [String: [String: Any]] else {
                throw MaterialError.invalid("Expected the actual frozen repair schema.")
            }
            var values = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(initial.utf8))
            if let fixed = fields["reference"]?["const"] as? String { values.reference = fixed }
            else { values.reference = reference }
            values.reviewOutcome = "accepted" // Explicit second scripted packet only.
            values.followUp = followUp; values.reason = reason; values.suggestion = suggestion
            output = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
