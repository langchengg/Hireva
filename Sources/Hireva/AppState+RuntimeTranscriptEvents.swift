import Foundation

extension AppState {
    // Live owns business transcript and capture facts. Diagnostics receives
    // the event plus immutable display snapshots and owns its own trace state.
    func recordTranscriptRuntimeEvent(_ event: TranscriptRuntimeEvent) {
        switch event {
        case let .audioStarted(_, timestamp):
            if lastCaptureStartedAt == nil { lastCaptureStartedAt = timestamp }
        case let .audioBufferReceived(_, _, timestamp, _, _):
            lastAudioBufferAt = timestamp
        case let .asrPartial(sessionID, text, _, _, _, _, _, _):
            rawTranscriptText = text
            partialTranscriptText = text
            displayTranscriptText = text
            lastSystemAudioASRPartialTranscript = text
            recordLifecycleTrace("transcript.partial", sessionID: sessionID, text: text)
        case let .asrFinal(sessionID, text, _, _, _, _, _, _):
            rawTranscriptText = text
            finalTranscriptText = text
            displayTranscriptText = text
            partialTranscriptText = ""
            lastSystemAudioASRFinalTranscript = text
            recordLifecycleTrace("transcript.final", sessionID: sessionID, text: text)
        case let .questionAccepted(_, candidate, _):
            lastAcceptedQuestionText = candidate.text
        default:
            break
        }
        diagnosticsState.record(event, context: .init(
            transcriptText: displayTranscriptText,
            visibleQuestionText: currentSuggestion?.questionText ?? lastDetectedQuestion?.questionText ?? lastAcceptedQuestionText
        ), mode: settings.effectiveDiagnosticTraceMode)
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
        liveInterview.cancelPartialUtteranceFinalizations()
        liveInterview.resetTranscriptDisplay()
        diagnosticsState.reset(clearEvents: clearEvents)
    }

    // internal for AppState extension access only
    func markRuntimeAudioStopped() {
        liveInterview.cancelPartialUtteranceFinalizations()
        diagnosticsState.markAudioStopped()
    }

    func runtimeTranscriptTraceExportText() -> String {
        diagnosticsState.exportText(mode: settings.effectiveDiagnosticTraceMode)
    }

    func clearRuntimeTranscriptTrace() throws {
        try diagnosticsState.clearTrace()
    }
}
