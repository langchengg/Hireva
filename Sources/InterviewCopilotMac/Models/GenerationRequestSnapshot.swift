import Foundation

enum AnswerPromptStage: String, Codable, Hashable {
    case firstAnswer
    case fullAnswer
    case sectionStream
    case jsonCard
}

enum ContextBleedRisk: String, Codable, Hashable {
    case low
    case medium
    case high
}

struct AnswerPromptSnapshot: Equatable {
    var detectedQuestionID: String?
    var questionTextSnapshot: String
    var normalizedQuestionText: String
    var questionIntent: AnswerRelevanceIntent
    var transcriptSegmentID: String?
    var ragContextSnapshot: RetrievedContext
    var ragChunkPreviews: [String]
    var ragChunkIDs: [String]
    var ragChunkIntents: [AnswerRelevanceIntent]
    var prompt: String
    var promptPrimaryQuestion: String
    var promptContainsPreviousQuestion: Bool
    var previousQuestionIncluded: Bool
    var previousQuestionText: String?
    var contextBleedRisk: ContextBleedRisk
    var promptTokenEstimate: Int
}

struct GenerationRequestSnapshot: Equatable {
    var detectedQuestionID: String
    var generationID: String
    var transcriptSegmentID: String?
    var questionText: String
    var normalizedQuestionText: String
    var questionIntent: AnswerRelevanceIntent
    var source: AudioSourceType?
    var speaker: SpeakerRole?
    var triggerPath: GenerationTriggerPath
    var acceptedAt: Date
    var ragContextSnapshot: RetrievedContext
    var promptSnapshot: AnswerPromptSnapshot

    var promptPrimaryQuestion: String { promptSnapshot.promptPrimaryQuestion }
    var promptContainsPreviousQuestion: Bool { promptSnapshot.promptContainsPreviousQuestion }
    var previousQuestionIncluded: Bool { promptSnapshot.previousQuestionIncluded }
    var previousQuestionText: String? { promptSnapshot.previousQuestionText }
    var contextBleedRisk: ContextBleedRisk { promptSnapshot.contextBleedRisk }
    var ragChunkIDs: [String] { promptSnapshot.ragChunkIDs }
    var ragChunkIntents: [AnswerRelevanceIntent] { promptSnapshot.ragChunkIntents }
}

struct IntentFallbackAnswer: Equatable {
    var sayFirst: String
    var keyPoints: [String]
}
