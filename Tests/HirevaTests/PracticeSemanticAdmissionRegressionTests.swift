import Foundation
import Testing
@testable import Hireva

/// Archived model bytes stay unchanged and decode with unknown dimensions.
/// Separately declared scripted clones test current request/admission contracts;
/// they are not new model-quality evidence or factual certification.
@Suite
@MainActor
struct PracticeSemanticAdmissionRegressionTests {
    @Test(arguments: Array(0..<16))
    func eachCapturedMapReceivesFullContextReviewAndExplicitRejectionStaysFailure(index: Int) async throws {
        let row = try fixtures()[index]
        let legacy = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.capturedWire.utf8))
        #expect(legacy.assessments == nil)
        // Explicit test declarations preserve each historical map without
        // promoting historical model judgments into verified facts.
        let declaredFulfilledIDs: [Set<String>] = [
            [], ["r0", "r1", "r2", "r3"], [], ["r0", "r1", "r2", "r3"],
            ["r0"], ["r0"], ["r0"], ["r0"],
            ["r0", "r1"], ["r0", "r1", "r3"], ["r0", "r1"], ["r0", "r1", "r3"],
            ["r0"], ["r0", "r1"], ["r0"], ["r0", "r1"]
        ]
        let capturedFields = try JSONDecoder().decode([String: String].self, from: Data(row.capturedWire.utf8))
        let scriptedWire = try scriptedPracticePacket(capturedFields, fulfilledIDs: declaredFulfilledIDs[index])
        let first = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(scriptedWire.utf8))
        let provider = AdmissionRegressionTransport(plans: [
            .text(scriptedWire), .review(scriptedWire, disposition: "rejected")
        ])
        do {
            _ = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-admission-regression")
            Issue.record("Captured draft feedback was published without accepting a full semantic review.")
        } catch {
            // Generic decode failure is not semantic rejection. The current
            // fake avoids unknown JSON keys, so failure is about admission.
            #expect(error.localizedDescription.contains("Semantic review rejected"))
        }
        let requests = await provider.requests
        try #require(requests.count == 2)
        #expect(requests[0].prompt != requests[1].prompt)
        let initial = try JSONDecoder().decode([String: String].self, from: Data(requests[0].prompt.utf8))
        #expect(initial["question"] == row.question && initial["answer"] == row.answer)
        let final = requests[1]
        #expect(final.systemPrompt?.contains("Independently critique the complete original answer") == true)
        let input = try JSONDecoder().decode([String: String].self, from: Data(final.prompt.utf8))
        #expect(input["question"] == row.question && input["answer"] == row.answer)
        #expect(input["source_evidence"] == "")
        let rubric = row.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n")
        #expect(input["rubric"] == rubric)
        #expect(input["draft_feedback"] == nil && input["draft_first_missing_rubric_id"] == nil)
        #expect(first.coverage == legacy.coverage)
        let fields = try schemaFields(final)
        #expect(fields["reviewOutcome"]?["enum"] as? [String] == ["accepted", "rejected"])
        #expect(requests.allSatisfy { $0.modelName == "synthetic-admission-regression" && $0.numPredict == 1200 && $0.temperature == 0 })
        #expect(row.rawCaptureID.count == 36 && row.rawCaptureSHA256.count == 64)
        #expect(row.attemptID == makeAttempt(row).id && row.revision == makeAttempt(row).revision)
    }

    @Test
    func completeGeneralMapCannotPublishAnInventedPastExperienceRequirement() async throws {
        let question = "Compare a bounded queue with an unbounded queue and explain the choice."
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-freeze", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "synthetic-queue-admission", questionRevision: 2, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-admission-regression", failure: nil, latencyMS: 0))
        task.criteria = ["Explain the distinction and trade-off"]
        let answer = "A bounded queue limits pending work and needs a defined overflow policy; an unbounded queue admits more work but may exhaust memory."
        let attempt = PracticeAttempt(questionID: "synthetic-queue-admission", question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task)
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(answer)],
            suggestion: "Describe a past project where you measured this choice.", followUp: nil,
            reason: "The distinction is covered but a past project is required.",
            reference: "Queue admission needs an explicit overload policy.")
        var final = first
        final.reason = "The distinction and trade-off are covered."
        final.suggestion = "No personal-history example is required."
        let provider = AdmissionRegressionTransport(plans: [
            .text(try wire(first)), .review(try wire(final), disposition: "accepted")
        ])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-admission-regression")
        #expect(feedback.reason == final.reason)
        #expect(feedback.suggestions == [final.suggestion])
        #expect(feedback.covered == [.init(criterion: task.criteria[0], quote: answer)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.requests
        try #require(requests.count == 2)
        #expect(requests[1].systemPrompt?.contains("Even when all criteria are covered") == true)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(input["question"] == question && input["answer"] == answer)
        #expect(input["rubric"] == "r0: \(task.criteria[0])")
        let fields = try schemaFields(requests[1])
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil)
        #expect(fields["followUp"]?["type"] as? String == "string" && fields["followUp"]?["const"] == nil)
    }

    @Test
    func admittedGeneralReferenceCanBeQualifiedWithoutChangingCoverage() async throws {
        let row = try fixtures()[12]
        let legacy = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.capturedWire.utf8))
        #expect(legacy.assessments == nil)
        let capturedFields = try JSONDecoder().decode([String: String].self, from: Data(row.capturedWire.utf8))
        let scriptedWire = try scriptedPracticePacket(capturedFields, fulfilledIDs: ["r0"])
        let first = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(scriptedWire.utf8))
        var final = first
        final.reference = "A cache keeps a reusable copy for access speed and needs invalidation. Durable storage can retain acknowledged data across restart when its configured durability boundary is met; consistency is a separate protocol property. Their costs and failure behavior depend on implementation and configuration."
        let provider = AdmissionRegressionTransport(plans: [
            .text(scriptedWire), .review(try wire(final), disposition: "accepted")
        ])
        // Reference corrections keep this declared map while the production
        // boundary still validates every quote against the original answer.
        let feedback = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-admission-regression")
        #expect(feedback.reference == final.reference)
        #expect(feedback.covered.map(\.quote) == first.coverage.keys.sorted().compactMap { first.coverage[$0] ?? nil })
        #expect(feedback.missing == [row.task.criteria[1]])
        let requests = await provider.requests
        try #require(requests.count == 2)
        let fields = try schemaFields(requests[1])
        #expect(fields["reference"]?["const"] == nil)
        let firstQuote = (first.coverage["r0"] ?? nil) ?? ""
        #expect(feedback.covered.first?.quote == firstQuote)
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil)
        #expect(fields["r1"]?["type"] as? String == "string" && fields["r1"]?["const"] == nil)
    }

    private func fixtures() throws -> [CapturedRow] {
        let path = try #require(Bundle.module.url(forResource: "PracticeScopedAcceptedContradictions", withExtension: "json"))
        return try JSONDecoder().decode([CapturedRow].self, from: Data(contentsOf: path))
    }
    private func makeAttempt(_ row: CapturedRow) -> PracticeAttempt {
        var value = PracticeAttempt(questionID: row.questionID, question: row.question, answer: row.answer,
            contextSnapshotID: row.contextSnapshotID, revision: row.revision, hinted: false, skipped: false,
            source: "synthetic-captured-regression", task: row.task)
        value.id = row.attemptID
        return value
    }
    private func wire(_ value: PracticeEvaluationPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func schemaFields(_ request: LocalLLMRequest) throws -> [String: [String: Any]] {
        let encoded = try JSONEncoder().encode(try #require(request.responseSchema))
        let schema = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return try #require(schema["properties"] as? [String: [String: Any]])
    }
    private struct CapturedRow: Decodable {
        let scenarioID: String
        let questionID: String
        let attemptID: String
        let revision: Int
        let contextSnapshotID: String?
        let question: String
        let answer: String
        let task: InterviewTaskDescriptor
        let capturedWire: String
        let rawCaptureID: String
        let rawCaptureSHA256: String
    }
}

private actor AdmissionRegressionTransport: LocalLLMProvider {
    enum Plan: Sendable {
        case text(String)
        case review(String, disposition: String)
    }
    nonisolated let id = "synthetic-admission-regression"
    nonisolated let displayName = "Synthetic admission regression"
    private let plans: [Plan]
    private(set) var requests: [LocalLLMRequest] = []
    init(plans: [Plan]) { self.plans = plans }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < plans.count else { throw MaterialError.invalid("Unexpected additional admission request.") }
        let text: String
        switch plans[index] {
        case .text(let captured):
            text = captured
        case .review(let controlledWire, let disposition):
            // Transport changes only the explicitly scripted disposition.
            // Nested assessments supplied at the fixture callsite stay intact.
            var object = try #require(try JSONSerialization.jsonObject(with: Data(controlledWire.utf8)) as? [String: Any])
            if let responseSchema = request.responseSchema {
                let schema = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(responseSchema)) as? [String: Any])
                let fields = try #require(schema["properties"] as? [String: [String: Any]])
                if fields["reviewOutcome"] != nil { object["reviewOutcome"] = disposition }
            }
            text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
