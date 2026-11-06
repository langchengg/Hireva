import Foundation
import Testing
@testable import Hireva

/// Actual evaluator contracts. First packet below is a captured synthetic-model
/// failure; repaired packets are scripted, not a real-model quality verdict.
@Suite
@MainActor
struct PracticeFeedbackRepairConsistencyTests {
    @Test
    func finalRepairCanCorrectProseWhilePreservingQuotesAndReference() async throws {
        let task = resolvedTask(question: "Explain cancellation and stale publication.")
        var customTask = task
        customTask.criteria = ["Explain cancellation", "Explain the identity check"]
        let attempt = makeAttempt(task: customTask, answer: "Cancellation requests resource cleanup.")
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(attempt.answer), "r1": .none],
            suggestion: "Explain cancellation before discussing publication.", followUp: nil,
            reason: "The answer does not explain cancellation.", reference: "Check request identity before publishing a result.")
        var repaired = first
        repaired.reason = "The answer explains cancellation; the request identity check is missing."
        repaired.suggestion = "Explain which identity must match before publishing a result."
        repaired.followUp = "Which identity check prevents a stale result from publishing?"
        repaired.reviewOutcome = "accepted"
        let provider = ConsistencyRepairTransport(outputs: [try wire(first), try wire(repaired)])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: customTask,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-consistency-model")
        #expect(feedback.reason == repaired.reason)
        #expect(feedback.suggestions == [repaired.suggestion])
        #expect(feedback.followUp == repaired.followUp)
        #expect(feedback.covered.map(\.quote) == [attempt.answer])
        #expect(feedback.missing == [customTask.criteria[1]])
        #expect(feedback.reference == first.reference)
        #expect(await provider.requests.count == 2)
    }

    @Test
    func capturedOriginalFailureCanRepairProseWithoutInventingQuotes() async throws {
        // E2 synthetic capture F7AA8762-B5A4-48B6-925B-8D3AAFB104E4:
        // result SHA256 3702da21e3cddb5fc267e6822184db9881b9cb9cf2b729d1b9930e1f09b28f3c.
        // The original input spelling is preserved; only the final fake packet is new.
        let firstText = #"""
        {
          "followUp": "",
          "r0": "A retrieve policy repeats failed requests at most three times.",
          "r1": "",
          "r2": "",
          "r3": "",
          "reason": "The answer provides a basic definition but lacks the detailed mechanics of exponential backoff (formula, initial delay, max cap) and jitter (type, purpose) required for a 'Correct explanation'. It also fails to address assumptions (e.g., network stability) and limitations (e.g., eventual consistency risks).",
          "reference": "A retry policy with bounded attempts limits the total number of retries (e.g., N=3). Exponential backoff calculates the delay as initial_delay * (2 ^ attempt_number), often capped at a maximum value. Jitter adds a random component (e.g., uniform or random delay) to the calculated backoff to prevent thundering herd problems where multiple services retry simultaneously at the same interval."
          ,
          "suggestion": "Expand the explanation to include the mathematical formula for exponential backoff, specify the role of jitter in avoiding simultaneous retries, and discuss the trade-offs between bounded attempts and eventual consistency."
        }
        """#
        let legacy = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(firstText.utf8))
        #expect(legacy.assessments == nil)
        let capturedFields = try JSONDecoder().decode([String: String].self, from: Data(firstText.utf8))
        // This new packet is a scripted reuse; firstText and its capture hash
        // remain historical evidence with unknown assessment dimensions.
        let scriptedFirst = try scriptedPracticePacket(capturedFields, fulfilledIDs: ["r0"])
        let first = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(scriptedFirst.utf8))
        let task = resolvedTask(question: "Explain a retry policy with bounded attempts, exponential backoff and jitter.")
        let attempt = makeAttempt(task: task,
            answer: "A retrieve policy repeats failed requests at most three times. Exponential backoff doubles the delay; jitter randomizes it to spread concurrent requests.")
        var repaired = first
        repaired.followUp = "Under what conditions should a failed request be retried, and how do exponential backoff and jitter serve different purposes?"
        repaired.reason = "The answer gives a concise mechanism explanation. It does not state conditions or distinguish when each technique is appropriate, and it omits a concrete example and a limitation."
        repaired.suggestion = "State when a failure is retryable, compare the roles of backoff and jitter, then give an example and a limitation."
        repaired.reviewOutcome = "accepted"
        let provider = ConsistencyRepairTransport(outputs: [scriptedFirst, try wire(repaired)])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-consistency-model")
        #expect(feedback.covered == [.init(criterion: task.criteria[0], quote: "A retrieve policy repeats failed requests at most three times.")])
        #expect(feedback.missing == Array(task.criteria.dropFirst()))
        #expect(feedback.covered.allSatisfy { attempt.answer.contains($0.quote) })
        #expect(feedback.reference == first.reference)
        #expect(feedback.followUp == repaired.followUp)
        #expect(feedback.reason == repaired.reason)
        #expect(feedback.suggestions == [repaired.suggestion])
        let requests = await provider.requests
        #expect(requests.count == 2)
        let request = try #require(requests.last)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(request.responseSchema))) as? [String: Any]
        let fields = try #require(schema?["properties"] as? [String: [String: Any]])
        #expect(fields["reference"]?["const"] == nil)
        #expect(fields["reference"]?["type"] as? String == "string")
        let reviewInput = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        #expect(reviewInput["draft_feedback"] == nil && reviewInput["draft_first_missing_rubric_id"] == nil)
        for index in task.criteria.indices {
            #expect(fields["r\(index)"]?["type"] as? String == "string" && fields["r\(index)"]?["const"] == nil)
        }
        #expect(fields["reason"]?["const"] == nil)
        #expect(fields["suggestion"]?["const"] == nil)
        #expect(requests.allSatisfy { $0.temperature == 0 && $0.numPredict == 1200 })
        #expect(attempt.answer.contains("A retrieve policy"))
    }

    @Test
    func prosaicReviewCannotChangeASourceLimitedPersonalReference() async throws {
        var task = InterviewTaskDescriptor(question: "Describe your real action to prevent stale publication and its outcome.", kind: .behavioral, language: "en")
        task.apply(.init(task: .behavioral, personalEvidence: .required, basis: .candidateRecord,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-source-boundary", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: "synthetic-consistency-question", questionRevision: 0,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-consistency-model", failure: nil, latencyMS: 0))
        task.criteria = ["Describe personal action", "Describe the actual outcome"]
        let attempt = makeAttempt(task: task, answer: "I checked request identity before publishing a result.")
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(attempt.answer), "r1": .none],
            suggestion: "Describe any outcome observed so far.", followUp: nil,
            reason: "The outcome is missing.", reference: InterviewQuestionDecision.missingPersonalEvidenceNotice(language: "en"))
        var repaired = first
        repaired.followUp = "What outcome was actually observed, if any?"
        repaired.reference = "I led the production rollout and eliminated all stale updates."
        repaired.reviewOutcome = "accepted"
        let provider = ConsistencyRepairTransport(outputs: [try wire(first), try wire(repaired)])
        do {
            _ = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-consistency-model")
            Issue.record("A model verdict cannot replace the protected source-limited personal notice.")
        } catch { #expect(error.localizedDescription.contains("source-limited reference")) }
        #expect(await provider.requests.count == 2)
        let review = try #require(await provider.requests.last)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(review.responseSchema))) as? [String: Any]
        let fields = try #require(object?["properties"] as? [String: [String: Any]])
        let admitted = try first.semanticReviewCandidate(answer: attempt.answer, task: task, evidence: [])
        #expect(fields["reference"]?["const"] as? String == "")
        #expect(admitted.reference == PracticeFeedback.sourceLimitedReference(language: "en"))
        #expect(attempt.feedback == nil)
    }

    private func resolvedTask(question: String) -> InterviewTaskDescriptor {
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-frozen-decision",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "synthetic-consistency-question", questionRevision: 0, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-consistency-model", failure: nil, latencyMS: 0))
        return task
    }
    private func makeAttempt(task: InterviewTaskDescriptor, answer: String) -> PracticeAttempt {
        .init(questionID: "synthetic-consistency-question", question: task.question, answer: answer,
            contextSnapshotID: nil, revision: 0, hinted: false, skipped: false, source: "synthetic-test", task: task)
    }
    private func wire(_ payload: PracticeEvaluationPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

private actor ConsistencyRepairTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-consistency-repair"
    nonisolated let displayName = "Synthetic consistency repair"
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
