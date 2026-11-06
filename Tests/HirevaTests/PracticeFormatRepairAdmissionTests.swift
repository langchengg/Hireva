import Foundation
import Testing
@testable import Hireva

/// Actual evaluator admission regressions, compiling against the existing
/// payload API. Controlled replies prove lifecycle gates, not model truth.
@Suite
@MainActor
struct PracticeFormatRepairAdmissionTests {
    @Test(arguments: Array(0..<8))
    func invalidPrimaryDoesNotSupplyOrPreventTheApplicationOwnedReview(_ variant: Int) async throws {
        let malformedKind = variant / 2
        let acceptedDisposition = variant % 2 == 1
        let question = "Explain a bounded queue and its overflow policy."
        let answer = "A bounded queue has limited capacity and a defined overflow policy."
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-format-admission", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "synthetic-format-admission", questionRevision: 3, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-format-admission", failure: nil, latencyMS: 0))
        task.criteria = ["Define the capacity boundary", "State the overflow requirement"]
        let attempt = PracticeAttempt(questionID: "synthetic-format-admission", question: question, answer: answer,
            contextSnapshotID: nil, revision: 3, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let declared: [String: String] = ["r0": "limited capacity", "r1": "defined overflow policy",
            "followUp": "", "reason": "Both supplied criteria are covered.",
            "suggestion": "Keep the boundary and policy explicit.",
            "reference": "A bounded queue needs explicit admission and overflow rules."]
        let complete = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try scriptedPracticePacket(declared, fulfilledIDs: ["r0", "r1"]).utf8))
        let validWire = try wire(complete)
        // Prove the controlled final packet already passes the real structural
        // quote/rubric/source checks; final review still requires disposition.
        let structurallyValid = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(validWire.utf8))
            .feedback(task: task).validated(answer: answer, task: task, evidence: [])
        #expect(structurallyValid.covered.count == 2 && structurallyValid.missing.isEmpty)
        var first = complete
        let malformed: String
        switch malformedKind {
        case 0:
            first.removeValue(forKey: "r1")
            malformed = try wire(first)
        case 1:
            first.removeValue(forKey: "reason")
            malformed = try wire(first)
        case 2:
            malformed = "This is not a JSON evaluation object."
        default:
            first["r0"] = .string("These words never appeared in the submitted answer.")
            malformed = try wire(first)
        }
        var final = complete
        if acceptedDisposition { final["reviewOutcome"] = .string("accepted") }
        let provider = FormatAdmissionTransport(outputs: [malformed, try wire(final)])
        if acceptedDisposition {
            let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
                evidence: [], provider: provider, model: "synthetic-format-admission")
            #expect(feedback.covered == structurallyValid.covered && feedback.missing.isEmpty)
            #expect(feedback.referenceOrigin == .modelDraft)
        } else {
            do {
                _ = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
                    evidence: [], provider: provider, model: "synthetic-format-admission")
                Issue.record("A final packet without review disposition bypassed admission.")
            } catch { #expect(error.localizedDescription.contains("did not verify")) }
        }
        let requests = await provider.requests
        try #require(requests.count == 2)
        let finalRequest = requests[1]
        let input = try JSONDecoder().decode([String: String].self, from: Data(finalRequest.prompt.utf8))
        #expect(input["question"] == question && input["answer"] == answer)
        #expect(input["rubric"] == "r0: \(task.criteria[0])\nr1: \(task.criteria[1])")
        #expect(input["previous_invalid_output"] == nil)
        #expect(input["draft_feedback"] == nil)
        #expect(input["first_missing_rubric_id"] == nil && input["first_missing_rubric_criterion"] == nil)
        #expect(finalRequest.systemPrompt?.contains("Independently critique the complete original answer") == true)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8)) == finalRequest.responseSchema)
        #expect(finalRequest.responseSchema == PracticeEvaluationPayload(coverage: ["r0": nil, "r1": nil],
            suggestion: "", followUp: nil, reason: "", reference: "")
            .semanticReviewSchema(fixedReference: false, criteria: task.criteria, feedbackLanguage: task.explanationLanguage ?? task.language))
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 && $0.modelName == "synthetic-format-admission" })
        #expect(attempt.feedback == nil && attempt.revision == 3 && attempt.answer == answer)
    }
    private func wire(_ object: [String: LocalJSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    }
}

private actor FormatAdmissionTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-format-admission"
    nonisolated let displayName = "Synthetic format admission"
    private let outputs: [String]
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected third format repair request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
