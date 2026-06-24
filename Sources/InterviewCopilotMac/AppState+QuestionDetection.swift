// Owns automatic interviewer-question detection and local system-audio
// segmentation.
// This extension may create DetectedQuestion records and decide whether to
// trigger generation. It must not own the generation lifecycle, provider calls,
// RAG scoring, or UI answer mutation.

import Foundation

extension AppState {
    // MARK: - Local System-Audio Extraction

    // internal for AppState extension access only
    func systemAudioSegmentForQuestionExtraction(from segment: TranscriptSegment) -> TranscriptSegment? {
        guard segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock else {
            return nil
        }
        guard systemAudioCanUseQuestionIntent(segment) else {
            return nil
        }
        return transcriptReconciler.segmentForQuestionExtraction(segment)
    }

    // internal for AppState extension access only
    func extractSystemAudioQuestionsIfNeeded(from segment: TranscriptSegment) -> [ExtractedTranscriptQuestion] {
        guard segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock else {
            return []
        }
        guard systemAudioCanUseQuestionIntent(segment) else {
            return []
        }
        return SystemAudioQuestionExtractor.extract(
            from: segment.text,
            isFinal: segment.asrFinalizationReason != "partial"
        )
    }

    // internal for AppState extension access only
    func shouldUseExtractedSystemAudioQuestions(
        _ extractedQuestions: [ExtractedTranscriptQuestion],
        classification: UtteranceIntentClassification?
    ) -> Bool {
        guard !extractedQuestions.isEmpty else { return false }
        // Local extraction is the runtime source of truth once it has produced
        // a complete accepted system-audio candidate. Provider detection may
        // still run when local extraction finds nothing, but it must not shrink
        // a conditional question such as "If ..., how would you debug it?" into
        // a tail-only candidate like "would you debug it".
        return true
    }

    // internal for AppState extension access only
    func processExtractedSystemAudioQuestions(
        _ extractedQuestions: [ExtractedTranscriptQuestion],
        segment: TranscriptSegment,
        session: InterviewSession,
        suggestionTranscript: String
    ) {
        // One ASR segment can contain several interviewer questions. Persist
        // each accepted detection, but generate only for the newest question so
        // the visible answer stays aligned with the visible current question.
        let baseDate = Date()
        let acceptedQuestions = extractedQuestions.enumerated().compactMap { index, extracted in
            let detected = makeDetectedQuestion(
                from: extracted,
                sessionID: session.id,
                segment: segment,
                createdAt: baseDate.addingTimeInterval(Double(index) / 1_000.0)
            )
            return runtimeAcceptedQuestionForGeneration(
                detected,
                triggeringSegmentID: segment.id
            )
        }
        guard !acceptedQuestions.isEmpty else {
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "lowConfidence"
            lastTranscriptQuestionGenerationTrace.ignoredReason = "No extracted question passed runtime acceptance checks"
            return
        }

        let wasFirstAnswerWorthyQuestion = detectedQuestionsInSessionCount == 0
        var freshQuestions: [DetectedQuestion] = []
        var duplicateQuestions: [DetectedQuestion] = []
        let isCumulativeTranscript = extractedQuestions.count > 1
        for question in acceptedQuestions {
            let replaySource = consumedReplaySource(
                question,
                isCumulativeTranscript: isCumulativeTranscript
            )
            let replayedOccurrence = replaySource != nil
            let intentionalRepeat = isIntentionalQuestionRepeat(
                question,
                replayedOccurrence: replayedOccurrence
            )
            if replayedOccurrence || (!intentionalRepeat && !wasFirstAnswerWorthyQuestion && isRecentDuplicateAutoQuestion(
                question.questionText,
                transcriptSegmentID: question.transcriptSegmentID
            )) {
                if let replaySource, let ingress = question.ingressIdentity {
                    recordTranscriptRuntimeEvent(.cumulativeReplayRejected(
                        sessionID: session.id,
                        questionID: question.id,
                        question: question.questionText,
                        normalizedQuestion: ingress.normalizedText,
                        oldRecognitionEpoch: replaySource.recognitionTaskID,
                        newRecognitionEpoch: ingress.recognitionTaskID,
                        oldSourceSpan: replaySource.sourceSpanDescription,
                        newSourceSpan: ingress.sourceSpanDescription,
                        overlapScore: sourceSpanOverlapScore(replaySource, ingress),
                        reason: "consumed_source_span_overlap",
                        timestamp: Date()
                    ))
                }
                duplicateQuestions.append(question)
            } else {
                if intentionalRepeat {
                    intentionalRepeatQuestionIDs.insert(question.id)
                    recordTranscriptRuntimeEvent(.intentionalQuestionRepeatAccepted(
                        sessionID: session.id,
                        questionID: question.id,
                        question: question.questionText,
                        occurrenceKey: question.ingressIdentity?.occurrenceKey ?? "segment:\(question.transcriptSegmentID ?? "unknown")",
                        timestamp: Date()
                    ))
                }
                freshQuestions.append(question)
            }
        }

        for duplicate in duplicateQuestions {
            recordTranscriptRuntimeEvent(.generationRejected(
                sessionID: session.id,
                question: duplicate.questionText,
                reason: .duplicateSuppressed,
                timestamp: Date()
            ))
            recordTranscriptRuntimeEvent(.duplicatePartialSuppressed(
                sessionID: session.id,
                question: duplicate.questionText,
                reason: .duplicateSuppressed,
                timestamp: Date()
            ))
        }

        guard let firstQuestion = freshQuestions.first else {
            recordDuplicateSuppression()
            lastTranscriptQuestionGenerationTrace.duplicateSuppressed = true
            lastTranscriptQuestionGenerationTrace.generationTriggered = false
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "duplicateSuppressed"
            if let duplicate = duplicateQuestions.last, !visibleAnswerExists {
                showDuplicateQuestionNotice(for: duplicate, session: session)
            }
            return
        }

        saveDetectedQuestionsInBackground(freshQuestions)

        let latestQuestion = freshQuestions.last ?? firstQuestion
        detectedQuestionsInSessionCount += freshQuestions.count
        lastDetectedQuestion = latestQuestion
        lastDetectedQuestionSource = segment.source.rawValue
        lastDetectedQuestionSpeaker = segment.speaker.rawValue
        lastQuestionDetectionProvider = "Local Question Extractor"
        lastQuestionDetectionModel = "system-audio-question-extractor"
        lastDetectedQuestionText = latestQuestion.questionText
        lastDetectionSubmittedSegmentText = segment.text
        lastDetectionPromptSource = segment.source.rawValue
        lastDetectionPromptSpeaker = segment.speaker.rawValue
        lastDetectionConfidence = latestQuestion.confidence
        lastQuestionConfidence = latestQuestion.confidence
        lastDetectionShouldTrigger = true
        lastDetectionReason = latestQuestion.intent.displayName
        lastDetectionRawJSON = latestQuestion.rawJSON ?? ""
        lastDetectionQuestionComplete = true
        lastDetectionAnswerStrategy = latestQuestion.answerStrategy.displayName
        lastQuestionDetectionResult = "Extracted \(freshQuestions.count) new question(s) from one transcript. Latest: \"\(latestQuestion.questionText)\""

        updateDiagnostics {
            $0.lastDetectedQuestionJSON = latestQuestion.rawJSON
            $0.lastProviderName = "Local Question Extractor"
            $0.lastProviderModel = "system-audio-question-extractor"
        }

        lastTranscriptQuestionGenerationTrace.detectedQuestionID = latestQuestion.id
        lastTranscriptQuestionGenerationTrace.questionConfidence = latestQuestion.confidence
        lastTranscriptQuestionGenerationTrace.questionIntent = latestQuestion.intent.rawValue
        lastTranscriptQuestionGenerationTrace.providerStatus = "Local Question Extractor"
        lastTranscriptQuestionGenerationTrace.firstQuestionSuppressedReason = ""
        currentFirstQuestionSuppressedReason = ""

        for question in freshQuestions {
            rememberConsumedTranscriptOccurrence(question)
            rememberAutoQuestion(
                question.questionText,
                transcriptSegmentID: question.transcriptSegmentID
            )
        }
        lastAutoSuggestionAt = Date()
        lastTranscriptQuestionGenerationTrace.generationTriggered = true
        lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
        recordLifecycleTrace(
            "question.accepted",
            sessionID: session.id,
            questionID: latestQuestion.id,
            text: latestQuestion.questionText
        )
        pendingAcceptedQuestions.removeAll()
        launchAutoSuggestionGeneration(for: latestQuestion, session: session, transcript: suggestionTranscript)
    }

    private func persistMergedTranscriptSnapshot(
        for question: DetectedQuestion,
        session: InterviewSession,
        segment: TranscriptSegment
    ) {
        let requestStart = Date()
        let generationID = UUID().uuidString
        recordTranscriptRuntimeEvent(.generationStarted(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            timestamp: requestStart
        ))
        var card = makeInitialFirstAnswerFallbackCard(
            cardID: UUID().uuidString,
            question: question,
            session: session,
            requestStart: requestStart
        )
        card.modelName = "local-merged-question-snapshot"
        card.promptVersion = "merged-transcript-snapshot-v1"
        card.providerName = "Local Question Snapshot"
        card.confidence = max(card.confidence ?? 0.45, 0.72)
        card.caution = "Saved from an earlier complete question in a merged transcript."
        card.questionText = question.questionText
        card.transcriptSegmentID = question.transcriptSegmentID
        card.generationID = generationID
        card.source = segment.source.rawValue
        card.speaker = segment.speaker.rawValue
        card.triggerPath = .autoDetect
        card.questionIntent = AnswerRelevancePolicy.intent(for: question.questionText)
        card.promptQuestionText = question.questionText
        card.promptPrimaryQuestion = question.questionText
        card.promptContainsPreviousQuestion = false
        card.previousQuestionIncluded = false
        card.previousQuestionText = nil
        card.contextBleedRisk = .low
        card.ragChunkIDs = []
        card.ragChunkIntents = []
        card.firstQuestionSuppressedReason = nil
        card.promptTokenEstimate = AnswerRelevancePolicy.estimateTokens(question.questionText)
        card.mismatchReason = nil
        card.sayFirstSource = "local_merged_question_snapshot"
        card.stageATimedOut = false
        card.stageBCompleted = true
        card.stageBStatus = "local_snapshot"
        card.latencyFirstVisibleMS = 0
        card.latencyFullCardMS = 0
        card.softFallbackUsed = true
        card.softFallbackLatencyMS = 0
        card.finalVisibleSource = "local_merged_question_snapshot"
        card.firstVisibleAnswerMS = 0
        card.firstKeyPointVisibleMS = card.keyPoints.isEmpty ? nil : 0
        card.allKeyPointsVisibleMS = card.keyPoints.isEmpty ? nil : 0
        card.followUpVisibleMS = card.followUpReady.isEmpty ? nil : 0
        card.fullCardVisibleMS = 0

        let answerText = ([card.sayFirst] + card.keyPoints + card.followUpReady).joined(separator: " ")
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question.questionText,
            answerText: answerText,
            sayFirst: card.sayFirst,
            stageBCompleted: true
        )
        card.alignmentScore = alignment.score
        card.alignmentVerdict = alignment.verdict
        card.answerIntent = alignment.answerIntent
        card.mismatchReason = alignment.verdict == .mismatched ? alignment.reason : nil

        guard alignment.verdict == .aligned else {
            recordTranscriptRuntimeEvent(.generationRejected(
                sessionID: session.id,
                question: question.questionText,
                reason: alignment.verdict == .weaklyAligned ? .weakAlignment : .mismatchedAlignment,
                timestamp: Date()
            ))
            return
        }
        saveSuggestionSnapshotInBackground(card, chunks: [])
    }

    private func makeDetectedQuestion(
        from extracted: ExtractedTranscriptQuestion,
        sessionID: String,
        segment: TranscriptSegment,
        createdAt: Date
    ) -> DetectedQuestion {
        let rawJSON = """
        {"should_trigger":true,"question_complete":true,"question_text":\(JSONParsing.jsonString(extracted.text)),"intent":"\(extracted.intent.rawValue)","answer_strategy":"\(extracted.answerStrategy.rawValue)","confidence":\(extracted.confidence),"reason":"Extracted from multi-question system audio transcript."}
        """
        return DetectedQuestion(
            id: UUID().uuidString,
            sessionID: sessionID,
            transcriptSegmentID: segment.id,
            questionText: extracted.text,
            intent: extracted.intent,
            answerStrategy: extracted.answerStrategy,
            confidence: extracted.confidence,
            reason: "Extracted from multi-question system audio transcript.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "system-audio-question-extractor",
            promptVersion: "system-audio-extractor-v1",
            providerKind: .openAICompatible,
            providerName: "Local Question Extractor",
            providerBaseURL: "",
            latencyMS: 0,
            isLocal: true,
            rawJSON: rawJSON,
            createdAt: createdAt,
            ingressIdentity: TranscriptQuestionIngressIdentity(
                recognitionTaskID: segment.recognitionTaskID ?? "segment:\(segment.id)",
                recognitionEventSequence: segment.recognitionEventSequence ?? 0,
                sourceSegmentID: segment.id,
                sourceStartUTF16: (segment.sourceTextStartUTF16 ?? 0) + extracted.sourceStartUTF16,
                sourceEndUTF16: (segment.sourceTextStartUTF16 ?? 0) + extracted.sourceEndUTF16,
                normalizedText: SemanticDuplicateKeyBuilder.key(for: extracted.text),
                eventTimestamp: segment.createdAt,
                isFinal: segment.recognitionIsFinal ?? (segment.asrFinalizationReason != "partial")
            )
        )
    }

    // internal for AppState extension access only
    func ignoredReasonCode(for intent: UtteranceIntent) -> String {
        switch intent {
        case .answerWorthyQuestion:
            return ""
        case .candidateStyleAnswer:
            return "candidateSpeech"
        case .duplicatePartial:
            return "duplicateSuppressed"
        case .smallTalk, .interviewerStatement, .unknown:
            return "lowConfidence"
        }
    }

    // internal for AppState extension access only
    func classifySystemAudioUtteranceIfNeeded(
        _ segment: TranscriptSegment,
        previousSegment: TranscriptSegment?
    ) -> UtteranceIntentClassification? {
        guard segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock else {
            lastQuestionClassificationMs = 0
            return nil
        }
        guard systemAudioCanUseQuestionIntent(segment) else {
            lastQuestionClassificationMs = 0
            return nil
        }

        let startedAt = Date()
        let classification = SystemAudioUtteranceClassifier.classify(
            text: segment.text,
            previousText: previousSegment?.text
        )
        lastQuestionClassificationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        return classification
    }

    // internal for AppState extension access only
    func systemAudioCanUseQuestionIntent(_ segment: TranscriptSegment) -> Bool {
        if segment.speaker == .interviewer {
            return true
        }
        return settings.audioCaptureMode == .systemAudioOnly && segment.source == .systemAudio
    }

    // internal for AppState extension access only
    func recordIgnoredSystemAudioUtterance(
        _ segment: TranscriptSegment,
        classification: UtteranceIntentClassification
    ) {
        let reason = "\(classification.intent.displayName): \(classification.reason)"
        lastIgnoredSystemAudioReason = reason
        lastTranscriptQuestionGenerationTrace.ignoredReason = reason
        lastDetectionSkipReason = reason
        lastDetectionSubmittedSegmentText = segment.text
        lastDetectionPromptSource = segment.source.rawValue
        lastDetectionPromptSpeaker = segment.speaker.rawValue
        lastDetectedQuestionSource = segment.source.rawValue
        lastDetectedQuestionSpeaker = segment.speaker.rawValue
        lastDetectionShouldTrigger = false
        lastDetectionQuestionComplete = false
        lastDetectionAnswerStrategy = ""
        lastQuestionDetectionResult = "Ignored system audio: \(reason)"

        switch classification.intent {
        case .candidateStyleAnswer:
            ignoredSystemAudioAnswerLikeCount += 1
        case .smallTalk, .interviewerStatement, .unknown:
            ignoredSmallTalkCount += 1
        case .duplicatePartial:
            duplicateSuppressionCount += 1
            currentGenerationTelemetry.duplicateSuppressionCount = duplicateSuppressionCount
        case .answerWorthyQuestion:
            break
        }
        if !showImmediateFallbackForActiveGenerationIfNeeded(reason: reason),
           !visibleAnswerExists,
           let questionID = lastDetectedQuestion?.id {
            pendingIgnoredSystemAudioFallback = (questionID: questionID, reason: reason)
        }
        updateActiveTaskSummary()
    }

    // internal for AppState extension access only
    func maybeRunAutomaticDetection(triggeringSegment: TranscriptSegment) {
        detectionDebounceTask?.cancel()
        detectionDebounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.detectionDebounceSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.beginAutomaticDetection(triggeringSegment: triggeringSegment)
        }
        liveState = .listening
    }

    private func beginAutomaticDetection(triggeringSegment: TranscriptSegment) {
        let now = Date()
        lastDetectionAt = now
        let detectionTranscript = detectionTranscriptText(for: triggeringSegment)
        let suggestionTranscript = recentTranscriptText()
        guard !detectionTranscript.isEmpty, let session = currentSession else {
            liveState = .listening
            return
        }

        activeDetectionTask?.cancel()
        activeDetectionTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomaticDetection(
                session: session,
                detectionTranscript: detectionTranscript,
                suggestionTranscript: suggestionTranscript,
                triggeringSegmentID: triggeringSegment.id
            )
        }
    }

    // MARK: - Provider Detection

    // TODO: Move retry/detection coupling into GenerationCoordinator or QuestionDetectionCoordinator in Phase 2.
    /// Runs provider-backed question detection for one transcript snapshot.
    ///
    /// `detectionTranscript` may include recent context for classification, but
    /// any question accepted for generation must become a single current
    /// question. Previous questions are background only and must not replace the
    /// primary question sent to generation.
    func runAutomaticDetection(
        session: InterviewSession,
        detectionTranscript: String,
        suggestionTranscript: String,
        triggeringSegmentID: String?
    ) async {
        do {
            print("[AppState] Automatic question detection running on transcript context: \"\(detectionTranscript)\" | triggeringSegmentID = \(triggeringSegmentID ?? "nil")")
            liveState = .detectingQuestion

            // Set input segment submitted to question detection
            let triggeringSegment = transcriptSegments.first(where: { $0.id == triggeringSegmentID })
            self.lastDetectionSubmittedSegmentText = triggeringSegment?.text ?? "Unknown segment text"
            self.lastDetectionPromptSource = triggeringSegment?.source.rawValue ?? "Unknown source"
            self.lastDetectionPromptSpeaker = triggeringSegment?.speaker.rawValue ?? "Unknown speaker"
            self.lastDetectedQuestionSource = triggeringSegment?.source.rawValue ?? ""
            self.lastDetectedQuestionSpeaker = triggeringSegment?.speaker.rawValue ?? ""

            let detection = try await questionDetectionService.detect(
                transcriptContext: detectionTranscript,
                sessionID: session.id,
                transcriptSegmentID: triggeringSegmentID,
                model: activeRealtimeProvider?.model
            )
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionProvider = detection.response.providerName
            self.lastQuestionDetectionModel = detection.response.modelName
            updateDiagnostics {
                $0.lastDetectedQuestionJSON = detection.question.rawJSON
                $0.lastAPILatencyMS = detection.response.latencyMS
                $0.lastProviderName = detection.response.providerName
                $0.lastProviderModel = detection.response.modelName
                $0.apiCallCount += 1
            }

            var question = detection.question
            if let triggeringSegment,
               processLocallySplitProviderQuestionIfNeeded(
                   question,
                   segment: triggeringSegment,
                   session: session,
                   suggestionTranscript: suggestionTranscript
               ) {
                return
            }

            if question.shouldTrigger {
                guard let guarded = runtimeAcceptedQuestionForGeneration(
                    question,
                    triggeringSegmentID: triggeringSegmentID
                ) else {
                    if self.stopReason == nil && self.anyCaptureRunning {
                        liveState = .listening
                        currentCaptureRuntimeState = .listening
                    }
                    return
                }
                question = guarded
            }

            saveDetectedQuestionInBackground(question)
            lastDetectedQuestion = question
            if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                lastTranscriptQuestionGenerationTrace.detectedQuestionID = question.id
                lastTranscriptQuestionGenerationTrace.questionConfidence = question.confidence
                lastTranscriptQuestionGenerationTrace.questionIntent = question.intent.rawValue
                lastTranscriptQuestionGenerationTrace.providerStatus = detection.response.providerName
            }

            // Set structured question detection diagnostics
            self.lastDetectedQuestionText = question.questionText
            self.lastDetectionConfidence = question.confidence
            self.lastQuestionConfidence = question.confidence
            self.lastDetectionShouldTrigger = question.shouldTrigger
            self.lastDetectionReason = question.intent.displayName
            self.lastDetectionRawJSON = question.rawJSON ?? ""
            self.lastDetectionSkipReason = ""
            self.lastDetectionQuestionComplete = question.questionComplete
            self.lastDetectionAnswerStrategy = question.answerStrategy.displayName
            self.lastQuestionDetectionResult = "Question complete: \(question.questionComplete) | Text: \"\(question.questionText)\" | Confidence: \(Int(question.confidence * 100))%"

            let isFirstAnswerWorthyQuestion = detectedQuestionsInSessionCount == 0
            // Duplicate suppression must not become a global "generation is
            // already busy" state. If a question is suppressed, the UI must end
            // in a visible duplicate notice or listening state, not loading.
            let duplicateQuestion = !isFirstAnswerWorthyQuestion && isRecentDuplicateAutoQuestion(
                question.questionText,
                transcriptSegmentID: question.transcriptSegmentID
            )

            if question.shouldTrigger,
               question.questionComplete,
               question.confidence >= autoSuggestionConfidenceThreshold,
               !duplicateQuestion {
                rememberAutoQuestion(
                    question.questionText,
                    transcriptSegmentID: question.transcriptSegmentID
                )
                lastAutoSuggestionAt = Date()
                detectedQuestionsInSessionCount += 1
                if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                    lastTranscriptQuestionGenerationTrace.generationTriggered = true
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
                    lastTranscriptQuestionGenerationTrace.firstQuestionSuppressedReason = ""
                }
                currentFirstQuestionSuppressedReason = ""
                recordLifecycleTrace(
                    "question.accepted",
                    sessionID: session.id,
                    questionID: question.id,
                    text: question.questionText
                )
                startAutoSuggestionGeneration(for: question, session: session, transcript: suggestionTranscript)
            } else {
                var skipMsg = ""
                if !question.shouldTrigger {
                    skipMsg = "Question shouldTrigger is false"
                } else if !question.questionComplete {
                    skipMsg = "Question is not complete"
                } else if question.confidence < autoSuggestionConfidenceThreshold {
                    skipMsg = "Confidence (\(Int(question.confidence * 100))%) below threshold (\(Int(autoSuggestionConfidenceThreshold * 100))%)"
                } else if duplicateQuestion {
                    skipMsg = "Duplicate of recently answered question"
                    recordDuplicateSuppression()
                    recordTranscriptRuntimeEvent(.duplicatePartialSuppressed(
                        sessionID: session.id,
                        question: question.questionText,
                        reason: .duplicateSuppressed,
                        timestamp: Date()
                    ))
                    if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                        lastTranscriptQuestionGenerationTrace.duplicateSuppressed = true
                    }
                } else {
                    skipMsg = "Not qualified for suggestion generation"
                }
                if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                    let blockedReason = generationBlockedReason(
                        question: question,
                        duplicateQuestion: duplicateQuestion
                    )
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = blockedReason
                    if isFirstAnswerWorthyQuestion, question.shouldTrigger, question.questionComplete {
                        lastTranscriptQuestionGenerationTrace.firstQuestionSuppressedReason = blockedReason
                        currentFirstQuestionSuppressedReason = blockedReason
                    }
                }
                let interviewerAudioSegment = triggeringSegment?.speaker == .interviewer &&
                    (triggeringSegment?.source == .systemAudio || triggeringSegment?.source == .processAudio || triggeringSegment?.source == .mock)
                if !question.shouldTrigger, interviewerAudioSegment {
                    ignoredSmallTalkCount += 1
                }
                self.lastDetectionSkipReason = skipMsg

                if possibleQuestionConfidenceRange.contains(question.confidence) {
                    possibleQuestion = question
                }
                if self.stopReason == nil && self.anyCaptureRunning {
                    liveState = .listening
                    currentCaptureRuntimeState = .listening
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionResult = "Detection failed: \(error.localizedDescription)"
            self.lastDetectionSkipReason = "LLM/Detection API call error: \(error.localizedDescription)"
            if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                lastTranscriptQuestionGenerationTrace.generationBlockedReason = "deepSeekUnavailable"
                lastTranscriptQuestionGenerationTrace.providerStatus = error.localizedDescription
            }
            if self.stopReason == nil && self.anyCaptureRunning {
                liveState = .listening
                currentCaptureRuntimeState = .listening
            }

            if self.lastFailedTaskType != .suggestionGeneration {
                self.lastFailedTaskType = .questionDetection
                self.lastFailedQuestion = nil
                self.lastFailedTranscriptContext = detectionTranscript
                self.lastFailedCVJDContext = nil
                self.lastFailedProviderConfig = activeRealtimeProvider
            }

            showError(userFacing(error))
        }
    }

    // MARK: - Split Provider Output

    private func processLocallySplitProviderQuestionIfNeeded(
        _ question: DetectedQuestion,
        segment: TranscriptSegment,
        session: InterviewSession,
        suggestionTranscript: String
    ) -> Bool {
        guard segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock else {
            return false
        }

        let extractedQuestions = SystemAudioQuestionExtractor.extract(from: question.questionText)
        guard !extractedQuestions.isEmpty else { return false }

        let providerQuestion = normalizedBindingText(question.questionText)
        let extractedQuestion = normalizedBindingText(extractedQuestions.map(\.text).joined(separator: " "))
        let shouldReplaceProviderQuestion = extractedQuestions.count > 1 || extractedQuestion != providerQuestion
        guard shouldReplaceProviderQuestion else { return false }

        processExtractedSystemAudioQuestions(
            extractedQuestions,
            segment: segment,
            session: session,
            suggestionTranscript: suggestionTranscript
        )
        return true
    }

    private func generationBlockedReason(question: DetectedQuestion, duplicateQuestion: Bool) -> String {
        if !question.shouldTrigger {
            return "lowConfidence"
        }
        if !question.questionComplete {
            return "lowConfidence"
        }
        if question.confidence < autoSuggestionConfidenceThreshold {
            return "lowConfidence"
        }
        if duplicateQuestion {
            return "duplicateSuppressed"
        }
        return "unknown"
    }

    // MARK: - Generation Trigger

    /// Starts suggestion generation for an accepted interviewer question.
    ///
    /// This method is only the bridge from detection into generation. Task
    /// ownership, active generation guards, fallback watchdogs, and visible
    /// answer mutation remain in AppState+Generation/AppState.generateSuggestion.
    private func startAutoSuggestionGeneration(
        for question: DetectedQuestion,
        session: InterviewSession,
        transcript: String
    ) {
        guard let acceptedQuestion = runtimeAcceptedQuestionForGeneration(
            question,
            triggeringSegmentID: question.transcriptSegmentID
        ) else {
            return
        }
        pendingAcceptedQuestions.removeAll()
        launchAutoSuggestionGeneration(for: acceptedQuestion, session: session, transcript: transcript)
    }

    // internal for AppState extension access only
    func processNextQueuedAutoQuestionIfIdle() {
        let sessionID = currentSession?.id ?? pendingAcceptedQuestions.first?.session.id ?? ""
        recordTranscriptRuntimeEvent(.queueDrainRequested(
            sessionID: sessionID,
            depth: pendingAcceptedQuestions.count,
            reason: "process_next_if_idle",
            timestamp: Date()
        ))
        if let blockReason = queueDrainBlockReasonForCurrentState() {
            recordTranscriptRuntimeEvent(.queueDrainBlocked(
                sessionID: sessionID,
                depth: pendingAcceptedQuestions.count,
                reason: blockReason,
                timestamp: Date()
            ))
            return
        }
        guard !pendingAcceptedQuestions.isEmpty else {
            recordTranscriptRuntimeEvent(.queueDrainBlocked(
                sessionID: sessionID,
                depth: 0,
                reason: "blocked_empty_queue",
                timestamp: Date()
            ))
            return
        }
        let pending = pendingAcceptedQuestions.removeFirst()
        recordTranscriptRuntimeEvent(.queueDepthChanged(
            sessionID: pending.session.id,
            depth: pendingAcceptedQuestions.count,
            reason: "dequeued",
            timestamp: Date()
        ))
        recordTranscriptRuntimeEvent(.questionDequeued(
            sessionID: pending.session.id,
            questionID: pending.question.id,
            question: pending.question.questionText,
            duplicateKey: pending.duplicateKey,
            timestamp: Date()
        ))
        lastDetectedQuestion = pending.question
        lastDetectedQuestionText = pending.question.questionText
        lastAutoSuggestionAt = Date()
        launchAutoSuggestionGeneration(for: pending.question, session: pending.session, transcript: pending.transcript)
    }

    private func shouldQueueAutoSuggestionGeneration(for question: DetectedQuestion) -> Bool {
        guard shouldQueueAutoSuggestionGenerationForCurrentState() else { return false }
        return activeQuestionID != question.id
    }

    private func shouldQueueAutoSuggestionGenerationForCurrentState() -> Bool {
        queueDrainBlockReasonForCurrentState() != nil
    }

    private func queueDrainBlockReasonForCurrentState() -> String? {
        if autoSuggestionLaunchPending {
            return "blocked_pending_generation_launch"
        }
        if suggestionGenerationStarted || isStreamingSayFirst || providerStreamActive || fallbackWatchdogActive {
            return "blocked_active_generation"
        }
        if isExpandingSuggestionCard || stageBTaskActive {
            return visibleAnswerExists ? "blocked_stage_b_pending" : "blocked_no_safe_visible_answer"
        }
        guard activeGenerationController != nil else { return nil }
        if let activeGenerationID,
           generationUIState.generationID == activeGenerationID,
           !generationUIState.isTerminal {
            return visibleAnswerExists ? "blocked_stage_b_pending" : "blocked_no_safe_visible_answer"
        }
        return nil
    }

    private func queueAcceptedAutoQuestion(
        _ question: DetectedQuestion,
        session: InterviewSession,
        transcript: String,
        drainImmediately: Bool = true
    ) {
        let duplicateKey = SemanticDuplicateKeyBuilder.key(for: question.questionText)
        if pendingAcceptedQuestions.contains(where: { $0.duplicateKey == duplicateKey }) {
            recordDuplicateSuppression()
            recordTranscriptRuntimeEvent(.generationRejected(
                sessionID: session.id,
                question: question.questionText,
                reason: .duplicateSuppressed,
                timestamp: Date()
            ))
            recordTranscriptRuntimeEvent(.duplicatePartialSuppressed(
                sessionID: session.id,
                question: question.questionText,
                reason: .duplicateSuppressed,
                timestamp: Date()
            ))
            return
        }
        let pending = PendingAcceptedQuestion(
            question: question,
            session: session,
            transcript: transcript,
            canonicalQuestion: QuestionCanonicalizer.canonicalize(question.questionText),
            intent: AnswerRelevancePolicy.intent(for: question.questionText),
            promptPrimaryQuestion: question.questionText,
            duplicateKey: duplicateKey,
            queuedAt: Date()
        )
        pendingAcceptedQuestions.append(pending)
        recordTranscriptRuntimeEvent(.questionQueued(
            sessionID: session.id,
            questionID: question.id,
            question: question.questionText,
            duplicateKey: duplicateKey,
            timestamp: pending.queuedAt
        ))
        recordTranscriptRuntimeEvent(.queueDepthChanged(
            sessionID: session.id,
            depth: pendingAcceptedQuestions.count,
            reason: "queued",
            timestamp: Date()
        ))
        recordTranscriptRuntimeEvent(.generationSkippedBecauseActive(
            sessionID: session.id,
            questionID: question.id,
            generationID: activeGenerationID,
            question: question.questionText,
            timestamp: Date()
        ))
        lastTranscriptQuestionGenerationTrace.generationTriggered = false
        lastTranscriptQuestionGenerationTrace.generationBlockedReason = "generationActiveQueued"
        if drainImmediately {
            finishActiveVisibleGenerationBeforeDrainingQueueIfNeeded(session: session)
        }
    }

    private func finishActiveVisibleGenerationBeforeDrainingQueueIfNeeded(session: InterviewSession) {
        recordTranscriptRuntimeEvent(.queueDrainRequested(
            sessionID: session.id,
            depth: pendingAcceptedQuestions.count,
            reason: "visible_answer_queue_check",
            timestamp: Date()
        ))
        guard !pendingAcceptedQuestions.isEmpty,
              let controller = activeGenerationController,
              visibleAnswerExists,
              let current = currentSuggestion else {
            let reason: String
            if pendingAcceptedQuestions.isEmpty {
                reason = "blocked_empty_queue"
            } else if autoSuggestionLaunchPending {
                reason = "blocked_pending_generation_launch"
            } else if activeGenerationController == nil {
                reason = currentGenerationID == nil ? "blocked_no_safe_visible_answer" : "blocked_stale_generation_flags"
            } else if !visibleAnswerExists {
                reason = "blocked_no_safe_visible_answer"
            } else {
                reason = "blocked_active_generation"
            }
            recordTranscriptRuntimeEvent(.queueDrainBlocked(
                sessionID: session.id,
                depth: pendingAcceptedQuestions.count,
                reason: reason,
                timestamp: Date()
            ))
            return
        }
        let activeQuestionText = current.questionText ??
            current.promptPrimaryQuestion ??
            current.promptQuestionText ??
            controller.questionTextSnapshot
        guard visibleCardMatchesGeneration(
            card: current,
            generationID: controller.generationID,
            detectedQuestionID: controller.questionID,
            promptPrimaryQuestion: activeQuestionText
        ) else {
            recordTranscriptRuntimeEvent(.queueDrainBlocked(
                sessionID: session.id,
                depth: pendingAcceptedQuestions.count,
                reason: "blocked_stale_generation_flags",
                timestamp: Date()
            ))
            return
        }
        let acceptance = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: activeQuestionText, isFinal: true)
        guard let candidate = acceptance.candidate else {
            recordTranscriptRuntimeEvent(.queueDrainBlocked(
                sessionID: session.id,
                depth: pendingAcceptedQuestions.count,
                reason: "blocked_no_safe_visible_answer",
                timestamp: Date()
            ))
            return
        }

        let activeQuestion = DetectedQuestion(
            id: controller.questionID ?? current.questionID ?? UUID().uuidString,
            sessionID: current.sessionID,
            transcriptSegmentID: current.transcriptSegmentID,
            questionText: candidate.text,
            intent: candidate.intent,
            answerStrategy: candidate.answerStrategy,
            confidence: candidate.confidence,
            reason: "Visible first answer completed before queued question.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: current.modelName,
            promptVersion: current.promptVersion,
            providerKind: current.providerKind,
            providerName: current.providerName,
            providerBaseURL: current.providerBaseURL,
            latencyMS: current.latencyMS,
            isLocal: current.isLocal,
            rawJSON: current.rawJSON,
            createdAt: current.createdAt
        )
        _ = finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
            generationID: controller.generationID,
            question: activeQuestion,
            session: session,
            requestStart: controller.startedAt,
            triggerPath: controller.triggerPath
        )
    }

    private func launchAutoSuggestionGeneration(
        for acceptedQuestion: DetectedQuestion,
        session: InterviewSession,
        transcript: String
    ) {
        activeAITask?.cancel()
        let launchID = UUID().uuidString
        autoSuggestionLaunchID = launchID
        autoSuggestionLaunchPending = true
        activeAITask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.autoSuggestionLaunchID == launchID {
                    self.autoSuggestionLaunchPending = false
                    self.autoSuggestionLaunchID = nil
                }
            }
            do {
                try await self.generateSuggestion(for: acceptedQuestion, session: session, transcript: transcript, autoGenerated: true)
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacing(error)
                if self.stopReason == nil && self.anyCaptureRunning {
                    self.liveState = .listening
                    self.currentCaptureRuntimeState = .listening
                }
                self.lastFailedTaskType = .suggestionGeneration
                self.lastFailedQuestion = acceptedQuestion
                self.lastFailedTranscriptContext = transcript
                self.lastFailedCVJDContext = nil
                self.lastFailedProviderConfig = self.activeRealtimeProvider
                self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(message)")
                self.showError(message)
            }
        }
    }

    private func runtimeAcceptedQuestionForGeneration(
        _ question: DetectedQuestion,
        triggeringSegmentID: String?
    ) -> DetectedQuestion? {
        guard let accepted = question.runtimeAcceptedForGeneration() else {
            let result = QuestionRuntimeAcceptanceGuard.validateDetectedQuestionForGeneration(question)
            recordRuntimeQuestionRejected(question, result: result, triggeringSegmentID: triggeringSegmentID)
            if isRecentDuplicateAutoQuestion(
                question.questionText,
                transcriptSegmentID: question.transcriptSegmentID
            ) ||
                result.reason == .incompleteFragment,
               SemanticDuplicateKeyBuilder.areDuplicates(lastAcceptedQuestionText, question.questionText) {
                recordDuplicateSuppression()
                recordTranscriptRuntimeEvent(.duplicatePartialSuppressed(
                    sessionID: question.sessionID,
                    question: question.questionText,
                    reason: result.reason ?? .duplicateSuppressed,
                    timestamp: Date()
                ))
            }
            return nil
        }
        if let candidate = accepted.result.candidate {
            recordTranscriptRuntimeEvent(.questionAccepted(
                sessionID: question.sessionID,
                candidate: candidate,
                timestamp: Date()
            ))
            recordTranscriptRuntimeEvent(.utteranceBufferConsumed(
                sessionID: question.sessionID,
                questionID: accepted.question.id,
                question: candidate.text,
                timestamp: Date()
            ))
            recordTranscriptRuntimeEvent(.utteranceBufferReset(
                sessionID: question.sessionID,
                questionID: accepted.question.id,
                question: candidate.text,
                timestamp: Date()
            ))
        }
        return accepted.question
    }

    private func recordRuntimeQuestionRejected(
        _ question: DetectedQuestion,
        result: QuestionRuntimeAcceptanceResult,
        triggeringSegmentID: String?
    ) {
        let reason = result.reason?.rawValue ?? "rejected_by_question_candidate_pipeline"
        lastDetectedQuestionText = question.questionText
        lastDetectionConfidence = min(question.confidence, 0.5)
        lastQuestionConfidence = min(question.confidence, 0.5)
        lastDetectionShouldTrigger = false
        lastDetectionReason = reason
        lastDetectionSkipReason = reason
        lastDetectionQuestionComplete = false
        lastDetectionAnswerStrategy = AnswerStrategy.wait.displayName
        lastQuestionDetectionResult = "Runtime question guard rejected: \(result.diagnostic)"
        lastTranscriptQuestionGenerationTrace.generationTriggered = false
        lastTranscriptQuestionGenerationTrace.generationBlockedReason = reason
        lastTranscriptQuestionGenerationTrace.ignoredReason = result.diagnostic
        recordTranscriptRuntimeEvent(.questionRejected(
            sessionID: question.sessionID,
            text: question.questionText,
            reason: result.reason ?? .pipelineRejected,
            timestamp: Date()
        ))
        if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
            lastTranscriptQuestionGenerationTrace.detectedQuestionID = question.id
            lastTranscriptQuestionGenerationTrace.questionConfidence = min(question.confidence, 0.5)
            lastTranscriptQuestionGenerationTrace.questionIntent = question.intent.rawValue
        }
        updateDiagnostics {
            $0.lastDetectedQuestionJSON = question.rawJSON
        }
    }

    // internal for AppState extension access only
    func recentTranscriptText() -> String {
        let text = transcriptSegments
            .suffix(18)
            .map { "\(transcriptSpeakerLabel(for: $0)): \($0.text)" }
            .joined(separator: "\n")
        return ContextBudgeter.limitWords(text, maxWords: 800)
    }

    private func detectionTranscriptText(for segment: TranscriptSegment) -> String {
        let boundedText = ContextBudgeter.limitWords(segment.text, maxWords: 160)
        return "\(transcriptSpeakerLabel(for: segment)): \(boundedText)"
    }

    private func transcriptSpeakerLabel(for segment: TranscriptSegment) -> String {
        if settings.audioCaptureMode == .systemAudioOnly,
           segment.source == .systemAudio,
           SystemAudioUtteranceClassifier.classify(text: segment.text).intent == .answerWorthyQuestion {
            return SpeakerRole.interviewer.displayName
        }
        return segment.speaker.displayName
    }

    private func isOutsideAutoSuggestionCooldown() -> Bool {
        guard let lastAutoSuggestionAt else { return true }
        return Date().timeIntervalSince(lastAutoSuggestionAt) >= autoSuggestionCooldownSeconds
    }

    // internal for AppState extension access only
    func isDuplicateAutoQuestion(_ questionText: String) -> Bool {
        isDuplicateAutoQuestion(questionText, transcriptSegmentID: nil, now: Date())
    }

    // internal for deterministic duplicate-origin tests and live acceptance.
    func isDuplicateAutoQuestion(
        _ questionText: String,
        transcriptSegmentID: String?,
        now: Date
    ) -> Bool {
        let duplicate = isRecentDuplicateAutoQuestion(
            questionText,
            transcriptSegmentID: transcriptSegmentID,
            now: now
        )
        if duplicate {
            recordDuplicateSuppression()
        } else {
            rememberAutoQuestion(
                questionText,
                transcriptSegmentID: transcriptSegmentID,
                now: now
            )
        }
        return duplicate
    }

    private func isRecentDuplicateAutoQuestion(
        _ questionText: String,
        transcriptSegmentID: String? = nil,
        now: Date = Date()
    ) -> Bool {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return false }

        if let transcriptSegmentID,
           acceptedQuestionSegmentIDs[normalized] == transcriptSegmentID {
            return true
        }
        if let transcriptSegmentID {
            for (fingerprint, acceptedSegmentID) in acceptedQuestionSegmentIDs
            where acceptedSegmentID == transcriptSegmentID && isNearDuplicateQuestion(normalized, fingerprint) {
                return true
            }
        }

        pruneRecentQuestionTimestamps(now: now)

        if let lastTime = recentQuestionTimestamps[normalized],
           now.timeIntervalSince(lastTime) <= autoQuestionDuplicateCooldownSeconds {
            return true
        }

        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) <= autoQuestionDuplicateCooldownSeconds {
                if isNearDuplicateQuestion(normalized, fingerprint) {
                    return true
                }
            }
        }

        return false
    }

    private func isNearDuplicateQuestion(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs {
            return true
        }

        let lhsWordCount = lhs.split(separator: " ").count
        let rhsWordCount = rhs.split(separator: " ").count
        guard lhsWordCount > 0, rhsWordCount > 0 else {
            return false
        }

        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count > rhs.count ? lhs : rhs
        guard longer.contains(shorter) else {
            return false
        }

        let wordRatio = Double(max(lhsWordCount, rhsWordCount)) / Double(min(lhsWordCount, rhsWordCount))
        if wordRatio <= 1.35 {
            return true
        }

        let remainder = longer
            .replacingOccurrences(of: shorter, with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return !containsQuestionStarter(remainder)
    }

    private func containsQuestionStarter(_ text: String) -> Bool {
        let padded = " \(text.lowercased()) "
        let starters = [
            " what ", " how ", " why ", " where ", " who ", " when ",
            " can you ", " could you ", " would you ", " should you ",
            " are you ", " do you ", " have you ", " is there ",
            " tell me ", " walk me ", " describe ", " explain "
        ]
        return starters.contains { padded.contains($0) }
    }

    private func rememberAutoQuestion(
        _ questionText: String,
        transcriptSegmentID: String? = nil,
        now: Date = Date()
    ) {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return }
        pruneRecentQuestionTimestamps(now: now)
        recentQuestionTimestamps[normalized] = now
        if let transcriptSegmentID, !transcriptSegmentID.isEmpty {
            acceptedQuestionSegmentIDs[normalized] = transcriptSegmentID
        }
    }

    private func pruneRecentQuestionTimestamps(now: Date) {
        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) > autoQuestionDuplicateCooldownSeconds {
                recentQuestionTimestamps.removeValue(forKey: fingerprint)
            }
        }
    }

    private func normalizedQuestion(_ text: String) -> String {
        SystemAudioQuestionExtractor.duplicateKey(for: text)
    }

    private func consumedReplaySource(
        _ question: DetectedQuestion,
        isCumulativeTranscript: Bool
    ) -> TranscriptQuestionIngressIdentity? {
        guard let ingress = question.ingressIdentity else { return nil }
        if let consumed = consumedQuestionOccurrences[ingress.occurrenceKey] {
            return consumed
        }
        guard isCumulativeTranscript else { return nil }
        if let consumed = consumedQuestionSourceSpans[ingress.sourceSpanKey] {
            return consumed
        }
        if let consumed = consumedQuestionAbsoluteSourceSpans[ingress.absoluteSourceSpanKey] {
            return consumed
        }
        return consumedQuestionAbsoluteSourceSpans.values.first {
            $0.normalizedText == ingress.normalizedText &&
                sourceSpanOverlapScore($0, ingress) >= 0.80
        }
    }

    private func isIntentionalQuestionRepeat(
        _ question: DetectedQuestion,
        replayedOccurrence: Bool
    ) -> Bool {
        guard !replayedOccurrence else { return false }
        return acceptedNormalizedQuestionKeys.contains(normalizedQuestion(question.questionText))
    }

    private func rememberConsumedTranscriptOccurrence(_ question: DetectedQuestion) {
        let normalized = normalizedQuestion(question.questionText)
        acceptedNormalizedQuestionKeys.insert(normalized)
        guard let ingress = question.ingressIdentity else { return }
        consumedQuestionOccurrenceKeys.insert(ingress.occurrenceKey)
        consumedQuestionOccurrences[ingress.occurrenceKey] = ingress
        consumedQuestionSourceSpanKeys.insert(ingress.sourceSpanKey)
        consumedQuestionSourceSpans[ingress.sourceSpanKey] = ingress
        consumedQuestionAbsoluteSourceSpans[ingress.absoluteSourceSpanKey] = ingress
    }

    private func sourceSpanOverlapScore(
        _ lhs: TranscriptQuestionIngressIdentity,
        _ rhs: TranscriptQuestionIngressIdentity
    ) -> Double {
        let overlapStart = max(lhs.sourceStartUTF16, rhs.sourceStartUTF16)
        let overlapEnd = min(lhs.sourceEndUTF16, rhs.sourceEndUTF16)
        let overlap = max(0, overlapEnd - overlapStart)
        let shortest = max(1, min(
            lhs.sourceEndUTF16 - lhs.sourceStartUTF16,
            rhs.sourceEndUTF16 - rhs.sourceStartUTF16
        ))
        return Double(overlap) / Double(shortest)
    }
}
