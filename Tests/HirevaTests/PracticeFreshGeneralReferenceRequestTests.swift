import Foundation
import Testing
@testable import Hireva

/// Actual evaluator wire/admission only. Explicit packets cannot prove that a
/// real model independently generates correct technical reference content.
@Suite
@MainActor
struct PracticeReferenceReviewInputTests {
    @Test(arguments: FreshReferenceScenario.allCases)
    func finalReferenceKeepsSourceAuthorityWhileReevaluatingTheFrozenAnswer(scenario: FreshReferenceScenario) async throws {
        let fixture = try makeFixture(scenario)
        let provider = FreshReferencePacketProvider(packets: [fixture.primaryWire, fixture.finalWire])
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: fixture.attachment, evidence: fixture.evidence, provider: provider, model: "synthetic-fresh-reference")
        #expect(feedback.covered.map(\.quote) == fixture.quotes)
        #expect(feedback.missing == (scenario.withGap ? [fixture.task.criteria[1]] : []))
        #expect(feedback.followUp == (scenario.withGap ? fixture.final["followUp"] : nil))
        #expect(feedback.reference == (scenario.sourceLimited
            ? PracticeFeedback.sourceLimitedReference(language: fixture.task.language) : fixture.final["reference"]))
        #expect(feedback.reason == fixture.final["reason"] && feedback.suggestions == [fixture.final["suggestion"]!])
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let inputs = try requests.map { try JSONDecoder().decode([String: String].self, from: Data($0.prompt.utf8)) }
        for (request, input) in zip(requests, inputs) {
            #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
            #expect(input["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["attachment"] == fixture.attachment.text)
            #expect(input["source_evidence"] == (scenario.hasSource ? fixture.evidence[0].statementForPrompt : ""))
            #expect(input["assessment_basis"] == (scenario.sourceLimited ? "submitted_answer_and_frozen_rubric" : nil))
            #expect(input["reference_authority"] == (scenario.sourceLimited ? "application_source_notice" : nil))
            #expect(input["application_reference_notice"] == nil)
            #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
            #expect(request.modelName == "synthetic-fresh-reference" && request.prompt.utf8.count <= 24000)
        }
        #expect(inputs[0]["draft_feedback"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(inputs[0]["output_schema"]).utf8)) == requests[0].responseSchema)
        #expect(inputs[0]["reference_generation_basis"] == nil)
        #expect(requests[0].systemPrompt?.contains("Fresh reference task:") == false)
        #expect(requests[0].responseSchema == PracticeEvaluationPayload.schema(criteria: fixture.task.criteria,
            sourceLimitedReference: scenario.sourceLimited ? "" : nil))
        #expect(inputs[1]["draft_feedback"] == nil)
        #expect(!requests[1].prompt.contains("PROVISIONAL_REASON_RETAINED"))
        #expect(!requests[1].prompt.contains("PROVISIONAL_SUGGESTION_RETAINED"))
        #expect(!requests[1].prompt.contains(try #require(fixture.primary["reference"])))
        #expect(inputs[1]["reference_generation_basis"] == nil)
        #expect(inputs[1]["draft_first_missing_rubric_id"] == nil)
        #expect(inputs[1]["draft_first_missing_rubric_criterion"] == nil)
        let system = try #require(requests[1].systemPrompt)
        #expect(!system.contains("Fresh reference task:"))
        if scenario.general {
            #expect(system.contains("independently fill every editable field"))
            #expect(system.contains("reference directly answers the original question"))
            #expect(!requests[1].prompt.contains(try #require(fixture.primary["reference"])))
            #expect(feedback.reference != fixture.primary["reference"])
        }
        #expect(system.contains("reviewOutcome judges the corrected feedback's validity, not candidate competence or completeness"))
        #expect(system.contains("never presuppose a stated future activity already happened"))
        let schema = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(inputs[1]["output_schema"]).utf8))
        #expect(schema == requests[1].responseSchema)
        guard case .object(let object) = schema, case .object(let fields)? = object["properties"] else {
            Issue.record("Final reference generation must preserve the existing field contract."); return
        }
        for key in ["r0", "r1", "followUp"] {
            guard case .object(let field)? = fields[key] else {
                Issue.record("Final quote/question fields must stay editable strings."); return
            }
            #expect(field["type"] == .string("string"))
            #expect(Set(field.keys) == Set(["type", "description"]))
            if case .string(let description)? = field["description"] { #expect(!description.isEmpty) }
            else { Issue.record("Expected a string annotation, not an output constraint.") }
        }
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (scenario.sourceLimited
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string")])))
        #expect(fields["reviewOutcome"] == .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])]))
        let fixed = try stringList(inputs[1], key: "fixed_output_fields")
        let editable = try stringList(inputs[1], key: "editable_output_fields")
        #expect(Set(fixed).union(editable) == Set(fields.keys))
        #expect(Set(fixed).isDisjoint(with: Set(editable)))
        #expect(fixed.contains("reference") == scenario.sourceLimited)
        #expect(editable.contains("reference") == !scenario.sourceLimited)
    }

    @Test(arguments: FreshReferenceFailure.allCases)
    func referenceReviewCannotCreateAcceptanceOrWeakenFrozenAdmission(failure: FreshReferenceFailure) async throws {
        let fixture = try makeFixture(.generalGapEN)
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.finalWire.utf8))
        switch failure {
        case .rejected: final["reviewOutcome"] = .string("rejected"); final["reason"] = .string("The frozen quote cannot establish the supplied criterion.")
        case .unverified: final.removeValue(forKey: "reviewOutcome")
        case .attachmentQuote: final["r0"] = .string(fixture.attachment.text)
        case .emptyReference: final["reference"] = .string(" \n ")
        }
        let provider = FreshReferencePacketProvider(packets: [fixture.primaryWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: fixture.attachment, evidence: fixture.evidence, provider: provider, model: "synthetic-fresh-reference")
            Issue.record("Reference review cannot certify an unverified or invalid final packet.")
        } catch {
            switch failure {
            case .rejected: #expect(error.localizedDescription.contains("Reviewer reported (unverified)"))
            case .unverified: #expect(error.localizedDescription.contains("did not verify"))
            case .attachmentQuote: #expect(error.localizedDescription.contains("quote/rubric validation"))
            case .emptyReference: #expect(error.localizedDescription.contains("empty reference answer"))
            }
        }
        #expect(await provider.recorded().count == 2)
    }

    private func makeFixture(_ scenario: FreshReferenceScenario) throws -> FreshReferenceFixture {
        let chinese = scenario == .generalGapZH
        let language = chinese ? "zh" : "en"
        let first = scenario.general ? (chinese ? "不变量是在允许的转换中保持的性质。" : "An invariant is a property preserved by admitted transitions.") : "I recorded the agreed constraints."
        let second = scenario.general ? (chinese ? "规则仅适用于允许的转换。" : "The rule applies only to admitted transitions.") : "The group used that record."
        let answer = first + (scenario.withGap ? "" : " " + second)
        let question = scenario.general ? (chinese ? "解释不变量及所给规则的适用范围。" : "Explain an invariant and the scope of the supplied rule.") : scenario == .optionalMixed ? "Explain a coordination rule; optionally illustrate it with a real decision and its known outcome." : "Describe a coordination decision, your action and the outcome known so far."
        let criteria = scenario.general ? (chinese ? ["解释性质", "说明适用范围"] : ["Explain the property", "State its scope"]) : ["Stated action", "Known outcome"]
        let requirement: PersonalEvidenceRequirement
        switch scenario {
        case .generalCompleteEN, .generalGapEN, .generalGapZH: requirement = .notRequired
        case .optionalMixed: requirement = .optional
        case .requiredNoSource, .requiredWithSource: requirement = .required
        case .uncertainNoSource: requirement = .uncertain
        }
        let kind: InterviewTaskKind = scenario.general ? .generalKnowledge : .behavioral
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: requirement,
            basis: scenario.general ? .providedArtifact : scenario == .optionalMixed ? .mixed : scenario == .uncertainNoSource ? .unknown : .candidateRecord,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-fresh-reference", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-fresh-reference", questionRevision: 3,
            contextSnapshotID: "frozen-synthetic-context", artifactRevision: 4, model: "synthetic-fresh-reference", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attachment = ExtractedMaterial(filename: "synthetic-rule.txt", sha256: "synthetic-material-identity",
            sections: [.init(location: "rule", text: "Only admitted transitions are in scope; behavior outside that set is unspecified.", method: "synthetic")], warnings: [])
        let source = ProfileEvidence(id: "synthetic-fact", statement: first, sourceDocumentID: "synthetic-document",
            sourceChunkID: nil, sourceSpan: first, confidence: 1, evidenceType: .experience, explicitness: .userConfirmed)
        let evidence = scenario.hasSource ? [source] : []
        let primary = ["r0": first, "r1": scenario.withGap ? "" : second,
            "followUp": scenario.withGap ? "PROVISIONAL_FOLLOWUP" : "",
            "reason": "PROVISIONAL_REASON_RETAINED", "suggestion": "PROVISIONAL_SUGGESTION_RETAINED",
            "reference": "PROVISIONAL_REFERENCE: a named invariant guarantees every outcome of the surrounding system."]
        let final = ["r0": first, "r1": scenario.withGap ? "" : second,
            "followUp": scenario.withGap ? (scenario.general
                ? (chinese ? "所给规则适用于哪些转换？" : "Which transitions are in scope for the supplied rule?")
                : "What outcome is known so far, if any, or is there no outcome yet?") : "",
            "reason": chinese ? "性质已说明；适用范围仍未说明。" : scenario.withGap
                ? (scenario.general ? "The property is stated; its scope is not stated." : "The action is stated; no outcome is stated.") : "Both criteria are stated.",
            "suggestion": chinese ? "仅补充题目所给规则的适用范围。" : scenario.withGap
                ? (scenario.general ? "Add the supplied rule's scope." : "Describe only what is known so far, or state that there is no outcome yet.") : "No rubric gap remains.",
            "reference": scenario.sourceLimited ? ""
                : chinese ? "不变量是允许转换所保持的性质；结论限于所声明的状态和转换集合，集合外行为仍未指定。"
                : scenario.general ? "An invariant is a property preserved by admitted transitions. A conclusion is limited to the stated state and transition set; behavior outside it remains unspecified."
                : "Use the confirmed recorded constraints for the action; distinguish an already observed outcome from a future plan or an unconfirmed claim.",
            "reviewOutcome": "accepted"]
        return .init(attempt: .init(questionID: "synthetic-fresh-reference", question: question, answer: answer,
            contextSnapshotID: "frozen-synthetic-context", revision: 3, hinted: false, skipped: false,
            source: "synthetic-contract", task: task, attachment: attachment, attachmentRevision: 4),
            task: task, attachment: attachment, evidence: evidence, primary: primary, final: final,
            quotes: scenario.withGap ? [first] : [first, second],
            primaryWire: try scriptedPracticePacket(primary, fulfilledIDs: scenario.withGap ? ["r0"] : ["r0", "r1"]),
            finalWire: try scriptedPracticePacket(final, fulfilledIDs: scenario.withGap ? ["r0"] : ["r0", "r1"]))
    }
    private func stringList(_ input: [String: String], key: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(try #require(input[key]).utf8))
    }
}

enum FreshReferenceScenario: CaseIterable, Sendable {
    case generalCompleteEN, generalGapEN, generalGapZH, optionalMixed, requiredNoSource, uncertainNoSource, requiredWithSource
    var general: Bool { self == .generalCompleteEN || self == .generalGapEN || self == .generalGapZH }
    var withGap: Bool { self != .generalCompleteEN && self != .requiredWithSource }
    var sourceLimited: Bool { self == .requiredNoSource || self == .uncertainNoSource }
    var hasSource: Bool { self == .optionalMixed || self == .requiredWithSource }
}
enum FreshReferenceFailure: CaseIterable, Sendable { case rejected, unverified, attachmentQuote, emptyReference }
private struct FreshReferenceFixture {
    var attempt: PracticeAttempt
    var task: InterviewTaskDescriptor
    var attachment: ExtractedMaterial
    var evidence: [ProfileEvidence]
    var primary: [String: String]
    var final: [String: String]
    var quotes: [String]
    var primaryWire: String
    var finalWire: String
}
private actor FreshReferencePacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-fresh-reference"
    nonisolated let displayName = "Explicit independent reference packets"
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
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra reference request.") }
        let wire = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
