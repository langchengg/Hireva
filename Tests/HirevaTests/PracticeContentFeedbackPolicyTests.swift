import Foundation
import Testing
@testable import Hireva

/// Actual evaluator request and wire contracts. Scripted feedback does not
/// prove that a real model recognizes coverage or produces a targeted question.
@Suite
@MainActor
struct PracticeContentFeedbackPolicyTests {
    @Test(arguments: [0, 1, 2])
    func contentAnywhereCanUseTheSameExactQuoteForDifferentCriteria(_ layout: Int) async throws {
        let quote = "A lookup uses a stored result, but the entry can be stale."
        let answers = [quote, "An introductory sentence. \(quote) A final sentence.",
                       "Mechanism and limitation:\n\(quote)"]
        let (attempt, task) = fixture(question: "Explain a stored lookup and a limitation.",
            answer: answers[layout], kind: .generalKnowledge, language: "en",
            criteria: ["Explain the lookup mechanism", "State a limitation"])
        let declared = ["r0": quote, "r1": quote, "suggestion": "Keep the stated distinction.",
                      "followUp": "", "reason": "Both supplied criteria are covered.",
                      "reference": "A stored lookup reuses a result but can return a stale entry."]
        let values = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try scriptedPracticePacket(declared, fulfilledIDs: ["r0", "r1"]).utf8))
        var reviewed = values
        reviewed["reviewOutcome"] = .string("accepted")
        let provider = ContentFeedbackTransport(steps: [.text(try wire(values)), .text(try wire(reviewed))])
        let feedback = try await evaluate(attempt, task, provider)
        #expect(feedback.covered.map(\.quote) == [quote, quote])
        #expect(feedback.covered.map(\.criterion) == task.criteria)
        #expect(feedback.missing.isEmpty)
        #expect(feedback.followUp == nil)
        let requests = await provider.requests
        #expect(requests.count == 2)
        let review = try #require(requests.last)
        let reviewInput = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        #expect(reviewInput["draft_feedback"] == nil && reviewInput["draft_first_missing_rubric_id"] == nil)
        #expect(reviewInput["question"] == task.question && reviewInput["answer"] == attempt.answer)
        let reviewFields = try schemaFields(review)
        #expect(reviewFields["r0"]?["type"] as? String == "string" && reviewFields["r0"]?["const"] == nil && reviewFields["r1"]?["type"] as? String == "string" && reviewFields["r1"]?["const"] == nil)
        #expect(reviewFields["followUp"]?["type"] as? String == "string" && reviewFields["followUp"]?["const"] == nil)
        #expect(reviewFields["reference"]?["const"] == nil)
        let system = try #require(requests.first?.systemPrompt)
        assertContentPolicy(system)
        #expect(requests.first?.numPredict == 1200)
        #expect(requests.first?.temperature == 0)
    }

    @Test(arguments: ["r1", "reason"])
    func anOmittedPrimaryFieldDoesNotManufactureTheFreshReviewGap(_ omitted: String) async throws {
        let quote = "A lookup uses a stored result, but the entry can be stale."
        let (attempt, task) = fixture(question: "Explain a stored lookup and a limitation.",
            answer: quote, kind: .generalKnowledge, language: "en",
            criteria: ["Explain the lookup mechanism", "State a limitation"])
        let declared = ["r0": quote, "r1": quote, "suggestion": "Keep both points.",
                        "followUp": "", "reason": "Both criteria are covered.",
                        "reference": "A stored lookup reuses a result but can return a stale entry."]
        let complete = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try scriptedPracticePacket(declared, fulfilledIDs: ["r0", "r1"]).utf8))
        var incomplete = complete
        incomplete.removeValue(forKey: omitted)
        let incompleteText = try wire(incomplete)
        var reviewed = complete
        reviewed["reviewOutcome"] = .string("accepted")
        let provider = ContentFeedbackTransport(steps: [.text(incompleteText), .text(try wire(reviewed))])
        let structurallyValid = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(try wire(complete).utf8))
            .feedback(task: task).validated(answer: attempt.answer, task: task, evidence: [])
        #expect(structurallyValid.covered.map(\.quote) == [quote, quote] && structurallyValid.missing.isEmpty)
        let feedback = try await evaluate(attempt, task, provider)
        #expect(feedback.covered == structurallyValid.covered && feedback.missing.isEmpty)
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(attempt.feedback == nil)
        let repair = try #require(requests.last)
        let input = try JSONDecoder().decode([String: String].self, from: Data(repair.prompt.utf8))
        #expect(input["rubric"] != nil)
        #expect(input["previous_invalid_output"] == nil)
        #expect(input["first_missing_rubric_id"] == nil)
        #expect(input["first_missing_rubric_criterion"] == nil)
        #expect(input["draft_feedback"] == nil)
        let fields = try schemaFields(repair)
        #expect(fields["r0"]?["const"] == nil)
        #expect(fields["reference"]?["const"] == nil)
        let system = try #require(repair.systemPrompt)
        #expect(system.contains("Independently critique the complete original answer"))
        #expect(system.contains("from anywhere in the complete answer"))
        #expect(system.contains("A quote can be reused for different criteria if relevant"))
        #expect(system.contains("Do not add unspecified mechanisms, metrics, format or experience requirements"))
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8)) == repair.responseSchema)
        #expect(requests.allSatisfy { $0.modelName == "synthetic-content-feedback" && $0.numPredict == 1200 && $0.temperature == 0 })
    }

    @Test(arguments: ["r1", "reason"])
    func repeatedRequiredFieldOmissionStillFailsAfterExactlyTwoRequests(_ omitted: String) async throws {
        let quote = "A lookup uses a stored result, but the entry can be stale."
        let (attempt, task) = fixture(question: "Explain a stored lookup and a limitation.",
            answer: quote, kind: .generalKnowledge, language: "en",
            criteria: ["Explain the lookup mechanism", "State a limitation"])
        let declared = ["r0": quote, "r1": quote, "suggestion": "Keep both points.",
                      "followUp": "", "reason": "Both criteria are covered.",
                      "reference": "A stored lookup reuses a result but can return a stale entry."]
        var values = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try scriptedPracticePacket(declared, fulfilledIDs: ["r0", "r1"]).utf8))
        values.removeValue(forKey: omitted)
        let text = try wire(values)
        let provider = ContentFeedbackTransport(steps: [.text(text), .text(text)])
        do {
            _ = try await evaluate(attempt, task, provider)
            Issue.record("Missing required evaluation fields must not become accepted feedback.")
        } catch { #expect(!(error is CancellationError)) }
        #expect(await provider.requests.count == 2)
    }

    @Test(arguments: ["en", "zh"])
    func focusedFeedbackAddressesCandidateAndDoesNotPresumeAPlanWasCompleted(_ language: String) async throws {
        let chinese = language == "zh"
        let situation = chinese ? "我们对演示顺序有分歧。" : "We disagreed about the demo order."
        let action = chinese ? "我把两种顺序列在白板上。" : "I listed both orders on a board."
        let plan = chinese ? "我计划下周测试演示顺序。" : "I plan to test the demo order next week."
        let criteria = chinese ? ["情境", "个人行动", "实际结果", "反思"] : ["Situation", "Personal action", "Observed result", "Reflection"]
        let (attempt, task) = fixture(question: chinese ? "讲一次真实的团队分歧，你做了什么，结果和反思是什么？" : "Describe a real team disagreement, your actions, outcome and reflection.",
            answer: "\(situation) \(action) \(plan)", kind: .behavioral, language: language, criteria: criteria)
        let initial = ["r0": situation, "r1": action, "r2": "", "r3": "",
                       "suggestion": "Preserve the frozen map and reference.",
                       "followUp": "Does the answer include an actual result?",
                       "reason": "The observed outcome is absent.",
                       "reference": "Describe the observed outcome without inventing a result."]
        let followUp = chinese ? "目前实际观察到了什么，还是尚未有结果？" : "What have you actually observed so far, or is there no outcome yet?"
        let reason = chinese ? "回答描述了分歧和行动，但没有说明实际结果。" : "You describe the disagreement and action but no observed outcome."
        let suggestion = chinese ? "补充目前已有的实际观察；如果尚无结果，直接说明。" : "Add any outcome observed so far, or state that there is none yet."
        var final = initial
        final["followUp"] = followUp
        final["reason"] = reason
        final["suggestion"] = suggestion
        final["reference"] = ""
        final["reviewOutcome"] = "accepted"
        let provider = ContentFeedbackTransport(steps: [
            .text(try scriptedPracticePacket(initial, fulfilledIDs: ["r0", "r1"])),
            .text(try scriptedPracticePacket(final, fulfilledIDs: ["r0", "r1"]))])
        let feedback = try await evaluate(attempt, task, provider)
        let requests = await provider.requests
        #expect(requests.count == 2)
        let repair = try #require(requests.last)
        let input = try JSONDecoder().decode([String: String].self, from: Data(repair.prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil)
        #expect(input["draft_first_missing_rubric_criterion"] == nil)
        #expect(input["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(input["draft_feedback"] == nil)
        #expect(input["question"] == attempt.question && input["answer"] == attempt.answer)
        #expect(feedback.assessments?.map(\.judgment.fulfillment) == [.met, .met, .unmet, .unmet])
        #expect(input["previous_invalid_output"] == nil)
        #expect(input["source_evidence"] == "")
        let fields = try schemaFields(repair)
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil)
        #expect(fields["r1"]?["type"] as? String == "string" && fields["r1"]?["const"] == nil)
        #expect(fields["r2"]?["type"] as? String == "string" && fields["r2"]?["const"] == nil)
        #expect(fields["r3"]?["type"] as? String == "string" && fields["r3"]?["const"] == nil)
        #expect(fields["reference"]?["const"] as? String == "")
        #expect(feedback.reference == PracticeFeedback.sourceLimitedReference(language: language))
        #expect(feedback.reference != initial["reference"])
        #expect(feedback.covered.map(\.quote) == [situation, action])
        #expect(feedback.missing == Array(criteria.dropFirst(2)))
        #expect(feedback.followUp == followUp)
        #expect(feedback.reason == reason)
        #expect(feedback.suggestions == [suggestion])
        let system = try #require(repair.systemPrompt)
        #expect(system.contains("reason and suggestion summarize only the final criterion assessments"))
        #expect(system.contains("not schema or review mechanics"))
        #expect(system.contains("Match the original question's temporal scope"))
        #expect(system.contains("without repeating already answered content or combining later gaps"))
        #expect(system.contains("For an unresolved past outcome, allow no outcome yet"))
        #expect(system.contains("never presuppose a stated future activity already happened"))
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_first_missing_rubric_criterion"] == nil)
        #expect(requests.allSatisfy { $0.modelName == "synthetic-content-feedback" && $0.numPredict == 1200 && $0.temperature == 0 })
    }

    private func assertContentPolicy(_ system: String) {
        #expect(system.contains("substantive content anywhere in the answer, not its layout"))
        #expect(system.contains("Headings, separate paragraphs, a distinct category or a separate sentence are not required"))
        #expect(system.contains("A quote may support multiple criteria"))
    }
    private func fixture(question: String, answer: String, kind: InterviewTaskKind, language: String,
                         criteria: [String]) -> (PracticeAttempt, InterviewTaskDescriptor) {
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(InterviewQuestionDecision(task: kind, personalEvidence: kind == .behavioral ? .required : .notRequired,
            basis: kind == .behavioral ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-frozen-decision", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: questionID, questionRevision: 2,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-content-feedback", failure: nil, latencyMS: 0))
        task.criteria = criteria
        return (PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task), task)
    }
    private func evaluate(_ attempt: PracticeAttempt, _ task: InterviewTaskDescriptor,
                          _ provider: ContentFeedbackTransport) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-content-feedback")
    }
    private func wire(_ values: [String: LocalJSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
    private func schemaFields(_ request: LocalLLMRequest) throws -> [String: [String: Any]] {
        let schema = try #require(request.responseSchema)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        let fields = (object as? [String: Any])?["properties"] as? [String: [String: Any]]
        return try #require(fields)
    }
}

private actor ContentFeedbackTransport: LocalLLMProvider {
    enum Step: Sendable {
        case text(String)
    }
    nonisolated let id = "synthetic-content-feedback"
    nonisolated let displayName = "Synthetic content feedback"
    let steps: [Step]
    private(set) var requests: [LocalLLMRequest] = []
    init(steps: [Step]) { self.steps = steps }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < steps.count else { throw MaterialError.invalid("Unexpected extra evaluation request.") }
        let output: String
        switch steps[index] {
        case .text(let text): output = text

        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
