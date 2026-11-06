import Foundation
import Testing
@testable import Hireva

/// Existing JSON wire and actual evaluator only. Scripted review explanations
/// are untrusted diagnostic claims, never proof of model quality or competence.
@Suite
@MainActor
struct PracticeRejectedReviewDiagnosticTests {
    @Test(arguments: ["en", "zh"])
    func explicitRejectionReportsOnlyALabelledReviewerClaim(language: String) async throws {
        let fixture = try makeFixture(language: language)
        let reported = language == "zh"
            ? "固定引用表达了目标，没有表达评价标准所要求的观察。"
            : "The frozen quote states a goal rather than the requested observation."
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.packetWire.utf8))
        final["reviewOutcome"] = .string("accepted")
        final["reviewOutcome"] = .string("rejected")
        final["reason"] = .string(reported)
        final["suggestion"] = .string("REJECTED_SUGGESTION_MUST_NOT_BECOME_FEEDBACK")
        final["reference"] = .string("REJECTED_REFERENCE_MUST_NOT_BECOME_FEEDBACK")
        let provider = ReviewDiagnosticPacketProvider(packets: [fixture.packetWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        let error = try await failure(fixture: fixture, provider: provider)
        #expect(error.contains("Semantic review rejected"))
        #expect(error.contains("Reviewer reported (unverified): " + reported))
        #expect(error.contains("no feedback was accepted"))
        #expect(!error.contains("REJECTED_SUGGESTION_MUST_NOT_BECOME_FEEDBACK") && !error.contains("REJECTED_REFERENCE_MUST_NOT_BECOME_FEEDBACK"))
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
        #expect(input["rubric"] == "r0: " + fixture.task.criteria[0])
        #expect(input["source_evidence"] == "" && input["attachment"] == "")
        #expect(input["draft_feedback"] == nil)
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_first_missing_rubric_criterion"] == nil)
        #expect(!requests[1].prompt.contains(try #require(fixture.packet["suggestion"])))
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8)) == requests[1].responseSchema)
        #expect(try list(input, key: "fixed_output_fields") == [])
        #expect(try list(input, key: "editable_output_fields") == ["assessments", "followUp", "r0", "reason", "reference", "reviewOutcome", "suggestion"])
        let system = try #require(requests[1].systemPrompt)
        #expect(system.contains("reason/suggestion remain candidate-facing"))
        #expect(system.contains("otherwise reject and identify the concrete unsupported judgment"))
        #expect(system.contains("Acceptance is not independent fact certification"))
        #expect(system.contains("not candidate competence or completeness"))
        for request in requests {
            #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
            #expect(request.modelName == "synthetic-review-diagnostic" && request.prompt.utf8.count <= 24000)
        }
        let primary = try JSONDecoder().decode([String: String].self, from: Data(requests[0].prompt.utf8))
        #expect(primary["draft_feedback"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(primary["output_schema"]).utf8)) == requests[0].responseSchema)
        guard case .object(let schema)? = requests[1].responseSchema,
              case .object(let fields)? = schema["properties"] else {
            Issue.record("Actual final request must preserve the existing flat wire."); return
        }
        #expect(Set(fields.keys) == Set(["r0", "assessments", "followUp", "reason", "reference", "suggestion", "reviewOutcome"]))
        let feedbackField: LocalJSONValue = .object(["type": .string("string"), "description": .string(language == "zh"
            ? "此字段的候选人反馈必须使用中文；引用原文时保留原文语言。"
            : "Write this candidate-facing field in \(language); preserve the original language of quoted answer text.")])
        #expect(fields["reason"] == feedbackField && fields["suggestion"] == feedbackField)
        #expect(fields["reviewOutcome"] == .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])]))
    }

    @Test
    func acceptedReasonStillPublishesOnlyExistingCandidateFeedback() async throws {
        let fixture = try makeFixture(language: "en")
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.packetWire.utf8))
        final["reviewOutcome"] = .string("accepted")
        final["reviewOutcome"] = .string("accepted")
        let provider = ReviewDiagnosticPacketProvider(packets: [fixture.packetWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-review-diagnostic")
        #expect(feedback.reason == fixture.packet["reason"] && feedback.suggestions == [fixture.packet["suggestion"]!])
        #expect(feedback.reference == fixture.packet["reference"] && feedback.followUp == nil)
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: fixture.attempt.answer)])
        #expect(feedback.missing.isEmpty && !feedback.reason.contains("Reviewer reported"))
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: UnverifiedReviewDisposition.allCases)
    func unverifiedDispositionCannotExposeAReasonOrCreateAcceptance(disposition: UnverifiedReviewDisposition) async throws {
        let fixture = try makeFixture(language: "en")
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.packetWire.utf8))
        final["reviewOutcome"] = .string("accepted")
        switch disposition {
        case .missing: final.removeValue(forKey: "reviewOutcome")
        case .unknown: final["reviewOutcome"] = .string("unknown")
        case .paddedAcceptance: final["reviewOutcome"] = .string("accepted\n")
        }
        final["reason"] = .string("UNVERIFIED_REASON_MUST_REMAIN_UNPUBLISHED")
        let provider = ReviewDiagnosticPacketProvider(packets: [fixture.packetWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        let error = try await failure(fixture: fixture, provider: provider)
        #expect(error.contains("Semantic review rejected or did not verify"))
        #expect(!error.contains("UNVERIFIED_REASON_MUST_REMAIN_UNPUBLISHED") && !error.contains("Reviewer reported"))
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: ["ascii", "multibyte"])
    func explicitRejectedExplanationIsBoundedWithoutCuttingACharacter(kind: String) async throws {
        let fixture = try makeFixture(language: "en")
        let unit = kind == "ascii" ? "x" : "界🙂"
        let report = String(repeating: unit, count: 500) + "DO_NOT_EXPOSE_TRAILING_TEXT"
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.packetWire.utf8))
        final["reviewOutcome"] = .string("accepted")
        final["reviewOutcome"] = .string("rejected"); final["reason"] = .string(report)
        let provider = ReviewDiagnosticPacketProvider(packets: [fixture.packetWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        let error = try await failure(fixture: fixture, provider: provider)
        #expect(error.contains("Reviewer reported (unverified): " + String(report.prefix(400)) + "…"))
        #expect(!error.contains("DO_NOT_EXPOSE_TRAILING_TEXT"))
        #expect(!error.contains("�") && error.count < 700)
        #expect(await provider.recorded().count == 2)
    }

    @Test
    func rejectedEmptyReasonKeepsFailureWithoutFabricatingAnExplanation() async throws {
        let fixture = try makeFixture(language: "en")
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.packetWire.utf8))
        final["reviewOutcome"] = .string("accepted")
        final["reviewOutcome"] = .string("rejected"); final["reason"] = .string(" \n\t ")
        let provider = ReviewDiagnosticPacketProvider(packets: [fixture.packetWire, String(decoding: try JSONEncoder().encode(final), as: UTF8.self)])
        let error = try await failure(fixture: fixture, provider: provider)
        #expect(error.contains("Semantic review rejected"))
        #expect(error.contains("The reviewer provided no explanation."))
        #expect(!error.contains("Reviewer reported (unverified):"))
        #expect(error.contains("no feedback was accepted"))
        #expect(await provider.recorded().count == 2)
    }

    private func makeFixture(language: String) throws -> ReviewDiagnosticFixture {
        let chinese = language == "zh"
        let question = chinese ? "解释不变量的含义。" : "Explain what an invariant is."
        let answer = chinese ? "不变量是每次允许的状态转换都保持的性质。" : "An invariant is a property preserved by every admitted transition."
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-review-diagnostic", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-review-diagnostic", questionRevision: 2,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-review-diagnostic", failure: nil, latencyMS: 0))
        task.criteria = [chinese ? "解释不变量" : "Explain the invariant"]
        let attempt = PracticeAttempt(questionID: "synthetic-review-diagnostic", question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let packet = ["r0": answer, "followUp": "", "reason": chinese ? "已经解释了不变量。" : "The invariant is explained.",
            "suggestion": chinese ? "不需要额外的个人经历。" : "No personal experience is required.",
            "reference": chinese ? "不变量是在允许的转换中保持的性质；需要说明所约束的状态和转换。" : "An invariant is a property preserved by admitted transitions; specify the constrained state and transitions."]
        return .init(attempt: attempt, task: task, packet: packet,
            packetWire: try scriptedPracticePacket(packet, fulfilledIDs: ["r0"]))
    }
    private func failure(fixture: ReviewDiagnosticFixture, provider: ReviewDiagnosticPacketProvider) async throws -> String {
        do {
            _ = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-review-diagnostic")
            Issue.record("Rejected or unverified packets must not return accepted feedback.")
            return "UNEXPECTED_ACCEPTANCE"
        } catch { return error.localizedDescription }
    }
    private func list(_ input: [String: String], key: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(try #require(input[key]).utf8))
    }
}

enum UnverifiedReviewDisposition: CaseIterable, Sendable { case missing, unknown, paddedAcceptance }
private struct ReviewDiagnosticFixture {
    var attempt: PracticeAttempt
    var task: InterviewTaskDescriptor
    var packet: [String: String]
    var packetWire: String
}
private actor ReviewDiagnosticPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-review-diagnostic"
    nonisolated let displayName = "Explicit synthetic diagnostic packets"
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
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra diagnostic request.") }
        let wire = packets[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: wire, source: .localQwen, modelName: request.modelName)); continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
