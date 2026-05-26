import Foundation

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
}

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
