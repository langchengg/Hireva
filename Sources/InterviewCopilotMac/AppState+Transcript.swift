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
        transcriptionTask = Task { [weak self] in
            for await segment in provider.segments {
                guard !Task.isCancelled else { return }
                await self?.handleTranscriptSegment(segment)
            }
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
        let previousSegment = transcriptSegments.first(where: { $0.id == segment.id })
        defer {
            lastTranscriptIngestionMs = Int(Date().timeIntervalSince(ingestionStartedAt) * 1000)
        }
        print("[AppState] Received segment: id = \(segment.id) | source = \(segment.source.rawValue) | speaker = \(segment.speaker.rawValue) | text = \"\(segment.text)\"")
        liveState = .transcribing
        recordASRTranscriptRuntimeEvent(for: segment)
        if segment.asrFinalizationReason != "partial" {
            partialUtteranceFinalizationTasks[segment.id]?.cancel()
            partialUtteranceFinalizationTasks[segment.id] = nil
        }
        lastTranscriptQuestionGenerationTrace = TranscriptQuestionGenerationTrace(
            transcriptSegmentID: segment.id,
            source: segment.source.rawValue,
            speaker: segment.speaker.rawValue,
            text: segment.text,
            isFinal: segment.asrFinalizationReason != "partial",
            textLength: segment.text.count,
            normalizedText: normalizeTraceText(segment.text),
            providerStatus: activeRealtimeProviderBadge,
            currentGenerationState: generationUIState.displayName,
            currentSuggestionExists: currentSuggestion != nil
        )
        
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
                precomputeDebounceTask?.cancel()
                let retrievalService = contextRetrievalService!
                precomputeDebounceTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 400_000_000) // 300-500ms debounce
                    } catch {
                        return
                    }
                    guard let self = self, !Task.isCancelled else { return }
                    
                    let precomputeIntent = AnswerRelevancePolicy.intent(for: segment.text)
                    let key = self.ragPrecomputeCacheKey(
                        segmentID: segment.id,
                        questionText: segment.text,
                        intent: precomputeIntent
                    )
                    do {
                        let (context, trace) = try await Task.detached(priority: .utility) {
                            try await retrievalService.retrieveContextWithTrace(
                                question: segment.text,
                                intent: .unclear,
                                maxCVWords: 240,
                                maxJDWords: 120
                            )
                        }.value
                        await MainActor.run {
                            self.precomputedRAGCache[key] = RAGPrecomputeCacheItem(
                                context: context,
                                trace: trace,
                                rawText: segment.text,
                                normalizedQuestionText: AnswerRelevancePolicy.normalizedQuestionText(for: segment.text),
                                questionIntent: precomputeIntent
                            )
                            print("[PrecomputeRAG] Cached RAG context for segmentID: \(segment.id) | key: \(key)")
                        }
                    } catch {
                        print("[PrecomputeRAG] Background RAG precompute failed: \(error)")
                    }
                }
            }
        }

        // Echo/leakage protection keeps interviewer audio that bleeds into the
        // microphone from being treated as candidate speech or as a new question.
        if segment.source == .systemAudio {
            recentSystemAudioRecords.append(RecentSystemAudioRecord(text: segment.text, timestamp: Date()))
            recentSystemAudioRecords.removeAll { Date().timeIntervalSince($0.timestamp) > 5.0 }
            
            // Set last system audio transcript
            self.lastSystemAudioTranscript = segment.text
        }

        var isEchoLeakage = false
        if segment.source == .microphone {
            recentSystemAudioRecords.removeAll { Date().timeIntervalSince($0.timestamp) > 5.0 }
            
            let micWords = Set(segment.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            if !micWords.isEmpty {
                for record in recentSystemAudioRecords {
                    let systemWords = Set(record.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                    let intersection = micWords.intersection(systemWords)
                    let union = micWords.union(systemWords)
                    if !union.isEmpty {
                        let similarity = Double(intersection.count) / Double(union.count)
                        if similarity >= 0.5 { // 50% Jaccard word overlap indicates interviewer echo leak
                            isEchoLeakage = true
                            print("[EchoProtection] Detected interviewer leakage in mic stream: \"\(segment.text)\" matches recent system: \"\(record.text)\" with similarity \(String(format: "%.2f", similarity)). Question detection bypassed.")
                            break
                        }
                    }
                }
            }
        }

        var shouldTriggerDetection = false
        var skipReason = ""
        
        if !settings.automaticQuestionDetectionEnabled {
            skipReason = "automatic question detection disabled in settings"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "autoDetectDisabled"
        } else if settings.manualOnlyMode {
            skipReason = "manual only mode enabled"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "captureModeDisabled"
        } else if isEchoLeakage {
            skipReason = "echo/leakage detected in mic stream"
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
        } else {
            switch segment.source {
            case .systemAudio:
                if settings.audioCaptureMode == .systemAudioOnly,
                   let systemAudioClassification,
                   systemAudioClassification.intent == .answerWorthyQuestion,
                   systemAudioClassification.confidence >= autoSuggestionConfidenceThreshold {
                    shouldTriggerDetection = true
                } else if settings.audioCaptureMode == .systemAudioOnly,
                          systemAudioClassification != nil {
                    shouldTriggerDetection = true
                } else if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                } else {
                    skipReason = "speaker is not interviewer (speaker: \(segment.speaker.rawValue))"
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
                }
            case .processAudio:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                } else {
                    skipReason = "speaker is not interviewer (speaker: \(segment.speaker.rawValue))"
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
                }
            case .mock:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                } else {
                    skipReason = "mock speaker is not interviewer"
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
                }
            case .microphone, .mixed:
                if !settings.allowQuestionDetectionFromMicrophoneOnly {
                    skipReason = "question detection from microphone is disabled (allowQuestionDetectionFromMicrophoneOnly = false)"
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = "captureModeDisabled"
                } else if segment.speaker != .interviewer && segment.speaker != .unknown {
                    skipReason = "speaker is candidate (speaker: \(segment.speaker.rawValue))"
                    lastTranscriptQuestionGenerationTrace.generationBlockedReason = "candidateSpeech"
                } else {
                    shouldTriggerDetection = true
                }
            }
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
            skipReason: skipReason
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
            print("[GatingLog] Auto detection deferred: \(reason) | segmentID: \(segment.id) | text: \"\(segment.text)\"")
            liveState = .listening
            return
        }

        if shouldTriggerDetection,
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
            print("[GatingLog] Auto detection deferred: \(reason) | segmentID: \(segment.id) | text: \"\(segment.text)\"")
            liveState = .listening
            return
        }

        if shouldTriggerDetection, isASRPartial {
            lastTranscriptQuestionGenerationTrace.acceptedFromPartial = true
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
            processExtractedSystemAudioQuestions(
                extractedSystemAudioQuestions,
                segment: questionExtractionSegment ?? segment,
                session: session,
                suggestionTranscript: recentTranscriptText()
            )
            liveState = .listening
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
        partialUtteranceFinalizationTasks[segment.id]?.cancel()

        let segmentID = segment.id
        let textSnapshot = segment.text
        let delayNanoseconds = UInt64(max(900, min(partialStabilityWindowMS, 1_500))) * 1_000_000
        partialUtteranceFinalizationTasks[segmentID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let stableSegment: TranscriptSegment? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                defer { self.partialUtteranceFinalizationTasks[segmentID] = nil }
                guard let current = self.transcriptSegments.first(where: { $0.id == segmentID }),
                      current.asrFinalizationReason == "partial",
                      current.text == textSnapshot else {
                    return nil
                }
                return TranscriptSegment(
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
            }

            guard let stableSegment else { return }
            await self?.handleTranscriptSegment(stableSegment)
        }
    }

    // MARK: - Background Persistence

    func saveTranscriptSegmentInBackground(_ segment: TranscriptSegment) {
        let repository = transcriptRepository
        markSQLiteOperation("Saving transcript segment in background")
        Task.detached(priority: .utility) { [weak self] in
            do {
                try repository.saveSegment(segment)
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Saved transcript segment"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Transcript save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func saveDetectedQuestionInBackground(_ question: DetectedQuestion) {
        let repository = suggestionRepository
        markSQLiteOperation("Saving detected question in background")
        Task.detached(priority: .utility) { [weak self] in
            do {
                try repository.saveDetectedQuestion(question)
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Saved detected question"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Detected question save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func saveDetectedQuestionsInBackground(_ questions: [DetectedQuestion]) {
        guard !questions.isEmpty else { return }
        let repository = suggestionRepository
        markSQLiteOperation("Saving extracted detected questions in background")
        Task.detached(priority: .utility) { [weak self] in
            do {
                for question in questions {
                    try repository.saveDetectedQuestion(question)
                }
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Saved extracted detected questions"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Extracted detected question save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func saveSuggestionSnapshotInBackground(_ card: SuggestionCard, chunks: [RetrievedChunk]) {
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
        guard claimSuggestionPersistence(sanitizedCard, generationID: sanitizedCard.generationID) else {
            return
        }
        let repository = suggestionRepository
        recordTranscriptRuntimeEvent(.persistenceStarted(
            sessionID: sanitizedCard.sessionID,
            questionID: sanitizedCard.detectedQuestionID,
            generationID: sanitizedCard.generationID,
            question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
            timestamp: Date()
        ))
        markSQLiteOperation("Saving suggestion snapshot in background")
        Task.detached(priority: .utility) { [weak self, sanitizedCard] in
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
                        self?.lastSQLiteOperation = "Suggestion snapshot save blocked: \(detachedGuard.reason?.rawValue ?? "rejected_pre_persistence_guard")"
                        self?.lastAlignmentError = detachedGuard.diagnostic
                        self?.recordTranscriptRuntimeEvent(.persistenceRejected(
                            sessionID: sanitizedCard.sessionID,
                            questionID: sanitizedCard.detectedQuestionID ?? sanitizedCard.questionID,
                            generationID: sanitizedCard.generationID,
                            question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
                            reason: self?.snapshotPersistenceTraceReason(for: detachedGuard) ?? "persistence_rejected_unknown",
                            timestamp: Date()
                        ))
                        if detachedGuard.diagnostic.localizedCaseInsensitiveContains("wrong project grounding") {
                            self?.recordTranscriptRuntimeEvent(.answerRejectedWrongProjectGrounding(
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
                try repository.saveSuggestionCard(detachedCard, retrievedChunks: chunks)
                await MainActor.run { [weak self, detachedCard] in
                    guard let self else { return }
                    self.lastSQLiteOperation = "Saved suggestion snapshot"
                    self.refreshLiveSuggestionHistory(
                        sessionID: detachedCard.sessionID,
                        latestQuestion: detachedCard.questionText ?? detachedCard.promptPrimaryQuestion ?? ""
                    )
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
                    self.lastSQLiteOperation = "Suggestion snapshot save failed: \(error.localizedDescription)"
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
