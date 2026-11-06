import Foundation
import Testing
@testable import Hireva

/// The finite packets prove actual evaluator input/admission contracts only.
/// A provisional map is retained input; the final packet must establish its own
/// authority. Scripted packets do not prove model quality.
@Suite
@MainActor
struct PracticeDraftCoverageInputTests {
    @Test(arguments: DraftCoverageScenario.allCases)
    func finalDraftPreservesProvisionalMapAndFrozenInputs(scenario: DraftCoverageScenario) async throws {
        let f = fixture(scenario)
        let frozen = try f.primary.semanticReviewCandidate(answer: f.attempt.answer, task: f.task, evidence: [])
        let provider = DraftCoveragePacketProvider(packets: [f.primary, f.final])
        let feedback = try await PracticeController.evaluate(attempt: f.attempt, task: f.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-coverage-projection")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let firstInput = try input(requests[0])
        let reviewInput = try input(requests[1])
        #expect(reviewInput["draft_feedback"] == nil)
        #expect(reviewInput["draft_first_missing_rubric_id"] == nil && reviewInput["draft_first_missing_rubric_criterion"] == nil)
        for key in ["question", "answer", "rubric", "source_evidence", "attachment",
                    "assessment_basis", "reference_authority", "application_reference_notice"] {
            #expect(reviewInput[key] == firstInput[key])
        }
        #expect(reviewInput["question"] == f.attempt.question && reviewInput["answer"] == f.attempt.answer)
        #expect(reviewInput["rubric"] == f.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(firstInput["draft_feedback"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(firstInput["output_schema"]).utf8)) == requests[0].responseSchema)
        #expect(reviewInput["previous_invalid_output"] == nil)
        #expect(reviewInput["draft_first_missing_rubric_id"] == nil)
        #expect(reviewInput["draft_first_missing_rubric_criterion"] == nil)
        #expect(requests[0].responseSchema == PracticeEvaluationPayload.schema(criteria: f.task.criteria,
            sourceLimitedReference: scenario.personal ? "" : nil))
        #expect(requests[1].responseSchema == frozen.semanticReviewSchema(fixedReference: scenario.personal, criteria: f.task.criteria, feedbackLanguage: f.task.explanationLanguage ?? f.task.language))
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(reviewInput["output_schema"]).utf8)) == requests[1].responseSchema)
        let fixed = try list(reviewInput, key: "fixed_output_fields")
        #expect(fixed == (scenario.personal ? ["reference"] : []))
        let editable = try list(reviewInput, key: "editable_output_fields")
        #expect(editable.contains("r0") && editable.contains("r1") && editable.contains("followUp") && editable.contains("assessments"))
        #expect(feedback.covered.map(\.quote) == f.final.coverage.keys.sorted().compactMap { id in
            f.final.assessments?[id]?.fulfillment == .met ? (f.final.coverage[id] ?? nil) : nil
        })
        #expect(feedback.missing == (scenario.finalHasGap ? [f.task.criteria[1]] : []))
        #expect(feedback.followUp == f.final.followUp && feedback.reference == (scenario.personal
            ? PracticeFeedback.sourceLimitedReference(language: f.task.language) : f.final.reference))
        #expect(feedback.reason == f.final.reason && feedback.suggestions == [f.final.suggestion])
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 &&
            $0.modelName == "synthetic-coverage-projection" && !$0.thinkingEnabled && $0.prompt.utf8.count <= 24000 })
        #expect(requests[1].systemPrompt?.contains("earlier model's rubric judgments, feedback and generated reference are deliberately not supplied") == true)
    }

    @Test(arguments: DraftCoverageBadFinal.allCases)
    func draftInputDoesNotAuthorizeAnInvalidFinalPacket(kind: DraftCoverageBadFinal) async throws {
        let f = fixture(kind == .personalReference ? .personalGap : .generalGap)
        var final = f.final
        switch kind {
        case .inventedQuote: final.coverage["r0"] = .some("This exact revision never states this sentence.")
        case .missingRubric: final.coverage.removeValue(forKey: "r1")
        case .unverified: final.reviewOutcome = nil
        case .personalReference: final.reference = "I delivered an unconfirmed production success."
        case .emptyReference: final.reference = " \n"
        }
        let provider = DraftCoveragePacketProvider(packets: [f.primary, final])
        do {
            _ = try await PracticeController.evaluate(attempt: f.attempt, task: f.task,
                attachment: nil, evidence: [], provider: provider, model: "synthetic-coverage-projection")
            Issue.record("A draft input cannot authorize an invalid final map, quote, source or verdict.")
        } catch {
            switch kind {
            case .inventedQuote: #expect(error.localizedDescription.contains("quote/rubric validation"))
            case .missingRubric: #expect(error.localizedDescription.contains("omitted or invented rubric IDs"))
            case .unverified: #expect(error.localizedDescription.contains("did not verify"))
            case .personalReference: #expect(error.localizedDescription.contains("source-limited reference"))
            case .emptyReference: #expect(error.localizedDescription.contains("empty reference answer"))
            }
        }
        #expect(await provider.recorded().count == 2)
        #expect(f.attempt.feedback == nil)
    }

    @Test
    func unverifiedDraftProseIsExcludedFromTheFreshFinalRequest() async throws {
        var f = fixture(.generalGap)
        f.primary.suggestion = String(repeating: "Synthetic retained prose. ", count: 1100)
        let provider = DraftCoveragePacketProvider(packets: [f.primary, f.final])
        let feedback = try await PracticeController.evaluate(attempt: f.attempt, task: f.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-coverage-projection")
        #expect(feedback.reason == f.final.reason)
        let requests = await provider.recorded()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.prompt.utf8.count <= 24000 })
        let finalInput = try input(try #require(requests.last))
        #expect(finalInput["draft_feedback"] == nil && finalInput["previous_invalid_output"] == nil)
        #expect(finalInput["answer"] == f.attempt.answer && finalInput["question"] == f.attempt.question)
        #expect(requests.last?.prompt.contains("Synthetic retained prose.") == false)
    }

    private func fixture(_ scenario: DraftCoverageScenario) -> DraftCoverageFixture {
        let personal = scenario.personal
        let question = personal ? "Describe your recorded action and observed outcome." : "Explain an append-only ledger and its modification limit."
        let firstQuote = personal ? "I wrote down the constraints." : "A ledger appends new entries."
        let secondQuote = personal ? "The group adopted the list." : "Existing entries cannot be changed."
        let extra = personal ? "A separate trial is planned next week." : "An unrelated screen uses a dark theme."
        let answer = firstQuote + (scenario.finalHasGap ? "" : " " + secondQuote) + " " + extra
        let criteria = personal ? ["Stated personal action", "Observed outcome"] : ["Explain adding entries", "State the modification limit"]
        var task = InterviewTaskDescriptor(question: question, kind: personal ? .behavioral : .generalKnowledge, language: "en")
        task.apply(.init(task: personal ? .behavioral : .generalKnowledge,
            personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-projection", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: "synthetic-projection", questionRevision: 4,
            contextSnapshotID: "synthetic-projection-context", artifactRevision: 0,
            model: "synthetic-coverage-projection", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: "synthetic-projection", question: question, answer: answer,
            contextSnapshotID: "synthetic-projection-context", revision: 4, hinted: false,
            skipped: false, source: "synthetic-contract", task: task)
        let primarySecond: String? = scenario.primaryHasGap ? nil : (scenario == .falseCoveredGap ? extra : secondQuote)
        let primary = PracticeEvaluationPayload(coverage: ["r0": .some(firstQuote), "r1": primarySecond],
            suggestion: "PROVISIONAL_SUGGESTION: review the stated criteria.", followUp: nil,
            reason: "PROVISIONAL_REASON: the initial map is not authoritative.",
            reference: personal ? "UNTRUSTED_PRIMARY_PERSONAL_REFERENCE" : "An append-only ledger adds new records and prevents changing existing entries.")
        let final = PracticeEvaluationPayload(coverage: ["r0": .some(firstQuote), "r1": scenario.finalHasGap ? nil : secondQuote],
            suggestion: scenario.finalHasGap ? "Explain the second supplied criterion." : "No rubric gap remains.",
            followUp: scenario.finalHasGap ? (personal ? "What outcome is observed so far, if any?" : "What changes are permitted to existing entries?") : nil,
            reason: scenario.finalHasGap ? "The second supplied criterion is not stated." : "Both supplied criteria are stated.",
            reference: personal ? "" : "An append-only ledger adds new records and prevents changing existing entries.",
            reviewOutcome: "accepted")
        return .init(attempt: attempt, task: task, primary: primary, final: final)
    }
    private func input(_ request: LocalLLMRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
    }
    private func list(_ values: [String: String], key: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(try #require(values[key]).utf8))
    }
}

enum DraftCoverageScenario: CaseIterable, Sendable {
    case generalGap, generalComplete, personalGap, personalComplete, falseMissingComplete, falseCoveredGap
    var personal: Bool { self == .personalGap || self == .personalComplete }
    var primaryHasGap: Bool { self == .generalGap || self == .personalGap || self == .falseMissingComplete }
    var finalHasGap: Bool { self == .generalGap || self == .personalGap || self == .falseCoveredGap }
}
enum DraftCoverageBadFinal: CaseIterable, Sendable { case inventedQuote, missingRubric, unverified, personalReference, emptyReference }
private struct DraftCoverageFixture {
    var attempt: PracticeAttempt
    var task: InterviewTaskDescriptor
    var primary: PracticeEvaluationPayload
    var final: PracticeEvaluationPayload
}
private actor DraftCoveragePacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-coverage-projection"
    nonisolated let displayName = "Explicit finite projection packets"
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
        guard index < packets.count && index < 2 else { throw MaterialError.invalid("Unexpected extra projection request.") }
        let text = String(decoding: try JSONEncoder().encode(packets[index]), as: UTF8.self)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName)); continuation.finish()
        }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
