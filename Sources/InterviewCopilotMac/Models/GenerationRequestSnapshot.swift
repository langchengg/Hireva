// Immutable prompt/generation snapshot models.
// These structs capture the question, RAG context, transcript background, and
// generation identity that were valid when generation started.

import Foundation

/// Generation prompt variant being built.
enum AnswerPromptStage: String, Codable, Hashable {
    case firstAnswer
    case fullAnswer
    case sectionStream
    case jsonCard
}

/// Diagnostic estimate of how likely previous transcript could bleed into the
/// current answer prompt.
enum ContextBleedRisk: String, Codable, Hashable {
    case low
    case medium
    case high
}

/// Immutable prompt snapshot for one answer-generation stage.
///
/// `promptPrimaryQuestion` must match `questionTextSnapshot`; previous
/// transcript is diagnostic/background only and must never redefine the answer
/// target.
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

/// Immutable request snapshot for one generation attempt.
///
/// This binds the generation ID, detected question ID, source attribution, and
/// prompt snapshot so late callbacks can be checked against the active request.
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

/// Local fallback answer selected by question intent.
///
/// Fallbacks must be complete speakable answers, not instructions about what to
/// say, because they may become the visible first answer during provider delay.
struct IntentFallbackAnswer: Equatable {
    var sayFirst: String
    var keyPoints: [String]
}
