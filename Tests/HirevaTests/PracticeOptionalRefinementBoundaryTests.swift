import Foundation
import Testing
@testable import Hireva

/// Real evaluator wire tests with finite packets. Scripted corrections prove
/// request/admission contracts only, never whether the model obeys the policy.
@Suite
@MainActor
struct PracticeOptionalRefinementBoundaryTests {
    @Test(arguments: [false, true])
    func criticSeparatesOptionalDraftRefinementFromRequiredRubric(withGap: Bool) async throws {
        let question = "Explain the supplied state transitions."
        let answer = withGap ? "A label was recorded." : "Allowed transitions are queued to active and active to closed."
        let criterion = "Identify allowed transitions"
        let task = task(question: question, criterion: criterion)
        let attempt = PracticeAttempt(questionID: "refinement-contract", question: question,
            answer: answer, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let quote = withGap ? "" : answer
        let first: [String: String] = ["r0": quote, "suggestion": "An optional diagram could improve presentation.",
            "followUp": withGap ? "Which state transitions are allowed?" : "Can you add a diagram?",
            "reason": withGap ? "The transitions are absent." : "The transitions are stated.",
            "reference": "Declare the allowed transitions; an optional diagram may illustrate the same transitions."]
        var final = first
        final["followUp"] = withGap ? "Which state transitions are allowed?" : ""
        final["reviewOutcome"] = "accepted"
        let provider = RefinementPackets(packets: [
            try scriptedPracticePacket(first, fulfilledIDs: withGap ? [] : ["r0"]),
            try scriptedPracticePacket(final, fulfilledIDs: withGap ? [] : ["r0"])
        ])
        let feedback = try await evaluate(attempt: attempt, task: task, provider: provider)
        #expect(feedback.missing == (withGap ? [criterion] : []))
        #expect(feedback.covered.map(\.quote) == (withGap ? [] : [answer]))
        #expect(feedback.followUp == (withGap ? final["followUp"] : nil))
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let primary = requests[0], review = requests[1]
        let prompt = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        let original = try JSONDecoder().decode([String: String].self, from: Data(primary.prompt.utf8))
        #expect(prompt["draft_feedback"] == nil && prompt["draft_first_missing_rubric_id"] == nil)
        for field in ["question", "answer", "rubric", "source_evidence", "attachment"] {
            #expect(prompt[field] == original[field])
        }
        let grounded = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(prompt["output_schema"]).utf8))
        #expect(grounded == review.responseSchema)
        #expect(primary.responseSchema == PracticeEvaluationPayload.schema(criteria: task.criteria))
        let candidate = PracticeEvaluationPayload(coverage: ["r0": withGap ? nil : answer],
            suggestion: first["suggestion"]!, followUp: nil, reason: first["reason"]!, reference: first["reference"]!)
        #expect(review.responseSchema == candidate.semanticReviewSchema(fixedReference: false, criteria: task.criteria, feedbackLanguage: task.explanationLanguage ?? task.language))
        #expect(prompt["fixed_output_fields"] == "[]")
        #expect(review.systemPrompt?.contains("Do not alter them or use another revision.") == true)
        #expect(review.systemPrompt?.contains("For hypothetical tasks assess reasoning and trade-offs, without demanding a completed personal event.") == true)
        #expect(review.systemPrompt?.contains("All-met means empty followUp.") == true)
        #expect(primary.systemPrompt?.contains("Refinement boundary:") == false)
        for request in requests {
            #expect(request.modelName == "synthetic-refinement-contract" && request.temperature == 0)
            #expect(request.numPredict == 1200 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
        }
    }

    @Test(arguments: ["generic-context", "follow-up"])
    func capturedFalseGapDemonstratesStructuralAdmissionIsNotSemanticProof(caseID: String) async throws {
        let url = try #require(Bundle.module.url(forResource: "practice-v3-admitted-false-gap", withExtension: "json"))
        let all = try JSONDecoder().decode([AdmittedFalseGap].self, from: Data(contentsOf: url))
        let row = try #require(all.first { $0.caseID == caseID })
        let task = task(question: row.question, criterion: row.criterion, kind: .systemDesign)
        let attempt = PracticeAttempt(questionID: "refinement-contract", question: row.question,
            answer: row.answer, revision: 2, hinted: false, skipped: false, source: "synthetic-capture", task: task)
        let legacyProvider = RefinementPackets(packets: [row.primaryOutput, row.reviewOutput])
        let initial = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.primaryOutput.utf8))
        let final = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.reviewOutput.utf8))
        let supporting = try #require(initial.coverage["r0"] ?? nil)
        #expect(row.answer.contains(supporting))
        #expect(final.coverage["r0"] == .some(nil) && final.reviewOutcome == "accepted")
        // Original model bytes remain legacy with unknown dimensions; they do not
        // acquire fulfillment metadata merely by being replayed.
        #expect(initial.assessments == nil && final.assessments == nil)
        do {
            _ = try await evaluate(attempt: attempt, task: task, provider: legacyProvider)
            Issue.record("Legacy captured quotes cannot establish current assessment dimensions.")
        } catch { #expect(error.localizedDescription.contains("criterion assessments")) }
        #expect(await legacyProvider.recorded().count == 2)
        // Separately declared scripted claims retain the historical adverse
        // map. Structure cannot prove this false semantic judgment correct.
        let firstFields = try JSONDecoder().decode([String: String].self, from: Data(row.primaryOutput.utf8))
        let finalFields = try JSONDecoder().decode([String: String].self, from: Data(row.reviewOutput.utf8))
        let provider = RefinementPackets(packets: [
            try scriptedPracticePacket(firstFields, fulfilledIDs: ["r0"]),
            try scriptedPracticePacket(finalFields, fulfilledIDs: [])
        ])
        let feedback = try await evaluate(attempt: attempt, task: task, provider: provider)
        #expect(feedback.covered.isEmpty && feedback.missing == [row.criterion])
        #expect(feedback.followUp == final.followUp && feedback.reason == final.reason)
        #expect(feedback.reference == final.reference)
        #expect(await provider.recorded().count == 2)
        #expect(row.originalRun == "practice-final-gap-schema-core-local-v3-r1")
        #expect([row.primaryRequestSHA256, row.primaryResultSHA256, row.reviewRequestSHA256, row.reviewResultSHA256].allSatisfy { $0.count == 64 })
    }

    private func task(question: String, criterion: String, kind: InterviewTaskKind = .generalKnowledge) -> InterviewTaskDescriptor {
        var value = InterviewTaskDescriptor(question: question, kind: kind, language: "en")
        value.apply(.init(task: kind, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-refinement-contract", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: "refinement-contract", questionRevision: 2,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-refinement-contract", failure: nil, latencyMS: 0))
        value.criteria = [criterion]
        return value
    }
    private func evaluate(attempt: PracticeAttempt, task: InterviewTaskDescriptor, provider: RefinementPackets) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-refinement-contract")
    }
}
private struct AdmittedFalseGap: Decodable {
    let caseID, question, answer, criterion, primaryOutput, reviewOutput: String
    let primaryID, reviewID, primaryRequestSHA256, primaryResultSHA256, reviewRequestSHA256, reviewResultSHA256, originalRun: String
}
private actor RefinementPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-refinement-contract"
    nonisolated let displayName = "Finite optional refinement contract packets"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra refinement evaluation request.") }
        let packet = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: packet, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
