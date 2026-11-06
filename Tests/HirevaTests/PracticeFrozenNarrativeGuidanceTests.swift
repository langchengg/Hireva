import Foundation
import Testing
@testable import Hireva

/// Tests the actual evaluate request boundary, not scripted semantic quality.
/// Both streams are finite; no hardware, cloud, model or process is started.
@Suite
@MainActor
struct PracticeFrozenNarrativeGuidanceTests {
    @Test(arguments: PracticeNarrativeScope.nonPersonal, ["en", "zh"])
    func generalArtifactAndUnresolvedInputsDoNotReceivePersonalEventRubricExamples(
        scope: PracticeNarrativeScope, language: String
    ) async throws {
        let fixture = makeFixture(scope: scope, language: language)
        let provider = NarrativeScopePacketProvider(packets: try packets(fixture))
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-narrative-scope")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let primary = try #require(requests[0].systemPrompt)
        #expect(!primary.contains("A situation criterion can be covered"))
        #expect(!primary.contains("the actual problem or disagreement"))
        #expect(!primary.contains("A reflection or lesson criterion needs"))
        #expect(!primary.contains("中文场景项可以由简洁背景与实际问题或分歧覆盖"))
        #expect(!primary.contains("中文反思或经验项需要回答明确说出的认识"))
        try checkSharedContract(fixture, requests: requests, feedback: feedback)
    }

    @Test(arguments: PracticeNarrativeScope.personal, ["en", "zh"])
    func frozenCandidateRecordAndMixedPartsKeepEventTemporalAndRubricBoundaries(
        scope: PracticeNarrativeScope, language: String
    ) async throws {
        let fixture = makeFixture(scope: scope, language: language)
        let provider = NarrativeScopePacketProvider(packets: try packets(fixture))
        let feedback = try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-narrative-scope")
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let primary = try #require(requests[0].systemPrompt)
        #expect(primary.contains("A situation criterion can be covered by a concise setting and the actual problem or disagreement"))
        #expect(primary.contains("A reflection or lesson criterion needs a stated lesson, self-assessment or insight from the event"))
        #expect(primary.contains("Do not quote an intention as proof of a lesson."))
        #expect(primary.contains("it must not presuppose that a planned test or deployment already happened."))
        #expect(primary.contains("Suggestions request missing real facts, never supply an invented first-person past outcome."))
        #expect(primary.contains("中文反思或经验项需要回答明确说出的认识、教训或自我评估"))
        #expect(primary.contains("中文场景项可以由简洁背景与实际问题或分歧覆盖"))
        if scope.basis == .mixed {
            #expect(primary.contains("For mixed questions, preserve the separately requested general and personal parts."))
            #expect(primary.contains("A missing general criterion asks for general reasoning, not a new past experience."))
        }
        try checkSharedContract(fixture, requests: requests, feedback: feedback)
    }

    private func checkSharedContract(_ fixture: Fixture, requests: [LocalLLMRequest], feedback: PracticeFeedback) throws {
        #expect(feedback.covered == [.init(criterion: fixture.task.criteria[0], quote: fixture.quote)])
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let primary = try #require(requests[0].systemPrompt)
        #expect(primary.contains("One exact quote may support multiple criteria when it supplies the requested content for each."))
        #expect(primary.contains("Evaluate each criterion independently; its quote need not contain the whole answer or the other criteria."))
        #expect(primary.contains("Check each nonempty quote against the particular criterion before deciding that it is covered."))
        #expect(primary.contains("For a real past event, a result or outcome criterion needs an outcome the answer says actually happened"))
        #expect(primary.contains("Do not invent an outcome or require numbers when the rubric does not."))
        #expect(primary.contains("For a hypothetical design or proposed experiment, evaluate the proposed reasoning and trade-offs; do not demand an already completed personal event."))
        #expect(primary.contains("Coverage is determined ONLY by the supplied rubric."))
        #expect(primary.contains("Copy spelling and punctuation literally. Never invent quotes."))
        #expect(primary.contains("followUp targets only the FIRST criterion whose assessments fulfillment is not met"))
        #expect(primary.contains("State the assumptions and conditions on which each claimed guarantee depends."))
        #expect(requests.allSatisfy { $0.modelName == "synthetic-narrative-scope" && $0.numPredict == 1200 && $0.temperature == 0 && $0.prompt.utf8.count <= 24000 })
        for request in requests {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["answer"] == fixture.attempt.answer && input["question"] == fixture.attempt.question)
            #expect(input["rubric"] == "r0: \(fixture.task.criteria[0])")
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(request.systemPrompt?.contains("reference uses \(fixture.task.language)") == true)
        }
        let reviewInput = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(reviewInput["draft_feedback"] == nil)
        #expect(reviewInput["draft_first_missing_rubric_id"] == nil && reviewInput["draft_first_missing_rubric_criterion"] == nil)
        #expect(requests[1].systemPrompt?.contains("Acceptance is not independent fact certification.") == true)
        #expect(requests[1].systemPrompt?.contains("followUp asks only for the FIRST non-met assessment") == true)
        if [.required, .uncertain].contains(fixture.scope.evidence) {
            let safeReference = PracticeFeedback.sourceLimitedReference(language: fixture.task.language)
            #expect(feedback.reference == safeReference)
            #expect(reviewInput["application_reference_notice"] == nil)
            guard case .object(let schema)? = requests[1].responseSchema,
                  case .object(let fields)? = schema["properties"],
                  case .object(let reference)? = fields["reference"] else {
                Issue.record("The source-limited wire reference must remain fixed in the real transport schema.")
                return
            }
            #expect(reference["const"] == .string(""))
        }
    }

    private struct Fixture {
        let scope: PracticeNarrativeScope
        let task: InterviewTaskDescriptor
        let attempt: PracticeAttempt
        let quote: String
        let reference: String
    }
    private func makeFixture(scope: PracticeNarrativeScope, language: String) -> Fixture {
        let personal = PracticeNarrativeScope.personal.contains(scope)
        let question = personal
            ? (language == "zh" ? "说明你参与的规划讨论，并区分已有行动与未来试验。" : "Describe a planning discussion you took part in and distinguish actions from a future trial.")
            : (language == "zh" ? "说明一个有界方案的组件与准入选择；可使用假设推理。" : "Explain a bounded design's components and admission choice using hypothetical reasoning.")
        let quote = language == "zh" ? "有界工作队列限制待处理工作。" : "A bounded work queue limits pending work."
        let answer = quote + (language == "zh" ? " 我计划明天测试准入限制。" : " I plan to test the admission limit tomorrow.")
        var task = InterviewTaskDescriptor(question: question, kind: .systemDesign, language: language)
        task.apply(.init(task: .systemDesign, personalEvidence: scope.evidence, basis: scope.basis,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-narrative-scope", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-narrative-scope",
            questionRevision: 3, contextSnapshotID: nil, artifactRevision: 0,
            model: "synthetic-narrative-scope", failure: nil, latencyMS: 0))
        task.criteria = [language == "zh" ? "说明待处理工作" : "Explain pending work"]
        let attempt = PracticeAttempt(questionID: "synthetic-narrative-scope", question: question,
            answer: answer, contextSnapshotID: nil, revision: 3, hinted: false,
            skipped: false, source: "synthetic-test", task: task)
        let reference = [.required, .uncertain].contains(scope.evidence)
            ? PracticeFeedback.sourceLimitedReference(language: language)
            : (language == "zh" ? "有界队列需要明确准入策略。" : "A bounded queue needs an explicit admission policy.")
        return .init(scope: scope, task: task, attempt: attempt, quote: quote, reference: reference)
    }
    private func packets(_ fixture: Fixture) throws -> [String] {
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(fixture.quote)], suggestion: "",
            followUp: nil, reason: fixture.task.language == "zh" ? "已引用所述机制。" : "The stated mechanism is quoted.",
            reference: [.required, .uncertain].contains(fixture.scope.evidence) ? "" : fixture.reference)
        var final = first; final.reviewOutcome = "accepted"
        return try [first, final].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }
}

enum PracticeNarrativeScope: String, Sendable {
    case general, artifact, optionalGeneral, unresolved, candidateRecord, mixed, optionalCandidate
    static let nonPersonal: [Self] = [.general, .artifact, .optionalGeneral, .unresolved]
    static let personal: [Self] = [.candidateRecord, .mixed, .optionalCandidate]
    var evidence: PersonalEvidenceRequirement {
        switch self {
        case .general, .artifact: return .notRequired
        case .optionalGeneral, .optionalCandidate: return .optional
        case .unresolved: return .uncertain
        case .candidateRecord, .mixed: return .required
        }
    }
    var basis: QuestionAnswerBasis {
        switch self {
        case .general, .optionalGeneral: return .generalKnowledge
        case .artifact: return .providedArtifact
        case .unresolved: return .unknown
        case .candidateRecord, .optionalCandidate: return .candidateRecord
        case .mixed: return .mixed
        }
    }
}

private actor NarrativeScopePacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-narrative-scope"
    nonisolated let displayName = "Synthetic narrative scope"
    private let packets: [String]
    private var requests: [LocalLLMRequest] = []
    init(packets: [String]) { self.packets = packets }
    func recorded() -> [LocalLLMRequest] { requests }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < packets.count else { throw MaterialError.invalid("Unexpected extra narrative scope request.") }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: packets[index], source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
