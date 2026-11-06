import Foundation
import Testing
@testable import Hireva

/// Synthetic transport contracts, not real-model or holdout quality evidence.
@Suite
@MainActor
struct PracticeFocusedRepairTests {
    @Test(arguments: ["Explain the identity check", "Explain how cleanup is observed"])
    func missingQuestionOnlyUsesFinalCallWithFrozenFields(_ gap: String) async throws {
        let (attempt, task) = fixture(gap: gap)
        let first = payload(quote: attempt.answer, followUp: nil)
        var repaired = first
        repaired.followUp = gap == "Explain the identity check"
            ? "Which identity check prevents an old result from publishing?"
            : "Which observable condition proves that the owned resources were released?"
        repaired.reviewOutcome = "accepted"
        let provider = FocusedRepairTransport(outputs: [try wire(first), try wire(repaired)])
        let result = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-frozen-model")
        let requests = await provider.requests
        #expect(requests.count == 2)
        let request = try #require(requests.last)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(request.responseSchema))) as? [String: Any]
        let fields = try #require(schema?["properties"] as? [String: [String: Any]])
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil)
        #expect(fields["r1"]?["type"] as? String == "string" && fields["r1"]?["const"] == nil)
        #expect(fields["reason"]?["type"] as? String == "string")
        #expect(fields["reason"]?["const"] == nil)
        #expect(fields["suggestion"]?["type"] as? String == "string")
        #expect(fields["suggestion"]?["const"] == nil)
        #expect(fields["reference"]?["const"] == nil)
        #expect(fields["reference"]?["type"] as? String == "string")
        #expect(result.reference == first.reference)
        #expect(fields["followUp"]?["type"] as? String == "string")
        #expect(result.followUp?.isEmpty == false)
        #expect(fields["followUp"]?["const"] == nil)
        let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil)
        #expect(input["draft_first_missing_rubric_criterion"] == nil)
        #expect(input["rubric"] == "r0: \(task.criteria[0])\nr1: \(gap)")
        #expect(input["previous_invalid_output"] == nil)
        #expect(input["draft_feedback"] == nil)
        #expect(input["question"] == attempt.question && input["answer"] == attempt.answer)
        #expect(input["source_evidence"] == "" && input["attachment"] == "")
        #expect(fields["assessments"]?["type"] as? String == "object")
        #expect(request.systemPrompt?.contains("followUp asks only for the FIRST non-met assessment's remaining gap") == true)
        #expect(result.covered.map(\.quote) == [attempt.answer])
        #expect(result.missing == [gap])
        #expect(result.followUp == repaired.followUp)
        #expect(requests.allSatisfy { $0.modelName == "synthetic-frozen-model" && $0.numPredict == 1200 && $0.temperature == 0 })
    }

    @Test
    func schemaDisobedientInventedQuoteCannotBecomeSuccessfulFeedback() async throws {
        let (attempt, task) = fixture(gap: "Explain the identity check")
        let first = payload(quote: attempt.answer, followUp: nil)
        // Declare a normal complete scripted map, then corrupt only its quote.
        var rewritten = PracticeEvaluationPayload(coverage: ["r0": .some(attempt.answer), "r1": .some(attempt.answer)],
            suggestion: first.suggestion, followUp: nil, reason: first.reason, reference: first.reference)
        rewritten.coverage["r1"] = .some("The next answer revision states an identity check.")
        rewritten.reviewOutcome = "accepted" // Adversarial verdict must not authorize a foreign-answer quote.
        let provider = FocusedRepairTransport(outputs: [try wire(first), try wire(rewritten)])
        do {
            _ = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-frozen-model")
            Issue.record("A review must not accept a quote absent from this exact answer revision.")
        } catch { #expect(error.localizedDescription.contains("quote/rubric validation")) }
        #expect(await provider.requests.count == 2)
    }

    @Test
    func invalidFirstQuoteStillRequiresDispositionOnTheFreshReview() async throws {
        let (attempt, task) = fixture(gap: "Explain the identity check")
        let first = payload(quote: "This quote does not occur in the answer.", followUp: nil)
        let repaired = payload(quote: attempt.answer, followUp: "Which identity check prevents an old result from publishing?")
        let firstWire = try wire(first)
        let provider = FocusedRepairTransport(outputs: [firstWire, try wire(repaired)])
        let structurallyValid = try repaired.feedback(task: task).validated(answer: attempt.answer, task: task, evidence: [])
        #expect(structurallyValid.covered.map(\.quote) == [attempt.answer])
        #expect(structurallyValid.followUp == repaired.followUp)
        do {
            _ = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-frozen-model")
            Issue.record("A final review cannot skip its disposition check.")
        } catch { #expect(error.localizedDescription.contains("did not verify")) }
        let request = try #require(await provider.requests.last)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(request.responseSchema))) as? [String: Any]
        let fields = try #require(schema?["properties"] as? [String: [String: Any]])
        #expect(fields["r0"]?["const"] == nil)
        let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        #expect(input["draft_feedback"] == nil && input["previous_invalid_output"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8)) == request.responseSchema)
        #expect(request.systemPrompt?.contains("Independently critique the complete original answer") == true)
        #expect(attempt.feedback == nil)
        #expect(await provider.requests.count == 2)
    }

    @Test
    func completeCoverageHasOneFinalReviewWithoutQuestionOrThirdRequest() async throws {
        let original = fixture(gap: "Explain the identity check")
        var attempt = original.0
        let task = original.1
        attempt.answer = "Cancellation requests cleanup, and the request identity check prevents old publication."
        let declared = payload(quote: attempt.answer, followUp: nil)
        var complete = PracticeEvaluationPayload(coverage: ["r0": .some(attempt.answer), "r1": .some(attempt.answer)],
            suggestion: declared.suggestion, followUp: nil, reason: declared.reason, reference: declared.reference)
        complete.reason = "Both supplied criteria are covered."
        complete.suggestion = "Keep cancellation and the identity boundary explicit."
        var reviewed = complete
        reviewed.reviewOutcome = "accepted"
        let provider = FocusedRepairTransport(outputs: [try wire(complete), try wire(reviewed)])
        let result = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-frozen-model")
        #expect(result.missing.isEmpty)
        #expect(result.followUp == nil)
        #expect(await provider.requests.count == 2)
        let review = try #require(await provider.requests.last)
        let input = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        #expect(input["draft_feedback"] == nil && input["draft_first_missing_rubric_id"] == nil)
        #expect(result.covered.map(\.quote) == [attempt.answer, attempt.answer])
    }

    private func fixture(gap: String) -> (PracticeAttempt, InterviewTaskDescriptor) {
        var task = InterviewTaskDescriptor(question: "Explain task cancellation and publication.", kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-frozen-decision",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "synthetic-focused-question", questionRevision: 3, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-frozen-model", failure: nil, latencyMS: 0))
        task.criteria = ["Explain cancellation", gap]
        return (PracticeAttempt(questionID: "synthetic-focused-question", question: task.question,
            answer: "Cancellation asks the task to release its resources.", contextSnapshotID: nil,
            revision: 3, hinted: false, skipped: false, source: "synthetic-test", task: task), task)
    }
    private func payload(quote: String, followUp: String?) -> PracticeEvaluationPayload {
        PracticeEvaluationPayload(coverage: ["r0": .some(quote), "r1": .none],
            suggestion: "Address the remaining criterion.", followUp: followUp,
            reason: "The remaining criterion is not covered.", reference: "Check identity before publication and observe resource cleanup.")
    }
    private func wire(_ payload: PracticeEvaluationPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

private actor FocusedRepairTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-focused-repair"
    nonisolated let displayName = "Synthetic focused repair"
    let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra repair request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
