import Foundation
import Testing
@testable import Hireva

/// Predetermined replies inspect actual request/admission only. Field annotations
/// cannot prove that a model identifies substantive support or technical truth.
@Suite
@MainActor
struct PracticeGroundedCriterionSchemaTests {
    @Test(arguments: [false, true])
    func absentAssessmentSchemaPreservesTheRuntimeAdmissionContract(final: Bool) throws {
        let f = fixture(chinese: false, personal: false, reversed: false)
        let schema = final ? f.primary.semanticReviewSchema(fixedReference: false, criteria: f.task.criteria)
            : PracticeEvaluationPayload.schema(criteria: f.task.criteria)
        let fields = try properties(schema)
        guard case .object(let assessment)? = fields["assessments"],
              case .object(let definitions)? = assessment["$defs"],
              case .object(let definition)? = definitions["assessment"],
              case .array(let branches)? = definition["anyOf"], branches.count == 2,
              case .object(let items)? = assessment["properties"] else {
            Issue.record("Both request phases must constrain absence without repeating the full schema per criterion."); return
        }
        for id in ["r0", "r1"] {
            guard case .object(let item)? = items[id] else { Issue.record("Missing criterion reference."); continue }
            #expect(item["$ref"] == .string("#/properties/assessments/$defs/assessment"))
            #expect(item["description"] != nil)
        }
        guard case .object(let absent) = branches[0], case .object(let absentFields)? = absent["properties"],
              case .object(let presence)? = absentFields["presence"],
              case .object(let accuracy)? = absentFields["accuracy"], case .array(let accuracies)? = accuracy["enum"],
              case .object(let fulfillment)? = absentFields["fulfillment"], case .array(let fulfillments)? = fulfillment["enum"] else {
            Issue.record("Absent branch must be a complete constrained object."); return
        }
        #expect(presence["enum"] == .array([.string("absent")]))
        for branch in branches {
            guard case .object(let object) = branch else { Issue.record("Expected complete object branch."); continue }
            #expect(object["type"] == .string("object") && object["additionalProperties"] == .boolean(false))
            #expect(object["required"] == .array(["accuracy", "accuracyBasis", "basis", "fulfillment", "presence"].map(LocalJSONValue.string)))
            #expect(Set(try properties(branch).keys) == Set(["accuracy", "accuracyBasis", "basis", "fulfillment", "presence"]))
        }
        let expressed = try properties(branches[1])
        for (name, choices) in ["presence": ["present", "partial", "uncertain"],
                                "accuracy": ["supported", "contradicted", "unverified", "not_applicable"],
                                "fulfillment": ["met", "partly_met", "unmet", "uncertain"]] {
            #expect(expressed[name] == .object(["type": .string("string"), "enum": .array(choices.map(LocalJSONValue.string))]))
        }
        for accuracy in ["supported", "contradicted", "unverified", "not_applicable"] {
            for fulfillment in ["met", "partly_met", "unmet", "uncertain"] {
                let judgment = PracticeFeedback.RubricAssessment(presence: .absent,
                    accuracy: try #require(.init(rawValue: accuracy)), accuracyBasis: "No relevant claim was expressed.",
                    fulfillment: try #require(.init(rawValue: fulfillment)), basis: "The requested content is absent.")
                #expect((accuracies.contains(.string(accuracy)) && fulfillments.contains(.string(fulfillment))) == judgment.admits(quote: nil))
            }
        }
    }

    @Test(arguments: Array(0..<8))
    func bothEvaluationPhasesBindEachFieldToItsFrozenCriterion(_ variant: Int) async throws {
        let chinese = variant & 1 != 0, personal = variant & 2 != 0, reversed = variant & 4 != 0
        let f = fixture(chinese: chinese, personal: personal, reversed: reversed)
        let provider = CriterionSchemaPackets(outputs: try outputs(f))
        let feedback = try await evaluate(f, provider)
        #expect(feedback.covered.map(\.criterion) == f.task.criteria)
        #expect(feedback.covered.map(\.quote) == f.quotes)
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        #expect(feedback.reference == f.reference)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let frozen = try f.primary.semanticReviewCandidate(answer: f.attempt.answer, task: f.task, evidence: [])
        for (phase, request) in requests.enumerated() {
            let input = try values(request)
            #expect(input["question"] == f.attempt.question && input["answer"] == f.attempt.answer)
            #expect(input["rubric"] == f.task.criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
            #expect(input["attachment"] == "" && input["source_evidence"] == "")
            #expect(request.modelName == "synthetic-criterion-schema" && request.temperature == 0)
            #expect(request.numPredict == 1200 && !request.thinkingEnabled && request.prompt.utf8.count <= 24000)
            let schema = try #require(request.responseSchema)
            let fields = try properties(schema)
            for (index, criterion) in f.task.criteria.enumerated() {
                let id = "r\(index)"
                guard case .object(let field)? = fields[id], case .string(let description)? = field["description"] else {
                    Issue.record("Every primary/final field needs its actual frozen criterion annotation."); continue
                }
                #expect(Set(field.keys) == Set(["type", "description"]))
                #expect(field["type"] == .string("string"))
                #expect(description.contains(id) && description.contains(criterion))
                #expect(description.contains("copy an exact answer substring") && description.contains("empty"))
            }
            let template = phase == 0
                ? PracticeEvaluationPayload.schema(criteriaCount: f.task.criteria.count, sourceLimitedReference: personal ? "" : nil)
                : frozen.semanticReviewSchema(fixedReference: personal)
            #expect(try withoutRubricDescriptions(schema, count: f.task.criteria.count) == withoutRubricDescriptions(template, count: f.task.criteria.count))
            if phase == 1 {
                let grounded = try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(input["output_schema"]).utf8))
                #expect(grounded == schema)
                #expect(input["draft_feedback"] == nil && input["draft_first_missing_rubric_id"] == nil)
                #expect(input["fixed_output_fields"] == (personal ? "[\"reference\"]" : "[]"))
                #expect(input["previous_invalid_output"] == nil)
            } else {
                #expect(input["draft_feedback"] == nil)
                #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(input["output_schema"]).utf8)) == schema)
            }
        }
    }

    @Test(arguments: Array(0..<4))
    func criticFeedbackFieldsBindTheFrozenLanguageWithoutChangingQuoteLanguage(_ variant: Int) async throws {
        var f = fixture(chinese: variant & 1 != 0, personal: true, reversed: false)
        let feedbackLanguage = variant & 2 == 0 ? f.task.language : (f.task.language == "zh" ? "en" : "zh")
        f.task.explanationLanguage = feedbackLanguage
        f.attempt.task = f.task
        f.primary.reason = feedbackLanguage == "zh" ? "已表达行动与结果。" : "The stated action and result are expressed."
        f.primary.suggestion = feedbackLanguage == "zh" ? "保留所述内容。" : "Keep the expressed content."
        let provider = CriterionSchemaPackets(outputs: try outputs(f))
        let feedback = try await evaluate(f, provider)
        #expect(feedback.covered.map(\.quote) == f.quotes && feedback.reference == f.reference)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for (phase, request) in requests.enumerated() {
            let input = try values(request)
            #expect(input["feedback_language"] == feedbackLanguage && input["reference_language"] == f.task.language)
            #expect(input["answer"] == f.attempt.answer)
            #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(try #require(input["output_schema"]).utf8)) == request.responseSchema)
            let fields = try properties(try #require(request.responseSchema))
            for name in ["reason", "suggestion"] {
                guard case .object(let field)? = fields[name] else { Issue.record("Missing feedback field."); continue }
                if phase == 0 { #expect(field == ["type": .string("string")]) }
                else {
                    let description = try #require(field["description"])
                    #expect(description == .string(feedbackLanguage == "zh"
                        ? "此字段的候选人反馈必须使用中文；引用原文时保留原文语言。"
                        : "Write this candidate-facing field in \(feedbackLanguage); preserve the original language of quoted answer text."))
                    #expect(Set(field.keys) == Set(["type", "description"]))
                }
            }
        }
    }

    @Test
    func twelveDeclaredCriteriaRemainBoundedWithoutTruncatingControlledScenario() async throws {
        var f = fixture(chinese: false, personal: false, reversed: false)
        f.task.question += " Scenario notes: " + String(repeating: "n", count: 6500)
        f.attempt.question = f.task.question
        f.task.criteria = (0..<12).map { "Supplied rule criterion \($0)" }
        f.attempt.task = f.task
        f.quotes = Array(repeating: f.attempt.answer, count: 12)
        f.primary = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues: f.quotes.enumerated().map { ("r\($0.offset)", Optional($0.element)) }),
            suggestion: f.primary.suggestion, followUp: nil, reason: f.primary.reason, reference: f.primary.reference)
        let provider = CriterionSchemaPackets(outputs: try outputs(f))
        let feedback = try await evaluate(f, provider)
        #expect(feedback.covered.map(\.quote) == f.quotes && feedback.missing.isEmpty)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        for request in requests {
            let input = try values(request)
            #expect(input["question"] == f.attempt.question && input["answer"] == f.attempt.answer)
            #expect(request.prompt.utf8.count <= 24000 && request.numPredict == 1200)
            let fields = try properties(try #require(request.responseSchema))
            for (index, criterion) in f.task.criteria.enumerated() {
                guard case .object(let field)? = fields["r\(index)"], case .string(let description)? = field["description"] else {
                    Issue.record("The capacity case must retain all twelve actual criterion annotations."); continue
                }
                #expect(description.contains(criterion))
            }
        }
    }

    @Test
    func criterionAnnotationsDoNotAuthorizeAnInventedFinalQuote() async throws {
        let f = fixture(chinese: false, personal: false, reversed: false)
        var packets = try outputs(f)
        var invalid = f.primary; invalid.reviewOutcome = "accepted"
        invalid.coverage["r0"] = .some("A different revision added this absent explanation.")
        packets[1] = String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self)
        let provider = CriterionSchemaPackets(outputs: packets)
        do {
            _ = try await evaluate(f, provider)
            Issue.record("Criterion annotations cannot bypass same-revision literal validation.")
        } catch { #expect(error.localizedDescription.contains("quote/rubric validation")) }
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: [false, true])
    func invalidPrimaryQuoteKeepsItsDiagnosticOutOfTheIndependentCritic(repaired: Bool) async throws {
        let f = fixture(chinese: false, personal: false, reversed: false)
        var invalid = f.primary
        invalid.coverage["r1"] = .some(nil)
        invalid.assessments?["r1"]?.accuracy = .supported
        do {
            _ = try invalid.semanticReviewCandidate(answer: f.attempt.answer, task: f.task, evidence: [])
            Issue.record("The invalid primary must retain its original admission failure.")
        } catch {
            let diagnostic = error.localizedDescription
            #expect(diagnostic.contains("r1") && diagnostic.contains("quoteEmpty=true"))
            #expect(diagnostic.contains("presence=present") && diagnostic.contains("accuracy=supported") && diagnostic.contains("fulfillment=met"))
        }
        var final = repaired ? f.primary : invalid
        final.reviewOutcome = "accepted"
        let packets = try [invalid, final].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let provider = CriterionSchemaPackets(outputs: packets)
        do {
            let feedback = try await evaluate(f, provider)
            #expect(repaired)
            #expect(feedback.covered.map(\.quote) == f.quotes && feedback.missing.isEmpty)
        } catch {
            #expect(!repaired)
            #expect(error.localizedDescription.contains("r1"))
        }
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let input = try values(requests[1])
        #expect(input["validation_failure"] == nil)
        #expect(!requests[1].prompt.contains("quoteEmpty=true") && !requests[1].prompt.contains("presence=present"))
        #expect(input["answer"] == f.attempt.answer && input["previous_invalid_output"] == nil)
    }

    @Test
    func independentCriticCanReassessAnInvalidPresentClaimAsActuallyAbsent() async throws {
        var f = fixture(chinese: false, personal: false, reversed: false)
        f.attempt.answer = f.quotes[0]
        var invalid = f.primary
        invalid.coverage["r1"] = .some(nil)
        invalid.assessments?["r1"]?.accuracy = .contradicted
        invalid.reason = "stale-primary-judgment"
        invalid.reference = "stale-primary-reference"
        var final = f.primary
        final.coverage["r1"] = .some(nil)
        final.assessments?["r1"] = .init(presence: .absent, accuracy: .unverified,
            accuracyBasis: "No modification claim was expressed.", fulfillment: .unmet,
            basis: "The answer states appending only.")
        final.reason = "Appending is stated; the modification limit is not stated."
        final.suggestion = "State the modification limit."
        final.followUp = "What changes to existing entries does the rule permit?"
        final.reviewOutcome = "accepted"
        let provider = CriterionSchemaPackets(outputs: try [invalid, final].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })
        let feedback = try await evaluate(f, provider)
        #expect(feedback.covered.map(\.quote) == [f.quotes[0]])
        #expect(feedback.missing == [f.task.criteria[1]])
        #expect(feedback.followUp == final.followUp && feedback.reference == f.reference)
        let requests = await provider.recorded()
        try #require(requests.count == 2)
        let input = try values(requests[1])
        #expect(input["answer"] == f.attempt.answer && input["validation_failure"] == nil)
        #expect(input["draft_feedback"] == nil && input["previous_invalid_output"] == nil)
        #expect(!requests[1].prompt.contains("stale-primary-") && !requests[1].prompt.contains("accuracy=contradicted"))
    }

    private func fixture(chinese: Bool, personal: Bool, reversed: Bool) -> CriterionSchemaFixture {
        let question = personal ? "Describe your stated action and outcome." : "Explain the supplied ledger rule."
        var criteria = personal ? ["State the personal action", "State the observed outcome"] : ["Explain adding entries", "State the modification limit"]
        var quotes = personal ? ["I wrote the constraints down.", "The group adopted the checklist."] : ["New ledger entries are appended.", "Existing entries cannot be changed."]
        if chinese {
            criteria = personal ? ["说明个人行动", "说明已经观察到的结果"] : ["说明如何追加条目", "说明修改限制"]
            quotes = personal ? ["我写下了限制条件。", "小组采用了清单。"] : ["新条目通过追加写入。", "已有条目不能修改。"]
        }
        let answer = quotes.joined(separator: " ")
        if reversed { criteria.reverse(); quotes.reverse() }
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        let language = chinese ? "zh" : "en"
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-criterion-schema",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: "criterion-schema", questionRevision: 5, contextSnapshotID: "criterion-schema-context",
            artifactRevision: 0, model: "synthetic-criterion-schema", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let reference = personal ? PracticeFeedback.sourceLimitedReference(language: language) : (chinese ? "所给只追加规则允许新增条目，不允许修改已有条目。" : "The supplied append-only rule adds entries and prevents modifying previous entries.")
        let primary = PracticeEvaluationPayload(coverage: Dictionary(uniqueKeysWithValues: quotes.enumerated().map { ("r\($0.offset)", Optional($0.element)) }),
            suggestion: chinese ? "保留所述两点。" : "Keep the two stated points.", followUp: nil, reason: chinese ? "已说明所给两点。" : "Both supplied points are stated.", reference: personal ? "" : reference)
        let attempt = PracticeAttempt(questionID: "criterion-schema", question: question, answer: answer,
            contextSnapshotID: "criterion-schema-context", revision: 5, hinted: false, skipped: false, source: "synthetic-contract", task: task)
        return .init(task: task, attempt: attempt, quotes: quotes, reference: reference, primary: primary)
    }
    private func outputs(_ f: CriterionSchemaFixture) throws -> [String] {
        var final = f.primary; final.reviewOutcome = "accepted"
        return try [f.primary, final].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    }
    private func evaluate(_ f: CriterionSchemaFixture, _ provider: CriterionSchemaPackets) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: f.attempt, task: f.task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-criterion-schema")
    }
    private func values(_ request: LocalLLMRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
    }
    private func properties(_ schema: LocalJSONValue) throws -> [String: LocalJSONValue] {
        guard case .object(let object) = schema, case .object(let fields)? = object["properties"] else { throw MaterialError.invalid("Expected the existing flat schema.") }
        return fields
    }
    private func withoutRubricDescriptions(_ schema: LocalJSONValue, count: Int) throws -> LocalJSONValue {
        guard case .object(var object) = schema, case .object(var fields)? = object["properties"] else { throw MaterialError.invalid("Expected flat schema.") }
        for index in 0..<count {
            guard case .object(var field)? = fields["r\(index)"] else { throw MaterialError.invalid("Required field missing.") }
            field.removeValue(forKey: "description"); fields["r\(index)"] = .object(field)
        }
        if case .object(var assessment)? = fields["assessments"], case .object(var items)? = assessment["properties"] {
            for id in items.keys {
                if case .object(var item)? = items[id] { item.removeValue(forKey: "description"); items[id] = .object(item) }
            }
            assessment["properties"] = .object(items); fields["assessments"] = .object(assessment)
        }
        if case .object(var followUp)? = fields["followUp"] {
            followUp.removeValue(forKey: "description"); fields["followUp"] = .object(followUp)
        }
        for name in ["reason", "suggestion"] {
            if case .object(var field)? = fields[name] { field.removeValue(forKey: "description"); fields[name] = .object(field) }
        }
        if let reference = fields["reference"] {
            fields["reference"] = practiceReferenceSchemaConstraints(reference)
        }
        object["properties"] = .object(fields); return .object(object)
    }
}
private struct CriterionSchemaFixture {
    var task: InterviewTaskDescriptor; var attempt: PracticeAttempt; var quotes: [String]
    var reference: String; var primary: PracticeEvaluationPayload
}
private actor CriterionSchemaPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-criterion-schema"
    nonisolated let displayName = "Finite criterion-schema packets"
    private let outputs: [String]
    private var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth { .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil) }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count && index < 2 else { throw MaterialError.invalid("Unexpected additional criterion-schema request.") }
        return AsyncThrowingStream { c in c.yield(.init(text: outputs[index], source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
