import Foundation

/// Coarse provider/question-detection intent used before answer-specific
/// relevance intent is derived.
enum QuestionIntent: String, CaseIterable, Identifiable, Codable {
    case behavioral
    case technical
    case projectDeepDive = "project_deep_dive"
    case coding
    case companyFit = "company_fit"
    case salaryVisa = "salary_visa"
    case smallTalk = "small_talk"
    case instruction
    case unclear

    var id: String { rawValue }

    var displayName: String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// Generation strategy requested by question detection.
enum AnswerStrategy: String, CaseIterable, Identifiable, Codable {
    case directAnswer = "direct_answer"
    case starStory = "star_story"
    case technicalExplanation = "technical_explanation"
    case projectWalkthrough = "project_walkthrough"
    case clarifyFirst = "clarify_first"
    case wait

    var id: String { rawValue }

    var displayName: String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// Accepted or candidate interviewer question extracted from transcript.
///
/// `questionText` should be one clean question, not a merged transcript.
/// Generation and DB alignment rely on this ID/text staying stable.
struct DetectedQuestion: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var transcriptSegmentID: String?
    var questionText: String
    var intent: QuestionIntent
    var answerStrategy: AnswerStrategy
    var confidence: Double
    var reason: String?
    var shouldTrigger: Bool
    var questionComplete: Bool
    var modelName: String
    var promptVersion: String
    var providerKind: LLMProviderKind? = nil
    var providerName: String? = nil
    var providerBaseURL: String? = nil
    var latencyMS: Int? = nil
    var isLocal: Bool = false
    var rawJSON: String?
    var createdAt: Date
    var ingressIdentity: TranscriptQuestionIngressIdentity? = nil
}

/// Immutable identity of the exact transcript occurrence that produced an
/// accepted question. A repeated sentence is intentional only when its source
/// span differs, not merely because time elapsed or a callback ID rotated.
struct TranscriptQuestionIngressIdentity: Hashable, Codable {
    let recognitionTaskID: String
    let recognitionEventSequence: Int
    let sourceSegmentID: String
    let sourceStartUTF16: Int
    let sourceEndUTF16: Int
    let normalizedText: String
    let eventTimestamp: Date
    let isFinal: Bool

    var occurrenceKey: String {
        [recognitionTaskID, String(sourceStartUTF16)].joined(separator: "|")
    }

    var sourceSpanKey: String {
        [recognitionTaskID, normalizedText, String(sourceStartUTF16), String(sourceEndUTF16)].joined(separator: "|")
    }

    var absoluteSourceSpanKey: String {
        [normalizedText, String(sourceStartUTF16), String(sourceEndUTF16)].joined(separator: "|")
    }

    var sourceSpanDescription: String {
        "\(sourceStartUTF16)-\(sourceEndUTF16)"
    }
}

/// Decoded provider response for question detection.
///
/// The payload can classify incomplete questions; downstream gating decides
/// whether it is safe to trigger generation.
struct QuestionDetectionPayload: Decodable {
    var shouldTrigger: Bool
    var questionComplete: Bool
    var questionText: String
    var intent: QuestionIntent
    var answerStrategy: AnswerStrategy
    var confidence: Double
    var reason: String

    enum CodingKeys: String, CodingKey {
        case shouldTrigger = "should_trigger"
        case questionComplete = "question_complete"
        case questionText = "question_text"
        case intent
        case answerStrategy = "answer_strategy"
        case confidence
        case reason
    }
}
