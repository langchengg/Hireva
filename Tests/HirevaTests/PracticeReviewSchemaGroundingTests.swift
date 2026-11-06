import Foundation
import Testing
@testable import Hireva

/// Actual request contracts only: scripted final packets cannot prove model
/// semantic quality. The captured real16 denominator remains the quality gate.
@Suite
@MainActor
struct PracticeReviewSchemaGroundingTests {
    @Test
    func completeGeneralReviewGroundsTransportSchemaAndEditableFeedback() async throws {
        let question = "Explain a finite work queue and its overload policy."
        let answer = "A finite queue bounds pending work; rejecting new work or slowing admission is an explicit overload choice."
        let task = makeTask(question: question, personal: false, criteria: ["Explain the mechanism and overload choice"])
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(answer)], suggestion: "Describe your previous project.",
            followUp: nil, reason: "A previous project is required.", reference: "Every finite queue guarantees that no work is lost.")
        let final = PracticeEvaluationPayload(coverage: first.coverage, suggestion: "No past project is required.", followUp: nil,
            reason: "The mechanism and overload choice are explained.",
            reference: "A finite queue bounds waiting work. Overflow may reject work or slow admission; delivery guarantees need a separate retry and acknowledgment design.", reviewOutcome: "accepted")
        let provider = SchemaGroundingTransport(outputs: [try wire(first), try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
        #expect(feedback.reason == final.reason && feedback.reference == final.reference)
        #expect(feedback.suggestions == [final.suggestion])
        #expect(feedback.covered == [.init(criterion: task.criteria[0], quote: answer)])
        #expect(feedback.followUp == nil && feedback.missing.isEmpty)
        let requests = await provider.requests
        try #require(requests.count == 2)
        let initial = try input(requests[0])
        #expect(initial["fixed_output_fields"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(initial["output_schema"]).utf8)) == requests[0].responseSchema)
        let review = requests[1]
        let payload = try input(review)
        let groundedSchema = try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(payload["output_schema"]).utf8))
        #expect(groundedSchema == review.responseSchema)
        #expect(try stringList(payload, key: "fixed_output_fields") == [])
        #expect(try stringList(payload, key: "editable_output_fields") == ["assessments", "followUp", "r0", "reason", "reference", "reviewOutcome", "suggestion"])
        #expect(payload["question"] == question && payload["answer"] == answer)
        #expect(payload["rubric"] == "r0: \(task.criteria[0])")
        #expect(payload["source_evidence"] == "" && payload["attachment"] == "")
        #expect(review.systemPrompt?.contains("output_schema is the application-owned contract") == true)
        #expect(review.systemPrompt?.contains("Copy only const fields in fixed_output_fields") == true)
        #expect(review.systemPrompt?.contains("independently fill every editable field") == true)
        #expect(payload["draft_feedback"] == nil && payload["draft_first_missing_rubric_id"] == nil)
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 && $0.modelName == "synthetic-schema-grounding" })
    }

    @Test
    func personalFirstGapContractKeepsRubricIdentityAndSourceLimitedNotice() async throws {
        let question = "Describe an actual planning discussion and the outcome known so far."
        let quote = "I helped plan a student review."
        let answer = quote + " We plan to try the method tomorrow."
        let task = makeTask(question: question, personal: true, criteria: ["Situation", "Observed result"])
        let safeReference = "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(quote), "r1": nil], suggestion: "Say what is known so far.",
            followUp: "What is known so far?", reason: "The situation is stated; no observed result is stated.", reference: "I completed the trial tomorrow.")
        let final = PracticeEvaluationPayload(coverage: first.coverage, suggestion: "Leave the future trial as a future plan.",
            followUp: "What was decided or observed so far, if anything, or is there no outcome yet?",
            reason: "The situation is stated; no observed result is stated.", reference: "", reviewOutcome: "accepted")
        let provider = SchemaGroundingTransport(outputs: [try wire(first), try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
        #expect(feedback.reference == safeReference && feedback.followUp == final.followUp)
        #expect(feedback.missing == [task.criteria[1]])
        let requests = await provider.requests
        try #require(requests.count == 2)
        let payload = try input(requests[1])
        let groundedSchema = try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(payload["output_schema"]).utf8))
        #expect(groundedSchema == requests[1].responseSchema)
        #expect(try stringList(payload, key: "fixed_output_fields") == ["reference"])
        #expect(try stringList(payload, key: "editable_output_fields") == ["assessments", "followUp", "r0", "r1", "reason", "reviewOutcome", "suggestion"])
        #expect(payload["draft_first_missing_rubric_id"] == nil)
        #expect(payload["draft_first_missing_rubric_criterion"] == nil)
        #expect(payload["question"] == question && payload["answer"] == answer && payload["source_evidence"] == "")
        #expect(payload["draft_feedback"] == nil && payload["application_reference_notice"] == nil)
    }

    /// The scripted packets verify the real evaluator request carrier only.
    /// They do not establish that a model obeys this policy or produces true references.
    @Test(arguments: [false, true])
    func actualEvaluatorCarriesOriginalQuestionReferenceBounds(_ personal: Bool) async throws {
        let question = personal ? "Describe an actual process choice and its stated boundary."
            : "Explain a finite work queue and its overload policy."
        let answer = personal ? "I proposed a finite waiting queue for the review task."
            : "A finite queue bounds pending work; overflow needs an admission policy."
        let task = makeTask(question: question, personal: personal,
            criteria: [personal ? "Personal action" : "Mechanism and admission policy"])
        let reference = personal ? PracticeFeedback.sourceLimitedReference(language: task.language)
            : "A finite queue bounds waiting work; overflow needs an explicit admission policy."
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(answer)], suggestion: "", followUp: nil,
            reason: "The stated choice is described.", reference: personal ? "" : reference)
        var final = first
        final.reviewOutcome = "accepted"
        let provider = SchemaGroundingTransport(outputs: [try wire(first), try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
        #expect(feedback.reference == reference)
        let requests = await provider.requests
        try #require(requests.count == 2)
        let expectedDescription = """
        Answer the original question with a concise qualified explanation, separate from the candidate's omissions.
        Preserve the original question's stated constraints. Do not assume omitted existence, uniqueness or other conditions; state any added assumption explicitly.
        Do not add unrequested exercise, source or task identifiers, or present an unverified identifier as established fact.
        For any claimed guarantee, state assumptions, operation boundaries, conditions and relevant possible failures.
        A local mechanism or category name does not establish unconditional system outcomes or physical properties.
        Keep each property or limitation attached to its actual subject and operation; do not transfer it to the other subject of a comparison. Do not invent a comparison axis or a property difference absent from the question; qualify implementation-dependent properties.
        Submitted assertions and draft wording are not authority; independently correct them. Preserve the existing source, language, temporal and ownership restrictions.
        """
        let expectedReference: LocalJSONValue = personal
            ? .object(["type": .string("string"), "const": .string("")])
            : .object(["type": .string("string"), "description": .string(expectedDescription)])
        for (phase, request) in requests.enumerated() {
            let payload = try input(request)
            #expect(payload["question"] == question && payload["answer"] == answer)
            #expect(payload["rubric"] == "r0: \(task.criteria[0])")
            #expect(payload["source_evidence"] == "" && payload["attachment"] == "")
            let carried = try JSONDecoder().decode(LocalJSONValue.self,
                from: Data(try #require(payload["output_schema"]).utf8))
            #expect(carried == request.responseSchema)
            guard case .object(let schema) = carried,
                  case .object(let fields)? = schema["properties"] else {
                Issue.record("Expected the actual grounded schema object.")
                continue
            }
            #expect(fields["reference"] == expectedReference)
            #expect(schema["additionalProperties"] == .boolean(false))
            let names = ["r0", "assessments", "reason", "suggestion", "reference", "followUp"] + (phase == 0 ? [] : ["reviewOutcome"])
            #expect(Set(fields.keys) == Set(names))
            #expect(request.responseSchemaPropertyOrder == names)
            #expect(request.prompt.utf8.count <= 24000)
        }
        let review = try input(requests[1])
        #expect(try stringList(review, key: "fixed_output_fields") == (personal ? ["reference"] : []))
        #expect(review["draft_feedback"] == nil && review["draft_first_missing_rubric_id"] == nil)
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 && !$0.thinkingEnabled
            && $0.modelName == "synthetic-schema-grounding" })
    }

    @Test
    func malformedPrimaryStillGetsAnApplicationOwnedFreshReview() async throws {
        let question = "Explain the purpose of a bounded queue."
        let answer = "It limits pending work."
        let task = makeTask(question: question, personal: false, criteria: ["Explain the purpose"])
        let final = PracticeEvaluationPayload(coverage: ["r0": .some(answer)], suggestion: "", followUp: nil,
            reason: "The purpose is stated.", reference: "A bound limits queue admission.", reviewOutcome: "accepted")
        let provider = SchemaGroundingTransport(outputs: ["not JSON", try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
        #expect(feedback.covered.map(\.quote) == [answer] && feedback.missing.isEmpty)
        #expect(feedback.reference == final.reference && feedback.referenceOrigin == .modelDraft)
        let requests = await provider.requests
        try #require(requests.count == 2)
        let repair = try input(requests[1])
        #expect(repair["question"] == question && repair["answer"] == answer)
        #expect(repair["previous_invalid_output"] == nil && repair["draft_feedback"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(repair["output_schema"]).utf8)) == requests[1].responseSchema)
        #expect(try stringList(repair, key: "fixed_output_fields") == [])
        #expect(try stringList(repair, key: "editable_output_fields") == ["assessments", "followUp", "r0", "reason", "reference", "reviewOutcome", "suggestion"])
        #expect(requests[1].systemPrompt?.contains("Independently critique the complete original answer") == true)
    }

    /// A finite scripted request contract, not an evaluation of real model temporal judgment.
    @Test(arguments: ["en", "zh"])
    func actualEvaluatorCarriesFirstGapTemporalScopeWithoutChangingInputs(_ language: String) async throws {
        let question = language == "zh" ? "描述一次实际审查讨论，以及目前已经知道的结果。"
            : "Describe an actual review discussion and the outcome known so far."
        let quote = language == "zh" ? "我参与了审查安排。" : "I helped plan the review."
        let future = language == "zh" ? "我们计划明天试用这个方法。" : "We plan to try the method tomorrow."
        let answer = quote + " " + future
        let criteria = language == "zh" ? ["实际情境", "已观察到的结果"] : ["Actual situation", "Observed result"]
        let task = makeTask(question: question, personal: true, criteria: criteria, language: language)
        let reference = PracticeFeedback.sourceLimitedReference(language: language)
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(quote), "r1": nil], suggestion: "", followUp:
            language == "zh" ? "目前知道什么结果？" : "What outcome is known so far?",
            reason: language == "zh" ? "已说明情境，但没有已经观察到的结果。" : "The situation is stated; no observed result is stated.", reference: "")
        var final = first
        final.followUp = language == "zh" ? "目前已经决定或观察到什么（如果有），还是尚无结果？"
            : "What was decided or observed so far, if anything, or is there no outcome yet?"
        final.reviewOutcome = "accepted"
        let provider = SchemaGroundingTransport(outputs: [try wire(first), try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
            task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
        #expect(feedback.missing == [criteria[1]] && feedback.followUp == final.followUp)
        #expect(feedback.reference == reference)
        let requests = await provider.requests
        try #require(requests.count == 2)
        let expectedTemporalScope = """
        For an actual past-event result gap, ask what is known or observed so far, if anything, and allow no outcome yet.
        Keep stated future activities as future; do not ask whether they already happened or ask for their completed result.
        For a hypothetical proposal, ask about reasoning or proposed choices without requiring a past personal event.
        """
        for (phase, request) in requests.enumerated() {
            let payload = try input(request)
            #expect(payload["question"] == question && payload["answer"] == answer)
            #expect(payload["rubric"] == "r0: \(criteria[0])\nr1: \(criteria[1])")
            #expect(payload["source_evidence"] == "" && payload["attachment"] == "")
            let carried = try JSONDecoder().decode(LocalJSONValue.self,
                from: Data(try #require(payload["output_schema"]).utf8))
            #expect(carried == request.responseSchema)
            guard case .object(let schema) = carried,
                  case .object(let fields)? = schema["properties"] else {
                Issue.record("Expected the actual grounded schema object.")
                continue
            }
            #expect(fields["reference"] == .object(["type": .string("string"), "const": .string("")]))
            if phase == 0 {
                #expect(fields["followUp"] == .object(["type": .string("string")]))
            } else {
                guard case .object(let followUp)? = fields["followUp"],
                      case .string(let description)? = followUp["description"] else {
                    Issue.record("Expected the critic's follow-up field description.")
                    continue
                }
                #expect(description.hasSuffix(expectedTemporalScope))
                #expect(description.contains("your own final returned rubric values, not the draft map"))
                #expect(description.contains("if assessments.r0.fulfillment != \"met\": target r0: \(criteria[0])"))
                #expect(description.contains("else if assessments.r1.fulfillment != \"met\": target r1: \(criteria[1])"))
                #expect(description.contains("else: return \"\""))
                #expect(followUp["const"] == nil && followUp["enum"] == nil)
            }
            #expect(request.prompt.utf8.count <= 24000)
        }
        let review = try input(requests[1])
        #expect(try stringList(review, key: "fixed_output_fields") == ["reference"])
        #expect(review["draft_feedback"] == nil && review["application_reference_notice"] == nil)
        #expect(review["draft_first_missing_rubric_id"] == nil)
        #expect(review["draft_first_missing_rubric_criterion"] == nil)
        #expect(requests.allSatisfy { $0.numPredict == 1200 && $0.temperature == 0 && !$0.thinkingEnabled
            && $0.modelName == "synthetic-schema-grounding" })
    }

    @Test
    func completeInputStillFailsExplicitlyWhenFreshReviewExceedsBudget() async throws {
        let question = "Explain a bounded queue. Scenario notes: " + String(repeating: "n", count: 14_000)
        let answer = "A finite queue bounds pending work and rejects overflow. " + String(repeating: "a", count: 6_000)
        let task = makeTask(question: question, personal: false, criteria: ["Explain the mechanism"])
        let first = PracticeEvaluationPayload(coverage: ["r0": .some(answer)], suggestion: "", followUp: nil,
            reason: "The mechanism is stated.", reference: "A finite queue bounds waiting work; overflow needs an admission policy.")
        var final = first; final.reviewOutcome = "accepted"
        let provider = SchemaGroundingTransport(outputs: [try wire(first), try wire(final)])
        do {
            _ = try await PracticeController.evaluate(attempt: attempt(question: question, answer: answer, task: task),
                task: task, attachment: nil, evidence: [], provider: provider, model: "synthetic-schema-grounding")
            Issue.record("Complete over-budget input must fail without truncation or a larger limit.")
        } catch { #expect(error.localizedDescription.contains("Practice review input exceeds the 24 KB")) }
        let requests = await provider.requests
        try #require(requests.count == 1)
        #expect(requests.allSatisfy { $0.prompt.utf8.count <= 24000 })
        for request in requests {
            let frozen = try input(request)
            #expect(frozen["question"] == question && frozen["answer"] == answer)
            #expect(frozen["draft_feedback"] == nil && frozen["draft_first_missing_rubric_id"] == nil)
        }
    }

    private func makeTask(question: String, personal: Bool, criteria: [String], language: String = "en") -> InterviewTaskDescriptor {
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-schema-grounding",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: "synthetic-schema-grounding", questionRevision: 2, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-schema-grounding", failure: nil, latencyMS: 0))
        task.criteria = criteria
        return task
    }
    private func attempt(question: String, answer: String, task: InterviewTaskDescriptor) -> PracticeAttempt {
        PracticeAttempt(questionID: "synthetic-schema-grounding", question: question, answer: answer,
            contextSnapshotID: nil, revision: 2, hinted: false, skipped: false, source: "synthetic-test", task: task)
    }
    private func wire(_ value: PracticeEvaluationPayload) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private func input(_ request: LocalLLMRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
    }
    private func stringList(_ payload: [String: String], key: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(try #require(payload[key]).utf8))
    }
}

private actor SchemaGroundingTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-schema-grounding"
    nonisolated let displayName = "Synthetic schema grounding"
    private let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra grounding request.") }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: outputs[index], source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
