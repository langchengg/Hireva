import Foundation

/// Immutable identity for one accepted-question generation attempt.
///
/// Every asynchronous result and side-effect boundary can compare this complete
/// snapshot instead of relying on a generation ID or question string alone.
struct GenerationIdentity: Equatable, Hashable {
    let acceptedQuestionID: String
    let generationID: String
    let sessionID: String
    let questionText: String
    let normalizedQuestionText: String
    let questionIntent: AnswerRelevanceIntent
    let promptPrimaryQuestion: String
    let ingressIdentity: TranscriptQuestionIngressIdentity?

    init(
        acceptedQuestionID: String,
        generationID: String,
        sessionID: String,
        questionText: String,
        normalizedQuestionText: String? = nil,
        questionIntent: AnswerRelevanceIntent? = nil,
        promptPrimaryQuestion: String,
        ingressIdentity: TranscriptQuestionIngressIdentity? = nil
    ) {
        self.acceptedQuestionID = acceptedQuestionID
        self.generationID = generationID
        self.sessionID = sessionID
        self.questionText = questionText
        self.normalizedQuestionText = normalizedQuestionText ?? SemanticDuplicateKeyBuilder.key(for: questionText)
        self.questionIntent = questionIntent ?? AnswerRelevancePolicy.intent(for: questionText)
        self.promptPrimaryQuestion = promptPrimaryQuestion
        self.ingressIdentity = ingressIdentity
    }

    init(question: DetectedQuestion, generationID: String, promptPrimaryQuestion: String? = nil) {
        self.init(
            acceptedQuestionID: question.id,
            generationID: generationID,
            sessionID: question.sessionID,
            questionText: question.questionText,
            questionIntent: AnswerRelevancePolicy.intent(for: question.questionText),
            promptPrimaryQuestion: promptPrimaryQuestion ?? question.questionText,
            ingressIdentity: question.ingressIdentity
        )
    }

    init?(card: SuggestionCard, generationID: String) {
        guard let acceptedQuestionID = card.detectedQuestionID,
              let questionText = card.questionText,
              let promptPrimaryQuestion = card.promptPrimaryQuestion ?? card.promptQuestionText,
              !acceptedQuestionID.isEmpty,
              !questionText.isEmpty,
              !promptPrimaryQuestion.isEmpty else {
            return nil
        }
        self.init(
            acceptedQuestionID: acceptedQuestionID,
            generationID: generationID,
            sessionID: card.sessionID,
            questionText: questionText,
            questionIntent: card.questionIntent ?? AnswerRelevancePolicy.intent(for: questionText),
            promptPrimaryQuestion: promptPrimaryQuestion,
            ingressIdentity: card.ingressIdentity
        )
    }

    func mismatchReason(comparedTo current: GenerationIdentity) -> String? {
        if acceptedQuestionID != current.acceptedQuestionID { return "accepted_question_id_mismatch" }
        if generationID != current.generationID { return "generation_id_mismatch" }
        if sessionID != current.sessionID { return "session_id_mismatch" }
        if normalizedQuestionText != current.normalizedQuestionText { return "normalized_question_text_mismatch" }
        if ingressIdentity != current.ingressIdentity { return "transcript_ingress_identity_mismatch" }
        if questionIntent != current.questionIntent { return "question_intent_mismatch" }
        if SemanticDuplicateKeyBuilder.key(for: promptPrimaryQuestion) != SemanticDuplicateKeyBuilder.key(for: current.promptPrimaryQuestion) {
            return "prompt_primary_question_mismatch"
        }
        if SemanticDuplicateKeyBuilder.key(for: questionText) != SemanticDuplicateKeyBuilder.key(for: current.questionText) {
            return "question_text_mismatch"
        }
        return nil
    }
}

/// Immutable render snapshot. Question, answer, selection identity, and status
/// are captured together so SwiftUI never composes one visible card from
/// unrelated mutable fields.
struct VisibleSuggestionState: Equatable {
    let identity: GenerationIdentity
    let questionText: String
    let answerText: String
    let status: String
    let generationErrorText: String?
    let card: SuggestionCard?
}

/// View-facing answer state consumed by the floating panel and Home preview.
///
/// `answerText` is intentionally reserved for valid answer content. Terminal
/// generation failures are exposed through `generationErrorText` so they are not
/// copied into answer history, exports, follow-up context, or analytics.
struct VisibleAssistantRenderState: Equatable {
    let questionText: String
    let answerText: String
    let keyPoints: [String]
    let generationStatus: String
    let generationErrorText: String?
    let isGenerating: Bool
    let hasAnswerText: Bool
    let activeGenerationID: String?
    let activeQuestionID: String?
}
