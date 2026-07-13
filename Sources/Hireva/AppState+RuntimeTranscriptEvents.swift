import Foundation

extension AppState {
    // internal for AppState extension access only
    func recordTranscriptRuntimeEvent(_ event: TranscriptRuntimeEvent) {
        var diagnostics = transcriptRuntimeDiagnostics
        switch event {
        case let .audioStarted(sessionID, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.audioIsRunning = true
            if lastCaptureStartedAt == nil {
                lastCaptureStartedAt = timestamp
            }
        case let .audioBufferReceived(sessionID, frameCount, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.audioIsRunning = true
            diagnostics.lastAudioBufferAt = timestamp
            diagnostics.audioBufferCount += 1
            lastAudioBufferAt = timestamp
            if frameCount > 0 {
                totalSystemAudioASRBuffersAppended = max(totalSystemAudioASRBuffersAppended, diagnostics.audioBufferCount)
            }
        case let .asrPartial(sessionID, text, _, _, _, _, _, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.audioIsRunning = true
            diagnostics.lastASRPartialAt = timestamp
            diagnostics.partialTranscriptCount += 1
            rawTranscriptText = text
            partialTranscriptText = text
            displayTranscriptText = text
            lastSystemAudioASRPartialTranscript = text
            recordLifecycleTrace("transcript.partial", sessionID: sessionID, text: text)
        case let .asrFinal(sessionID, text, _, _, _, _, _, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.audioIsRunning = true
            diagnostics.lastASRFinalAt = timestamp
            diagnostics.finalTranscriptCount += 1
            rawTranscriptText = text
            finalTranscriptText = text
            displayTranscriptText = text
            partialTranscriptText = ""
            lastSystemAudioASRFinalTranscript = text
            recordLifecycleTrace("transcript.final", sessionID: sessionID, text: text)
        case let .utteranceCandidate(sessionID, _, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastQuestionCandidateAt = timestamp
        case let .questionAccepted(sessionID, candidate, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastQuestionAcceptedAt = timestamp
            lastAcceptedQuestionText = candidate.text
        case let .questionRejected(sessionID, _, _, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastQuestionRejectedAt = timestamp
        case let .questionQueued(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .questionDequeued(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .queueDepthChanged(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .queueDrainRequested(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .queueDrainBlocked(sessionID, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .utteranceBufferConsumed(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .utteranceBufferReset(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .generationSkippedBecauseActive(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .generationStarted(sessionID, _, _, _, timestamp):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationStartedAt = timestamp
            diagnostics.lastGenerationRejectedReason = ""
        case let .generationCompleted(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = ""
        case let .generationTimedOut(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = "timed_out"
        case let .generationRejected(sessionID, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason.rawValue
        case let .partialAnswerRejectedIncomplete(sessionID, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .fallbackUsedForIncompleteStream(sessionID, _, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .persistenceStarted(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .persistenceSucceeded(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .persistenceRejected(sessionID, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .duplicatePersistenceRejected(sessionID, _, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .intentionalQuestionRepeatAccepted(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .cumulativeReplayRejected(sessionID, _, _, _, _, _, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .cancelledGenerationPersistenceRejected(sessionID, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .staleGenerationResultRejected(sessionID, _, _, _, _, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .currentCardRegressionRejected(sessionID, _, _, _, _, _, _, _, reason, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = reason
        case let .questionHistoryAppended(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .visibleCurrentSuggestionUpdated(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .queuedAnswerPersisted(sessionID, _, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .uiHistoryRefresh(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
        case let .duplicatePartialSuppressed(sessionID, _, _, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastQuestionRejectedAt = Date()
        case let .answerRejectedWrongProjectGrounding(sessionID, _, _, _, _, _):
            diagnostics.audioSessionID = sessionID
            diagnostics.lastGenerationRejectedReason = QuestionRuntimeRejectionReason.mismatchedAlignment.rawValue
        case let .lifecycle(_, sessionID, _, _, _, _, reason, _, skipped, _):
            diagnostics.audioSessionID = sessionID
            if skipped || !reason.isEmpty {
                diagnostics.lastGenerationRejectedReason = reason
            }
        }
        transcriptRuntimeDiagnostics = diagnostics

        // Audio buffers are represented by aggregate counters above. Keeping or
        // enriching one record per PCM buffer would still burden the main actor.
        if case .audioBufferReceived = event {
            return
        }

        let shouldPersist = shouldPersistRuntimeTranscriptEvent(event)
        let record = shouldPersist ? enrichedRuntimeTranscriptRecord(event.record) : event.record
        recentTranscriptRuntimeEvents.append(record)
        if recentTranscriptRuntimeEvents.count > 40 {
            recentTranscriptRuntimeEvents.removeFirst(recentTranscriptRuntimeEvents.count - 40)
        }
        if shouldPersist {
            appendRuntimeTranscriptTraceLog(record)
        }
    }

    private func shouldPersistRuntimeTranscriptEvent(_ event: TranscriptRuntimeEvent) -> Bool {
        switch event {
        case .audioBufferReceived:
            return false
        case let .asrPartial(sessionID, _, recognitionTaskID, _, _, _, _, timestamp):
            return claimHighFrequencyRuntimeEventKey(
                "asrPartial|\(sessionID)|\(recognitionTaskID ?? "session")",
                timestamp: timestamp
            )
        case let .partialAnswerRejectedIncomplete(sessionID, questionID, generationID, _, _, timestamp):
            return claimHighFrequencyRuntimeEventKey(
                "partialAnswerRejectedIncomplete|\(sessionID)|\(generationID ?? questionID ?? "unknown")",
                timestamp: timestamp
            )
        case let .visibleCurrentSuggestionUpdated(sessionID, questionID, generationID, _, timestamp):
            return claimHighFrequencyRuntimeEventKey(
                "visibleCurrentSuggestionUpdated|\(sessionID)|\(generationID ?? questionID ?? "unknown")",
                timestamp: timestamp
            )
        case let .lifecycle(eventName, sessionID, questionID, generationID, _, _, _, _, _, timestamp)
            where eventName == "transcript.partial" ||
                  eventName == "answer.ui.rendered":
            return claimHighFrequencyRuntimeEventKey(
                "\(eventName)|\(sessionID)|\(generationID ?? questionID ?? "session")",
                timestamp: timestamp
            )
        default:
            return true
        }
    }

    private func claimHighFrequencyRuntimeEventKey(_ key: String, timestamp: Date) -> Bool {
        if let lastPersistedAt = persistedHighFrequencyRuntimeEventAt[key],
           timestamp.timeIntervalSince(lastPersistedAt) < 1.0 {
            return false
        }
        persistedHighFrequencyRuntimeEventAt[key] = timestamp
        return true
    }

    // internal for AppState extension access only
    func recordLifecycleTrace(
        _ eventName: String,
        sessionID: String? = nil,
        questionID: String? = nil,
        generationID: String? = nil,
        text: String = "",
        reason: String = "",
        cancelled: Bool = false,
        skipped: Bool = false
    ) {
        recordTranscriptRuntimeEvent(.lifecycle(
            eventName: eventName,
            sessionID: sessionID ?? currentSession?.id ?? transcriptRuntimeDiagnostics.audioSessionID,
            questionID: questionID,
            generationID: generationID,
            text: text,
            currentState: "\(liveState) | \(generationUIState.displayName)",
            reason: reason,
            cancelled: cancelled,
            skipped: skipped,
            timestamp: Date()
        ))
    }

    // internal for AppState extension access only
    func recordAnswerRequestSkipped(
        reason: String,
        blockedReasonCode: String? = nil,
        sessionID: String? = nil,
        questionID: String? = nil,
        generationID: String? = nil,
        text: String = ""
    ) {
        recordLifecycleTrace(
            "answer.request.skipped",
            sessionID: sessionID,
            questionID: questionID,
            generationID: generationID,
            text: text,
            reason: reason,
            skipped: true
        )
        lastDetectionSkipReason = reason
        lastTranscriptQuestionGenerationTrace.generationTriggered = false
        lastTranscriptQuestionGenerationTrace.generationBlockedReason = blockedReasonCode ?? reason
    }

    // internal for AppState extension access only
    func resetRuntimeTranscriptState(clearEvents: Bool) {
        partialUtteranceFinalizationTasks.values.forEach { $0.cancel() }
        partialUtteranceFinalizationTasks.removeAll()
        rawTranscriptText = ""
        partialTranscriptText = ""
        finalTranscriptText = ""
        displayTranscriptText = ""
        lastAcceptedQuestionText = ""
        transcriptRuntimeDiagnostics = .empty
        if clearEvents {
            recentTranscriptRuntimeEvents = []
            persistedHighFrequencyRuntimeEventAt = [:]
        }
    }

    // internal for AppState extension access only
    func markRuntimeAudioStopped() {
        partialUtteranceFinalizationTasks.values.forEach { $0.cancel() }
        partialUtteranceFinalizationTasks.removeAll()
        var diagnostics = transcriptRuntimeDiagnostics
        diagnostics.audioIsRunning = false
        transcriptRuntimeDiagnostics = diagnostics
    }

    func runtimeTranscriptTraceExportText() -> String {
        recentTranscriptRuntimeEvents.map { $0.jsonLine() }.joined(separator: "\n")
    }

    private func enrichedRuntimeTranscriptRecord(_ input: TranscriptRuntimeEventRecord) -> TranscriptRuntimeEventRecord {
        var record = input
        let sourceText = record.rawText.isEmpty ? record.text : record.rawText
        if !sourceText.isEmpty {
            let canonicalTerms = ASRCanonicalizer.canonicalizeTerms(sourceText)
            if record.canonicalText.isEmpty {
                record.canonicalText = QuestionCanonicalizer.canonicalize(sourceText)
            }
            let splitCandidates = MultiQuestionSplitter.split(canonicalTerms)
                .map { RawQuestionCleaner.clean($0) }
                .filter { !$0.isEmpty }
            if record.splitCandidates.isEmpty {
                record.splitCandidates = splitCandidates
            }
            let acceptedCandidates = QuestionCandidatePipeline.extract(from: sourceText)
            if record.completenessResult.isEmpty {
                if acceptedCandidates.isEmpty {
                    record.completenessResult = QuestionCompletenessGate.isIncompleteFragment(sourceText) ? "incomplete" : "not_accepted"
                } else {
                    record.completenessResult = "accepted:\(acceptedCandidates.count)"
                }
            }
            if let first = acceptedCandidates.first {
                if record.candidateText.isEmpty {
                    record.candidateText = first.text
                }
                if record.questionIntent.isEmpty {
                    record.questionIntent = first.answerRelevanceIntent.rawValue
                }
                if record.intentResult.isEmpty {
                    record.intentResult = first.intent.rawValue
                }
                if record.duplicateKey.isEmpty {
                    record.duplicateKey = first.duplicateKey
                }
            }
        }
        if record.acceptanceStatus.isEmpty {
            record.acceptanceStatus = "observed"
        }
        if record.rejectionReason.isEmpty {
            record.rejectionReason = record.reason
        }
        if record.generationRejectedReason.isEmpty, record.name == "generationRejected" {
            record.generationRejectedReason = record.rejectionReason
        }
        record.uiTranscriptText = displayTranscriptText
        record.visibleQuestionText = currentSuggestion?.questionText ??
            lastDetectedQuestion?.questionText ??
            lastAcceptedQuestionText
        return record
    }

    private func appendRuntimeTranscriptTraceLog(_ record: TranscriptRuntimeEventRecord) {
        RuntimeTranscriptTraceStore.shared.append(
            line: record.jsonLine(),
            to: runtimeTranscriptTraceLogURL
        )
    }
}
