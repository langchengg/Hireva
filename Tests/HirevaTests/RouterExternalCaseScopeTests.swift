import Foundation
import Testing
@testable import Hireva

/// Actual first/review requests carry scope, while scripted wires only prove
/// protocol and identity handling. They do not measure real-model accuracy.
@Suite
struct RouterExternalCaseScopeTests {
    @Test(arguments: ["en", "zh"])
    func externalAdverseCaseIsNotATruthfulDenialOfCandidateHistory(_ language: String) async throws {
        let question = language == "en"
            ? "A relay misses messages during a power interruption. How would a proposed recovery method work?"
            : "一次电源中断导致转发器漏收消息。你会怎样设计恢复方法？"
        let first = InterviewQuestionRouter.Wire(task: .systemDesign, personalEvidence: .uncertain,
            basis: .unknown, relation: .independent, clarification: "")
        let reviewed = InterviewQuestionRouter.Wire(task: .systemDesign, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, clarification: "")
        let outputs = try [first, reviewed].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let provider = ExternalScopeTransport(outputs: outputs)
        let input = InterviewRoutingInput(question: question, questionID: UUID().uuidString,
            revision: 4, contextSnapshotID: "synthetic-external-scope", language: language)
        let decision = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-external-scope")
        let requests = await provider.requests
        try #require(requests.count == 2)
        for request in requests {
            let system = try #require(request.systemPrompt)
            #expect(system.contains("For a question explicitly asking whether the candidate performed a past action or holds a current preference, a truthful denial still needs candidate facts."))
            #expect(system.contains("An adverse state, failure or discrepancy in an external case is not such a denial and does not establish candidate involvement."))
            #expect(request.temperature == 0 && request.numPredict == 260 && !request.thinkingEnabled)
            #expect(request.responseSchema == InterviewQuestionRouter.Wire.schema)
        }
        #expect(requests[0].prompt == requests[1].prompt)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(requests[0].prompt.utf8)) as? [String: Any])
        #expect(payload["question"] as? String == question)
        #expect(payload["hasParent"] as? Bool == false)
        #expect(payload["artifact"] == nil && payload["previousQuestion"] == nil)
        #expect(decision.task == .systemDesign && decision.personalEvidence == .notRequired)
        #expect(decision.basis == .generalKnowledge && !decision.usesCandidateEvidence)
        #expect(decision.questionID == input.questionID && decision.questionRevision == input.revision)
        #expect(decision.contextSnapshotID == input.contextSnapshotID && decision.language == language)
        #expect(decision.modelRequests == 2 && decision.modelEvidenceReviews == 1 && decision.modelFormatRepairs == 0)
        #expect(decision.failure == nil && InterviewQuestionRouter.timeoutSeconds == 8)
    }
}

private actor ExternalScopeTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-external-scope"
    nonisolated let displayName = "Synthetic external scope"
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra external-scope request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
