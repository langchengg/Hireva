import Foundation
import Testing
@testable import Hireva

@Suite("Practice evaluation repair", .serialized)
@MainActor
struct PracticeEvaluationRepairTests {
    @Test(arguments: ["Prevent cancelled work from publishing", "Prove the owned helper has exited"])
    func repairIdentifiesFrozenFirstMissingCriterion(_ missingCriterion: String) async throws {
        let fixture = makeAttempt(missingCriterion: missingCriterion)
        let followUp = missingCriterion == "Prevent cancelled work from publishing"
            ? "Which identity check prevents a cancelled operation from updating the UI?"
            : "What evidence would show that the owned helper process has exited?"
        let provider = PracticeRepairTransport(outputs: [
            try wire(answerQuote: fixture.attempt.answer, followUp: nil),
            try wire(answerQuote: fixture.attempt.answer, followUp: followUp, reviewOutcome: "accepted")
        ])
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "frozen-repair-model")
        let requests = await provider.requests
        #expect(requests.count == 2)
        let repair = try #require(requests.last)
        // Fresh review retains the complete rubric and answer. Its own final
        // assessment selects the gap; no earlier map or gap label is input.
        let context = try? JSONDecoder().decode([String: String].self, from: Data(repair.prompt.utf8))
        #expect(context?["draft_first_missing_rubric_id"] == nil)
        #expect(context?["draft_first_missing_rubric_criterion"] == nil)
        #expect(context?["validation_failure"] == nil)
        #expect(context?["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(context?["draft_feedback"] == nil)
        guard case .object(let schema)? = repair.responseSchema,
              case .object(let fields)? = schema["properties"],
              case .object(let followUpField)? = fields["followUp"],
              case .string(let description)? = followUpField["description"] else {
            Issue.record("Fresh review must carry the frozen first-gap field contract."); return
        }
        #expect(description.contains("else if assessments.r1.fulfillment != \"met\": target r1: \(missingCriterion)"))
        #expect(context?["question"] == fixture.attempt.question && context?["answer"] == fixture.attempt.answer)
        #expect(context?["previous_invalid_output"] == nil)
        #expect(feedback.followUp == followUp)
        #expect(feedback.missing == [missingCriterion, "Explain the remaining limitation"])
        #expect(feedback.covered.map(\.quote) == [fixture.attempt.answer])
        #expect(requests.allSatisfy { $0.modelName == "frozen-repair-model" })
        #expect(fixture.attempt.revision == 7)
    }

    @Test
    func secondMissingFollowUpStillFailsInsteadOfCreatingAQuestion() async throws {
        let fixture = makeAttempt(missingCriterion: "Prevent cancelled work from publishing")
        let invalid = try wire(answerQuote: fixture.attempt.answer, followUp: nil)
        let final = try wire(answerQuote: fixture.attempt.answer, followUp: nil, reviewOutcome: "accepted")
        let provider = PracticeRepairTransport(outputs: [invalid, final, "{\"followUp\":\"\"}"])
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: provider, model: "frozen-repair-model")
            Issue.record("A repeated missing follow-up must remain a failed evaluation.")
        } catch {
            #expect(error.localizedDescription.contains("no targeted follow-up"))
        }
        #expect(await provider.requests.count == 3)
        #expect(fixture.attempt.feedback == nil)
    }

    @Test
    func repairCannotReplaceExactQuotesWithTextAbsentFromTheAttempt() async throws {
        let fixture = makeAttempt(missingCriterion: "Prevent cancelled work from publishing")
        let provider = PracticeRepairTransport(outputs: [
            try wire(answerQuote: fixture.attempt.answer, followUp: nil),
            try wire(answerQuote: "An invented corrected answer", followUp: "Which identity check prevents stale UI updates?", reviewOutcome: "accepted")
        ])
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: provider, model: "frozen-repair-model")
            Issue.record("A targeted question cannot authorize an invented quote.")
        } catch {
            #expect(error.localizedDescription.contains("quote/rubric validation"))
        }
        #expect(await provider.requests.count == 2)
        #expect(fixture.attempt.answer == "Cancellation releases the owned task.")
        #expect(fixture.attempt.feedback == nil)
    }

    private func makeAttempt(missingCriterion: String) -> (attempt: PracticeAttempt, task: InterviewTaskDescriptor) {
        let question = "Explain how cancellation relates to resource ownership."
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-frozen-decision",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "synthetic-repair-question", questionRevision: 7, contextSnapshotID: "synthetic-repair-snapshot",
            artifactRevision: 0, model: "frozen-repair-model", failure: nil, latencyMS: 0))
        task.criteria = ["Explain cancellation", missingCriterion, "Explain the remaining limitation"]
        return (PracticeAttempt(questionID: "synthetic-repair-question", question: question,
            answer: "Cancellation releases the owned task.", contextSnapshotID: "synthetic-repair-snapshot",
            revision: 7, hinted: false, skipped: false, source: "synthetic-test", task: task), task)
    }

    private func wire(answerQuote: String, followUp: String?, reviewOutcome: String? = nil) throws -> String {
        let payload = PracticeEvaluationPayload(coverage: ["r0": .some(answerQuote), "r1": .none, "r2": .none],
            suggestion: "Address the first missing criterion.", followUp: followUp,
            reason: "The explanation does not cover both remaining criteria.", reference: "Separate task cancellation from resource cleanup.", reviewOutcome: reviewOutcome)
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

private actor PracticeRepairTransport: LocalLLMProvider {
    nonisolated let id = "practice-repair-transport"
    nonisolated let displayName = "Synthetic Practice repair transport"
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
        let index = requests.count
        requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra evaluation request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
