import Foundation
import Testing
@testable import Hireva

/// Real evaluate entry with two finite controlled packets. These tests prove
/// the admission boundary, not a local model's semantic or reference quality.
@Suite
@MainActor
struct PracticeFinalMapAuthorityTests {
    @Test
    func capturedGenericBottleneckFailureCanReceiveAJustifiedFinalMapCorrection() async throws {
        // Original synthetic primary output: B9699DF6-E685-405B-B8DD-E6DB4793E8B8.
        // The already-correct route is frozen here, so only the two evaluation calls run.
        let question = "What bottlenecks can arise under peak load and how would the design mitigate them?"
        let answer = "Queue backpressure and provider rate limits are likely bottlenecks. Measure queue age and retry rate. Bound worker concurrency per provider and tenant, apply backpressure at the API, and scale workers only within provider limits. Partition queues to isolate noisy tenants."
        var task = InterviewTaskDescriptor(question: question, kind: .systemDesign, language: "en")
        task.apply(.init(task: .systemDesign, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-final-map", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "synthetic-bottleneck", questionRevision: 1,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-final-map", failure: nil, latencyMS: 0))
        task.criteria = ["Bottlenecks / 瓶颈"]
        let attempt = PracticeAttempt(questionID: "synthetic-bottleneck", question: question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let historicalPrimary = try JSONDecoder().decode([String: String].self, from: Data("{\"followUp\":\"Can you describe a specific instance where a queue age or retry rate metric indicated an impending bottleneck, and what was the actual observed outcome?\", \"r0\":\"\", \"reason\":\"The answer correctly identifies potential bottlenecks (queue backpressure, provider rate limits) and mitigation strategies (measuring metrics, bounding concurrency, applying backpressure, partitioning queues). However, it lacks a concrete, observed outcome or result from a real or hypothetical scenario to satisfy the 'Bottlenecks' criterion, which requires stating the actual problem or disagreement that occurred. The answer provides intentions and proposed actions but does not describe a specific situation where a bottleneck was actually encountered or confirmed.\", \"reference\":\"Under peak load, bottlenecks typically arise from queue backpressure (messages piling up due to slow consumers or rate-limited providers) and provider rate limits (API quotas). To mitigate these, measure queue age and retry rates to detect saturation early. Bound worker concurrency per provider and tenant, apply backpressure at the API layer (e.g., throttling requests), and scale workers only within provider limits. Partition queues to isolate noisy tenants and prevent them from affecting others.\", \"suggestion\":\"The answer correctly identifies the likely bottlenecks and mitigation strategies. To fully satisfy the rubric, consider adding a specific example or hypothetical scenario describing a situation where these bottlenecks were observed (e.g., 'In a previous design, queue age spiked to 5 minutes when...') to demonstrate the actual impact and confirm the mitigation's necessity.\"}".utf8))
        let historicalWire = String(decoding: try JSONEncoder().encode(historicalPrimary), as: UTF8.self)
        let legacy = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(historicalWire.utf8))
        #expect(legacy.assessments == nil)
        let primary = try JSONDecoder().decode(PracticeEvaluationPayload.self, from:
            Data(try scriptedPracticePacket(historicalPrimary, fulfilledIDs: []).utf8))
        let quote = "Queue backpressure and provider rate limits are likely bottlenecks."
        let final = try packet([quote], fulfilledIDs: ["r0"], followUp: "", reason: "The answer identifies the requested bottlenecks and concrete mitigations.",
            reference: primary.reference, final: true)
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-final-map")
        #expect(feedback.covered == [.init(criterion: task.criteria[0], quote: quote)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for request in requests {
            let values = try input(request)
            #expect(values["question"] == question && values["answer"] == answer)
            #expect(values["source_evidence"] == "" && values["rubric"] == "r0: Bottlenecks / 瓶颈")
        }
    }

    @Test(arguments: ["en", "zh"])
    func finalReviewCanCorrectAnIncorrectMissingJudgment(language: String) async throws {
        let fixture = makeFixture(language: language)
        let quote = fixture.definition
        let primary = try packet([""], fulfilledIDs: [], followUp: fixture.firstQuestion,
            reason: "A concrete observed outcome is still needed.")
        var final = try packet([quote], fulfilledIDs: ["r0"], followUp: "",
            reason: language == "zh" ? "已说明所问概念。" : "The supplied concept criterion is stated.",
            reference: language == "zh" ? "不变量是允许的转换所保持的性质；结论限于该转换范围。" : "An invariant is a property preserved by permitted transitions; the conclusion is scoped to those transitions.", final: true)
        if language == "zh" { final.suggestion = "" }
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: quote)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try checkFrozenInputs(fixture, requests)
        let review = try input(requests[1])
        #expect(review["draft_feedback"] == nil)
        #expect(review["first_missing_rubric_id"] == nil)
        #expect(review["draft_first_missing_rubric_id"] == nil)
        #expect(review["draft_first_missing_rubric_criterion"] == nil)
        let fields = try fields(requests[1])
        for key in ["r0", "followUp"] {
            guard case .object(let field)? = fields[key] else {
                Issue.record("Final quote/question fields must stay editable strings."); return
            }
            #expect(field["type"] == .string("string"))
            #expect(Set(field.keys) == Set(["type", "description"]))
            if case .string(let description)? = field["description"] { #expect(!description.isEmpty) }
            else { Issue.record("Expected a string annotation, not an output constraint.") }
        }
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == .object(["type": .string("string")]))
        let fixed = try JSONDecoder().decode([String].self, from: Data(try #require(review["fixed_output_fields"]).utf8))
        #expect(fixed.isEmpty)
    }

    @Test
    func finalReviewCanRemoveLiteralButUnsupportedCoverageAndExposeItsGap() async throws {
        let fixture = makeFixture(language: "en", withScope: true, answerMode: .scopeOnly)
        let primary = try packet([fixture.unrelated, fixture.scope], fulfilledIDs: ["r0", "r1"], followUp: "", reason: "Both criteria are covered.")
        let final = try packet(["", fixture.scope], fulfilledIDs: ["r1"], followUp: fixture.firstQuestion,
            reason: "The scope is stated; the preserved property is not defined.", final: true)
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[1], quote: fixture.scope)])
        #expect(feedback.missing == [fixture.task.criteria[0]])
        #expect(feedback.followUp == fixture.firstQuestion)
        let requests = await provider.recorded()
        try checkFrozenInputs(fixture, requests)
        let review = try input(requests[1])
        #expect(review["draft_first_missing_rubric_id"] == nil)
        let reviewFields = try fields(requests[1])
        for key in ["followUp"] {
            guard case .object(let field)? = reviewFields[key] else {
                Issue.record("Final quote/question fields must stay editable strings."); return
            }
            #expect(field["type"] == .string("string"))
            #expect(Set(field.keys) == Set(["type", "description"]))
            if case .string(let description)? = field["description"] { #expect(!description.isEmpty) }
            else { Issue.record("Expected a string annotation, not an output constraint.") }
        }
    }

    @Test
    func firstGapComesFromTheCorrectedMapRatherThanThePrimaryMap() async throws {
        let fixture = makeFixture(language: "en", withScope: true)
        let primary = try packet(["", fixture.unrelated], fulfilledIDs: ["r1"], followUp: fixture.firstQuestion,
            reason: "The definition is missing; the scope is covered.")
        let final = try packet([fixture.definition, ""], fulfilledIDs: ["r0"], followUp: fixture.scopeQuestion,
            reason: "The definition is stated; the scope is missing.", final: true)
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: fixture.definition)])
        #expect(feedback.missing == [fixture.task.criteria[1]])
        #expect(feedback.followUp == fixture.scopeQuestion)
        let requests = await provider.recorded()
        try checkFrozenInputs(fixture, requests)
        let review = try input(requests[1])
        #expect(review["first_missing_rubric_id"] == nil && review["first_missing_rubric_criterion"] == nil)
        #expect(review["draft_first_missing_rubric_id"] == nil)
        #expect(requests[1].systemPrompt?.contains("followUp asks only for the FIRST non-met assessment") == true)
    }

    @Test
    func finalReviewMayUseADifferentSupportingSubstringOfTheSameRevision() async throws {
        let fixture = makeFixture(language: "en")
        let shorter = "property preserved by admitted transitions."
        let primary = try packet([fixture.definition], fulfilledIDs: ["r0"], followUp: "", reason: "The definition is stated.")
        let final = try packet([shorter], fulfilledIDs: ["r0"], followUp: "", reason: "The same definition is supported by the unchanged substring.", final: true)
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: shorter)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        try checkFrozenInputs(fixture, await provider.recorded())
    }

    @Test(arguments: FinalMapInvalidOutput.allCases)
    fileprivate func mapCorrectionCannotWeakenLiteralRubricSourceOrReviewAdmission(failure: FinalMapInvalidOutput) async throws {
        let fixture = makeFixture(language: "en", personal: failure == .sourceNotice)
        let primary = try packet([fixture.definition], fulfilledIDs: ["r0"], followUp: "", reason: "The stated content is quoted.",
            reference: fixture.reference)
        var final = try packet([fixture.definition], fulfilledIDs: ["r0"], followUp: "", reason: "The stated content is quoted.",
            reference: fixture.reference, final: true)
        switch failure {
        case .inventedQuote: final.coverage["r0"] = .some("NOT_IN_THE_ORIGINAL_ANSWER")
        case .otherRevisionQuote: final.coverage["r0"] = .some("I corrected the later revision to state a different property.")
        case .inventedID: final.coverage["r99"] = .some(fixture.definition)
        case .omittedID: final.coverage.removeValue(forKey: "r0")
        case .sourceNotice: final.reference = "I completed a deployment and improved throughput by 80%."
        case .unverified: final.reviewOutcome = nil
        case .rejected: final.reviewOutcome = "rejected"
        case .emptyReference: final.reference = " \n "
        case .completeWithQuestion: final.followUp = fixture.firstQuestion
        }
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let error = try await rejected(fixture, provider)
        switch failure {
        case .inventedQuote, .otherRevisionQuote: #expect(error.contains("quote/rubric validation"))
        case .inventedID, .omittedID: #expect(error.contains("omitted or invented rubric IDs"))
        case .sourceNotice: #expect(error.contains("source-limited reference"))
        case .unverified: #expect(error.contains("did not verify"))
        case .rejected: #expect(error.contains("Reviewer reported (unverified)"))
        case .emptyReference: #expect(error.contains("empty reference answer"))
        case .completeWithQuestion: #expect(error.contains("complete rubric map"))
        }
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: InvalidPrimaryMap.allCases)
    fileprivate func anInvalidPrimaryMapDoesNotBecomeTheFinalReviewAuthority(failure: InvalidPrimaryMap) async throws {
        let fixture = makeFixture(language: "en")
        var primary = try packet([fixture.definition], fulfilledIDs: ["r0"], followUp: "", reason: "Draft only.")
        switch failure {
        case .inventedQuote: primary.coverage["r0"] = .some("NOT_IN_THIS_REVISION")
        case .inventedID: primary.coverage["r9"] = .some(fixture.definition)
        case .omittedID: primary.coverage.removeValue(forKey: "r0")
        }
        let final = try packet([fixture.definition], fulfilledIDs: ["r0"], followUp: "", reason: "The supplied definition is stated.", final: true)
        let provider = FinalMapPacketProvider(packets: [primary, final])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: fixture.definition)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let review = try input(requests[1])
        #expect(review["draft_feedback"] == nil && review["previous_invalid_output"] == nil)
        #expect(requests[1].systemPrompt?.contains("Independently critique the complete original answer") == true)
        try checkFrozenInputs(fixture, requests)
    }

    private func makeFixture(language: String, withScope: Bool = false, answerMode: FinalMapAnswerMode = .definition,
                             personal: Bool = false) -> FinalMapFixture {
        let chinese = language == "zh"
        let definition = personal ? "I recorded the agreed constraints." : chinese
            ? "不变量是允许的转换所保持的性质。" : "An invariant is a property preserved by admitted transitions."
        let scope = "The scope is the admitted transitions."
        let unrelated = "I enjoy drawing."
        let answer = answerMode == .scopeOnly ? scope + " " + unrelated : definition + " " + unrelated
        let question = personal ? "Describe an action you performed." : chinese ? "解释不变量。" : withScope
            ? "Define an invariant and identify its scope." : "Define an invariant."
        let criteria = personal ? ["Stated action"] : chinese ? ["解释性质"] : withScope
            ? ["Define the property", "State its scope"] : ["Define the property"]
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-final-map", routerVersion: InterviewQuestionRouter.version, language: language,
            clarification: "", questionID: "synthetic-final-map", questionRevision: 7,
            contextSnapshotID: "synthetic-frozen-context", artifactRevision: 0,
            model: "synthetic-final-map", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: "synthetic-final-map", question: question, answer: answer,
            contextSnapshotID: "synthetic-frozen-context", revision: 7, hinted: false, skipped: false,
            source: "synthetic-test", task: task)
        return .init(attempt: attempt, task: task, definition: definition, scope: scope, unrelated: unrelated,
            firstQuestion: chinese ? "需要保持的性质是什么？" : "Which property is preserved by the admitted transitions?",
            scopeQuestion: "Which transitions are in scope for the supplied rule?",
            reference: personal ? PracticeFeedback.sourceLimitedReference(language: language)
                : "Define the preserved property and admitted transitions; conclusions are limited to that stated scope.")
    }
    private func packet(_ quotes: [String], fulfilledIDs: Set<String>, followUp: String, reason: String,
                        reference: String = "Define the property and admitted transitions; guarantees depend on that scope.",
                        final: Bool = false) throws -> PracticeEvaluationPayload {
        var result = Dictionary(uniqueKeysWithValues: quotes.enumerated().map { ("r\($0.offset)", $0.element) })
        result.merge(["suggestion": "Explain only the remaining requested information.", "followUp": followUp,
            "reason": reason, "reference": reference]) { _, new in new }
        if final { result["reviewOutcome"] = "accepted" }
        return try JSONDecoder().decode(PracticeEvaluationPayload.self, from:
            Data(try scriptedPracticePacket(result, fulfilledIDs: fulfilledIDs).utf8))
    }
    private func evaluate(_ fixture: FinalMapFixture, _ provider: FinalMapPacketProvider) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-final-map")
    }
    private func rejected(_ fixture: FinalMapFixture, _ provider: FinalMapPacketProvider) async throws -> String {
        do {
            _ = try await evaluate(fixture, provider)
            Issue.record("An invalid packet was accepted as feedback.")
            return "UNEXPECTED_ACCEPTANCE"
        } catch { return error.localizedDescription }
    }
    private func checkFrozenInputs(_ fixture: FinalMapFixture, _ requests: [LocalLLMRequest]) throws {
        try #require(requests.count == 2)
        for request in requests {
            let values = try input(request)
            #expect(values["question"] == fixture.attempt.question && values["answer"] == fixture.attempt.answer)
            #expect(values["rubric"] == fixture.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(values["attachment"] == "" && values["source_evidence"] == "")
            #expect(request.modelName == "synthetic-final-map" && request.temperature == 0)
            #expect(request.numPredict == 1200 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
        }
        let review = try input(requests[1])
        let schema = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(review["output_schema"]).utf8))
        #expect(schema == requests[1].responseSchema)
        let fields = try fields(requests[1])
        #expect(Set(fields.keys) == Set(fixture.task.criteria.indices.map { "r\($0)" } + ["assessments", "suggestion", "followUp", "reason", "reference", "reviewOutcome"]))
    }
    private func input(_ request: LocalLLMRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
    }
    private func fields(_ request: LocalLLMRequest) throws -> [String: LocalJSONValue] {
        guard case .object(let schema)? = request.responseSchema,
              case .object(let fields)? = schema["properties"] else {
            throw MaterialError.invalid("Missing final map schema.")
        }
        return fields
    }
}
private enum FinalMapAnswerMode { case definition, scopeOnly }
private enum FinalMapInvalidOutput: CaseIterable, Sendable {
    case inventedQuote, otherRevisionQuote, inventedID, omittedID, sourceNotice, unverified, rejected, emptyReference, completeWithQuestion
}
private enum InvalidPrimaryMap: CaseIterable, Sendable { case inventedQuote, inventedID, omittedID }
private struct FinalMapFixture {
    var attempt: PracticeAttempt
    var task: InterviewTaskDescriptor
    var definition: String
    var scope: String
    var unrelated: String
    var firstQuestion: String
    var scopeQuestion: String
    var reference: String
}
private actor FinalMapPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-final-map"
    nonisolated let displayName = "Finite map-correction packets"
    private let packets: [PracticeEvaluationPayload]
    private var requests: [LocalLLMRequest] = []
    init(packets: [PracticeEvaluationPayload]) { self.packets = packets }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra final-map request.") }
        let wire = String(decoding: try JSONEncoder().encode(packets[index]), as: UTF8.self)
        return AsyncThrowingStream { c in
            c.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); c.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
