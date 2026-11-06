import Foundation
import Testing
@testable import Hireva

/// These finite packets inspect the real evaluator's outgoing contract and
/// existing fail-closed admission. They do not prove model coverage or truth.
@Suite
@MainActor
struct PracticeFinalGapSchemaCorrelationTests {
    @Test(arguments: [1, 4, 12], [false, true])
    func finalReviewPreservesEditableCorrectedMapAndSourceContract(criteriaCount: Int, personal: Bool) async throws {
        let fixture = makeFixture(criteriaCount: criteriaCount, personal: personal)
        let initial = try packet(fixture, missing: Set([0]))
        let final = try packet(fixture, reviewed: true)
        let provider = FinalGapSchemaPackets(packets: [initial, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered.map(\.quote) == fixture.quotes)
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        #expect(requests[0].responseSchema == PracticeEvaluationPayload.schema(criteria: fixture.task.criteria,
            sourceLimitedReference: personal ? "" : nil))
        let review = requests[1]
        let input = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        let schema = try object(try #require(review.responseSchema))
        let fields = try object(try #require(schema["properties"]))
        let grounded = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8))
        #expect(grounded == review.responseSchema)
        #expect(schema["additionalProperties"] == .boolean(false))
        #expect(Set(try strings(try #require(schema["required"]))) == Set(fields.keys))
        let expectedKeys = Set((0..<criteriaCount).map { "r\($0)" } + ["assessments", "followUp", "reason", "reference", "reviewOutcome", "suggestion"])
        #expect(Set(fields.keys) == expectedKeys)
        for i in 0..<criteriaCount {
            let options = try object(try #require(fields["r\(i)"]))
            #expect(Set(options.keys) == ["type", "description"])
            #expect(options["type"] == .string("string") && options["const"] == nil)
        }
        let followUpOptions = try object(try #require(fields["followUp"]))
        #expect(Set(followUpOptions.keys) == ["type", "description"])
        #expect(followUpOptions["type"] == .string("string") && followUpOptions["const"] == nil)
        #expect(fields["reviewOutcome"] == .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])]))
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (personal
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string")])))
        if !personal {
            let referenceField = try object(try #require(fields["reference"]))
            guard case .string(let description)? = referenceField["description"] else {
                Issue.record("Editable reference has no correctness contract."); return
            }
            #expect(description.contains("attached to its actual subject and operation"))
            #expect(description.contains("qualify implementation-dependent properties"))
        }
        // The real-model correlation experiment was rejected. Keep the
        // final map editable and let the existing runtime reject inconsistent
        // map/follow-up packets rather than constrain a fabricated gap.
        #expect(schema["$defs"] == nil && schema["anyOf"] == nil)
        #expect(input["draft_feedback"] == nil)
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_first_missing_rubric_criterion"] == nil)
        #expect(!review.prompt.contains("The first stated boundary gap needs clarification."))
        #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
        #expect(input["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(input["source_evidence"] == "" && input["attachment"] == "")
        let fixed = try JSONDecoder().decode([String].self, from: Data(try #require(input["fixed_output_fields"]).utf8))
        #expect(fixed == (personal ? ["reference"] : []))
        for request in requests {
            #expect(request.modelName == "synthetic-gap-schema" && request.temperature == 0)
            #expect(request.numPredict == 1200 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
        }
    }

    @Test(arguments: [1, 4, 12], [false, true])
    func bothRequestsDescribeFrozenCriteriaWithLiteralQuotesAndFinalFirstGap(criteriaCount: Int, personal: Bool) async throws {
        let fixture = makeFixture(criteriaCount: criteriaCount, personal: personal)
        let provider = FinalGapSchemaPackets(packets: [try packet(fixture, missing: Set([0])), try packet(fixture, reviewed: true)])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered.map(\.quote) == fixture.quotes)
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let primary = try object(try #require(requests[0].responseSchema))
        let primaryFields = try object(try #require(primary["properties"]))
        for i in 0..<criteriaCount {
            let id = "r\(i)"
            #expect(primaryFields[id] == .object(["type": .string("string"), "description": .string("Supplied frozen rubric criterion for \(id): \(fixture.task.criteria[i])\nFor \(id), copy an exact answer substring expressing relevant content even if wrong or incomplete, or empty if absent. Assess fulfillment separately in assessments; do not put explanations in the quote.")]))
        }
        #expect(primaryFields["followUp"] == .object(["type": .string("string")]))
        let review = requests[1]
        let input = try JSONDecoder().decode([String: String].self, from: Data(review.prompt.utf8))
        let grounded = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8))
        #expect(grounded == review.responseSchema)
        let schema = try object(try #require(review.responseSchema))
        let fields = try object(try #require(schema["properties"]))
        for i in 0..<criteriaCount {
            let id = "r\(i)"
            #expect(fields[id] == .object(["type": .string("string"), "description": .string("Supplied frozen rubric criterion for \(id): \(fixture.task.criteria[i])\nFor \(id), copy an exact answer substring expressing content relevant to its supplied criterion, even when wrong or incomplete; empty only when absent. Assess fulfillment separately in assessments. Never put explanations in the quote field.")]))
        }
        let boundFollowUp = try object(try #require(fields["followUp"]))
        #expect(Set(boundFollowUp.keys) == ["type", "description"] && boundFollowUp["type"] == .string("string"))
        guard case .string(let followUpDescription)? = boundFollowUp["description"] else { Issue.record("Expected the final selector annotation."); return }
        #expect(followUpDescription.hasPrefix("One direct question for only the first criterion whose assessments fulfillment is not met, in rubric order. Ask for the actual gap or clarification, not content already expressed. Empty when all are met. Optional refinements belong in suggestion.\n"))
        #expect(followUpDescription.contains("your own final returned rubric values, not the draft map"))
        #expect(schema["anyOf"] == nil && schema["$defs"] == nil && schema["additionalProperties"] == .boolean(false))
        #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
        #expect(input["source_evidence"] == "" && input["attachment"] == "")
        let fixed = try JSONDecoder().decode([String].self, from: Data(try #require(input["fixed_output_fields"]).utf8))
        #expect(fixed == (personal ? ["reference"] : []))
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (personal
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string")])))
        for request in requests {
            #expect(request.modelName == "synthetic-gap-schema" && request.temperature == 0)
            #expect(request.numPredict == 1200 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
        }
    }

    @Test
    func twelveCriteriaKeepTheExistingScenarioWithinBudgetWithoutTruncation() async throws {
        // This same-size request crossed 24KB in rejected complete-object v2.
        let fixture = makeFixture(criteriaCount: 12, personal: true, scenarioLength: 6500)
        let provider = FinalGapSchemaPackets(packets: [try packet(fixture, missing: Set([0])), try packet(fixture, reviewed: true)])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered.count == 12 && feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
            #expect(input["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(request.prompt.utf8.count <= 24000 && request.numPredict == 1200)
        }
    }

    @Test(arguments: [0, 1, 2])
    func changedFinalMapStillOwnsItsFirstGap(firstGap: Int) async throws {
        let fixture = makeFixture(criteriaCount: 3, absentBoundary: firstGap)
        let primary = try packet(fixture) // Its unrelated literal quote is not support for the selected criterion.
        let final = try packet(fixture, missing: Set([firstGap]), reviewed: true)
        let provider = FinalGapSchemaPackets(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.missing == [fixture.task.criteria[firstGap]])
        #expect(feedback.covered.map(\.quote) == fixture.quotes.enumerated().filter { $0.offset != firstGap }.map(\.element))
        #expect(feedback.followUp == (try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(final.utf8))).followUp)
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: FinalGapInvalidPacket.allCases)
    fileprivate func ignoredSchemaCannotWeakenRuntimeAdmission(failure: FinalGapInvalidPacket) async throws {
        let fixture = makeFixture(criteriaCount: 2, personal: failure == .changedSourceNotice)
        let primary = try packet(fixture)
        let needsRepair = failure == .missingWithoutQuestion || failure == .missingWithWhitespaceQuestion
        let declaredFinal = try packet(fixture, missing: needsRepair ? Set([0]) : [], reviewed: true)
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(declaredFinal.utf8))
        let expected: String
        switch failure {
        case .completeWithQuestion: final["followUp"] = .string("Which nonexistent gap remains?"); expected = "complete rubric map"
        case .missingWithoutQuestion: final["followUp"] = .string(""); expected = "provides no targeted follow-up"
        case .missingWithWhitespaceQuestion: final["followUp"] = .string(" \n "); expected = "provides no targeted follow-up"
        case .inventedQuote: final["r0"] = .string("An unsupported quote from another revision."); expected = "quote/rubric validation"
        case .omittedRubric: final.removeValue(forKey: "r0"); expected = "omitted or invented rubric IDs"
        case .inventedRubric: final["r88"] = .string(fixture.quotes[0]); expected = "omitted or invented rubric IDs"
        case .changedSourceNotice: final["reference"] = .string("I delivered the initiative and increased output by 80%."); expected = "source-limited reference"
        case .unverified: final.removeValue(forKey: "reviewOutcome"); expected = "did not verify"
        case .rejected: final["reviewOutcome"] = .string("rejected"); expected = "Reviewer reported (unverified)"
        case .emptyReference: final["reference"] = .string(" \n "); expected = "empty reference answer"
        }
        let finalWire = String(decoding: try JSONEncoder().encode(final), as: UTF8.self)
        let packets = needsRepair ? [primary, finalWire, "{\"followUp\":\"\"}"] : [primary, finalWire]
        let provider = FinalGapSchemaPackets(packets: packets)
        do {
            _ = try await evaluate(fixture, provider)
            Issue.record("The schema-ignoring packet was accepted.")
        } catch { #expect(error.localizedDescription.contains(expected)) }
        #expect(await provider.recorded().count == (needsRepair ? 3 : 2))
    }

    private func makeFixture(criteriaCount: Int, personal: Bool = false, absentBoundary: Int? = nil, scenarioLength: Int = 0) -> FinalGapSchemaFixture {
        let quotes = (0..<criteriaCount).map { index in
            index == absentBoundary ? "A separate rehearsal note was recorded." : personal
                ? "I recorded boundary \(index)." : "Boundary \(index) is the declared set of admitted transitions."
        }
        let question = (personal ? "Describe the boundaries you recorded." : "Explain the supplied boundaries.")
            + String(repeating: "n", count: scenarioLength)
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: "en")
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-gap-schema",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "synthetic-gap-schema", questionRevision: 3, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-gap-schema", failure: nil, latencyMS: 0))
        task.criteria = (0..<criteriaCount).map { "Describe boundary \($0)" }
        let attempt = PracticeAttempt(questionID: "synthetic-gap-schema", question: question,
            answer: quotes.joined(separator: " "), contextSnapshotID: nil, revision: 3, hinted: false,
            skipped: false, source: "synthetic-test", task: task)
        return .init(attempt: attempt, task: task, quotes: quotes, reference: personal
            ? PracticeFeedback.sourceLimitedReference(language: "en")
            : "The specified admitted transitions define the scope; conclusions apply only to that declared scope.")
    }
    private func packet(_ fixture: FinalGapSchemaFixture, missing: Set<Int> = [], reviewed: Bool = false) throws -> String {
        var wire = Dictionary(uniqueKeysWithValues: fixture.quotes.enumerated().map { ("r\($0.offset)", missing.contains($0.offset) ? "" : $0.element) })
        let question = missing.min().map { "What information defines boundary \($0)?" } ?? ""
        wire.merge(["suggestion": "Explain only the requested boundaries.", "followUp": question,
            "reason": missing.isEmpty ? "The supplied boundaries are stated." : "The first stated boundary gap needs clarification.",
            "reference": fixture.task.personalEvidence == .required ? "" : fixture.reference]) { _, new in new }
        if reviewed { wire["reviewOutcome"] = "accepted" }
        let fulfilledIDs = Set(fixture.task.criteria.indices.filter { !missing.contains($0) }.map { "r\($0)" })
        return try scriptedPracticePacket(wire, fulfilledIDs: fulfilledIDs)
    }
    private func evaluate(_ fixture: FinalGapSchemaFixture, _ provider: FinalGapSchemaPackets) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-gap-schema")
    }
    private func object(_ value: LocalJSONValue) throws -> [String: LocalJSONValue] {
        guard case .object(let fields) = value else { throw MaterialError.invalid("Expected schema object.") }
        return fields
    }
    private func array(_ value: LocalJSONValue) throws -> [LocalJSONValue] {
        guard case .array(let values) = value else { throw MaterialError.invalid("Expected schema array.") }
        return values
    }
    private func strings(_ value: LocalJSONValue) throws -> [String] {
        try array(value).map {
            guard case .string(let text) = $0 else { throw MaterialError.invalid("Expected schema string.") }
            return text
        }
    }
}
private struct FinalGapSchemaFixture {
    let attempt: PracticeAttempt
    let task: InterviewTaskDescriptor
    let quotes: [String]
    let reference: String
}
private enum FinalGapInvalidPacket: CaseIterable, Sendable {
    case completeWithQuestion, missingWithoutQuestion, missingWithWhitespaceQuestion, inventedQuote
    case omittedRubric, inventedRubric, changedSourceNotice, unverified, rejected, emptyReference
}
private actor FinalGapSchemaPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-gap-schema"
    nonisolated let displayName = "Finite final-gap contract packets"
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
        guard index < packets.count && index < 3 else { throw MaterialError.invalid("Unexpected additional correlation request.") }
        let wire = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
