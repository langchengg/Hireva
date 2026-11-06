import Foundation
import FSRS

/// Wire rubric IDs are mapped only to the frozen rubric, never inferred from
/// malformed output. Quotes describe expressed content, independently of fulfillment.
struct PracticeEvaluationPayload: Codable {
    var coverage: [String: String?]
    var assessments: [String: PracticeFeedback.RubricAssessment]?
    var suggestion: String
    var followUp: String?
    var reason: String
    var reference: String
    // Wire-only final review disposition. It is not persisted as a score,
    // candidate fact, or proof that arbitrary technical claims are true.
    var reviewOutcome: String?
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(coverage: [String: String?], suggestion: String, followUp: String?, reason: String, reference: String, reviewOutcome: String? = nil,
         assessments: [String: PracticeFeedback.RubricAssessment]? = nil) {
        self.coverage = coverage; self.suggestion = suggestion; self.followUp = followUp; self.reason = reason; self.reference = reference
        self.reviewOutcome = reviewOutcome
        // This initializer receives caller-declared fulfillment, not model text
        // or stored records. Legacy decoding below never upgrades judgments.
        self.assessments = assessments ?? coverage.mapValues { quote in
            .init(presence: quote == nil ? .absent : .present,
                accuracy: quote == nil ? .notApplicable : .unverified,
                accuracyBasis: "caller declaration; factual support unverified",
                fulfillment: quote == nil ? .unmet : .met, basis: "Caller-declared rubric fulfillment.")
        }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        suggestion = try values.decode(String.self, forKey: Key("suggestion"))
        let followUpText = try values.decode(String.self, forKey: Key("followUp"))
        followUp = followUpText.isEmpty ? nil : followUpText
        reason = try values.decode(String.self, forKey: Key("reason"))
        reference = try values.decode(String.self, forKey: Key("reference"))
        reviewOutcome = try values.decodeIfPresent(String.self, forKey: Key("reviewOutcome"))
        assessments = try values.decodeIfPresent([String: PracticeFeedback.RubricAssessment].self, forKey: Key("assessments"))
        coverage = [:]
        let fixed = Set(["suggestion", "followUp", "reason", "reference", "reviewOutcome", "assessments"])
        for key in values.allKeys where !fixed.contains(key.stringValue) {
            guard key.stringValue.first == "r", Int(key.stringValue.dropFirst()) != nil else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Unexpected evaluation field")
            }
            let quote = try values.decode(String.self, forKey: key)
            coverage[key.stringValue] = .some(quote.isEmpty ? nil : quote)
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(suggestion, forKey: Key("suggestion"))
        try values.encode(followUp ?? "", forKey: Key("followUp"))
        try values.encode(reason, forKey: Key("reason"))
        try values.encode(reference, forKey: Key("reference"))
        try values.encodeIfPresent(reviewOutcome, forKey: Key("reviewOutcome"))
        try values.encodeIfPresent(assessments, forKey: Key("assessments"))
        for (id, quote) in coverage { try values.encode(quote ?? "", forKey: Key(id)) }
    }
    static func schema(criteriaCount: Int, sourceLimitedReference: String? = nil) -> LocalJSONValue {
        let text: LocalJSONValue = .object(["type": .string("string")])
        let nullable = text // Empty string explicitly represents an unfilled rubric slot.
        let ids = (0..<criteriaCount).map { "r\($0)" }
        var fields = Dictionary(uniqueKeysWithValues: ids.map { ($0, nullable) })
        fields.merge(["suggestion": text, "followUp": nullable, "reason": text, "reference": text]) { _, next in next }
        fields["assessments"] = assessmentSchema(ids: ids)
        if let sourceLimitedReference {
            fields["reference"] = .object(["type": .string("string"), "const": .string(sourceLimitedReference)])
        }
        return .object(["type": .string("object"), "properties": .object(fields), "required": .array((ids + ["assessments", "suggestion", "followUp", "reason", "reference"]).map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
    }
    private static func assessmentSchema(ids: [String]) -> LocalJSONValue {
        func choice(_ values: [String]) -> LocalJSONValue {
            .object(["type": .string("string"), "enum": .array(values.map(LocalJSONValue.string))])
        }
        let fields: [String: LocalJSONValue] = [
            "presence": choice(["present", "partial", "uncertain"]),
            "accuracy": choice(["supported", "contradicted", "unverified", "not_applicable"]),
            "accuracyBasis": .object(["type": .string("string")]),
            "fulfillment": choice(["met", "partly_met", "unmet", "uncertain"]),
            "basis": .object(["type": .string("string")])]
        var absent = fields
        absent["presence"] = choice(["absent"])
        absent["accuracy"] = choice(["unverified", "not_applicable"])
        absent["fulfillment"] = choice(["partly_met", "unmet", "uncertain"])
        // Absence cannot contradict a claim or fulfill a requirement; literal quotes still pass runtime admission.
        let branches = [absent, fields].map { properties in
            LocalJSONValue.object(["type": .string("object"), "properties": .object(properties),
                "required": .array(properties.keys.sorted().map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
        }
        let item: LocalJSONValue = .object(["$ref": .string("#/properties/assessments/$defs/assessment")])
        return .object(["type": .string("object"), "$defs": .object(["assessment": .object(["anyOf": .array(branches)])]), "description": .string("For each criterion independently: presence is expressed content; accuracy and accuracyBasis describe only its claim's actual support/scope (model drafts are unverified); fulfillment and basis state the requested requirement and concrete remaining gap, without extra requirements."), "properties": .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, item) })),
            "required": .array(ids.map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
    }
    /// The primary map is a structurally admitted draft, never final authority.
    /// The reviewer may correct coverage using only this same answer/rubric;
    /// its final map passes literal quote, rubric and source checks again.
    func semanticReviewCandidate(answer: String, task: InterviewTaskDescriptor, evidence: [ProfileEvidence]) throws -> Self {
        var candidate = try mappedFeedback(task: task)
        candidate.followUp = nil
        let validated = try candidate.validated(answer: answer, task: task, evidence: evidence)
        var frozen = self
        // Preserve a gap question as untrusted review input. Complete drafts
        // still suppress optional refinements; the final map/question remains
        // independently editable and passes the normal admission boundary.
        frozen.followUp = validated.missing.isEmpty ? nil : followUp
        frozen.reference = validated.reference
        frozen.assessments = validated.assessments.map {
            Dictionary(uniqueKeysWithValues: $0.enumerated().map { ("r\($0.offset)", $0.element.judgment) })
        }
        frozen.reviewOutcome = nil
        return frozen
    }

    func semanticReviewSchema(fixedReference: Bool) -> LocalJSONValue {
        func fixed(_ value: String) -> LocalJSONValue {
            .object(["type": .string("string"), "const": .string(value)])
        }
        // Keys come from the already admitted frozen rubric. Values are draft
        // judgments, not immutable facts: the final reviewer may correct them.
        var fields = Dictionary(uniqueKeysWithValues: coverage.keys.map { id in
            (id, LocalJSONValue.object(["type": .string("string"), "description": .string("For \(id), copy an exact answer substring expressing content relevant to its supplied criterion, even when wrong or incomplete; empty only when absent. Assess fulfillment separately in assessments. Never put explanations in the quote field.")]))
        })
        fields["assessments"] = Self.assessmentSchema(ids: coverage.keys.sorted())
        fields["suggestion"] = .object(["type": .string("string")])
        fields["reason"] = .object(["type": .string("string")])
        // A normalized draft may already contain the application's notice.
        // That UI value must never return to the model as evidence or output.
        fields["reference"] = fixedReference ? fixed("") : .object(["type": .string("string")])
        // The final map can expose or resolve a gap absent from the draft.
        fields["followUp"] = .object(["type": .string("string"), "description": .string("One direct question for only the first criterion whose assessments fulfillment is not met, in rubric order. Ask for the actual gap or clarification, not content already expressed. Empty when all are met. Optional refinements belong in suggestion.")])
        fields["reviewOutcome"] = .object(["type": .string("string"), "enum": .array([.string("accepted"), .string("rejected")])])
        return .object(["type": .string("object"), "properties": .object(fields),
            "required": .array(fields.keys.sorted().map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
    }

    /// Bind each quote field to this request's frozen criterion. Descriptions
    /// are annotations only; literal/source/final-map admission stays unchanged.
    static func schema(criteria: [String], sourceLimitedReference: String? = nil) -> LocalJSONValue {
        describingRubric(schema(criteriaCount: criteria.count, sourceLimitedReference: sourceLimitedReference), criteria: criteria)
    }
    func semanticReviewSchema(fixedReference: Bool, criteria: [String], feedbackLanguage: String? = nil) -> LocalJSONValue {
        let schema = Self.describingRubric(semanticReviewSchema(fixedReference: fixedReference), criteria: criteria)
        guard let feedbackLanguage, case .object(var object) = schema,
              case .object(var fields)? = object["properties"] else { return schema }
        // Bind prose locally too; bilingual rubric annotations do not select its language.
        for name in ["reason", "suggestion"] {
            guard case .object(var field)? = fields[name] else { continue }
            field["description"] = .string(feedbackLanguage == "zh"
                ? "此字段的候选人反馈必须使用中文；引用原文时保留原文语言。"
                : "Write this candidate-facing field in \(feedbackLanguage); preserve the original language of quoted answer text.")
            fields[name] = .object(field)
        }
        object["properties"] = .object(fields)
        return .object(object)
    }
    private static func describingRubric(_ schema: LocalJSONValue, criteria: [String]) -> LocalJSONValue {
        guard case .object(var object) = schema, case .object(var fields)? = object["properties"] else { return schema }
        for (index, criterion) in criteria.enumerated() {
            let id = "r\(index)"
            guard case .object(var field)? = fields[id] else { continue }
            let rule: String
            if case .string(let existing)? = field["description"] { rule = existing }
            else { rule = "For \(id), copy an exact answer substring expressing relevant content even if wrong or incomplete, or empty if absent. Assess fulfillment separately in assessments; do not put explanations in the quote." }
            field["description"] = .string("Supplied frozen rubric criterion for \(id): \(criterion)\n\(rule)")
            fields[id] = .object(field)
        }
        if case .object(var assessmentObject)? = fields["assessments"],
           case .object(var items)? = assessmentObject["properties"] {
            for (index, criterion) in criteria.enumerated() {
                let id = "r\(index)"
                if case .object(var item)? = items[id] {
                    item["description"] = .string("Assess only this frozen criterion: \(criterion). Its quote is the separate \(id) field.")
                    items[id] = .object(item)
                }
            }
            assessmentObject["properties"] = .object(items)
            fields["assessments"] = .object(assessmentObject)
        }
        if fields["reviewOutcome"] != nil,
           case .object(var followUp)? = fields["followUp"],
           case .string(let rule)? = followUp["description"] {
            let branches = criteria.enumerated().map { index, criterion in
                "\(index == 0 ? "if" : "else if") assessments.r\(index).fulfillment != \"met\": target r\(index): \(criterion)"
            }.joined(separator: "\n")
            followUp["description"] = .string("""
            \(rule)
            Select using your own final returned rubric values, not the draft map. Use the first matching branch in this frozen rubric order:
            \(branches)
            else: return ""
            For the selected target, ask one direct candidate-facing question requesting only its remaining unmet part, without repeating already expressed content. Use the original question as context. Keep later gaps and optional refinements in suggestion. Follow the existing language, temporal and question-scope rules. Do not emit rubric IDs or selection mechanics.
            For an actual past-event result gap, ask what is known or observed so far, if anything, and allow no outcome yet.
            Keep stated future activities as future; do not ask whether they already happened or ask for their completed result.
            For a hypothetical proposal, ask about reasoning or proposed choices without requiring a past personal event.
            """)
            fields["followUp"] = .object(followUp)
        }
        if case .object(var reference)? = fields["reference"], reference["const"] == nil {
            reference["description"] = .string("""
            Answer the original question with a concise qualified explanation, separate from the candidate's omissions.
            Preserve the original question's stated constraints. Do not assume omitted existence, uniqueness or other conditions; state any added assumption explicitly.
            Do not add unrequested exercise, source or task identifiers, or present an unverified identifier as established fact.
            For any claimed guarantee, state assumptions, operation boundaries, conditions and relevant possible failures.
            A local mechanism or category name does not establish unconditional system outcomes or physical properties.
            Keep each property or limitation attached to its actual subject and operation; do not transfer it to the other subject of a comparison. Do not invent a comparison axis or a property difference absent from the question; qualify implementation-dependent properties.
            Submitted assertions and draft wording are not authority; independently correct them. Preserve the existing source, language, temporal and ownership restrictions.
            """)
            fields["reference"] = .object(reference)
        }
        object["properties"] = .object(fields)
        return .object(object)
    }

    func feedback(task: InterviewTaskDescriptor) throws -> PracticeFeedback {
        let feedback = try mappedFeedback(task: task)
        guard feedback.missing.isEmpty || !(followUp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw MaterialError.invalid("Evaluation marks a rubric gap but provides no targeted follow-up. Recheck the answer quotes and missing criteria.")
        }
        guard !feedback.missing.isEmpty || (followUp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw MaterialError.invalid("Evaluation asks a follow-up despite a complete rubric map.")
        }
        return feedback
    }

    private func mappedFeedback(task: InterviewTaskDescriptor) throws -> PracticeFeedback {
        guard Set(coverage.keys) == Set(task.criteria.indices.map { "r\($0)" }) else { throw MaterialError.invalid("Evaluation omitted or invented rubric IDs.") }
        guard let assessments, Set(assessments.keys) == Set(coverage.keys) else {
            throw MaterialError.invalid("Evaluation omitted or invented criterion assessments. Legacy quotes alone do not establish fulfillment.")
        }
        var covered: [PracticeFeedback.Coverage] = [], missing: [String] = []
        var judgments: [PracticeFeedback.CriterionAssessment] = []
        for (index, criterion) in task.criteria.enumerated() {
            let id = "r\(index)"
            let quote = coverage[id] ?? nil
            guard let judgment = assessments[id], judgment.admits(quote: quote) else {
                throw MaterialError.invalid("Criterion assessment conflicts with its quote or omitted its basis: \(id), quoteEmpty=\(quote == nil), presence=\(assessments[id]?.presence.rawValue ?? "missing"), accuracy=\(assessments[id]?.accuracy.rawValue ?? "missing"), fulfillment=\(assessments[id]?.fulfillment.rawValue ?? "missing"). Reconcile these fields using an exact substring of the submitted answer; do not invent a quote.")
            }
            if judgment.fulfillment == .met, let quote { covered.append(.init(criterion: criterion, quote: quote)) }
            else { missing.append(criterion) }
            judgments.append(.init(criterion: criterion, quote: quote, judgment: judgment))
        }
        return .init(covered: covered, missing: missing, suggestions: [suggestion], followUp: missing.isEmpty ? nil : followUp, reason: reason, reference: reference, assessments: judgments)
    }

    func firstUnmetCriterion(task: InterviewTaskDescriptor) throws -> Int? {
        let feedback = try mappedFeedback(task: task)
        return task.criteria.firstIndex { feedback.missing.contains($0) }
    }
}

enum PracticePhase: String, Codable {
    case preparing, asking, answering, evaluating, followUp, completed, paused, cancelled, failed
}
struct PracticeFeedback: Codable, Equatable {
    struct Coverage: Codable, Equatable { var criterion: String; var quote: String }
    enum ReferenceOrigin: String, Codable { case modelDraft, applicationSourceNotice }
    struct RubricAssessment: Codable, Equatable {
        enum Presence: String, Codable { case present, partial, absent, uncertain }
        enum Accuracy: String, Codable { case supported, contradicted, unverified; case notApplicable = "not_applicable" }
        enum Fulfillment: String, Codable { case met, unmet, uncertain; case partlyMet = "partly_met" }
        var presence: Presence
        var accuracy: Accuracy
        var accuracyBasis: String
        var fulfillment: Fulfillment
        var basis: String

        func admits(quote: String?) -> Bool {
            basis.count <= 1000 && !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && accuracyBasis.count <= 1000 && (!accuracyBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (presence == .absent && accuracy == .notApplicable && quote == nil))
                && (quote == nil || quote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                && (![.supported, .contradicted].contains(accuracy) || quote != nil)
                && (presence != .absent || (quote == nil && ![.supported, .contradicted].contains(accuracy)))
                && (![.present, .partial].contains(presence) || quote != nil)
                && (fulfillment != .met || quote != nil)
        }
    }
    struct CriterionAssessment: Codable, Equatable {
        var criterion: String
        var quote: String?
        var judgment: RubricAssessment
    }
    var covered: [Coverage]
    var missing: [String]
    var suggestions: [String]
    var followUp: String?
    var reason: String
    var reference: String
    // Application-owned provenance; structural admission is not fact verification.
    var referenceOrigin: ReferenceOrigin? = nil
    var assessments: [CriterionAssessment]? = nil

    var assessmentLines: [String] {
        guard let assessments else {
            return ["Legacy coverage; assessment dimensions unknown."] + covered.map { "\($0.criterion): “\($0.quote)”" }
                + ["Legacy gaps: " + missing.joined(separator: "; ")]
        }
        return ["Model judgments; factual accuracy is not independently certified."] + assessments.map {
            "\($0.criterion): \($0.judgment.presence.rawValue) · \($0.judgment.accuracy.rawValue) · \($0.judgment.fulfillment.rawValue)\n"
                + ($0.quote.map { "“\($0)”\n" } ?? "") + $0.judgment.basis
                + ($0.judgment.accuracyBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : "\nBasis: " + $0.judgment.accuracyBasis)
        }
    }

    // This is the application's source restriction, never a model evaluation
    // of the submitted answer or an automatic final-review disposition.
    static func sourceLimitedReference(language: String) -> String {
        language == "zh"
            ? "个人参考答案暂不可生成：请提供并确认相关事实。可继续练习；按评价标准补充真实经历，缺失结果或数字留空。"
            : "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
    }

    func validated(answer: String, task: InterviewTaskDescriptor, evidence: [ProfileEvidence]) throws -> Self {
        if let assessments {
            guard assessments.count == task.criteria.count,
                  assessments.map(\.criterion) == task.criteria,
                  assessments.allSatisfy({ $0.judgment.admits(quote: $0.quote) && ($0.quote.map(answer.contains) ?? true) }),
                  covered == assessments.filter({ $0.judgment.fulfillment == .met }).compactMap({ item in
                      item.quote.map { Coverage(criterion: item.criterion, quote: $0) }
                  }),
                  missing == assessments.filter({ $0.judgment.fulfillment != .met }).map(\.criterion) else {
                throw MaterialError.invalid("Feedback criterion assessments failed literal quote/rubric validation.")
            }
        }
        guard covered.count <= 12, missing.count <= 12, suggestions.count <= 8,
              covered.allSatisfy({ !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.contains($0.quote) && task.criteria.contains($0.criterion) }),
              missing.allSatisfy(task.criteria.contains),
              Set(covered.map(\.criterion)).isDisjoint(with: Set(missing)),
              !task.criteria.isEmpty, Set(covered.map(\.criterion) + missing) == Set(task.criteria),
              Set(covered.map(\.criterion) + missing).count == covered.count + missing.count,
              reference.count <= 5000, reason.count <= 2000,
              followUp == nil || (!missing.isEmpty && !(followUp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) else {
            throw MaterialError.invalid("Feedback failed quote/rubric validation. Retry or review your answer manually.")
        }
        var safe = self
        // shortcut: Han presence rejects entirely non-Chinese prose; fluency and semantic correctness still need review.
        if (task.explanationLanguage ?? task.language) == "zh",
           ([reason] + suggestions + [followUp ?? ""]).contains(where: {
               !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !QuestionLanguageSupport.containsHan($0)
           }) {
            throw MaterialError.invalid("Feedback prose did not use the frozen Chinese feedback language.")
        }
        let sourceFreeBehavioralRubric = task.personalEvidence == .required
            && task.decision?.basis == .candidateRecord && task.kind == .behavioral
            && task.criteria == InterviewTaskKind.behavioral.criteria && !evidence.contains(where: \.isUsable)
        // shortcut: the source-free rule covers default personal STAR criteria; custom and mixed rubrics need item-level source scope.
        safe.assessments = assessments?.map { assessment in
            var assessment = assessment
            if assessment.judgment.accuracy == .supported, let quote = assessment.quote,
               sourceFreeBehavioralRubric || !AnswerClaimValidator().validate(answer: quote, candidateEvidence: evidence,
                   opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty {
                assessment.judgment.accuracy = .unverified
                assessment.judgment.accuracyBasis = (task.explanationLanguage ?? task.language) == "zh"
                    ? "个人事实来源尚未核实；原文引用只证明说过，不能证明经历属实。"
                    : "Personal source support is unverified; an answer quote establishes expression, not the claimed experience."
            }
            return assessment
        }
        // Without personal sources, a model reference is unsafe even in second
        // person. Still evaluate the submitted answer; never treat it as a CV.
        if [.required, .uncertain].contains(task.personalEvidence) && !evidence.contains(where: \.isUsable) {
            safe.reference = Self.sourceLimitedReference(language: task.language)
            safe.referenceOrigin = .applicationSourceNotice
            return safe
        }
        let claims = AnswerClaimValidator().validate(answer: reference, candidateEvidence: evidence, opportunityEvidence: [], domainKnowledge: [])
        guard claims.unsupportedClaims.isEmpty else { throw MaterialError.invalid("Reference answer contained unsupported personal claims.") }
        if task.language == "zh", !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !QuestionLanguageSupport.containsHan(reference) {
            throw MaterialError.invalid("Reference answer did not use the frozen Chinese question language.")
        }
        return safe
    }
}
struct PracticeAttempt: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var questionID: String
    var parentQuestionID: String?
    var question: String
    var answer: String
    var contextSnapshotID: String?
    var revision: Int
    var hinted: Bool
    var skipped: Bool
    var source: String
    var task: InterviewTaskDescriptor?
    var attachment: ExtractedMaterial?
    var attachmentRevision: Int?
    var feedback: PracticeFeedback?
    var createdAt = Date()
    var corrections: [PracticeAttemptRevision]?
}
struct PracticeRun: Codable, Identifiable {
    var id: String { sessionID }
    var sessionID: String
    var snapshotID: String?
    var task: InterviewTaskDescriptor
    var questionID: String
    var mainQuestionID: String
    var phase: PracticePhase
    var historyAllowed: Bool?
    var draft = ""
    var attempts: [PracticeAttempt] = []
    var followUpCount = 0
    var maxFollowUps = 2
    var revision = 0
    var hinted = false
    var source = "keyboard"
    var attachment: ExtractedMaterial?
    var attachmentOriginalData: Data?
    var attachmentRevision = 0
    var sqlResults: [PracticeSQLExecution] = []
    var updatedAt = Date()
}
struct KnowledgeReviewCard: Codable, Identifiable {
    var id: String // attempt id makes creation idempotent
    var sessionID: String
    var question: String
    var answer: String
    var card: Card
    var log: [ReviewLog] = []
    var hinted: Bool
    var algorithm = "swift-fsrs-4.1.0"
    var needsReevaluation: Bool?
    var sourceAttemptRevision: Int? = nil
}

struct PracticeSQLExecution: Codable {
    var questionID: String
    var revision: Int
    var attachmentRevision: Int
    var contextSnapshotID: String?
    var result: SQLPracticeResult
}

/// Correction history preserves the original attempt identity and assistance.
struct PracticeAttemptRevision: Codable, Equatable {
    var hinted: Bool? = nil
    var revision: Int
    var question: String
    var answer: String
    var task: InterviewTaskDescriptor?
    var feedback: PracticeFeedback?
    var correctedAt: Date
}
