import Foundation
import Testing
@testable import Hireva

/// Captured synthetic failures exercise the actual evaluator. Scripted final
/// packets prove admission/rejection contracts, never real-model truth.
@Suite
@MainActor
struct PracticeSemanticReviewTests {
    @Test(arguments: Array(0...11))
    func absentClaimNeedsAGapBasisButNoFactualBasis(_ defect: Int) async throws {
        let answer = "I can bake bread."
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-absence-contract", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "absence-contract", questionRevision: 0, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-semantic-review", failure: nil, latencyMS: 0))
        task.criteria = ["Explain the mechanism"]
        var judgment = PracticeFeedback.RubricAssessment(presence: .absent, accuracy: .notApplicable,
            accuracyBasis: "", fulfillment: .unmet, basis: "The answer does not describe the requested mechanism.")
        var quote: String?
        switch defect {
        case 1: judgment.presence = .present; judgment.accuracy = .unverified; quote = answer
        case 2: judgment.presence = .uncertain
        case 3: judgment.accuracy = .supported
        case 4: judgment.accuracy = .contradicted
        case 5: judgment.basis = ""
        case 6: judgment.fulfillment = .met
        case 7: judgment.presence = .partial; judgment.accuracy = .unverified; quote = answer
        case 8: judgment.accuracy = .unverified
        case 9: judgment.basis = String(repeating: "X", count: 1001)
        case 10: judgment.accuracyBasis = String(repeating: "X", count: 1001)
        case 11: quote = " "
        default: break
        }
        let primary = PracticeEvaluationPayload(coverage: ["r0": quote], suggestion: judgment.basis,
            followUp: "What is the mechanism?", reason: "The requested mechanism is not expressed.",
            reference: "A queue stores pending work; a bound limits the number of queued items.",
            assessments: ["r0": judgment])
        var final = primary; final.reviewOutcome = "accepted"
        let provider = SemanticReviewTransport(outputs: try [primary, final].map(wire))
        let attempt = PracticeAttempt(questionID: "absence-contract", question: task.question, answer: answer,
            revision: 0, hinted: false, skipped: false, source: "synthetic-regression", task: task)
        if defect == 0 {
            let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
                evidence: [], provider: provider, model: "synthetic-semantic-review")
            #expect(feedback.covered.isEmpty && feedback.missing == task.criteria)
            #expect(feedback.assessments?.first?.quote == nil)
            #expect(feedback.assessments?.first?.judgment == judgment)
            #expect(!feedback.assessmentLines.contains { $0.contains("\nBasis: ") })
            let restored = try JSONDecoder().decode(PracticeFeedback.self, from: JSONEncoder().encode(feedback))
            #expect(try restored.validated(answer: answer, task: task, evidence: []) == feedback)
        } else {
            await #expect(throws: (any Error).self) {
                try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
                    evidence: [], provider: provider, model: "synthetic-semantic-review")
            }
        }
        #expect(await provider.requests.count == 2)
    }

    @Test(arguments: Array(0...7))
    func behavioralExpressionDoesNotEstablishPersonalSourceSupport(_ sourceCase: Int) async throws {
        let situation = "During a student team planning meeting, we disagreed about which prototype to build."
        let reflection = "I learned to make the comparison criteria explicit before asking teammates to defend their proposals."
        let quote = sourceCase == 4 ? "A bounded queue caps pending work." : sourceCase == 1 ? reflection : situation
        var task = InterviewTaskDescriptor(question: sourceCase == 4 ? "Explain a bounded queue."
            : sourceCase == 3 ? "Describe a real disagreement, then explain the general comparison principle."
            : "Describe a real disagreement and what you learned.", kind: sourceCase == 4 ? .generalKnowledge : .behavioral)
        task.apply(.init(task: task.kind, personalEvidence: sourceCase == 4 ? .notRequired : .required,
            basis: sourceCase == 3 ? .mixed : .candidateRecord, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-source-boundary", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "behavioral-source", questionRevision: sourceCase == 1 ? 1 : 0,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-semantic-review", failure: nil, latencyMS: 0))
        if sourceCase == 2 { task.criteria = ["Clear structure"] }
        let evidence: [ProfileEvidence] = sourceCase < 5 ? [] : [.init(id: "synthetic-source",
            statement: quote, sourceDocumentID: "synthetic-cv", sourceChunkID: nil, sourceSpan: quote,
            confidence: 1, evidenceType: .project,
            explicitness: sourceCase == 5 ? .explicit : sourceCase == 6 ? .inferred : .userRejected)]
        let target = sourceCase == 1 ? 3 : 0
        var coverage: [String: String?] = [:]
        var assessments: [String: PracticeFeedback.RubricAssessment] = [:]
        for i in task.criteria.indices {
            coverage.updateValue(i == target ? quote : nil, forKey: "r\(i)")
            assessments["r\(i)"] = .init(presence: i == target ? .present : .absent,
                accuracy: i == target ? .supported : .notApplicable, accuracyBasis: "Synthetic declared assessment.",
                fulfillment: i == target ? .met : .unmet, basis: i == target ? "The statement is expressed." : "Not expressed.")
        }
        let primary = PracticeEvaluationPayload(coverage: coverage, suggestion: "Keep the stated scope.",
            followUp: task.criteria.count > 1 ? "What happened next?" : nil, reason: "The statement is expressed.",
            reference: [.required, .uncertain].contains(task.personalEvidence) && !evidence.contains(where: \.isUsable)
                ? PracticeFeedback.sourceLimitedReference(language: "en")
                : "Keep the discussion limited to the supplied facts and stated constraints.", assessments: assessments)
        var final = primary; final.reviewOutcome = "accepted"
        if [.required, .uncertain].contains(task.personalEvidence) && !evidence.contains(where: \.isUsable) {
            final.reference = ""
        }
        let expected: PracticeFeedback.RubricAssessment.Accuracy = [0, 1, 6, 7].contains(sourceCase) ? .unverified : .supported
        let frozen = try primary.semanticReviewCandidate(answer: quote, task: task, evidence: evidence)
        #expect(frozen.assessments?["r\(target)"]?.accuracy == expected)
        let provider = SemanticReviewTransport(outputs: try [primary, final].map(wire))
        let attempt = PracticeAttempt(questionID: "behavioral-source", question: task.question, answer: quote,
            revision: sourceCase == 1 ? 1 : 0, hinted: false, skipped: false, source: "synthetic-regression", task: task)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: evidence, provider: provider, model: "synthetic-semantic-review")
        let admitted = try #require(feedback.assessments?.first { $0.criterion == task.criteria[target] })
        #expect(admitted.judgment.accuracy == expected)
        #expect(admitted.quote == quote && admitted.judgment.presence == .present && admitted.judgment.fulfillment == .met)
        #expect(feedback.covered.map(\.criterion) == [task.criteria[target]])
        #expect(feedback.missing == task.criteria.enumerated().filter { $0.offset != target }.map(\.element))
        #expect(await provider.requests.count == 2)
    }

    @Test(arguments: Array(0...5))
    func submittedPersonalActionNeedsSourceSupportWithoutLosingCoverage(_ sourceCase: Int) async throws {
        let general = sourceCase == 5
        let answer = general ? "I would use a finite queue." : "I built a prototype and tested transaction rollback by injecting failures."
        var task = InterviewTaskDescriptor(question: general ? "Explain a bounded queue." : "Describe your prototype action.",
            kind: general ? .generalKnowledge : .project)
        task.apply(.init(task: task.kind, personalEvidence: general ? .notRequired : .required,
            basis: general ? .generalKnowledge : .candidateRecord, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "source-scope-regression", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "source-scope", questionRevision: 1, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-semantic-review", failure: nil, latencyMS: 0))
        task.criteria = ["State the requested action"]
        let statement = sourceCase == 2 ? "I studied drawing and painted a landscape."
            : sourceCase == 3 ? "I will build a prototype and test transaction rollback by injecting failures." : answer
        let evidence: [ProfileEvidence] = sourceCase == 0 || general ? [] : [.init(id: "synthetic-source",
            statement: statement, sourceDocumentID: "synthetic-cv", sourceChunkID: nil, sourceSpan: statement,
            confidence: 1, evidenceType: .project, explicitness: sourceCase == 4 ? .userRejected : .explicit)]
        let judgment = PracticeFeedback.RubricAssessment(presence: .present, accuracy: .supported,
            accuracyBasis: "The candidate explicitly stated this action.", fulfillment: .met,
            basis: "The requested action is expressed.")
        let primary = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: "Keep the stated scope.",
            followUp: nil, reason: "The requested action is expressed.",
            reference: general || sourceCase != 0 && sourceCase != 4 ? "Describe only the supplied action, without inventing results."
                : PracticeFeedback.sourceLimitedReference(language: "en"), assessments: ["r0": judgment])
        var final = primary; final.reviewOutcome = "accepted"
        if [.required, .uncertain].contains(task.personalEvidence) && !evidence.contains(where: \.isUsable) {
            final.reference = ""
        }
        let frozen = try primary.semanticReviewCandidate(answer: answer, task: task, evidence: evidence)
        #expect(frozen.assessments?["r0"]?.accuracy == (sourceCase == 1 || general ? .supported : .unverified))
        let provider = SemanticReviewTransport(outputs: try [primary, final].map(wire))
        let attempt = PracticeAttempt(questionID: "source-scope", question: task.question, answer: answer,
            revision: 1, hinted: false, skipped: false, source: "synthetic-regression", task: task)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: evidence, provider: provider, model: "synthetic-semantic-review")
        let admitted = try #require(feedback.assessments?.first)
        #expect(admitted.quote == answer && admitted.judgment.presence == .present)
        #expect(admitted.judgment.fulfillment == .met && feedback.covered.first?.quote == answer)
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        #expect(admitted.judgment.accuracy == (sourceCase == 1 || general ? .supported : .unverified))
        #expect(await provider.requests.count == 2)
    }

    @Test(arguments: [false, true])
    func expressedIncompleteOrWrongContentRemainsQuotedButIsNotMet(wrong: Bool) async throws {
        var task = InterviewTaskDescriptor(question: "Explain the mechanism and its limits.", kind: .generalKnowledge)
        task.apply(.init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-dimensions", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "dimensions", questionRevision: 2, contextSnapshotID: nil,
            artifactRevision: 0, model: "synthetic-dimensions", failure: nil, latencyMS: 0))
        task.criteria = ["Explain the mechanism and limits"]
        let answer = wrong ? "Replication always guarantees consistency." : "Replication copies data to another replica."
        let judgment = PracticeFeedback.RubricAssessment(presence: .present,
            accuracy: wrong ? .contradicted : .supported, accuracyBasis: "synthetic declared technical example, not a model fact certification",
            fulfillment: wrong ? .unmet : .partlyMet, basis: wrong ? "The unconditional guarantee is incorrect." : "The mechanism is stated; its limits are not.")
        let first = PracticeEvaluationPayload(coverage: ["r0": answer], suggestion: judgment.basis,
            followUp: "What conditions and limitations apply?", reason: judgment.basis,
            reference: "Copies require a defined consistency and failure policy.", assessments: ["r0": judgment])
        var final = first; final.reviewOutcome = "accepted"
        let provider = SemanticReviewTransport(outputs: try [first, final].map(wire))
        let attempt = PracticeAttempt(questionID: "dimensions", question: task.question, answer: answer,
            revision: 2, hinted: false, skipped: false, source: "synthetic-dimensions", task: task)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-dimensions")
        #expect(feedback.covered.isEmpty && feedback.missing == task.criteria)
        #expect(feedback.assessments?.first?.quote == answer)
        #expect(feedback.assessments?.first?.judgment == judgment)
        #expect(feedback.followUp == first.followUp)
        #expect(feedback.assessmentLines.contains { $0.contains(answer) && $0.contains(judgment.fulfillment.rawValue) })
        let requests = await provider.requests
        #expect(requests.count == 2)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_feedback"] == nil)
        #expect(input["answer"] == answer && input["rubric"] == "r0: \(task.criteria[0])")
    }

    @Test
    func unmatchedQuoteInUnmetCriterionStillFailsLiteralValidation() throws {
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.criteria = ["Explain the mechanism"]
        let judgment = PracticeFeedback.RubricAssessment(presence: .present, accuracy: .unverified,
            accuracyBasis: "unavailable", fulfillment: .unmet, basis: "Expression is incomplete.")
        let packet = PracticeEvaluationPayload(coverage: ["r0": "A quote from another revision."], suggestion: "Add the mechanism.",
            followUp: "What is the mechanism?", reason: "Not met.", reference: "A bounded mechanism.", assessments: ["r0": judgment])
        #expect(throws: (any Error).self) {
            try packet.semanticReviewCandidate(answer: "Current original answer.", task: task, evidence: [])
        }
    }

    @Test
    func legacyOutputDoesNotAcquireAssessmentDimensions() throws {
        let row = try fixtures()[12]
        let legacy = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.capturedWire.utf8))
        #expect(legacy.assessments == nil)
        #expect(throws: (any Error).self) { try legacy.semanticReviewCandidate(answer: row.answer, task: row.task, evidence: []) }
        let oldFeedback = PracticeFeedback(covered: [.init(criterion: row.task.criteria[0], quote: row.answer)],
            missing: [], suggestions: [], followUp: nil, reason: "Historical judgment.", reference: "Historical model draft.")
        let restored = try JSONDecoder().decode(PracticeFeedback.self, from: JSONEncoder().encode(oldFeedback))
        #expect(restored.assessments == nil && restored.assessmentLines.first?.contains("unknown") == true)
    }

    @Test(arguments: [false, true])
    func uncertainPresenceWithoutContentCannotAcquireFactualVerdict(contradicted: Bool) throws {
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.criteria = ["Explain the mechanism"]
        var judgment = PracticeFeedback.RubricAssessment(presence: .uncertain,
            accuracy: contradicted ? .contradicted : .supported,
            accuracyBasis: "No current answer claim was identified.",
            fulfillment: .uncertain, basis: "Relevant expression is unresolved.")
        let packet = PracticeEvaluationPayload(coverage: ["r0": nil], suggestion: "Clarify the mechanism.",
            followUp: "What is the mechanism?", reason: "Relevant expression is unresolved.",
            reference: "A bounded mechanism.", assessments: ["r0": judgment])
        #expect(throws: (any Error).self) {
            try packet.semanticReviewCandidate(answer: "Current answer.", task: task, evidence: [])
        }
        let feedback = PracticeFeedback(covered: [], missing: task.criteria, suggestions: [],
            followUp: packet.followUp, reason: packet.reason, reference: packet.reference,
            assessments: [.init(criterion: task.criteria[0], quote: nil, judgment: judgment)])
        #expect(throws: (any Error).self) { try feedback.validated(answer: "Current answer.", task: task, evidence: []) }

        judgment.accuracy = .unverified
        var unresolved = packet
        unresolved.assessments = ["r0": judgment]
        #expect(throws: Never.self) {
            try unresolved.semanticReviewCandidate(answer: "Current answer.", task: task, evidence: [])
        }
    }

    @Test(arguments: [" ", "\n\t", "\u{00A0}"], [false, true])
    func whitespaceOnlyQuoteCannotEstablishCoverage(quote: String, legacy: Bool) throws {
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.criteria = ["Explain the mechanism"]
        let judgment = PracticeFeedback.RubricAssessment(presence: .present, accuracy: .unverified,
            accuracyBasis: "Submitted content only.", fulfillment: .met, basis: "Declared expression.")
        let feedback = PracticeFeedback(covered: [.init(criterion: task.criteria[0], quote: quote)],
            missing: [], suggestions: [], followUp: nil, reason: "Declared expression.", reference: "A bounded mechanism.",
            assessments: legacy ? nil : [.init(criterion: task.criteria[0], quote: quote, judgment: judgment)])
        #expect(throws: (any Error).self) {
            try feedback.validated(answer: "First sentence." + quote + "Second sentence.", task: task, evidence: [])
        }
    }

    @Test(arguments: ["  A bounded mechanism.  ", "\nA bounded mechanism.\n"], [false, true])
    func substantiveLiteralQuoteRetainsItsWhitespace(quote: String, legacy: Bool) throws {
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.criteria = ["Explain the mechanism"]
        let judgment = PracticeFeedback.RubricAssessment(presence: .present, accuracy: .unverified,
            accuracyBasis: "Submitted content only.", fulfillment: .met, basis: "Declared expression.")
        let feedback = PracticeFeedback(covered: [.init(criterion: task.criteria[0], quote: quote)],
            missing: [], suggestions: [], followUp: nil, reason: "Declared expression.", reference: "A bounded mechanism.",
            assessments: legacy ? nil : [.init(criterion: task.criteria[0], quote: quote, judgment: judgment)])
        #expect(try feedback.validated(answer: quote, task: task, evidence: []).covered.first?.quote == quote)
    }

    @Test(arguments: Array(0..<4))
    func persistedAssessmentCannotBypassQuoteAndDimensionAdmission(_ defect: Int) throws {
        var task = InterviewTaskDescriptor(question: "Explain a mechanism.", kind: .generalKnowledge)
        task.criteria = ["Explain the mechanism"]
        let answer = "First original sentence. Second original sentence."
        var judgment = PracticeFeedback.RubricAssessment(presence: .present, accuracy: .unverified,
            accuracyBasis: "submitted content only", fulfillment: .met, basis: "Caller-declared explanation.")
        var quote: String? = "First original sentence."
        if defect == 1 { judgment.presence = .absent }
        if defect == 2 { judgment.basis = "" }
        if defect == 3 { judgment.presence = .absent; judgment.accuracy = .contradicted; judgment.fulfillment = .unmet; quote = nil }
        let feedback = PracticeFeedback(covered: defect == 3 ? [] : [.init(criterion: task.criteria[0],
            quote: defect == 0 ? "Second original sentence." : "First original sentence.")],
            missing: defect == 3 ? task.criteria : [], suggestions: [], followUp: nil,
            reason: "Scripted judgment.", reference: "A bounded mechanism.", assessments: [.init(criterion: task.criteria[0], quote: quote, judgment: judgment)])
        #expect(throws: (any Error).self) { try feedback.validated(answer: answer, task: task, evidence: []) }
    }

    @Test
    func futurePlanGapReviewPreservesPastOutcomeScopeAndSourceLimitedReference() async throws {
        let row = try fixtures()[8]
        let first = try declaredScriptedDraft(row)
        var final = first
        final.reviewOutcome = "accepted"
        final.followUp = "What was actually decided or observed after the disagreement, if anything, or is there no outcome yet?"
        final.reason = "The past disagreement and action are covered; the actual outcome is not stated."
        final.suggestion = "Add an already observed outcome, if any; keep the planned test as a future step."
        final.reference = ""
        let transport = SemanticReviewTransport(outputs: [try wire(first), try wire(final)])
        let feedback = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
            attachment: nil, evidence: [], provider: transport, model: "synthetic-semantic-review")
        #expect(feedback.followUp == final.followUp)
        #expect(feedback.reason == final.reason)
        #expect(feedback.reference == first.reference)
        let request = try #require(await transport.requests.last)
        #expect(request.systemPrompt?.contains("never presuppose a stated future activity already happened") == true)
        let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        #expect(input["draft_first_missing_rubric_id"] == nil && input["draft_first_missing_rubric_criterion"] == nil)
        #expect(input["answer"] == row.answer)
    }

    @Test
    func reviewCannotReplaceSourceLimitedNoticeWithAnUnverifiedBiography() async throws {
        let row = try fixtures()[8]
        let first = try declaredScriptedDraft(row)
        var final = first
        final.reviewOutcome = "accepted"
        final.reference = "I resolved the disagreement and completed the planned prototype test."
        let transport = SemanticReviewTransport(outputs: [try wire(first), try wire(final)])
        do {
            _ = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
                attachment: nil, evidence: [], provider: transport, model: "synthetic-semantic-review")
            Issue.record("A final review cannot upgrade submitted text into verified source facts.")
        } catch { #expect(error.localizedDescription.contains("source-limited reference")) }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func missingReviewDispositionDoesNotBecomeAcceptedFeedback() async throws {
        let row = try fixtures()[4]
        let first = try declaredScriptedDraft(row)
        let transport = SemanticReviewTransport(outputs: [try wire(first), try wire(first)])
        do {
            _ = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
                attachment: nil, evidence: [], provider: transport, model: "synthetic-semantic-review")
            Issue.record("No final review disposition means no acceptance.")
        } catch { #expect(error.localizedDescription.contains("Semantic review rejected")) }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func schemaIgnoringReviewCannotQuoteAnotherAnswerRevision() async throws {
        let row = try fixtures()[12]
        let first = try declaredScriptedDraft(row)
        var final = first
        final.reviewOutcome = "accepted"
        final.coverage["r1"] = .some("The later answer revision supplies a limitation not present here.")
        final.assessments?["r1"] = .init(presence: .present, accuracy: .unverified,
            accuracyBasis: "declared scripted packet", fulfillment: .met, basis: "Declared scripted fulfillment.")
        final.followUp = nil
        let transport = SemanticReviewTransport(outputs: [try wire(first), try wire(final)])
        do {
            _ = try await PracticeController.evaluate(attempt: makeAttempt(row), task: row.task,
                attachment: nil, evidence: [], provider: transport, model: "synthetic-semantic-review")
            Issue.record("Review cannot import a quote from another answer revision.")
        } catch { #expect(error.localizedDescription.contains("quote/rubric validation")) }
        #expect(await transport.requests.count == 2)
    }

    private func fixtures() throws -> [CapturedRow] {
        let path = try #require(Bundle.module.url(forResource: "PracticeScopedAcceptedContradictions", withExtension: "json"))
        return try JSONDecoder().decode([CapturedRow].self, from: Data(contentsOf: path))
    }
    // Reuses archived quotes/prose as a separately declared scripted packet;
    // neither historical bytes nor historical real-model results are upgraded.
    private func declaredScriptedDraft(_ row: CapturedRow) throws -> PracticeEvaluationPayload {
        let old = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(row.capturedWire.utf8))
        return .init(coverage: old.coverage, suggestion: old.suggestion, followUp: old.followUp,
            reason: old.reason, reference: old.reference, reviewOutcome: old.reviewOutcome)
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
    }
}

private actor SemanticReviewTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-semantic-review"
    nonisolated let displayName = "Synthetic semantic review"
    let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra semantic review request.") }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: outputs[index], source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
