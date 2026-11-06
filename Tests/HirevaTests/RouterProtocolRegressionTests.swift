import Foundation
import Testing
@testable import Hireva

/// Native router request/decoder contracts. Scripted outputs do not measure model quality.
@Suite
struct RouterProtocolRegressionTests {
    @Test(arguments: [QuestionAnswerBasis.candidateRecord, .mixed])
    func negativeEvidenceCannotDeclareActualCandidateFacts(basis: QuestionAnswerBasis) throws {
        let text = try wire(evidence: .notRequired, basis: basis)
        #expect(throws: (any Error).self) { try InterviewQuestionRouter.Wire.decode(text) }
    }

    @Test
    func nonCandidateAndUnresolvedBasisContractsRemainAvailable() throws {
        for basis in [QuestionAnswerBasis.generalKnowledge, .providedArtifact, .unknown] {
            #expect(try InterviewQuestionRouter.Wire.decode(wire(evidence: .notRequired, basis: basis)).basis == basis)
        }
        for evidence in [PersonalEvidenceRequirement.required, .optional, .uncertain] {
            for basis in [QuestionAnswerBasis.candidateRecord, .mixed] {
                #expect(try InterviewQuestionRouter.Wire.decode(wire(evidence: evidence, basis: basis)).basis == basis)
            }
        }
    }

    @Test(arguments: [QuestionAnswerBasis.candidateRecord, .mixed], Array(0..<3))
    func contradictoryNegativeResponseUsesExistingRepairOrRetainsFirstReview(basis: QuestionAnswerBasis, phase: Int) async throws {
        let bad = try wire(evidence: .notRequired, basis: basis)
        let first = phase == 2 ? try wire(evidence: .uncertain, basis: .unknown) : bad
        let second = phase == 0 ? try wire(evidence: .notRequired, basis: .generalKnowledge) : bad
        let provider = RouterProtocolTransport(outputs: [first, second])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Explain a general procedure.", questionID: "negative-basis"),
            provider: provider, model: "synthetic-protocol-model")
        #expect(await provider.requests.count == 2 && result.modelRequests == 2)
        if phase == 0 {
            #expect(result.personalEvidence == .notRequired && result.basis == .generalKnowledge && result.failure == nil)
            #expect(result.modelFormatRepairs == 1 && result.modelEvidenceReviews == 0)
        } else if phase == 1 {
            #expect(result.source == "safeFallback" && result.personalEvidence == .uncertain && result.basis == .unknown)
            #expect(result.failure == "invalidOrUnavailable" && result.modelPersonalEvidence == nil)
        } else {
            #expect(result.personalEvidence == .uncertain && result.basis == .unknown)
            #expect(result.failure == "evidenceReviewInvalidOrUnavailable" && result.modelPersonalEvidence == .uncertain)
            #expect(result.modelEvidenceReviews == 1 && result.modelFormatRepairs == 0)
        }
    }

    @Test
    func oldPersistedDecisionIsNotReclassifiedByNewWireAdmission() throws {
        let data = Data(#"{"task":"systemDesign","personalEvidence":"notRequired","basis":"mixed","relation":"independent","source":"legacy","routerVersion":"legacy","language":"en","clarification":"","questionID":"legacy-question","questionRevision":0,"artifactRevision":0,"model":"legacy","latencyMS":0}"#.utf8)
        let stored = try JSONDecoder().decode(InterviewQuestionDecision.self, from: data)
        #expect(stored.personalEvidence == .notRequired && stored.basis == .mixed)
        #expect(try JSONDecoder().decode(InterviewQuestionDecision.self, from: JSONEncoder().encode(stored)) == stored)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_ROUTING_REPLAY_ROOT"] != nil))
    func storedRoutingResponsesUseTheProductionDecoderWithoutInference() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HIREVA_ROUTING_REPLAY_ROOT"]))
        let paths = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: root.appendingPathComponent("v21-routing-replay-files.json")))
        let expectation = try #require(try JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("v21-routing-replay-expected.json"))) as? [String: Any])
        let rejected = Set(expectation["currentWireRejectionPaths"] as? [String] ?? [])
        #expect(rejected.isSubset(of: Set(paths)))
        if let version = expectation["routerVersion"] as? String { #expect(version == InterviewQuestionRouter.version) }
        // Terminal admission remains separate: a cancelled complete JSON can
        // decode successfully without becoming a completed model response.
        var stopCount = 0, decodableCount = 0, stopDecodableCount = 0
        for path in paths {
            let result = try #require(try JSONSerialization.jsonObject(with:
                Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            let text = try #require(result["output"] as? String)
            let decoded = try? InterviewQuestionRouter.Wire.decode(text)
            if decoded != nil { decodableCount += 1 }
            if rejected.contains(path) { #expect(decoded == nil, "A predeclared contradictory wire must be rejected: \(path)") }
            let diagnostics = result["providerDiagnostics"] as? [String: Any]
            if result["streamFinished"] as? Bool == true,
               result["taskCancelled"] as? Bool == false,
               diagnostics?["done_reason"] as? String == "stop" {
                stopCount += 1
                if decoded != nil { stopDecodableCount += 1 }
                if !rejected.contains(path) { #expect(decoded != nil, "A formal stop response failed the production decoder: \(path)") }
            }
        }
        #expect(paths.count == (expectation["totalFiles"] as? Int))
        #expect(stopCount == (expectation["formalDoneStop"] as? Int))
        #expect(decodableCount == (expectation["expectedActualWireDecodableAllIncludingCancelledComplete"] as? Int))
        #expect(stopDecodableCount == (expectation["formalDoneStopExpectedActualWireDecodable"] as? Int))
        print("Production decoder replay: files=\(paths.count), formalStop=\(stopCount), decodable=\(decodableCount); no inference or terminal promotion")
    }

    @Test
    func resolveCarriesExistingStrictRequiredBasisRuleIntoSchema() async throws {
        let output = try wire(evidence: .notRequired, basis: .generalKnowledge)
        let provider = RouterProtocolTransport(outputs: [output])
        _ = try await InterviewQuestionRouter.resolve(.init(question: "Explain resource ownership.", questionID: "synthetic-schema"),
            provider: provider, model: "synthetic-protocol-model")
        let request = try #require(await provider.requests.first)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(request.responseSchema))) as? [String: Any]
        let branches = try #require(schema?["anyOf"] as? [[String: Any]])
        #expect(branches.count == 3)
        for branch in branches {
            #expect(branch["additionalProperties"] as? Bool == false)
            #expect(Set(try #require(branch["required"] as? [String])) == ["task", "personalEvidence", "basis", "relation", "clarification"])
        }
        for evidence in PersonalEvidenceRequirement.allCases {
            for basis in QuestionAnswerBasis.allCases {
                let permits = branches.contains { branch in
                    guard let fields = branch["properties"] as? [String: [String: Any]],
                          let allowedEvidence = fields["personalEvidence"]?["enum"] as? [String],
                          let allowedBasis = fields["basis"]?["enum"] as? [String] else { return false }
                    return allowedEvidence.contains(evidence.rawValue) && allowedBasis.contains(basis.rawValue)
                }
                // Expected legality comes from the actual strict production decoder,
                // not a copied implementation of its evidence rule.
                let text = try wire(evidence: evidence, basis: basis)
                let decoderAccepts = (try? InterviewQuestionRouter.Wire.decode(text)) != nil
                #expect(permits == decoderAccepts)
            }
        }
        #expect(request.temperature == 0 && request.numPredict == 260 && !request.thinkingEnabled)
    }

    @Test
    func inconsistentProviderResponseStillNeedsActualSecondDecode() async throws {
        let provider = RouterProtocolTransport(outputs: [try wire(evidence: .required, basis: .providedArtifact), try wire(evidence: .required, basis: .candidateRecord)])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Describe an actual decision.", questionID: "synthetic-inconsistent"),
            provider: provider, model: "synthetic-protocol-model")
        #expect(result.personalEvidence == .required)
        #expect(result.basis == .candidateRecord)
        #expect(result.failure == nil)
        #expect(result.modelRequests == 2)
        #expect(await provider.requests.count == 2)
    }

    @Test
    func repeatedInconsistencyStillAbstains() async throws {
        let invalid = try wire(evidence: .required, basis: .providedArtifact)
        let provider = RouterProtocolTransport(outputs: [invalid, invalid])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Describe an actual decision.", questionID: "synthetic-repeated"),
            provider: provider, model: "synthetic-protocol-model")
        #expect(result.source == "safeFallback")
        #expect(result.personalEvidence == .uncertain)
        #expect(result.failure == "invalidOrUnavailable")
        #expect(await provider.requests.count == 2)
    }

    private func wire(evidence: PersonalEvidenceRequirement, basis: QuestionAnswerBasis) throws -> String {
        String(decoding: try JSONEncoder().encode(InterviewQuestionRouter.Wire(task: .unknown,
            personalEvidence: evidence, basis: basis, relation: .independent, clarification: "")), as: UTF8.self)
    }
}

private actor RouterProtocolTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-router-protocol"
    nonisolated let displayName = "Synthetic router protocol"
    let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra routing request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
