import Foundation
import Combine
import SwiftUI
import AppKit

extension AppState {
    func consumeSegments(from provider: TranscriptionProvider) {
        transcriptionTask = Task { [weak self] in
            for await segment in provider.segments {
                guard !Task.isCancelled else { return }
                await self?.handleTranscriptSegment(segment)
            }
        }
    }

    func handleTranscriptSegment(_ segment: TranscriptSegment) async {
        let ingestionStartedAt = Date()
        let previousSegment = transcriptSegments.first(where: { $0.id == segment.id })
        defer {
            lastTranscriptIngestionMs = Int(Date().timeIntervalSince(ingestionStartedAt) * 1000)
        }
        print("[AppState] Received segment: id = \(segment.id) | source = \(segment.source.rawValue) | speaker = \(segment.speaker.rawValue) | text = \"\(segment.text)\"")
        liveState = .transcribing
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
            let repository = sessionRepository
            markSQLiteOperation("Loading transcript session in background")
            Task.detached(priority: .utility) { [weak self] in
                let session = try? repository.session(id: segment.sessionID)
                await MainActor.run { [weak self] in
                    guard let self, self.currentSession == nil else { return }
                    self.currentSession = session
                    self.lastSQLiteOperation = session == nil ? "Transcript session not found" : "Loaded transcript session"
                }
            }
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
        let extractedSystemAudioQuestions = extractSystemAudioQuestionsIfNeeded(from: segment)
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

        // Background debounced RAG precompute
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

        // Echo/Leakage Protection sliding window update
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

        if shouldTriggerDetection,
           shouldUseExtractedSystemAudioQuestions(extractedSystemAudioQuestions, classification: systemAudioClassification),
           let session = currentSession {
            self.lastDetectionSkipReason = ""
            processExtractedSystemAudioQuestions(
                extractedSystemAudioQuestions,
                segment: segment,
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
        let repository = suggestionRepository
        markSQLiteOperation("Saving suggestion snapshot in background")
        Task.detached(priority: .utility) { [weak self] in
            do {
                try repository.saveSuggestionCard(card, retrievedChunks: chunks)
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Saved suggestion snapshot"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Suggestion snapshot save failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
