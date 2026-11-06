import Foundation
import Testing
@testable import Hireva

/// Actual evaluate entry and exact wire guards only. Fixed packets do not prove
/// that a real model follows this policy or that technical references are true.
@Suite
@MainActor
struct PracticeReviewDispositionTargetTests {
    @Test(arguments: ReviewTargetScenario.allCases)
    func requestSeparatesFeedbackValidityFromAnswerCompleteness(scenario: ReviewTargetScenario) async throws {
        let fixture = makeFixture(scenario)
        var final = fixture.primary
        final["reviewOutcome"] = "accepted"
        let provider = DispositionTargetProvider(packets: [
            try scriptedPracticePacket(fixture.primary, fulfilledIDs: fixture.fulfilledIDs),
            try scriptedPracticePacket(final, fulfilledIDs: fixture.fulfilledIDs)
        ])
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-disposition-target")
        #expect(feedback.covered.map(\.quote) == fixture.expectedQuotes)
        #expect(feedback.missing == fixture.expectedMissing)
        #expect(feedback.followUp == (fixture.expectedMissing.isEmpty ? nil : final["followUp"]))
        #expect(feedback.reference == (scenario.personal ? PracticeFeedback.sourceLimitedReference(language: fixture.task.language) : final["reference"]))
        #expect(feedback.reason == final["reason"])
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let inputs = try requests.map { try JSONDecoder().decode([String: String].self, from: Data($0.prompt.utf8)) }
        for (request, input) in zip(requests, inputs) {
            #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(request.modelName == "synthetic-disposition-target" && request.numPredict == 1200)
            #expect(request.temperature == 0 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
        }
        let system = try #require(requests[1].systemPrompt)
        #expect(system.contains("reviewOutcome judges the corrected feedback's validity, not candidate competence or completeness"))
        #expect(system.contains("Brief, wrong or incomplete answers can receive accepted accurate feedback"))
        #expect(system.contains("Acceptance is not independent fact certification"))
        #expect(!(try #require(requests[0].systemPrompt)).contains("Review-disposition target:"))
        #expect(inputs[1]["validation_failure"] == nil)
        #expect(inputs[1]["draft_feedback"] == nil)
        #expect(inputs[1]["draft_first_missing_rubric_id"] == nil && inputs[1]["draft_first_missing_rubric_criterion"] == nil)
        let schema = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(inputs[1]["output_schema"]).utf8))
        #expect(schema == requests[1].responseSchema)
        guard case .object(let object) = schema, case .object(let fields)? = object["properties"] else {
            Issue.record("Final schema must preserve the frozen rubric IDs and source authority."); return
        }
        for (index, _) in fixture.task.criteria.enumerated() {
            let key = "r\(index)"
            guard case .object(let field)? = fields[key] else {
                Issue.record("Final quote fields must stay editable strings."); return
            }
            #expect(field["type"] == .string("string"))
            #expect(Set(field.keys) == Set(["type", "description"]))
            if case .string(let description)? = field["description"] { #expect(!description.isEmpty) }
            else { Issue.record("Expected a string annotation, not an output constraint.") }
        }
        #expect(fields["reviewOutcome"] == .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])]))
        #expect(practiceReferenceSchemaConstraints(fields["reference"]) == (scenario.personal
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string")])))
    }

    @Test(arguments: [false, true])
    func anExplicitDefectStillRejectsWithoutPublishingFeedback(personal: Bool) async throws {
        let fixture = makeFixture(personal ? .personalFutureGapZH : .offTopicEN)
        var final = fixture.primary
        final["reviewOutcome"] = "rejected"
        final["reason"] = "The frozen map cannot be supported by the submitted answer."
        final["suggestion"] = "REJECTED_SUGGESTION_NOT_FEEDBACK"
        let provider = DispositionTargetProvider(packets: [
            try scriptedPracticePacket(fixture.primary, fulfilledIDs: fixture.fulfilledIDs),
            try scriptedPracticePacket(final, fulfilledIDs: fixture.fulfilledIDs)
        ])
        let error = try await rejected(fixture, provider: provider)
        #expect(error.contains("Semantic review rejected this feedback"))
        #expect(error.contains("Reviewer reported (unverified)"))
        #expect(!error.contains(final["suggestion"]!))
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: [false, true])
    func acceptanceCannotInventQuotesFromAnotherAnswer(personal: Bool) async throws {
        let fixture = makeFixture(personal ? .personalFutureGapZH : .offTopicEN)
        var final = fixture.primary
        final["reviewOutcome"] = "accepted"
        let rawFinal = try scriptedPracticePacket(final, fulfilledIDs: fixture.fulfilledIDs)
        var foreign = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(rawFinal.utf8))
        foreign.coverage["r0"] = .some(personal ? "I completed the later review." : "The later answer supplies an invariant not stated here.")
        foreign.assessments?["r0"] = .init(presence: .present, accuracy: .unverified,
            accuracyBasis: "scripted adversarial declaration; not factual verification", fulfillment: .met,
            basis: "Scripted adversarial fulfillment claim.")
        let provider = DispositionTargetProvider(packets: [
            try scriptedPracticePacket(fixture.primary, fulfilledIDs: fixture.fulfilledIDs),
            String(decoding: try JSONEncoder().encode(foreign), as: UTF8.self)
        ])
        let error = try await rejected(fixture, provider: provider)
        #expect(error.contains("quote/rubric validation"))
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: ["missing", "unknown"])
    func incompleteAnswerDoesNotCreateAnImplicitAcceptance(disposition: String) async throws {
        let fixture = makeFixture(.emptyEN)
        var final = fixture.primary
        if disposition == "unknown" { final["reviewOutcome"] = "unknown" }
        let provider = DispositionTargetProvider(packets: [
            try scriptedPracticePacket(fixture.primary, fulfilledIDs: fixture.fulfilledIDs),
            try scriptedPracticePacket(final, fulfilledIDs: fixture.fulfilledIDs)
        ])
        let error = try await rejected(fixture, provider: provider)
        #expect(error.contains("Semantic review rejected or did not verify"))
        #expect(await provider.recorded().count == 2)
    }

    private func makeFixture(_ scenario: ReviewTargetScenario) -> DispositionTargetFixture {
        let personal = scenario.personal, chinese = scenario.chinese
        let question = personal ? "描述一次你的行动，以及目前已知的结果。" : (chinese ? "解释不变量及其适用范围。" : "Explain an invariant and its scope.")
        let definition = chinese ? "不变量是在允许转换中保持的性质。" : "An invariant is a property preserved by admitted transitions."
        let scope = "The scope is the admitted transitions."
        let action = "我记录了不同方案。"
        let answer: String
        switch scenario {
        case .offTopicEN: answer = "I enjoy drawing."
        case .emptyEN: answer = ""
        case .shortGapZH: answer = definition
        case .generalCompleteEN: answer = definition + " " + scope
        case .personalFutureGapZH: answer = action + " 我计划下周进行复核。"
        }
        let criteria = personal ? ["个人行动", "已观察结果"] : (chinese ? ["解释不变量", "说明范围"] : ["Explain invariant", "State scope"])
        let language = chinese ? "zh" : "en"
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-disposition-target", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-disposition-target", questionRevision: 2,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-disposition-target", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let first = personal ? action : (scenario == .shortGapZH || scenario == .generalCompleteEN ? definition : "")
        let second = scenario == .generalCompleteEN ? scope : ""
        let firstMissing = first.isEmpty ? "r0" : second.isEmpty ? "r1" : nil
        let primary = ["r0": first, "r1": second,
            "followUp": firstMissing == nil ? "" : (personal ? "目前已知或观察到什么结果，如果没有，可以说明尚无结果吗？" : (chinese ? "拟用规则的适用范围是什么？" : firstMissing == "r0" ? "What is an invariant?" : "Which transitions define this invariant's scope?")),
            "reason": chinese ? "已经表达的内容保留；所标明的评价项仍缺失。" : firstMissing == nil ? "Both requested elements are present." : "The stated content is retained; the indicated criterion is still missing.",
            "suggestion": chinese ? "只补充第一个缺口所要求的信息。" : firstMissing == nil ? "No further example is required." : "Add only the information needed for the first missing criterion.",
            "reference": personal ? "" : (chinese ? "定义所保持的性质和允许的转换；结论取决于该适用范围。" : "Define the preserved property and the admitted transitions; its guarantees depend on that scope.")]
        return .init(attempt: .init(questionID: "synthetic-disposition-target", question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task),
            task: task, primary: primary, expectedQuotes: [first, second].filter { !$0.isEmpty },
            expectedMissing: criteria.enumerated().compactMap { primary["r\($0.offset)"] == "" ? $0.element : nil },
            firstMissingID: firstMissing, fulfilledIDs: scenario == .generalCompleteEN ? ["r0", "r1"]
                : (scenario == .shortGapZH || scenario == .personalFutureGapZH ? ["r0"] : []))
    }
    private func rejected(_ fixture: DispositionTargetFixture, provider: DispositionTargetProvider) async throws -> String {
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-disposition-target")
            Issue.record("Unverified, rejected or foreign-answer outputs must not create feedback.")
            return "UNEXPECTED_ACCEPTANCE"
        } catch { return error.localizedDescription }
    }
}
enum ReviewTargetScenario: CaseIterable, Sendable {
    case offTopicEN, emptyEN, shortGapZH, generalCompleteEN, personalFutureGapZH
    var personal: Bool { self == .personalFutureGapZH }
    var chinese: Bool { self == .shortGapZH || personal }
}
private struct DispositionTargetFixture {
    var attempt: PracticeAttempt
    var task: InterviewTaskDescriptor
    var primary: [String: String]
    var expectedQuotes: [String]
    var expectedMissing: [String]
    var firstMissingID: String?
    var fulfilledIDs: Set<String>
}
private actor DispositionTargetProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-disposition-target"
    nonisolated let displayName = "Finite scripted disposition packets"
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
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra disposition request.") }
        let wire = packets[index]
        return AsyncThrowingStream { c in c.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
