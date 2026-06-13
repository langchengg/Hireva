// Owns automatic interviewer-question detection and local system-audio
// segmentation.
// This extension may create DetectedQuestion records and decide whether to
// trigger generation. It must not own the generation lifecycle, provider calls,
// RAG scoring, or UI answer mutation.

import Foundation

extension AppState {
    // MARK: - Local System-Audio Extraction

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
        if extractedQuestions.count > 1 { return true }
        return classification?.intent != .answerWorthyQuestion
    }

    // internal for AppState extension access only
    func processExtractedSystemAudioQuestions(
        _ extractedQuestions: [ExtractedTranscriptQuestion],
        segment: TranscriptSegment,
        session: InterviewSession,
        suggestionTranscript: String
    ) {
        // One ASR segment can contain several interviewer questions. Persist all
        // accepted questions for session history, but bind the visible answer to
        // the latest clean question only.
        let baseDate = Date()
        let acceptedQuestions = extractedQuestions.enumerated().map { index, extracted in
            makeDetectedQuestion(
                from: extracted,
                sessionID: session.id,
                transcriptSegmentID: segment.id,
                createdAt: baseDate.addingTimeInterval(Double(index) / 1_000.0)
            )
        }
        guard let latestQuestion = acceptedQuestions.last else {
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "lowConfidence"
            lastTranscriptQuestionGenerationTrace.ignoredReason = "No extracted question passed local completeness checks"
            return
        }

        let wasFirstAnswerWorthyQuestion = detectedQuestionsInSessionCount == 0
        saveDetectedQuestionsInBackground(acceptedQuestions)

        detectedQuestionsInSessionCount += acceptedQuestions.count
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
        lastQuestionDetectionResult = "Extracted \(acceptedQuestions.count) questions from one transcript. Latest: \"\(latestQuestion.questionText)\""

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

        // Duplicate suppression is intentionally per accepted question. The
        // first answer-worthy question must never be suppressed by stale memory,
        // and a suppressed duplicate must show a terminal state instead of a
        // spinner.
        let duplicateQuestion = !wasFirstAnswerWorthyQuestion && isRecentDuplicateAutoQuestion(latestQuestion.questionText)
        if duplicateQuestion {
            recordDuplicateSuppression()
            lastTranscriptQuestionGenerationTrace.duplicateSuppressed = true
            lastTranscriptQuestionGenerationTrace.generationTriggered = false
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "duplicateSuppressed"
            if !visibleAnswerExists {
                showDuplicateQuestionNotice(for: latestQuestion, session: session)
            }
            return
        }

        rememberAutoQuestion(latestQuestion.questionText)
        lastAutoSuggestionAt = Date()
        lastTranscriptQuestionGenerationTrace.generationTriggered = true
        lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
        startAutoSuggestionGeneration(for: latestQuestion, session: session, transcript: suggestionTranscript)
    }

    private func makeDetectedQuestion(
        from extracted: ExtractedTranscriptQuestion,
        sessionID: String,
        transcriptSegmentID: String,
        createdAt: Date
    ) -> DetectedQuestion {
        let rawJSON = """
        {"should_trigger":true,"question_complete":true,"question_text":\(JSONParsing.jsonString(extracted.text)),"intent":"\(extracted.intent.rawValue)","answer_strategy":"\(extracted.answerStrategy.rawValue)","confidence":\(extracted.confidence),"reason":"Extracted from multi-question system audio transcript."}
        """
        return DetectedQuestion(
            id: UUID().uuidString,
            sessionID: sessionID,
            transcriptSegmentID: transcriptSegmentID,
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
            createdAt: createdAt
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

            let question = detection.question
            if let triggeringSegment,
               processLocallySplitProviderQuestionIfNeeded(
                   question,
                   segment: triggeringSegment,
                   session: session,
                   suggestionTranscript: suggestionTranscript
               ) {
                return
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
            let duplicateQuestion = !isFirstAnswerWorthyQuestion && isRecentDuplicateAutoQuestion(question.questionText)

            if question.shouldTrigger,
               question.questionComplete,
               question.confidence >= autoSuggestionConfidenceThreshold,
               !duplicateQuestion {
                rememberAutoQuestion(question.questionText)
                lastAutoSuggestionAt = Date()
                detectedQuestionsInSessionCount += 1
                if triggeringSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
                    lastTranscriptQuestionGenerationTrace.generationTriggered = true
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
                    lastTranscriptQuestionGenerationTrace.firstQuestionSuppressedReason = ""
                }
                currentFirstQuestionSuppressedReason = ""
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
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: true)
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacing(error)
                if self.stopReason == nil && self.anyCaptureRunning {
                    self.liveState = .listening
                    self.currentCaptureRuntimeState = .listening
                }
                self.lastFailedTaskType = .suggestionGeneration
                self.lastFailedQuestion = question
                self.lastFailedTranscriptContext = transcript
                self.lastFailedCVJDContext = nil
                self.lastFailedProviderConfig = self.activeRealtimeProvider
                self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(message)")
                self.showError(message)
            }
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
        let duplicate = isRecentDuplicateAutoQuestion(questionText)
        if duplicate {
            recordDuplicateSuppression()
        } else {
            rememberAutoQuestion(questionText)
        }
        return duplicate
    }

    private func isRecentDuplicateAutoQuestion(_ questionText: String) -> Bool {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return false }

        let now = Date()
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

    private func rememberAutoQuestion(_ questionText: String) {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return }
        let now = Date()
        pruneRecentQuestionTimestamps(now: now)
        recentQuestionTimestamps[normalized] = now
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
}
