// Immutable execution context for one generation attempt.
// This model freezes inputs after context retrieval so later transcript updates
// or a newer detected question cannot change the provider prompt.

import Foundation

/// Immutable input snapshot for one suggestion generation attempt.
///
/// This prevents late transcript updates or a newer detected question from
/// changing the prompt after generation has already started. It is data only:
/// no AppState mutation, task ownership, provider streaming, or persistence.
struct GenerationExecutionContext: Equatable {
    let session: InterviewSession
    let question: DetectedQuestion
    let generationID: String
    let triggerPath: GenerationTriggerPath
    let providerID: String
    let providerModel: String
    let retrievedContext: RetrievedContext
    let promptSnapshot: AnswerPromptSnapshot
    let transcriptSnapshot: String
    let startedAt: Date
    let source: AudioSourceType?
    let speaker: SpeakerRole?

    var detectedQuestionID: String { question.id }
    var promptPrimaryQuestion: String { promptSnapshot.promptPrimaryQuestion }
    var identity: GenerationIdentity {
        GenerationIdentity(
            question: question,
            generationID: generationID,
            promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion
        )
    }

    init(
        session: InterviewSession,
        question: DetectedQuestion,
        generationID: String,
        triggerPath: GenerationTriggerPath,
        providerID: String,
        providerModel: String,
        retrievedContext: RetrievedContext,
        promptSnapshot: AnswerPromptSnapshot,
        transcriptSnapshot: String,
        startedAt: Date,
        source: AudioSourceType?,
        speaker: SpeakerRole?
    ) {
        self.session = session
        self.question = question
        self.generationID = generationID
        self.triggerPath = triggerPath
        self.providerID = providerID
        self.providerModel = providerModel
        self.retrievedContext = retrievedContext
        self.promptSnapshot = promptSnapshot
        self.transcriptSnapshot = transcriptSnapshot
        self.startedAt = startedAt
        self.source = source
        self.speaker = speaker
    }

    /// Builds the execution context and prompt snapshot from already-selected
    /// inputs. The resulting prompt primary question must equal the detected
    /// question text.
    static func make(
        session: InterviewSession,
        question: DetectedQuestion,
        generationID: String,
        triggerPath: GenerationTriggerPath,
        provider: LLMProviderConfiguration?,
        retrievedContext: RetrievedContext,
        transcriptSnapshot: String,
        cvSummary: String,
        jdSummary: String,
        startedAt: Date,
        source: AudioSourceType?,
        speaker: SpeakerRole?,
        stage: AnswerPromptStage
    ) -> GenerationExecutionContext {
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: retrievedContext,
            transcriptContext: transcriptSnapshot,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage
        )
        return GenerationExecutionContext(
            session: session,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            providerID: provider?.id.uuidString ?? "unconfigured",
            providerModel: provider?.model ?? "unconfigured",
            retrievedContext: promptSnapshot.ragContextSnapshot,
            promptSnapshot: promptSnapshot,
            transcriptSnapshot: transcriptSnapshot,
            startedAt: startedAt,
            source: source,
            speaker: speaker
        )
    }
}
