import Foundation
import Testing
@testable import Hireva

/// Finite packets characterize actual requests and unchanged admission only.
/// The six predeclared controls are not proof that a model infers support.
/// The withdrawn description experiment did not fix actual model omission coverage;
/// its raw model failure is retained separately from these wire controls.
@Suite
@MainActor
struct PracticeCoverageSupportDefinitionTests {
    @Test(arguments: PracticeCoverageSupportScenario.allCases)
    func finalWireKeepsLiteralSupportDefinitionAndFrozenAnswerRevision(scenario: PracticeCoverageSupportScenario) async throws {
        for revision in [0, 1] {
            let record = scenario.record
            let answer = record.answer + (revision == 0 ? " Original annotation." : " Revised annotation.")
            let kind: InterviewTaskKind = record.personal ? .behavioral : .generalKnowledge
            var task = InterviewTaskDescriptor(question: record.question, kind: kind, language: "en")
            task.apply(.init(task: kind, personalEvidence: record.personal ? .required : .notRequired,
                basis: record.personal ? .candidateRecord : .generalKnowledge, relation: .independent,
                parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
                source: "synthetic-support-definition", routerVersion: InterviewQuestionRouter.version,
                language: "en", clarification: "", questionID: "same-synthetic-support-question",
                questionRevision: revision, contextSnapshotID: "synthetic-support-context-\(revision)",
                artifactRevision: revision, model: "synthetic-support-definition", failure: nil, latencyMS: 0))
            task.criteria = [record.criterion]
            let attempt = PracticeAttempt(questionID: "same-synthetic-support-question", question: record.question,
                answer: answer, contextSnapshotID: "synthetic-support-context-\(revision)", revision: revision,
                hinted: false, skipped: false, source: "synthetic-contract", task: task, attachmentRevision: revision)
            let reference = record.personal ? PracticeFeedback.sourceLimitedReference(language: "en")
                : "The requested conclusion is limited to the stated conditions; behavior outside the scope remains unspecified."
            let primary = ["r0": scenario == .omissionOnly ? record.answer : record.quote,
                "reason": "Provisional coverage judgment.", "suggestion": "Check the supplied criterion.",
                "followUp": record.followUp, "reference": record.personal ? "" : reference]
            let final = ["r0": record.quote, "reason": record.quote.isEmpty
                    ? "The requested explanation is absent." : "The requested content is explicitly stated.",
                "suggestion": record.quote.isEmpty ? "Add only the requested explanation." : "No additional criterion is required.",
                "followUp": record.followUp, "reference": record.personal ? "" : reference, "reviewOutcome": "accepted"]
            let provider = CoverageSupportPackets(packets: [
                try scriptedPracticePacket(primary, fulfilledIDs: scenario == .omissionOnly || !record.quote.isEmpty ? ["r0"] : []),
                try scriptedPracticePacket(final, fulfilledIDs: record.quote.isEmpty ? [] : ["r0"])])
            let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-support-definition")
            #expect(feedback.covered.map(\.quote) == (record.quote.isEmpty ? [] : [record.quote]))
            #expect(feedback.missing == (record.quote.isEmpty ? [record.criterion] : []))
            #expect(feedback.followUp == (record.quote.isEmpty ? record.followUp : nil))
            #expect(feedback.reason == final["reason"] && feedback.reference == reference)
            let requests = await provider.recorded()
            try #require(requests.count == 2)
            for request in requests {
                let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
                #expect(input["question"] == attempt.question && input["answer"] == attempt.answer)
                #expect(input["rubric"] == "r0: \(record.criterion)")
                #expect(input["source_evidence"] == "" && input["attachment"] == "")
                #expect(!request.prompt.contains(revision == 0 ? "Revised annotation." : "Original annotation."))
                #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
                #expect(request.modelName == "synthetic-support-definition" && request.prompt.utf8.count <= 24000)
            }
            #expect(requests[0].responseSchema == PracticeEvaluationPayload.schema(criteria: task.criteria,
                sourceLimitedReference: record.personal ? "" : nil))
            let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
            let grounded = try JSONDecoder().decode(LocalJSONValue.self,
                from: Data(try #require(input["output_schema"]).utf8))
            #expect(grounded == requests[1].responseSchema)
            #expect(input["draft_feedback"] == nil && input["draft_first_missing_rubric_id"] == nil)
            #expect(input["draft_first_missing_rubric_criterion"] == nil)
            guard case .object(let schema) = grounded, case .object(let fields)? = schema["properties"],
                  case .object(let criterion)? = fields["r0"], case .string(let definition)? = criterion["description"] else {
                Issue.record("Final criterion must preserve its literal support/absence contract."); return
            }
            #expect(criterion["type"] == .string("string") && criterion["const"] == nil)
            #expect(Set(criterion.keys) == ["type", "description"])
            #expect(definition.contains("copy an exact answer substring"))
            #expect(definition.contains("expressing content relevant to its supplied criterion"))
            #expect(definition.contains("empty only when absent"))
            #expect(definition.contains("Never put explanations in the quote field"))
            #expect(schema["anyOf"] == nil && schema["$defs"] == nil && schema["additionalProperties"] == .boolean(false))
            let fixed = try JSONDecoder().decode([String].self, from: Data(try #require(input["fixed_output_fields"]).utf8))
            #expect(fixed == (record.personal ? ["reference"] : []))
            if record.personal {
                #expect(fields["reference"] == .object(["type": .string("string"), "const": .string("")]))
            }
            #expect(requests[1].systemPrompt?.contains("reason and suggestion summarize only the final criterion assessments") == true)
            #expect(requests[1].systemPrompt?.contains("without repeating already answered content or combining later gaps") == true)
        }
    }
}

enum PracticeCoverageSupportScenario: CaseIterable, Sendable {
    case omissionOnly, negativeLimitation, explanationElsewhere, personalDenial, unrelatedNegation, qualitativeTradeOff
    var record: (question: String, answer: String, criterion: String, quote: String, followUp: String, personal: Bool) {
        switch self {
        case .omissionOnly:
            return ("Explain how a process recovers from failure.", "I have not described recovery.", "Explain recovery", "", "What procedure restores a completed state after failure?", false)
        case .negativeLimitation:
            let quote = "The rule does not constrain events outside its admitted transitions."
            return ("Explain the limit of the proposed rule.", quote, "State the rule's limitation", quote, "", false)
        case .explanationElsewhere:
            let quote = "A stored checkpoint restores the last completed state before work resumes."
            return ("Explain how a process recovers from failure.", "I did not describe recovery in the opening. " + quote, "Explain recovery", quote, "", false)
        case .personalDenial:
            let quote = "I did not approve the adjustment."
            return ("Did you approve the adjustment?", quote, "State whether you approved the adjustment", quote, "", true)
        case .unrelatedNegation:
            let quote = "The rule applies only to permitted transitions."
            return ("State the proposed rule's scope.", "The illustration is not an operational measurement. " + quote, "State the scope", quote, "", false)
        case .qualitativeTradeOff:
            let quote = "Stronger checks reduce ambiguity but add work per operation."
            return ("Explain the choices and their trade-off.", quote, "Explain a qualitative trade-off", quote, "", false)
        }
    }
}

private actor CoverageSupportPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-support-definition"
    nonisolated let displayName = "Finite substantive-support contract packets"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < 2 && index < packets.count else { throw MaterialError.invalid("Unexpected extra support-definition call.") }
        let wire = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
