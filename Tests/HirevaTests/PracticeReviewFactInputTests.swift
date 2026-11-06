import Foundation
import Testing
@testable import Hireva

/// Actual evaluate/request/validator protocol contract, not model-quality proof.
@Suite
@MainActor
struct PracticeReviewFactInputTests {
    @Test(arguments: FactInputScenario.allCases)
    func finalPhaseExcludesProvisionalJudgmentsWithoutChangingFixedEvidence(scenario: FactInputScenario) async throws {
        let personal = scenario.personal
        let withGap = scenario.withGap
        let question = personal
            ? "Describe a coordination decision, your action and the observed outcome."
            : "Explain a finite work queue and one operational limit."
        let firstQuote = personal ? "I listed the constraints." : "I would use a finite queue."
        let secondQuote = personal ? "The group agreed on the listed constraints." : "If the queue is full, reject the request."
        let answer = withGap ? firstQuote : firstQuote + " " + secondQuote
        let criteria = personal ? ["Personal action", "Observed result"] : ["Explain mechanism", "Operational limit"]
        var task = InterviewTaskDescriptor(question: question, kind: personal ? .behavioral : .generalKnowledge, language: "en")
        task.criteria = criteria
        task.apply(InterviewQuestionDecision(task: personal ? .behavioral : .generalKnowledge,
            personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "fact-input-protocol-contract", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: "fact-input", questionRevision: 2,
            contextSnapshotID: "frozen-context", artifactRevision: 0, model: "synthetic-fact-input",
            failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: "fact-input", question: question,
            answer: answer, contextSnapshotID: "frozen-context", revision: 2,
            hinted: false, skipped: false, source: "synthetic-contract", task: task)
        let badReason = "PROVISIONAL_REASON_CANARY: every covered criterion is missing without a past deployment."
        let badSuggestion = "PROVISIONAL_SUGGESTION_CANARY: only an unreported completed project can count."
        let badReference = "PROVISIONAL_REFERENCE_CANARY: a mechanism name proves unconditional system guarantees."
        let canonical = "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
        let followUp = withGap
            ? (personal ? "What outcome is known so far, if any, or is there no outcome yet?" : "What happens when the finite queue reaches capacity?") : ""
        let primary = PracticeEvaluationPayload(coverage: ["r0": firstQuote, "r1": withGap ? nil : secondQuote],
            suggestion: badSuggestion, followUp: withGap ? followUp : nil, reason: badReason, reference: badReference)
        let freshReference = personal ? canonical : "A finite queue bounds retained work; reaching capacity requires an explicit admission or rejection policy."
        let reviewed = PracticeEvaluationPayload(coverage: ["r0": firstQuote, "r1": withGap ? nil : secondQuote],
            suggestion: withGap ? "Explain the missing second criterion using the supplied question." : "No rubric gap remains.",
            followUp: withGap ? followUp : nil, reason: withGap ? "The second supplied criterion is not stated." : "Both supplied criteria are stated.",
            reference: personal ? "" : freshReference, reviewOutcome: "accepted")
        let provider = FactInputScriptedProvider(primary: primary, reviewed: reviewed)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-fact-input")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let payload = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(payload["draft_feedback"] == nil)
        #expect(payload["application_reference_notice"] == nil)
        #expect(payload["assessment_basis"] == (personal ? "submitted_answer_and_frozen_rubric" : nil))
        #expect(payload["reference_authority"] == (personal ? "application_source_notice" : nil))
        #expect(!requests[1].prompt.contains(badReason) && !requests[1].prompt.contains(badSuggestion))
        #expect(!requests[1].prompt.contains(badReference))
        #expect(payload["question"] == question && payload["answer"] == answer)
        #expect(payload["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(payload["source_evidence"] == "" && payload["attachment"] == "")
        #expect(payload["draft_first_missing_rubric_id"] == nil && payload["draft_first_missing_rubric_criterion"] == nil)
        let schema = try #require(requests[1].responseSchema)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(payload["output_schema"]).utf8)) == schema)
        guard case .object(let root) = schema, case .object(let fields)? = root["properties"],
              case .object(let r0)? = fields["r0"], case .object(let r1)? = fields["r1"],
              case .object(let reference)? = fields["reference"] else {
            Issue.record("Actual final schema has no frozen-rubric field contract."); return
        }
        #expect(r0["type"] == .string("string") && r0["const"] == nil)
        #expect(r1["type"] == .string("string") && r1["const"] == nil)
        #expect(reference["const"] == (personal ? .string("") : nil))
        #expect(feedback.covered.map(\.quote) == (withGap ? [firstQuote] : [firstQuote, secondQuote]))
        #expect(feedback.missing == (withGap ? [criteria[1]] : []))
        #expect(feedback.followUp == (withGap ? followUp : nil))
        #expect(feedback.reference == freshReference)
        #expect(feedback.referenceOrigin == (personal ? .applicationSourceNotice : .modelDraft))
        #expect(requests.allSatisfy { $0.modelName == "synthetic-fact-input" && $0.temperature == 0 && $0.numPredict == 1200 && !$0.thinkingEnabled })
    }

    @Test(arguments: ["", " \n"])
    func acceptedDispositionCannotPublishAnEmptyGeneralReference(emptyReference: String) async throws {
        let question = "Explain a finite work queue."
        let answer = "I would use a finite queue."
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "empty-reference-contract",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "empty-reference", questionRevision: 0, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-fact-input", failure: nil, latencyMS: 0))
        task.criteria = ["Explain mechanism"]
        let attempt = PracticeAttempt(questionID: "empty-reference", question: question,
            answer: answer, revision: 0, hinted: false, skipped: false, source: "synthetic-contract", task: task)
        let primary = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: "No rubric gap remains.",
            followUp: nil, reason: "The mechanism is stated.", reference: "A finite queue retains a bounded number of waiting jobs.")
        let reviewed = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: "No rubric gap remains.",
            followUp: nil, reason: "The mechanism is stated.", reference: emptyReference, reviewOutcome: "accepted")
        let provider = FactInputScriptedProvider(primary: primary, reviewed: reviewed)
        do {
            _ = try await PracticeController.evaluate(attempt: attempt, task: task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-fact-input")
            Issue.record("An accepted disposition cannot turn an empty reference into a useful answer.")
        } catch {
            #expect(error.localizedDescription.contains("empty reference answer"))
        }
        #expect(await provider.recorded().count == 2)
    }

    @Test
    func unresolvedPersonalReferencePreservesCanonicalNeedsInputNotice() async throws {
        let question = "Explain what is known about your coordination decision so far."
        let answer = "I have listed the current constraints."
        var task = InterviewTaskDescriptor(question: question, kind: .behavioral, language: "en")
        task.apply(InterviewQuestionDecision(task: .behavioral, personalEvidence: .uncertain,
            basis: .unknown, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "unresolved-reference-contract",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "Personal facts are not supplied.",
            questionID: "unresolved-reference", questionRevision: 0, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-fact-input", failure: nil, latencyMS: 0))
        task.criteria = ["Stated current status"]
        let attempt = PracticeAttempt(questionID: "unresolved-reference", question: question,
            answer: answer, revision: 0, hinted: false, skipped: false, source: "synthetic-contract", task: task)
        let canonical = "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
        let primary = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: "Confirm source facts before using a personal reference.",
            followUp: nil, reason: "The current status is stated.", reference: "")
        let reviewed = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: "Confirm source facts before using a personal reference.",
            followUp: nil, reason: "The current status is stated.", reference: "", reviewOutcome: "accepted")
        let provider = FactInputScriptedProvider(primary: primary, reviewed: reviewed)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-fact-input")
        #expect(feedback.reference == canonical && feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let payload = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(payload["draft_feedback"] == nil)
        #expect(payload["application_reference_notice"] == nil)
        #expect(payload["assessment_basis"] == "submitted_answer_and_frozen_rubric")
        #expect(payload["reference_authority"] == "application_source_notice")
        guard case .object(let schema)? = requests[1].responseSchema,
              case .object(let fields)? = schema["properties"],
              case .object(let reference)? = fields["reference"] else {
            Issue.record("Unresolved personal review must preserve the source-limited reference contract."); return
        }
        #expect(reference["const"] == .string(""))
    }

}

enum FactInputScenario: CaseIterable, Sendable {
    case generalComplete, generalGap, personalComplete, personalGap
    var personal: Bool { self == .personalComplete || self == .personalGap }
    var withGap: Bool { self == .generalGap || self == .personalGap }
}

/// Explicit scripted judgments only. Never apply this to model output or stored records.
func scriptedPracticePacket(_ fields: [String: String], fulfilledIDs: Set<String>) throws -> String {
    var wire = fields.mapValues(LocalJSONValue.string)
    let ids = Set(fields.keys.filter { $0.first == "r" && Int($0.dropFirst()) != nil }).union(fulfilledIDs)
    wire["assessments"] = .object(Dictionary(uniqueKeysWithValues: ids.map { id in
        let expressed = !(fields[id] ?? "").isEmpty
        let assessment: LocalJSONValue = .object([
            "presence": .string(expressed ? "present" : "absent"),
            "accuracy": .string(expressed ? "unverified" : "not_applicable"),
            "accuracyBasis": .string("Scripted fixture; factual support unverified."),
            "fulfillment": .string(fulfilledIDs.contains(id) ? "met" : "unmet"),
            "basis": .string("Explicit scripted rubric declaration.")])
        return (id, assessment)
    }))
    return String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
}

private actor FactInputScriptedProvider: LocalLLMProvider {
    nonisolated let id = "fact-input-protocol"
    nonisolated let displayName = "Explicit synthetic phase packets"
    private let primary: PracticeEvaluationPayload
    private let reviewed: PracticeEvaluationPayload
    private var requests: [LocalLLMRequest] = []
    init(primary: PracticeEvaluationPayload, reviewed: PracticeEvaluationPayload) {
        self.primary = primary; self.reviewed = reviewed
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        requests.append(request)
        guard requests.count <= 2 else { throw MaterialError.invalid("Unexpected third evaluation phase.") }
        // Accepted is an explicit scripted packet, never inferred from schema.
        let wire = requests.count == 1 ? primary : reviewed
        let text = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
