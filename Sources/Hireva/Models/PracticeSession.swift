import Foundation
import FSRS

/// Wire rubric IDs are mapped only to the frozen rubric, never inferred from
/// malformed output. Every key must exist, including empty strings for gaps. The wire is flat and string-only.
struct PracticeEvaluationPayload: Codable {
    var coverage: [String: String?]
    var suggestion: String
    var followUp: String?
    var reason: String
    var reference: String
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(coverage: [String: String?], suggestion: String, followUp: String?, reason: String, reference: String) {
        self.coverage = coverage; self.suggestion = suggestion; self.followUp = followUp; self.reason = reason; self.reference = reference
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        suggestion = try values.decode(String.self, forKey: Key("suggestion"))
        let followUpText = try values.decode(String.self, forKey: Key("followUp"))
        followUp = followUpText.isEmpty ? nil : followUpText
        reason = try values.decode(String.self, forKey: Key("reason"))
        reference = try values.decode(String.self, forKey: Key("reference"))
        coverage = [:]
        let fixed = Set(["suggestion", "followUp", "reason", "reference"])
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
        for (id, quote) in coverage { try values.encode(quote ?? "", forKey: Key(id)) }
    }
    static func schema(criteriaCount: Int) -> LocalJSONValue {
        let text: LocalJSONValue = .object(["type": .string("string")])
        let nullable = text // Empty string explicitly represents an unfilled rubric slot.
        let ids = (0..<criteriaCount).map { "r\($0)" }
        var fields = Dictionary(uniqueKeysWithValues: ids.map { ($0, nullable) })
        fields.merge(["suggestion": text, "followUp": nullable, "reason": text, "reference": text]) { _, next in next }
        return .object(["type": .string("object"), "properties": .object(fields), "required": .array((ids + ["suggestion", "followUp", "reason", "reference"]).map(LocalJSONValue.string)), "additionalProperties": .boolean(false)])
    }
    func feedback(task: InterviewTaskDescriptor) throws -> PracticeFeedback {
        guard Set(coverage.keys) == Set(task.criteria.indices.map { "r\($0)" }) else { throw MaterialError.invalid("Evaluation omitted or invented rubric IDs.") }
        var covered: [PracticeFeedback.Coverage] = [], missing: [String] = []
        for (index, criterion) in task.criteria.enumerated() {
            if let outer = coverage["r\(index)"], let quote = outer { covered.append(.init(criterion: criterion, quote: quote)) }
            else { missing.append(criterion) }
        }
        return .init(covered: covered, missing: missing, suggestions: [suggestion], followUp: missing.isEmpty ? nil : followUp, reason: reason, reference: reference)
    }
}

enum PracticePhase: String, Codable {
    case preparing, asking, answering, evaluating, followUp, completed, paused, cancelled, failed
}
struct PracticeFeedback: Codable, Equatable {
    struct Coverage: Codable, Equatable { var criterion: String; var quote: String }
    var covered: [Coverage]
    var missing: [String]
    var suggestions: [String]
    var followUp: String?
    var reason: String
    var reference: String

    func validated(answer: String, task: InterviewTaskDescriptor, evidence: [ProfileEvidence]) throws -> Self {
        guard covered.count <= 12, missing.count <= 12, suggestions.count <= 8,
              covered.allSatisfy({ !$0.quote.isEmpty && answer.contains($0.quote) && task.criteria.contains($0.criterion) }),
              missing.allSatisfy(task.criteria.contains),
              Set(covered.map(\.criterion)).isDisjoint(with: Set(missing)),
              !task.criteria.isEmpty, Set(covered.map(\.criterion) + missing) == Set(task.criteria),
              Set(covered.map(\.criterion) + missing).count == covered.count + missing.count,
              reference.count <= 5000, reason.count <= 2000,
              followUp == nil || (!missing.isEmpty && !(followUp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) else {
            throw MaterialError.invalid("Feedback failed quote/rubric validation. Retry or review your answer manually.")
        }
        // Without personal sources, a model reference is unsafe even in second
        // person. Still evaluate the submitted answer; never treat it as a CV.
        if task.requiresPersonalEvidence && !evidence.contains(where: \.isUsable) {
            var safe = self
            safe.reference = task.language == "zh"
                ? "个人参考答案暂不可生成：请提供并确认相关事实。可继续练习；按评价标准补充真实经历，缺失结果或数字留空。"
                : "A personal reference answer needs confirmed source facts. You can keep practicing: use the rubric to describe a real experience and leave missing results or numbers blank."
            return safe
        }
        let claims = AnswerClaimValidator().validate(answer: reference, candidateEvidence: evidence, opportunityEvidence: [], domainKnowledge: [])
        guard claims.unsupportedClaims.isEmpty else { throw MaterialError.invalid("Reference answer contained unsupported personal claims.") }
        return self
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
}

struct PracticeSQLExecution: Codable {
    var questionID: String
    var revision: Int
    var attachmentRevision: Int
    var contextSnapshotID: String?
    var result: SQLPracticeResult
}
