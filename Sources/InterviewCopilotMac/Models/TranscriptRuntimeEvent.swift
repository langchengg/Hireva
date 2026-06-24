import Foundation

/// Runtime events for the live audio -> transcript -> question -> answer chain.
///
/// This model is intentionally diagnostic-only. It carries no provider secrets
/// and does not own UI mutation, detection, generation, or persistence.
enum TranscriptRuntimeEvent: Equatable {
    case audioStarted(sessionID: String, timestamp: Date)
    case audioBufferReceived(sessionID: String, frameCount: Int, timestamp: Date)
    case asrPartial(sessionID: String, text: String, recognitionTaskID: String?, eventSequence: Int?, sourceStartUTF16: Int?, sourceEndUTF16: Int?, isFinal: Bool, timestamp: Date)
    case asrFinal(sessionID: String, text: String, recognitionTaskID: String?, eventSequence: Int?, sourceStartUTF16: Int?, sourceEndUTF16: Int?, isFinal: Bool, timestamp: Date)
    case utteranceCandidate(sessionID: String, text: String, timestamp: Date)
    case questionAccepted(sessionID: String, candidate: AcceptedQuestionCandidate, timestamp: Date)
    case questionRejected(sessionID: String, text: String, reason: QuestionRuntimeRejectionReason, timestamp: Date)
    case questionQueued(sessionID: String, questionID: String, question: String, duplicateKey: String, timestamp: Date)
    case questionDequeued(sessionID: String, questionID: String, question: String, duplicateKey: String, timestamp: Date)
    case queueDepthChanged(sessionID: String, depth: Int, reason: String, timestamp: Date)
    case queueDrainRequested(sessionID: String, depth: Int, reason: String, timestamp: Date)
    case queueDrainBlocked(sessionID: String, depth: Int, reason: String, timestamp: Date)
    case utteranceBufferConsumed(sessionID: String, questionID: String?, question: String, timestamp: Date)
    case utteranceBufferReset(sessionID: String, questionID: String?, question: String, timestamp: Date)
    case generationSkippedBecauseActive(sessionID: String, questionID: String, generationID: String?, question: String, timestamp: Date)
    case generationStarted(sessionID: String, questionID: String, generationID: String, question: String, timestamp: Date)
    case generationCompleted(sessionID: String, questionID: String?, generationID: String, question: String, timestamp: Date)
    case generationTimedOut(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case generationRejected(sessionID: String, question: String, reason: QuestionRuntimeRejectionReason, timestamp: Date)
    case partialAnswerRejectedIncomplete(sessionID: String, questionID: String?, generationID: String?, question: String, reason: String, timestamp: Date)
    case fallbackUsedForIncompleteStream(sessionID: String, questionID: String?, generationID: String?, question: String, reason: String, timestamp: Date)
    case persistenceStarted(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case persistenceSucceeded(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case persistenceRejected(sessionID: String, questionID: String?, generationID: String?, question: String, reason: String, timestamp: Date)
    case duplicatePersistenceRejected(sessionID: String, questionID: String?, generationID: String?, question: String, normalizedQuestion: String, reason: String, timestamp: Date)
    case intentionalQuestionRepeatAccepted(sessionID: String, questionID: String, question: String, occurrenceKey: String, timestamp: Date)
    case cumulativeReplayRejected(sessionID: String, questionID: String?, question: String, normalizedQuestion: String, oldRecognitionEpoch: String, newRecognitionEpoch: String, oldSourceSpan: String, newSourceSpan: String, overlapScore: Double, reason: String, timestamp: Date)
    case cancelledGenerationPersistenceRejected(sessionID: String, questionID: String?, generationID: String?, question: String, reason: String, timestamp: Date)
    case staleGenerationResultRejected(sessionID: String, oldGenerationID: String?, currentGenerationID: String?, oldAcceptedQuestionID: String?, currentAcceptedQuestionID: String?, oldQuestionText: String, currentQuestionText: String, sourceCallback: String, reason: String, timestamp: Date)
    case currentCardRegressionRejected(sessionID: String, oldGenerationID: String?, currentGenerationID: String?, oldAcceptedQuestionID: String?, currentAcceptedQuestionID: String?, oldQuestionText: String, currentQuestionText: String, sourceCallback: String, reason: String, timestamp: Date)
    case questionHistoryAppended(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case visibleCurrentSuggestionUpdated(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case queuedAnswerPersisted(sessionID: String, questionID: String?, generationID: String?, question: String, timestamp: Date)
    case uiHistoryRefresh(sessionID: String, question: String, count: Int, timestamp: Date)
    case duplicatePartialSuppressed(sessionID: String, question: String, reason: QuestionRuntimeRejectionReason, timestamp: Date)
    case answerRejectedWrongProjectGrounding(sessionID: String, questionID: String?, generationID: String?, question: String, reason: String, timestamp: Date)
    case lifecycle(eventName: String, sessionID: String, questionID: String?, generationID: String?, text: String, currentState: String, reason: String, cancelled: Bool, skipped: Bool, timestamp: Date)

    var record: TranscriptRuntimeEventRecord {
        switch self {
        case let .audioStarted(sessionID, timestamp):
            return TranscriptRuntimeEventRecord(timestamp: timestamp, name: "audioStarted", sessionID: sessionID)
        case let .audioBufferReceived(sessionID, frameCount, timestamp):
            return TranscriptRuntimeEventRecord(timestamp: timestamp, name: "audioBufferReceived", sessionID: sessionID, frameCount: frameCount)
        case let .asrPartial(sessionID, text, recognitionTaskID, eventSequence, sourceStartUTF16, sourceEndUTF16, isFinal, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "asrPartial",
                sessionID: sessionID,
                text: text,
                recognitionTaskID: recognitionTaskID ?? "",
                recognitionEventSequence: eventSequence ?? 0,
                sourceTextStartUTF16: sourceStartUTF16 ?? 0,
                sourceTextEndUTF16: sourceEndUTF16 ?? 0,
                recognitionIsFinal: isFinal
            )
        case let .asrFinal(sessionID, text, recognitionTaskID, eventSequence, sourceStartUTF16, sourceEndUTF16, isFinal, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "asrFinal",
                sessionID: sessionID,
                text: text,
                recognitionTaskID: recognitionTaskID ?? "",
                recognitionEventSequence: eventSequence ?? 0,
                sourceTextStartUTF16: sourceStartUTF16 ?? 0,
                sourceTextEndUTF16: sourceEndUTF16 ?? 0,
                recognitionIsFinal: isFinal
            )
        case let .utteranceCandidate(sessionID, text, timestamp):
            return TranscriptRuntimeEventRecord(timestamp: timestamp, name: "utteranceCandidate", sessionID: sessionID, text: text)
        case let .questionAccepted(sessionID, candidate, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "questionAccepted",
                sessionID: sessionID,
                text: candidate.text,
                canonicalText: QuestionCanonicalizer.canonicalize(candidate.text),
                candidateText: candidate.text,
                questionIntent: candidate.answerRelevanceIntent.rawValue,
                duplicateKey: candidate.duplicateKey,
                acceptanceStatus: "accepted",
                completenessResult: "complete",
                intentResult: candidate.intent.rawValue
            )
        case let .questionRejected(sessionID, text, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "questionRejected",
                sessionID: sessionID,
                text: text,
                reason: reason.rawValue,
                canonicalText: QuestionCanonicalizer.canonicalize(text),
                candidateText: text,
                acceptanceStatus: "rejected",
                rejectionReason: reason.rawValue,
                completenessResult: "rejected"
            )
        case let .questionQueued(sessionID, questionID, question, duplicateKey, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "questionQueued",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                duplicateKey: duplicateKey,
                acceptanceStatus: "queued"
            )
        case let .questionDequeued(sessionID, questionID, question, duplicateKey, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "questionDequeued",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                duplicateKey: duplicateKey,
                acceptanceStatus: "dequeued"
            )
        case let .queueDepthChanged(sessionID, depth, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "queueDepthChanged",
                sessionID: sessionID,
                text: "depth=\(depth)",
                reason: reason,
                acceptanceStatus: "queue_depth_changed:\(depth)"
            )
        case let .queueDrainRequested(sessionID, depth, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "queueDrainRequested",
                sessionID: sessionID,
                text: "depth=\(depth)",
                reason: reason,
                acceptanceStatus: "queue_drain_requested"
            )
        case let .queueDrainBlocked(sessionID, depth, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "queueDrainBlocked",
                sessionID: sessionID,
                text: "depth=\(depth)",
                reason: reason,
                acceptanceStatus: "queue_drain_blocked",
                rejectionReason: reason
            )
        case let .utteranceBufferConsumed(sessionID, questionID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "utteranceBufferConsumed",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "utterance_consumed"
            )
        case let .utteranceBufferReset(sessionID, questionID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "utteranceBufferReset",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "utterance_reset"
            )
        case let .generationSkippedBecauseActive(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "generationSkippedBecauseActive",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "generation_active_queued"
            )
        case let .generationStarted(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "generationStarted",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "generation_started",
                generationStarted: true
            )
        case let .generationCompleted(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "generationCompleted",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "generation_completed"
            )
        case let .generationTimedOut(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "generationTimedOut",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "generation_timed_out"
            )
        case let .generationRejected(sessionID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "generationRejected",
                sessionID: sessionID,
                text: question,
                reason: reason.rawValue,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "generation_rejected",
                rejectionReason: reason.rawValue,
                generationRejectedReason: reason.rawValue
            )
        case let .partialAnswerRejectedIncomplete(sessionID, questionID, generationID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "partialAnswerRejectedIncomplete",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "partial_answer_rejected",
                rejectionReason: QuestionRuntimeRejectionReason.incompleteAnswer.rawValue
            )
        case let .fallbackUsedForIncompleteStream(sessionID, questionID, generationID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "fallbackUsedForIncompleteStream",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "fallback_used_for_incomplete_stream"
            )
        case let .persistenceStarted(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "persistenceStarted",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "persistence_started",
                persistenceStarted: true
            )
        case let .persistenceSucceeded(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "persistenceSucceeded",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "persistence_succeeded",
                persistenceStarted: true
            )
        case let .persistenceRejected(sessionID, questionID, generationID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "persistenceRejected",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                acceptanceStatus: "persistence_rejected",
                rejectionReason: reason
            )
        case let .duplicatePersistenceRejected(sessionID, questionID, generationID, question, normalizedQuestion, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "duplicatePersistenceRejected",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: normalizedQuestion,
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: question),
                acceptanceStatus: "duplicate_persistence_rejected",
                rejectionReason: reason
            )
        case let .intentionalQuestionRepeatAccepted(sessionID, questionID, question, occurrenceKey, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "intentionalQuestionRepeatAccepted",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                reason: occurrenceKey,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: question),
                acceptanceStatus: "intentional_repeat_accepted"
            )
        case let .cumulativeReplayRejected(sessionID, questionID, question, normalizedQuestion, oldRecognitionEpoch, newRecognitionEpoch, oldSourceSpan, newSourceSpan, overlapScore, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "cumulativeReplayRejected",
                sessionID: sessionID,
                questionID: questionID,
                text: question,
                reason: reason,
                canonicalText: normalizedQuestion,
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: question),
                acceptanceStatus: "cumulative_replay_rejected",
                rejectionReason: reason,
                oldRecognitionTaskID: oldRecognitionEpoch,
                newRecognitionTaskID: newRecognitionEpoch,
                oldSourceSpan: oldSourceSpan,
                newSourceSpan: newSourceSpan,
                overlapScore: overlapScore
            )
        case let .cancelledGenerationPersistenceRejected(sessionID, questionID, generationID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "cancelledGenerationPersistenceRejected",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: question),
                acceptanceStatus: "cancelled_persistence_rejected",
                rejectionReason: reason
            )
        case let .staleGenerationResultRejected(sessionID, oldGenerationID, currentGenerationID, oldAcceptedQuestionID, currentAcceptedQuestionID, oldQuestionText, currentQuestionText, sourceCallback, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "staleGenerationResultRejected",
                sessionID: sessionID,
                generationID: oldGenerationID,
                text: oldQuestionText,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(oldQuestionText),
                candidateText: oldQuestionText,
                questionIntent: IntentRouter.answerIntent(for: oldQuestionText).rawValue,
                acceptanceStatus: "stale_generation_result_rejected",
                rejectionReason: reason,
                oldGenerationID: oldGenerationID ?? "",
                currentGenerationID: currentGenerationID ?? "",
                oldQuestionText: oldQuestionText,
                currentQuestionText: currentQuestionText,
                oldAcceptedQuestionID: oldAcceptedQuestionID ?? "",
                currentAcceptedQuestionID: currentAcceptedQuestionID ?? "",
                sourceCallback: sourceCallback
            )
        case let .currentCardRegressionRejected(sessionID, oldGenerationID, currentGenerationID, oldAcceptedQuestionID, currentAcceptedQuestionID, oldQuestionText, currentQuestionText, sourceCallback, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "currentCardRegressionRejected",
                sessionID: sessionID,
                generationID: oldGenerationID,
                text: oldQuestionText,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(oldQuestionText),
                candidateText: oldQuestionText,
                questionIntent: IntentRouter.answerIntent(for: oldQuestionText).rawValue,
                acceptanceStatus: "current_card_regression_rejected",
                rejectionReason: reason,
                oldGenerationID: oldGenerationID ?? "",
                currentGenerationID: currentGenerationID ?? "",
                oldQuestionText: oldQuestionText,
                currentQuestionText: currentQuestionText,
                oldAcceptedQuestionID: oldAcceptedQuestionID ?? "",
                currentAcceptedQuestionID: currentAcceptedQuestionID ?? "",
                sourceCallback: sourceCallback
            )
        case let .questionHistoryAppended(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "questionHistoryAppended",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                acceptanceStatus: "history_appended"
            )
        case let .visibleCurrentSuggestionUpdated(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "visibleCurrentSuggestionUpdated",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                acceptanceStatus: "visible_current_updated"
            )
        case let .queuedAnswerPersisted(sessionID, questionID, generationID, question, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "queuedAnswerPersisted",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                acceptanceStatus: "queued_answer_persisted",
                persistenceStarted: true
            )
        case let .uiHistoryRefresh(sessionID, question, count, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "uiHistoryRefresh",
                sessionID: sessionID,
                text: question,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                acceptanceStatus: "ui_history_refresh:\(count)"
            )
        case let .duplicatePartialSuppressed(sessionID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "duplicatePartialSuppressed",
                sessionID: sessionID,
                text: question,
                reason: reason.rawValue,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: question),
                acceptanceStatus: "duplicate_partial_suppressed",
                rejectionReason: reason.rawValue
            )
        case let .answerRejectedWrongProjectGrounding(sessionID, questionID, generationID, question, reason, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: "answerRejectedWrongProjectGrounding",
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: question,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(question),
                candidateText: question,
                questionIntent: IntentRouter.answerIntent(for: question).rawValue,
                acceptanceStatus: "answer_rejected_wrong_project_grounding",
                rejectionReason: QuestionRuntimeRejectionReason.mismatchedAlignment.rawValue
            )
        case let .lifecycle(eventName, sessionID, questionID, generationID, text, currentState, reason, cancelled, skipped, timestamp):
            return TranscriptRuntimeEventRecord(
                timestamp: timestamp,
                name: eventName,
                sessionID: sessionID,
                questionID: questionID,
                generationID: generationID,
                text: text,
                reason: reason,
                canonicalText: QuestionCanonicalizer.canonicalize(text),
                candidateText: text,
                acceptanceStatus: skipped ? "skipped" : "observed",
                rejectionReason: skipped ? reason : "",
                currentState: currentState,
                cancelled: cancelled,
                skipped: skipped
            )
        }
    }
}

struct TranscriptRuntimeEventRecord: Identifiable, Equatable {
    let id: String
    var timestamp: Date
    var name: String
    var sessionID: String
    var questionID: String?
    var text: String
    var reason: String
    var frameCount: Int?
    var rawText: String
    var canonicalText: String
    var candidateText: String
    var questionIntent: String
    var duplicateKey: String
    var acceptanceStatus: String
    var rejectionReason: String
    var generationRejectedReason: String
    var generationID: String?
    var generationStarted: Bool
    var persistenceStarted: Bool
    var uiTranscriptText: String
    var visibleQuestionText: String
    var splitCandidates: [String]
    var completenessResult: String
    var intentResult: String
    var oldGenerationID: String
    var currentGenerationID: String
    var oldQuestionText: String
    var currentQuestionText: String
    var oldAcceptedQuestionID: String
    var currentAcceptedQuestionID: String
    var sourceCallback: String
    var recognitionTaskID: String
    var recognitionEventSequence: Int
    var sourceTextStartUTF16: Int
    var sourceTextEndUTF16: Int
    var recognitionIsFinal: Bool
    var oldRecognitionTaskID: String
    var newRecognitionTaskID: String
    var oldSourceSpan: String
    var newSourceSpan: String
    var overlapScore: Double
    var currentState: String
    var cancelled: Bool
    var skipped: Bool

    init(
        timestamp: Date,
        name: String,
        sessionID: String,
        questionID: String? = nil,
        generationID: String? = nil,
        text: String = "",
        reason: String = "",
        frameCount: Int? = nil,
        rawText: String = "",
        canonicalText: String = "",
        candidateText: String = "",
        questionIntent: String = "",
        duplicateKey: String = "",
        acceptanceStatus: String = "",
        rejectionReason: String = "",
        generationRejectedReason: String = "",
        generationStarted: Bool = false,
        persistenceStarted: Bool = false,
        uiTranscriptText: String = "",
        visibleQuestionText: String = "",
        splitCandidates: [String] = [],
        completenessResult: String = "",
        intentResult: String = "",
        oldGenerationID: String = "",
        currentGenerationID: String = "",
        oldQuestionText: String = "",
        currentQuestionText: String = "",
        oldAcceptedQuestionID: String = "",
        currentAcceptedQuestionID: String = "",
        sourceCallback: String = "",
        recognitionTaskID: String = "",
        recognitionEventSequence: Int = 0,
        sourceTextStartUTF16: Int = 0,
        sourceTextEndUTF16: Int = 0,
        recognitionIsFinal: Bool = false,
        oldRecognitionTaskID: String = "",
        newRecognitionTaskID: String = "",
        oldSourceSpan: String = "",
        newSourceSpan: String = "",
        overlapScore: Double = 0,
        currentState: String = "",
        cancelled: Bool = false,
        skipped: Bool = false
    ) {
        self.id = UUID().uuidString
        self.timestamp = timestamp
        self.name = name
        self.sessionID = sessionID
        self.questionID = questionID
        self.generationID = generationID
        self.text = text
        self.reason = reason
        self.frameCount = frameCount
        self.rawText = rawText.isEmpty ? text : rawText
        self.canonicalText = canonicalText
        self.candidateText = candidateText
        self.questionIntent = questionIntent
        self.duplicateKey = duplicateKey
        self.acceptanceStatus = acceptanceStatus
        self.rejectionReason = rejectionReason
        self.generationRejectedReason = generationRejectedReason
        self.generationStarted = generationStarted
        self.persistenceStarted = persistenceStarted
        self.uiTranscriptText = uiTranscriptText
        self.visibleQuestionText = visibleQuestionText
        self.splitCandidates = splitCandidates
        self.completenessResult = completenessResult
        self.intentResult = intentResult
        self.oldGenerationID = oldGenerationID
        self.currentGenerationID = currentGenerationID
        self.oldQuestionText = oldQuestionText
        self.currentQuestionText = currentQuestionText
        self.oldAcceptedQuestionID = oldAcceptedQuestionID
        self.currentAcceptedQuestionID = currentAcceptedQuestionID
        self.sourceCallback = sourceCallback
        self.recognitionTaskID = recognitionTaskID
        self.recognitionEventSequence = recognitionEventSequence
        self.sourceTextStartUTF16 = sourceTextStartUTF16
        self.sourceTextEndUTF16 = sourceTextEndUTF16
        self.recognitionIsFinal = recognitionIsFinal
        self.oldRecognitionTaskID = oldRecognitionTaskID
        self.newRecognitionTaskID = newRecognitionTaskID
        self.oldSourceSpan = oldSourceSpan
        self.newSourceSpan = newSourceSpan
        self.overlapScore = overlapScore
        self.currentState = currentState
        self.cancelled = cancelled
        self.skipped = skipped
    }

    func jsonLine() -> String {
        let payload = RuntimeTranscriptTracePayload(
            timestamp: ISO8601DateFormatter().string(from: timestamp),
            sessionID: sessionID,
            eventType: name,
            rawText: rawText,
            canonicalText: canonicalText,
            candidateText: candidateText,
            splitCandidates: splitCandidates,
            completenessResult: completenessResult,
            questionIntent: questionIntent,
            intentResult: intentResult,
            duplicateKey: duplicateKey,
            acceptanceStatus: acceptanceStatus,
            rejectionReason: rejectionReason,
            generationRejectedReason: generationRejectedReason,
            generationID: generationID ?? "",
            questionID: questionID ?? "",
            generationStarted: generationStarted,
            persistenceStarted: persistenceStarted,
            uiTranscriptText: uiTranscriptText,
            visibleQuestionText: visibleQuestionText,
            oldGenerationID: oldGenerationID,
            currentGenerationID: currentGenerationID,
            oldQuestionText: oldQuestionText,
            currentQuestionText: currentQuestionText,
            oldAcceptedQuestionID: oldAcceptedQuestionID,
            currentAcceptedQuestionID: currentAcceptedQuestionID,
            sourceCallback: sourceCallback,
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: recognitionEventSequence,
            sourceTextStartUTF16: sourceTextStartUTF16,
            sourceTextEndUTF16: sourceTextEndUTF16,
            recognitionIsFinal: recognitionIsFinal,
            oldRecognitionTaskID: oldRecognitionTaskID,
            newRecognitionTaskID: newRecognitionTaskID,
            oldSourceSpan: oldSourceSpan,
            newSourceSpan: newSourceSpan,
            overlapScore: overlapScore,
            currentState: currentState,
            cancelled: cancelled,
            skipped: skipped
        )
        guard let data = try? JSONEncoder().encode(payload),
              let line = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return line
    }
}

private struct RuntimeTranscriptTracePayload: Encodable {
    var timestamp: String
    var sessionID: String
    var eventType: String
    var rawText: String
    var canonicalText: String
    var candidateText: String
    var splitCandidates: [String]
    var completenessResult: String
    var questionIntent: String
    var intentResult: String
    var duplicateKey: String
    var acceptanceStatus: String
    var rejectionReason: String
    var generationRejectedReason: String
    var generationID: String
    var questionID: String
    var generationStarted: Bool
    var persistenceStarted: Bool
    var uiTranscriptText: String
    var visibleQuestionText: String
    var oldGenerationID: String
    var currentGenerationID: String
    var oldQuestionText: String
    var currentQuestionText: String
    var oldAcceptedQuestionID: String
    var currentAcceptedQuestionID: String
    var sourceCallback: String
    var recognitionTaskID: String
    var recognitionEventSequence: Int
    var sourceTextStartUTF16: Int
    var sourceTextEndUTF16: Int
    var recognitionIsFinal: Bool
    var oldRecognitionTaskID: String
    var newRecognitionTaskID: String
    var oldSourceSpan: String
    var newSourceSpan: String
    var overlapScore: Double
    var currentState: String
    var cancelled: Bool
    var skipped: Bool

    enum CodingKeys: String, CodingKey {
        case timestamp
        case sessionID = "session_id"
        case eventType = "event_type"
        case rawText = "raw_text"
        case canonicalText = "canonical_text"
        case candidateText = "candidate_text"
        case splitCandidates = "split_candidates"
        case completenessResult = "completeness_result"
        case questionIntent = "question_intent"
        case intentResult = "intent_result"
        case duplicateKey = "duplicate_key"
        case acceptanceStatus = "acceptance_status"
        case rejectionReason = "rejection_reason"
        case generationRejectedReason = "generation_rejected_reason"
        case generationID = "generation_id"
        case questionID = "question_id"
        case generationStarted = "generation_started"
        case persistenceStarted = "persistence_started"
        case uiTranscriptText = "ui_transcript_text"
        case visibleQuestionText = "visible_question_text"
        case oldGenerationID = "old_generation_id"
        case currentGenerationID = "current_generation_id"
        case oldQuestionText = "old_question_text"
        case currentQuestionText = "current_question_text"
        case oldAcceptedQuestionID = "old_accepted_question_id"
        case currentAcceptedQuestionID = "current_accepted_question_id"
        case sourceCallback = "source_callback"
        case recognitionTaskID = "recognition_task_id"
        case recognitionEventSequence = "recognition_event_sequence"
        case sourceTextStartUTF16 = "source_text_start_utf16"
        case sourceTextEndUTF16 = "source_text_end_utf16"
        case recognitionIsFinal = "recognition_is_final"
        case oldRecognitionTaskID = "old_recognition_task_id"
        case newRecognitionTaskID = "new_recognition_task_id"
        case oldSourceSpan = "old_source_span"
        case newSourceSpan = "new_source_span"
        case overlapScore = "overlap_score"
        case currentState = "current_state"
        case cancelled
        case skipped
    }
}

struct TranscriptRuntimeDiagnostics: Equatable {
    var audioSessionID: String = ""
    var audioIsRunning: Bool = false
    var lastAudioBufferAt: Date?
    var audioBufferCount: Int = 0
    var lastASRPartialAt: Date?
    var lastASRFinalAt: Date?
    var partialTranscriptCount: Int = 0
    var finalTranscriptCount: Int = 0
    var lastQuestionCandidateAt: Date?
    var lastQuestionAcceptedAt: Date?
    var lastQuestionRejectedAt: Date?
    var lastGenerationStartedAt: Date?
    var lastGenerationRejectedReason: String = ""

    static let empty = TranscriptRuntimeDiagnostics()

    func chainStatus(now: Date = Date(), callbackTimeout: TimeInterval = 1.5) -> String {
        guard audioIsRunning else { return "capture stopped" }
        guard let lastAudioBufferAt else { return "waiting for audio buffer" }

        let latestASR = [lastASRPartialAt, lastASRFinalAt]
            .compactMap { $0 }
            .max()
        if latestASR == nil && now.timeIntervalSince(lastAudioBufferAt) >= callbackTimeout {
            return "ASR callback missing after audio buffer"
        }
        if let latestASR, latestASR < lastAudioBufferAt, now.timeIntervalSince(lastAudioBufferAt) >= callbackTimeout {
            return "ASR callback stale after latest audio buffer"
        }
        if let lastQuestionRejectedAt,
           lastQuestionAcceptedAt == nil || lastQuestionRejectedAt > (lastQuestionAcceptedAt ?? .distantPast) {
            return "candidate rejected"
        }
        if !lastGenerationRejectedReason.isEmpty {
            return "generation guard rejected"
        }
        return "runtime chain active"
    }
}
