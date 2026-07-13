import Foundation

enum UtteranceIntent: String, CaseIterable, Codable, Hashable {
    case answerWorthyQuestion
    case smallTalk
    case interviewerStatement
    case candidateStyleAnswer
    case duplicatePartial
    case unknown

    var displayName: String {
        switch self {
        case .answerWorthyQuestion:
            return "answer-worthy question"
        case .smallTalk:
            return "small talk"
        case .interviewerStatement:
            return "interviewer statement"
        case .candidateStyleAnswer:
            return "candidate-style answer"
        case .duplicatePartial:
            return "duplicate partial"
        case .unknown:
            return "unknown"
        }
    }
}

struct UtteranceIntentClassification: Equatable {
    var intent: UtteranceIntent
    var confidence: Double
    var reason: String
}
