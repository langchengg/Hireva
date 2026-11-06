// Ingests transcript segments from live ASR and routes them toward persistence,
// attribution diagnostics, question detection, and RAG precompute.
// This extension decides whether a segment is eligible for detection; it must
// not generate answers directly except by handing accepted questions to the
// question-detection/generation extensions.

import Foundation
import Combine
import SwiftUI
import AppKit

extension AppState {
    // MARK: - Segment Ingestion

    func consumeSegments(from provider: TranscriptionProvider) {
        // The provider may replace its stream on restart. Freeze this exact
        // stream and parent before task creation rather than looking them up
        // later on the consumer's first execution.
        let stream = provider.segments
        let speech = provider as? AppleSpeechTranscriptionService
        let outputIdentity = speech?.currentTranscriptOutputIdentity
        let terminalError = speech?.captureTerminalErrorReader()
        let sessionID = currentSession?.id
        captureLifecycle.consume { [weak self] consumerID in
            for await segment in stream {
                guard let self,
                      self.captureLifecycle.isConsumerCurrent(consumerID),
                      self.activeTranscriptionProvider === provider,
                      self.currentSession?.id == sessionID,
                      (speech == nil || speech?.currentTranscriptOutputIdentity == outputIdentity),
                      segment.sessionID == sessionID else { return }
                await self.handleTranscriptSegment(segment)
                guard self.captureLifecycle.isConsumerCurrent(consumerID),
                      self.activeTranscriptionProvider === provider,
                      self.currentSession?.id == sessionID,
                      (speech == nil || speech?.currentTranscriptOutputIdentity == outputIdentity) else { return }
            }
            guard let self, !self.isShuttingDown,
                  self.captureLifecycle.isConsumerCurrent(consumerID),
                  self.activeTranscriptionProvider === provider,
                  self.currentSession?.id == sessionID,
                  speech?.currentTranscriptOutputIdentity == outputIdentity,
                  let error = terminalError?() else { return }
            self.failAction(ActionID.startInterview, title: "Transcription failed", message: error.localizedDescription)
            // Nonblocking feedback can synchronously replace the current Live
            // capture. The old terminal then loses authority to stop that round.
            guard !self.isShuttingDown,
                  self.captureLifecycle.isConsumerCurrent(consumerID),
                  self.activeTranscriptionProvider === provider,
                  self.currentSession?.id == sessionID,
                  speech?.currentTranscriptOutputIdentity == outputIdentity else { return }
            self.stopListening(reason: .asrTaskFailed)
        }
    }

    /// Handles one ASR segment on MainActor.
    ///
    /// Partial ASR may update live transcript UI and diagnostics, but final ASR
    /// is preferred for answer generation. Candidate microphone speech is not
    /// allowed to auto-trigger answers unless explicitly enabled in settings.
    /// Short fragments such as "why do you want" are deferred so a later final
    /// segment can become the single clean current question.
    func handleTranscriptSegment(_ segment: TranscriptSegment) async {
        let ingestionStartedAt = Date()
        liveInterview.recordTranscriptIngress(segmentID: segment.id, at: ingestionStartedAt)
        let previousSegment = transcriptSegments.first(where: { $0.id == segment.id })
        defer {
            lastTranscriptIngestionMs = Int(Date().timeIntervalSince(ingestionStartedAt) * 1000)
        }
        print("[AppState] Received segment: id = \(segment.id) | source = \(segment.source.rawValue) | asrSource = \(segment.asrSource?.rawValue ?? "unknown") | speaker = \(segment.speaker.rawValue) | textLength = \(segment.text.count) | finalization = \(segment.asrFinalizationReason ?? "unknown")")
        liveState = .transcribing
        recordASRTranscriptRuntimeEvent(for: segment)
        if segment.asrFinalizationReason != "partial" {
            liveInterview.cancelPartialUtteranceFinalization(segmentID: segment.id)
        }
        lastTranscriptQuestionGenerationTrace = TranscriptQuestionGenerationTrace(
            transcriptSegmentID: segment.id,
            source: segment.source.rawValue,
            asrSource: segment.asrSource?.rawValue ?? "",
            speaker: segment.speaker.rawValue,
            speakerRole: segment.speaker.rawValue,
            interviewPhase: interviewPhase.rawValue,
            selectedSessionMode: interviewSessionMode.rawValue,
            resolvedSessionPhase: resolvedInterviewSessionPhase.rawValue,
            detectedSpeakerRole: detectedDialogueSpeakerRole.rawValue,
            detectedTurnType: detectedDialogueTurnType.rawValue,
            sourceChannel: segment.source.rawValue,
            modeTransition: "",
            modeTransitionReason: "",
            text: segment.text,
            isFinal: segment.asrFinalizationReason != "partial",
            textLength: segment.text.count,
            normalizedText: normalizeTraceText(segment.text),
            providerStatus: activeRealtimeProviderBadge,
            currentGenerationState: generationUIState.displayName,
            currentSuggestionExists: currentSuggestion != nil
        )
        let dialogueTrigger = InterviewDialogueTriggerPolicy.decideDialogueTrigger(
            segment: segment,
            sessionMode: interviewSessionMode,
            currentState: dialogueRuntimeState,
            answerPanelQuestions: answerPanelQuestionsEnabled,
            suppressPresentation: candidatePresentationMode == .suppressAnswers,
            suppressCandidateQuestions: candidateAsksPanelMode == .suppressAnswers,
            allowContextDependent: true
        )
        let phaseBeforeDialogueDecision = resolvedInterviewSessionPhase
        let isFinalOrStabilizedSegment = segment.asrFinalizationReason != "partial"
        applyDialogueDecision(
            dialogueTrigger,
            source: segment.source,
            allowModeTransition: isFinalOrStabilizedSegment
        )
        let segmentModeTransition = phaseBeforeDialogueDecision == resolvedInterviewSessionPhase
            ? ""
            : "\(phaseBeforeDialogueDecision.rawValue) -> \(resolvedInterviewSessionPhase.rawValue)"
        let segmentModeTransitionReason = segmentModeTransition.isEmpty ? "" : dialogueTrigger.modeTransitionReason
        lastSpeakerRole = dialogueTrigger.speakerRole.rawValue
        lastTriggerDecision = dialogueTrigger.decision.rawValue
        lastTriggerReason = dialogueTrigger.triggerReason
        lastSuppressionReason = dialogueTrigger.suppressionReason
        lastTranscriptQuestionGenerationTrace.triggerDecision = dialogueTrigger.decision.rawValue
        lastTranscriptQuestionGenerationTrace.triggerReason = dialogueTrigger.triggerReason
        lastTranscriptQuestionGenerationTrace.suppressionReason = dialogueTrigger.suppressionReason
        lastTranscriptQuestionGenerationTrace.selectedSessionMode = interviewSessionMode.rawValue
        lastTranscriptQuestionGenerationTrace.resolvedSessionPhase = resolvedInterviewSessionPhase.rawValue
        lastTranscriptQuestionGenerationTrace.detectedSpeakerRole = dialogueTrigger.speakerRole.rawValue
        lastTranscriptQuestionGenerationTrace.detectedTurnType = dialogueTrigger.turnType.rawValue
        lastTranscriptQuestionGenerationTrace.sourceChannel = segment.source.rawValue
        lastTranscriptQuestionGenerationTrace.modeTransition = segmentModeTransition
        lastTranscriptQuestionGenerationTrace.modeTransitionReason = segmentModeTransitionReason
        if dialogueTrigger.decision == .candidateQuestionToPanel,
           segment.asrFinalizationReason != "partial",
           previousSegment == nil {
            candidateQuestionsToPanelCount += 1
        }
        
        if let index = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            transcriptSegments[index] = segment
        } else {
            transcriptSegments.append(segment)
        }
        
        lastTranscriptSnippet = segment.text
        if segment.source == .systemAudio {
            lastSystemTranscript = segment.text
        }
        if currentSession == nil {
            bindCurrentSessionForTranscriptSegmentIfNeeded(segment)
        }
        if settings.saveTranscriptsLocally {
            saveTranscriptSegmentInBackground(segment)
        }

        let systemAudioClassification = classifySystemAudioUtteranceIfNeeded(
            segment,
            previousSegment: previousSegment
        )
        if let systemAudioClassification {
            lastTranscriptQuestionGenerationTrace.questionCandidate = systemAudioClassification.intent == .answerWorthyQuestion
            lastTranscriptQuestionGenerationTrace.questionConfidence = systemAudioClassification.confidence
            lastTranscriptQuestionGenerationTrace.questionIntent = systemAudioClassification.intent.rawValue
        } else {
            let localQuestion = questionDetectionService.isLikelyQuestion(segment.text)
            lastTranscriptQuestionGenerationTrace.questionCandidate = localQuestion.shouldTrigger
            lastTranscriptQuestionGenerationTrace.questionConfidence = localQuestion.confidence
            lastTranscriptQuestionGenerationTrace.questionIntent = localQuestion.reason
        }
        let questionExtractionSegment = systemAudioSegmentForQuestionExtraction(from: segment)
        let extractedSystemAudioQuestions = questionExtractionSegment.map {
            extractSystemAudioQuestionsIfNeeded(from: $0)
        } ?? []
        if !extractedSystemAudioQuestions.isEmpty {
            lastTranscriptQuestionGenerationTrace.extractedQuestionCount = extractedSystemAudioQuestions.count
            lastTranscriptQuestionGenerationTrace.extractedQuestionsPreview = extractedSystemAudioQuestions.map(\.text)
            lastTranscriptQuestionGenerationTrace.questionCandidate = true
            lastTranscriptQuestionGenerationTrace.questionConfidence = max(
                lastTranscriptQuestionGenerationTrace.questionConfidence,
                extractedSystemAudioQuestions.map(\.confidence).max() ?? 0.0
            )
            lastTranscriptQuestionGenerationTrace.questionIntent = extractedSystemAudioQuestions.last?.intent.rawValue ?? lastTranscriptQuestionGenerationTrace.questionIntent
        }

        // Background debounced RAG precompute. This is speculative support work
        // only: retrieved context must remain subordinate to the final current
        // question selected by detection.
        if segment.source == .systemAudio,
           systemAudioCanUseQuestionIntent(segment),
           systemAudioClassification?.intent == .answerWorthyQuestion {
            let words = segment.text.split(whereSeparator: \.isWhitespace)
            if words.count >= 6 { // 5-7 words range
                let retrievalService = contextRetrievalService!
                liveRAGPrefetch.schedule(resolve: { [weak self] in
                    guard let self, !self.isShuttingDown else { return nil }
                    let scope = LiveRAGPrefetch.Scope(sessionID: self.currentSession?.id,
                        snapshotID: self.activeContextSnapshot?.id,
                        cacheContextID: self.activeContextSnapshot?.id ?? self.currentSession?.contextSnapshotID ?? "legacy-context")
                    let frozenService = retrievalService.freezeConfiguration()
                    // Resolution may synchronously publish diagnostics. The
                    // owner separately rejects reentrant stop/replacement.
                    guard !self.isShuttingDown,
                          self.currentSession?.id == scope.sessionID,
                          self.activeContextSnapshot?.id == scope.snapshotID else { return nil }
                    return LiveRAGPrefetch.Request(scope: scope,
                        segmentID: segment.id, question: segment.text, service: frozenService)
                }, isScopeCurrent: { [weak self] scope in
                    guard let self else { return false }
                    return self.activeContextSnapshot?.id == scope.snapshotID && self.currentSession?.id == scope.sessionID
                })
            }
        }

        // Echo/leakage protection keeps interviewer audio that bleeds into the
        // microphone from being treated as candidate speech or as a new question.
        if segment.source == .systemAudio {
            liveInterview.recordSystemAudioForEcho(segment.text)
            
            // Set last system audio transcript
            self.lastSystemAudioTranscript = segment.text
        }

        var isEchoLeakage = false
        if segment.source == .microphone,
           let match = liveInterview.microphoneEchoMatch(segment.text) {
            isEchoLeakage = true
            print("[EchoProtection] Detected interviewer leakage in mic stream: segmentID = \(segment.id) | micTextLength = \(segment.text.count) | systemTextLength = \(match.textLength) | similarity = \(String(format: "%.2f", match.similarity)). Question detection bypassed.")
        }

        var shouldTriggerDetection = false
        var skipReason = ""
        
        if !dialogueTrigger.shouldEvaluateQuestion {
            skipReason = dialogueTrigger.suppressionReason
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = dialogueTrigger.blockedReasonCode
        } else if segment.source == .microphone && !settings.allowQuestionDetectionFromMicrophoneOnly {
            skipReason = "Microphone question detection requires explicit opt-in; speaker remains unknown"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
        } else if !settings.automaticQuestionDetectionEnabled {
            skipReason = "automatic question detection disabled in settings"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "autoDetectDisabled"
        } else if settings.manualOnlyMode {
            skipReason = "manual only mode enabled"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "captureModeDisabled"
        } else if isEchoLeakage {
            skipReason = "echo/leakage detected in mic stream"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
        } else {
            // Source, speaker, session mode, and turn semantics were resolved by
            // the centralized dialogue decision above. Re-checking raw speaker
            // fields here can contradict source-channel attribution and recreate
            // the old per-turn switching requirement.
            shouldTriggerDetection = true
        }

        // Output verbose gating logs
        print("[GatingLog] segmentSource: \(segment.source.rawValue) | segmentSpeaker: \(segment.speaker.rawValue) | eligibleForAutoDetection: \(shouldTriggerDetection)\(shouldTriggerDetection ? "" : " | skipReason: \(skipReason)")")

        // Capture attribution diagnostics
        let diag = SegmentAttributionDiagnostic(
            id: segment.id,
            textPreview: segment.text,
            source: segment.source,
            speaker: segment.speaker,
            createdAt: segment.createdAt,
            inputDeviceName: segment.inputDeviceName,
            outputDeviceName: segment.outputDeviceName,
            eligibleForAutoDetection: shouldTriggerDetection,
            skipReason: skipReason,
            triggerDecision: dialogueTrigger.decision.rawValue,
            triggerReason: dialogueTrigger.triggerReason,
            suppressionReason: dialogueTrigger.suppressionReason,
            interviewPhase: interviewPhase.rawValue,
            selectedSessionMode: interviewSessionMode.rawValue,
            resolvedSessionPhase: resolvedInterviewSessionPhase.rawValue,
            detectedSpeakerRole: dialogueTrigger.speakerRole.rawValue,
            detectedTurnType: dialogueTrigger.turnType.rawValue,
            sourceChannel: segment.source.rawValue
        )
        last10SegmentsDiagnostics.append(diag)
        if last10SegmentsDiagnostics.count > 10 {
            last10SegmentsDiagnostics.removeFirst()
        }

        let isSystemLikeDetectionAudio = segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock
        let isASRPartial = segment.asrFinalizationReason == "partial"
        let isIncompleteSystemAudioQuestionFragment = isSystemLikeDetectionAudio &&
            SystemAudioQuestionExtractor.isIncompleteQuestionFragment(segment.text)

        if shouldTriggerDetection,
           isSystemLikeDetectionAudio,
           isASRPartial {
            scheduleStablePartialUtteranceCandidateIfNeeded(segment)
            let reason = "waiting for final ASR transcript"
            self.lastDetectionSkipReason = reason
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "waitingForFinalASR"
            lastTranscriptQuestionGenerationTrace.ignoredReason = reason
            lastTranscriptQuestionGenerationTrace.generationTriggered = false
            lastTranscriptQuestionGenerationTrace.acceptedFromPartial = false
            lastQuestionDetectionResult = "Waiting for final interviewer transcript before generating an answer."
            print("[GatingLog] Auto detection deferred: \(reason) | segmentID: \(segment.id) | textLength = \(segment.text.count)")
            liveState = .listening
            return
        }

        if (shouldTriggerDetection || dialogueTrigger.blockedReasonCode == "notSubstantiveQuestion"),
           isSystemLikeDetectionAudio,
           extractedSystemAudioQuestions.isEmpty,
           isIncompleteSystemAudioQuestionFragment {
            // Do not generate from partial or obviously truncated interviewer
            // fragments. A later final segment with the full question must win.
            let reason = "incomplete question fragment"
            recordTranscriptRuntimeEvent(.questionRejected(
                sessionID: segment.sessionID,
                text: segment.text,
                reason: .incompleteFragment,
                timestamp: Date()
            ))
            if SemanticDuplicateKeyBuilder.areDuplicates(lastAcceptedQuestionText, segment.text) {
                recordDuplicateSuppression()
                recordTranscriptRuntimeEvent(.duplicatePartialSuppressed(
                    sessionID: segment.sessionID,
                    question: segment.text,
                    reason: .incompleteFragment,
                    timestamp: Date()
                ))
            }
            self.lastDetectionSkipReason = reason
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "incompleteQuestionFragment"
            lastTranscriptQuestionGenerationTrace.ignoredReason = reason
            lastTranscriptQuestionGenerationTrace.generationTriggered = false
            lastTranscriptQuestionGenerationTrace.acceptedFromPartial = false
            lastQuestionDetectionResult = "Waiting for a complete interviewer question before generating an answer."
            print("[GatingLog] Auto detection deferred: \(reason) | segmentID: \(segment.id) | textLength = \(segment.text.count)")
            liveState = .listening
            return
        }

        if shouldTriggerDetection, isASRPartial {
            lastTranscriptQuestionGenerationTrace.acceptedFromPartial = true
        }

        // Explicitly opted-in microphone finals use the same contextual ingress
        // as system audio. Provider detection otherwise discards this reference
        // before the shared runtime guard can freeze or clarify it.
        if shouldTriggerDetection, !isASRPartial, segment.source == .microphone,
           QuestionCandidatePipeline.isContextDependentRequest(segment.text), let session = currentSession {
            let candidates = SystemAudioQuestionExtractor.extract(from: segment.text, isFinal: true, allowContextDependent: true)
            processExtractedSystemAudioQuestions(candidates, segment: segment, session: session, suggestionTranscript: recentTranscriptText())
            return
        }

        if shouldTriggerDetection,
           shouldUseExtractedSystemAudioQuestions(extractedSystemAudioQuestions, classification: systemAudioClassification),
           currentSession == nil {
            let reason = "current_session_not_bound"
            recordAnswerRequestSkipped(reason: reason, sessionID: segment.sessionID, text: questionExtractionSegment?.text ?? segment.text)
            lastQuestionDetectionResult = "Generation skipped: current session is not bound for the finalized transcript."
            liveState = .listening
            return
        }

        if shouldTriggerDetection,
           shouldUseExtractedSystemAudioQuestions(extractedSystemAudioQuestions, classification: systemAudioClassification),
           let session = currentSession {
            recordTranscriptRuntimeEvent(.utteranceCandidate(
                sessionID: segment.sessionID,
                text: questionExtractionSegment?.text ?? segment.text,
                timestamp: Date()
            ))
            recordLifecycleTrace(
                "question.detected",
                sessionID: segment.sessionID,
                text: questionExtractionSegment?.text ?? segment.text
            )
            // Multi-question transcripts are split before generation so the
            // current answer is bound to one clean latest interviewer question,
            // not to a merged monologue.
            self.lastDetectionSkipReason = ""
            liveInterview.coordinateAcceptedQuestions {
                processExtractedSystemAudioQuestions(
                    extractedSystemAudioQuestions,
                    segment: questionExtractionSegment ?? segment,
                    session: session,
                    suggestionTranscript: recentTranscriptText()
                )
                liveState = .listening
            }
            return
        }

        if shouldTriggerDetection,
           let systemAudioClassification,
           systemAudioClassification.intent != .answerWorthyQuestion {
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = ignoredReasonCode(for: systemAudioClassification.intent)
            recordIgnoredSystemAudioUtterance(
                segment,
                classification: systemAudioClassification
            )
            if isSystemLikeDetectionAudio, !isASRPartial {
                recordAnswerRequestSkipped(
                    reason: ignoredReasonCode(for: systemAudioClassification.intent),
                    sessionID: segment.sessionID,
                    text: segment.text
                )
            }
            liveState = .listening
            return
        }

        if shouldTriggerDetection {
            self.lastDetectionSkipReason = ""
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
            recordTranscriptRuntimeEvent(.utteranceCandidate(
                sessionID: segment.sessionID,
                text: segment.text,
                timestamp: Date()
            ))
            maybeRunAutomaticDetection(triggeringSegment: segment)
        } else {
            self.lastDetectionSkipReason = skipReason
            lastTranscriptQuestionGenerationTrace.ignoredReason = skipReason
            if segment.source == .microphone,
               segment.speaker == .candidate,
               questionDetectionService.isLikelyQuestion(segment.text).shouldTrigger {
                ignoredCandidateQuestionCount += 1
            }
            if isSystemLikeDetectionAudio, !isASRPartial, !skipReason.isEmpty {
                recordAnswerRequestSkipped(
                    reason: skipReason,
                    blockedReasonCode: lastTranscriptQuestionGenerationTrace.generationBlockedReason.isEmpty
                        ? nil
                        : lastTranscriptQuestionGenerationTrace.generationBlockedReason,
                    sessionID: segment.sessionID,
                    text: segment.text
                )
            }
            liveState = .listening
        }

    }

    // MARK: - Normalization

    private func bindCurrentSessionForTranscriptSegmentIfNeeded(_ segment: TranscriptSegment) {
        guard currentSession == nil else { return }
        markSQLiteOperation("Loading transcript session for ASR segment")
        do {
            currentSession = try sessionRepository.session(id: segment.sessionID)
            lastSQLiteOperation = currentSession == nil ? "Transcript session not found" : "Loaded transcript session"
        } catch {
            lastSQLiteOperation = "Transcript session load failed: \(error.localizedDescription)"
        }
    }

    func normalizeTraceText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedBindingText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
    }

    // MARK: - Runtime Event Routing

    // internal for AppState extension access only
    func recordASRTranscriptRuntimeEvent(for segment: TranscriptSegment) {
        guard segment.speaker != .system else { return }
        if segment.asrFinalizationReason == "partial" {
            recordTranscriptRuntimeEvent(.asrPartial(
                sessionID: segment.sessionID,
                text: segment.text,
                recognitionTaskID: segment.recognitionTaskID,
                eventSequence: segment.recognitionEventSequence,
                sourceStartUTF16: segment.sourceTextStartUTF16,
                sourceEndUTF16: segment.sourceTextEndUTF16,
                isFinal: false,
                timestamp: segment.createdAt
            ))
        } else {
            // Stamp came from the actual Parakeet bridge before stream enqueue.
            // This does not substitute UI arrival time for provider production.
            recordVerificationBoundary("verification.asr_final_bridge_produced",
                at: segment.verificationFinalHostTicks, sessionID: segment.sessionID,
                segmentID: segment.id)
            recordVerificationBoundary("verification.asr_final_app_received",
                at: VerificationTiming.hostTicks(), sessionID: segment.sessionID,
                segmentID: segment.id)
            recordTranscriptRuntimeEvent(.asrFinal(
                sessionID: segment.sessionID,
                text: segment.text,
                recognitionTaskID: segment.recognitionTaskID,
                eventSequence: segment.recognitionEventSequence,
                sourceStartUTF16: segment.sourceTextStartUTF16,
                sourceEndUTF16: segment.sourceTextEndUTF16,
                isFinal: segment.recognitionIsFinal ?? true,
                timestamp: segment.createdAt
            ))
        }
    }

    // internal for AppState extension access only
    func scheduleStablePartialUtteranceCandidateIfNeeded(_ segment: TranscriptSegment) {
        let tokenCount = segment.text.split(whereSeparator: \.isWhitespace).count
        guard tokenCount >= minimumQuestionTokenCount else { return }
        let segmentID = segment.id
        let textSnapshot = segment.text
        let sessionSnapshot = currentSession
        let delayNanoseconds = UInt64(max(900, min(partialStabilityWindowMS, 1_500))) * 1_000_000
#if DEBUG
        let delayForTesting = partialFinalizationDelayForTesting
        let beforeSnapshotForTesting = partialFinalizationBeforeSnapshotForTesting
#endif
        liveInterview.submitPartialUtteranceFinalization(segmentID: segmentID) { [weak self] id in
            do {
#if DEBUG
                if let delayForTesting { try await delayForTesting(delayNanoseconds) }
                else { try await Task.sleep(nanoseconds: delayNanoseconds) }
#else
                try await Task.sleep(nanoseconds: delayNanoseconds)
#endif
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
#if DEBUG
            await beforeSnapshotForTesting?(segmentID)
#endif

            guard let self,
                  self.liveInterview.acceptsPartialUtteranceFinalization(segmentID: segmentID, id: id),
                  !Task.isCancelled,
                  self.currentSession?.id == sessionSnapshot?.id,
                  self.currentSession?.contextSnapshotID == sessionSnapshot?.contextSnapshotID,
                  self.currentSession?.contentRevision == sessionSnapshot?.contentRevision,
                  let current = self.transcriptSegments.first(where: { $0.id == segmentID }),
                  current.sessionID == segment.sessionID,
                  current.asrFinalizationReason == "partial",
                  current.text == textSnapshot else { return }
            let stableSegment = TranscriptSegment(
                id: current.id,
                sessionID: current.sessionID,
                source: current.source,
                speaker: current.speaker,
                text: current.text,
                startTime: current.startTime,
                endTime: current.endTime,
                createdAt: Date(),
                inputDeviceName: current.inputDeviceName,
                outputDeviceName: current.outputDeviceName,
                deviceID: current.deviceID,
                confidence: current.confidence,
                asrSource: current.asrSource,
                asrFirstPartialMS: current.asrFirstPartialMS,
                asrFinalMS: current.asrFinalMS,
                asrBestSelectedMS: current.asrBestSelectedMS,
                asrFinalizationReason: "stable_partial",
                recognitionTaskID: current.recognitionTaskID,
                recognitionEventSequence: current.recognitionEventSequence,
                sourceTextStartUTF16: current.sourceTextStartUTF16,
                sourceTextEndUTF16: current.sourceTextEndUTF16,
                recognitionIsFinal: true
            )
            // The finalized callback cancels only a still-current partial slot.
            // Release admission first without cancelling this executing root;
            // its exact receipt remains managed until the real Task exit.
            self.liveInterview.finishPartialUtteranceFinalizationAdmission(segmentID: segmentID, id: id)
            await self.handleTranscriptSegment(stableSegment)
        }
    }

    // MARK: - Background Persistence

    // These history writes outlive answer-generation terminals. Transfer their
    // exact handles to the existing admitted-write retirement owner before
    // yielding; permanent app shutdown closes new admission, not old tickets.

    func saveTranscriptSegmentInBackground(_ segment: TranscriptSegment, consentTicket frozenTicket: Int? = nil) {
        guard !isShuttingDown else { return }
        let consent = persistenceConsent
        let consentTicket = frozenTicket ?? consent.ticket()
        let repository = transcriptRepository
        markSQLiteOperation("Saving transcript segment in background")
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            do {
                try consent.write(ticket: consentTicket) { try repository.saveSegment(segment) }
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Saved transcript segment"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Transcript save failed: \(error.localizedDescription)"
                }
            }
        }
        generationCoordinator.retainAdmittedPersistenceUntilExit(task)
    }

    func saveDetectedQuestionInBackground(_ question: DetectedQuestion, consentTicket frozenTicket: Int? = nil) {
        guard !isShuttingDown else { return }
        guard settings.saveTranscriptsLocally else { return }
        let consent = persistenceConsent
        let consentTicket = frozenTicket ?? consent.ticket()
        let repository = suggestionRepository
        markSQLiteOperation("Saving detected question in background")
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            do {
                try consent.write(ticket: consentTicket) { try repository.saveDetectedQuestion(question) }
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Saved detected question"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Detected question save failed: \(error.localizedDescription)"
                }
            }
        }
        generationCoordinator.retainAdmittedPersistenceUntilExit(task)
    }

    func saveDetectedQuestionsInBackground(_ questions: [DetectedQuestion], consentTicket frozenTicket: Int? = nil) {
        guard !isShuttingDown else { return }
        guard settings.saveTranscriptsLocally else { return }
        guard !questions.isEmpty else { return }
        let consent = persistenceConsent
        let consentTicket = frozenTicket ?? consent.ticket()
        let repository = suggestionRepository
        markSQLiteOperation("Saving extracted detected questions in background")
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            do {
                for question in questions {
                    try consent.write(ticket: consentTicket) { try repository.saveDetectedQuestion(question) }
                }
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Saved extracted detected questions"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !self.isShuttingDown else { return }
                    self.lastSQLiteOperation = "Extracted detected question save failed: \(error.localizedDescription)"
                }
            }
        }
        generationCoordinator.retainAdmittedPersistenceUntilExit(task)
    }

    func saveSuggestionSnapshotInBackground(_ card: SuggestionCard, chunks: [RetrievedChunk], consentTicket: Int) {
        guard !isShuttingDown else { return }
        guard settings.saveTranscriptsLocally else { return }
        guard !card.isPartial else {
            print("[Transcript] Skipping saveSuggestionSnapshotInBackground for partial card.")
            recordTranscriptRuntimeEvent(.persistenceRejected(
                sessionID: card.sessionID,
                questionID: card.detectedQuestionID ?? card.questionID,
                generationID: card.generationID,
                question: card.questionText ?? card.promptPrimaryQuestion ?? "",
                reason: "persistence_skipped_no_aligned_answer",
                timestamp: Date()
            ))
            return
        }
        let persistenceGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card)
        guard persistenceGuard.accepted else {
            lastSQLiteOperation = "Suggestion snapshot save blocked: \(persistenceGuard.reason?.rawValue ?? "rejected_pre_persistence_guard")"
            lastAlignmentError = persistenceGuard.diagnostic
            recordTranscriptRuntimeEvent(.persistenceRejected(
                sessionID: card.sessionID,
                questionID: card.detectedQuestionID ?? card.questionID,
                generationID: card.generationID,
                question: card.questionText ?? card.promptPrimaryQuestion ?? "",
                reason: snapshotPersistenceTraceReason(for: persistenceGuard),
                timestamp: Date()
            ))
            if persistenceGuard.diagnostic.localizedCaseInsensitiveContains("wrong project grounding") {
                recordTranscriptRuntimeEvent(.answerRejectedWrongProjectGrounding(
                    sessionID: card.sessionID,
                    questionID: card.detectedQuestionID ?? card.questionID,
                    generationID: card.generationID,
                    question: card.questionText ?? card.promptPrimaryQuestion ?? "",
                    reason: persistenceGuard.diagnostic,
                    timestamp: Date()
                ))
            }
            return
        }
        let sanitizedCard = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
            card,
            result: persistenceGuard
        )
        let consent = persistenceConsent
        guard consent.isCurrent(ticket: consentTicket),
              claimSuggestionPersistence(sanitizedCard, generationID: sanitizedCard.generationID) else { return }
        let repository = suggestionRepository
        recordTranscriptRuntimeEvent(.persistenceStarted(
            sessionID: sanitizedCard.sessionID,
            questionID: sanitizedCard.detectedQuestionID,
            generationID: sanitizedCard.generationID,
            question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
            timestamp: Date()
        ))
        markSQLiteOperation("Saving suggestion snapshot in background")
        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self, sanitizedCard] in
            do {
                guard let self else { return }
                guard !(await self.rejectCancelledPersistenceIfNeeded(
                    card: sanitizedCard,
                    generationID: sanitizedCard.generationID,
                    sourceCallback: "snapshot_validation"
                )) else { return }
                let detachedGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(sanitizedCard)
                guard detachedGuard.accepted else {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if !self.isShuttingDown {
                            self.lastSQLiteOperation = "Suggestion snapshot save blocked: \(detachedGuard.reason?.rawValue ?? "rejected_pre_persistence_guard")"
                            self.lastAlignmentError = detachedGuard.diagnostic
                        }
                        self.recordTranscriptRuntimeEvent(.persistenceRejected(
                            sessionID: sanitizedCard.sessionID,
                            questionID: sanitizedCard.detectedQuestionID ?? sanitizedCard.questionID,
                            generationID: sanitizedCard.generationID,
                            question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
                            reason: self.snapshotPersistenceTraceReason(for: detachedGuard),
                            timestamp: Date()
                        ))
                        if detachedGuard.diagnostic.localizedCaseInsensitiveContains("wrong project grounding") {
                            self.recordTranscriptRuntimeEvent(.answerRejectedWrongProjectGrounding(
                                sessionID: sanitizedCard.sessionID,
                                questionID: sanitizedCard.detectedQuestionID ?? sanitizedCard.questionID,
                                generationID: sanitizedCard.generationID,
                                question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
                                reason: detachedGuard.diagnostic,
                                timestamp: Date()
                            ))
                        }
                    }
                    return
                }
                let detachedCard = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
                    sanitizedCard,
                    result: detachedGuard
                )
                guard !(await self.rejectCancelledPersistenceIfNeeded(
                    card: detachedCard,
                    generationID: detachedCard.generationID,
                    sourceCallback: "snapshot_sqlite_save"
                )) else { return }
                try consent.write(ticket: consentTicket) { try repository.saveSuggestionCard(detachedCard, retrievedChunks: chunks) }
                let verificationCommit = VerificationTimingEvent.card("verification.db_commit.snapshot",
                    at: VerificationTiming.hostTicks(), card: detachedCard)
                await MainActor.run { [weak self, detachedCard] in
                    guard let self else { return }
                    if let verificationCommit {
                        self.diagnosticsState.recordVerificationTiming(verificationCommit,
                            mode: self.settings.effectiveDiagnosticTraceMode)
                    }
                    if !self.isShuttingDown {
                        self.lastSQLiteOperation = "Saved suggestion snapshot"
                        self.refreshLiveSuggestionHistory(
                            sessionID: detachedCard.sessionID,
                            latestQuestion: detachedCard.questionText ?? detachedCard.promptPrimaryQuestion ?? ""
                        )
                    }
                    // A completed admitted write remains an audit fact even
                    // after shutdown closes publication to current UI.
                    if self.markSuggestionPersistenceSucceededOnce(
                        cardID: detachedCard.id,
                        generationID: detachedCard.generationID
                    ) {
                        self.recordTranscriptRuntimeEvent(.persistenceSucceeded(
                            sessionID: detachedCard.sessionID,
                            questionID: detachedCard.detectedQuestionID ?? detachedCard.questionID,
                            generationID: detachedCard.generationID,
                            question: detachedCard.questionText ?? detachedCard.promptPrimaryQuestion ?? "",
                            timestamp: Date()
                        ))
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.isShuttingDown {
                        self.lastSQLiteOperation = "Suggestion snapshot save failed: \(error.localizedDescription)"
                    }
                    self.recordTranscriptRuntimeEvent(.persistenceRejected(
                        sessionID: sanitizedCard.sessionID,
                        questionID: sanitizedCard.detectedQuestionID ?? sanitizedCard.questionID,
                        generationID: sanitizedCard.generationID,
                        question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
                        reason: "persistence_failed_sqlite_error",
                        timestamp: Date()
                    ))
                }
            }
        }
        generationCoordinator.retainAdmittedPersistenceUntilExit(task)
    }

    private func snapshotPersistenceTraceReason(for result: QuestionPersistenceGuardResult) -> String {
        switch result.reason {
        case .some(.incompleteAnswer):
            return "persistence_rejected_incomplete_answer"
        case .some(.emptyQuestion), .some(.incompleteFragment), .some(.vagueFollowup), .some(.genericKnownPattern),
             .some(.pipelineRejected), .some(.multipleQuestionsNeedSegmentation), .some(.promptQuestionMismatch):
            return "persistence_rejected_bad_question"
        case .some(.emptyAnswer), .some(.partialCard), .some(.weakAlignment), .some(.unknownAlignment), .some(.mismatchedAlignment),
             .some(.interviewerQuestionsIncomplete), .some(.unrelatedTechnicalTradeoff), .some(.duplicateSuppressed):
            return "persistence_skipped_no_aligned_answer"
        case nil:
            return "persistence_rejected_unknown"
        }
    }
}
