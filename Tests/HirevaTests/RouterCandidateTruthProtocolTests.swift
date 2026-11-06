import Foundation
import Testing
@testable import Hireva

/// Actual request/decision contracts. Scripted wires do not measure model accuracy.
@Suite
struct RouterCandidateTruthProtocolTests {
    @Test(arguments: [false, true])
    func actualRequestsExplainThatANegativePastAnswerStillNeedsCandidateTruth(chinese: Bool) async throws {
        let question = chinese ? "那次检查决定是否由你本人负责？" : "Were you personally responsible for that inspection decision?"
        let clarification = chinese ? "具体指哪次检查？" : "Which inspection is meant?"
        let provider = CandidateTruthTransport(outputs: [
            try wire(evidence: .uncertain, basis: .unknown, clarification: clarification),
            try wire(evidence: .required, basis: .candidateRecord)
        ])
        let input = InterviewRoutingInput(question: question, questionID: UUID().uuidString,
            revision: 3, contextSnapshotID: "synthetic-truth-context", language: chinese ? "zh" : "en")
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-truth-contract")
        let requests = await provider.requests
        try #require(requests.count == 2)
        for request in requests {
            let system = try #require(request.systemPrompt)
            // This asserts that the actual provider receives the general contract,
            // not a duplicate classifier implemented inside this test.
            #expect(system.contains("For a question explicitly asking whether the candidate performed a past action or holds a current preference, a truthful denial still needs candidate facts."))
            #expect(system.contains("An adverse state, failure or discrepancy in an external case is not such a denial and does not establish candidate involvement."))
            #expect(system.contains("Do not assume it happened."))
            #expect(request.temperature == 0 && request.numPredict == 260 && !request.thinkingEnabled)
            #expect(request.responseSchema == InterviewQuestionRouter.Wire.schema)
        }
        #expect(requests[0].prompt == requests[1].prompt)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(requests[1].prompt.utf8)) as? [String: Any])
        #expect(payload["question"] as? String == question)
        #expect(payload["hasParent"] as? Bool == false)
        #expect(payload["artifact"] == nil && payload["previousQuestion"] == nil)
        #expect(InterviewQuestionRouter.timeoutSeconds == 8)
        #expect(result.task == .unknown && result.relation == .independent)
        #expect(result.personalEvidence == .required && result.basis == .candidateRecord)
        #expect(result.usesCandidateEvidence && result.clarification == clarification)
        #expect(result.questionID == input.questionID && result.questionRevision == 3)
        #expect(result.modelRequests == 2 && result.modelEvidenceReviews == 1 && result.modelFormatRepairs == 0)
        #expect(result.failure == nil)
        #expect(result.evidencePolicy.contains("A question or submitted answer is not confirmed biographical evidence."))
    }

    @Test
    func fictionalExerciseCanAskWhetherAnActionOccurredWithoutCreatingCandidateHistory() async throws {
        let artifact = "Fictional exercise: a museum coordinator declined to reopen a gallery until the alarm was tested."
        let provider = CandidateTruthTransport(outputs: [try wire(evidence: .notRequired, basis: .providedArtifact)])
        let result = try await InterviewQuestionRouter.resolve(.init(
            question: "In the attached fictional exercise, did the coordinator approve reopening?", questionID: UUID().uuidString,
            artifactRevision: 2, artifact: artifact), provider: provider, model: "synthetic-truth-contract")
        #expect(result.personalEvidence == .notRequired && result.basis == .providedArtifact)
        #expect(!result.usesCandidateEvidence && result.artifactRevision == 2)
        #expect(result.modelRequests == 1 && result.modelEvidenceReviews == 0 && result.failure == nil)
        let request = try #require(await provider.requests.first)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any])
        #expect(payload["artifact"] as? String == artifact)
    }

    @Test
    func anAmbiguousGenericExampleRetainsAValidAbstention() async throws {
        let output = try wire(evidence: .uncertain, basis: .unknown, clarification: "Do you mean an actual event or a general example?")
        let provider = CandidateTruthTransport(outputs: [output, output])
        let result = try await InterviewQuestionRouter.resolve(.init(
            question: "Could you give an example of that approach?", questionID: UUID().uuidString),
            provider: provider, model: "synthetic-truth-contract")
        #expect(result.personalEvidence == .uncertain && result.basis == .unknown)
        #expect(!result.usesCandidateEvidence && !result.clarification.isEmpty)
        #expect(result.modelRequests == 2 && result.modelEvidenceReviews == 1 && result.failure == nil)
    }

    private func wire(evidence: PersonalEvidenceRequirement, basis: QuestionAnswerBasis, clarification: String = "") throws -> String {
        String(decoding: try JSONEncoder().encode(InterviewQuestionRouter.Wire(task: .unknown,
            personalEvidence: evidence, basis: basis, relation: .independent, clarification: clarification)), as: UTF8.self)
    }
}

private actor CandidateTruthTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-candidate-truth-contract"
    nonisolated let displayName = "Synthetic candidate truth contract"
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra candidate-truth request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
