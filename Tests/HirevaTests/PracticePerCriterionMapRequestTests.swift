import Foundation
import Testing
@testable import Hireva

/// A scripted transport verifies the real evaluator request and exact-quote
/// boundary. It cannot establish real model semantic coverage quality.
@Suite
@MainActor
struct PracticePerCriterionMapRequestTests {
    @Test
    func emptySlotCheckExaminesTheCompleteAnswerAndPreviouslyAssignedQuotes() async throws {
        let answer = "The ledger is append-only and entries cannot be changed."
        let criteria = ["Describe how records are added", "State the modification limit"]
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: "Explain an append-only ledger and its modification limit.",
                                           kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-map-request",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: questionID, questionRevision: 1, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-map-request", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: questionID, question: task.question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: false, skipped: false,
            source: "synthetic-map-request", task: task)
        let values = ["r0": answer, "r1": answer, "followUp": "", "reason": "Both requested points are stated.",
                      "suggestion": "Keep the explanation concise.",
                      "reference": "An append-only ledger adds new records and prevents changing existing entries."]
        let wire = try scriptedPracticePacket(values, fulfilledIDs: ["r0", "r1"])
        var accepted = values
        accepted["reviewOutcome"] = "accepted" // Only this declared final review packet.
        let finalWire = try scriptedPracticePacket(accepted, fulfilledIDs: ["r0", "r1"])
        let provider = CriterionMapRequestTransport(outputs: [wire, finalWire])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-map-request")
        #expect(feedback.covered.map(\.criterion) == criteria)
        #expect(feedback.covered.map(\.quote) == [answer, answer])
        #expect(feedback.missing.isEmpty)
        #expect(feedback.followUp == nil)
        let requests = await provider.requests
        #expect(requests.count == 2)
        let request = try #require(requests.first)
        let system = try #require(request.systemPrompt)
        #expect(system.contains("First identify what the complete answer actually expresses for each supplied criterion"))
        #expect(system.contains("it is not consumed by its first assignment"))
        #expect(system.contains("After assessing every criterion, reason and suggestion must acknowledge expressed content"))
        let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        #expect(input["answer"] == answer)
        #expect(input["rubric"] == "r0: \(criteria[0])\nr1: \(criteria[1])")
        #expect(input["source_evidence"] == "")
        #expect(request.numPredict == 1200)
        #expect(request.temperature == 0)
        #expect(request.responseSchema == PracticeEvaluationPayload.schema(criteria: criteria))
        let review = try #require(requests.last)
        let reviewInput = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        #expect(reviewInput["question"] == task.question && reviewInput["answer"] == answer)
        #expect(reviewInput["rubric"] == input["rubric"] && reviewInput["source_evidence"] == "")
        #expect(reviewInput["first_missing_rubric_id"] == nil)
        #expect(reviewInput["draft_feedback"] == nil && reviewInput["draft_first_missing_rubric_id"] == nil)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(review.responseSchema))) as? [String: Any]
        let fields = try #require(schema?["properties"] as? [String: [String: Any]])
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil && fields["r1"]?["type"] as? String == "string" && fields["r1"]?["const"] == nil)
        #expect(fields["followUp"]?["type"] as? String == "string" && fields["followUp"]?["const"] == nil)
        #expect(fields["reference"]?["const"] == nil)
        #expect(review.systemPrompt?.contains("Independently critique the complete original answer") == true)
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 && $0.modelName == "synthetic-map-request" })
    }
}

private actor CriterionMapRequestTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-map-request"
    nonisolated let displayName = "Synthetic criterion map request"
    private let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected third request in the no-gap case.") }
        let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        guard input["draft_feedback"] == nil,
              (index == 0 && input["editable_output_fields"] == nil) ||
              (index == 1 && input["editable_output_fields"] != nil && input["previous_invalid_output"] == nil) else {
            throw MaterialError.invalid("Unexpected phase in the declared initial/review script.")
        }
        let text = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
