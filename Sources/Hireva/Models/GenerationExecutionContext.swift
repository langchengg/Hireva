// Immutable execution context for one generation attempt.
// This model freezes inputs after context retrieval so later transcript updates
// or a newer detected question cannot change the provider prompt.

import Foundation

enum SnapshotBoundContextPolicy {
    static func retrievedContext(
        snapshot: InterviewContextSnapshot?,
        snapshotContext: RetrievedContext?,
        legacyContext: RetrievedContext
    ) -> RetrievedContext {
        guard snapshot != nil else { return legacyContext }
        return snapshotContext ?? RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
    }

    static func summaries(
        snapshot: InterviewContextSnapshot?,
        liveCVSummary: String,
        liveJDSummary: String
    ) -> (cv: String, jd: String) {
        guard let snapshot else { return (liveCVSummary, liveJDSummary) }
        return (
            ContextBudgeter.limitWords(snapshot.candidateEvidence.map(\.statement).joined(separator: " "), maxWords: 120),
            ContextBudgeter.limitWords(snapshot.opportunityEvidence.map(\.statement).joined(separator: " "), maxWords: 100)
        )
    }
}

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
    let interviewContextSnapshot: InterviewContextSnapshot?

    var detectedQuestionID: String { question.id }
    var contextSnapshotID: String? { interviewContextSnapshot?.id }
    var promptPrimaryQuestion: String { promptSnapshot.promptPrimaryQuestion }
    var identity: GenerationIdentity {
        GenerationIdentity(
            question: question,
            generationID: generationID,
            promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion,
            contextSnapshotID: contextSnapshotID
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
        speaker: SpeakerRole?,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
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
        self.interviewContextSnapshot = interviewContextSnapshot
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
        stage: AnswerPromptStage,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
    ) -> GenerationExecutionContext {
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: retrievedContext,
            transcriptContext: transcriptSnapshot,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: stage,
            interviewContextSnapshot: interviewContextSnapshot
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
            speaker: speaker,
            interviewContextSnapshot: interviewContextSnapshot
        )
    }
}
