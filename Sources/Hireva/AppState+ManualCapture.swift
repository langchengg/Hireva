// Owns the push-to-ask/manual capture workflow.
// Manual capture intentionally stops continuous pipelines before recording a
// focused question. It must not change continuous audio mode routing, automatic
// detection rules, or provider/keychain behavior.

import Foundation

extension AppState {
// MARK: - Manual Capture Push-to-Ask Controls

/// Starts a bounded manual recording session for one question.
///
/// This path is separate from live interview listening: it explicitly stops
/// continuous capture first, then records and transcribes a single prompt before
/// handing it to generation.
@MainActor
func startManualCapture() {
    guard !isActionLoading(ActionID.manualRecord) else { return }
    guard onboardingComplete else {
        let message = liveBlockedReason ?? "Run the readiness check before recording a question."
        failAction(ActionID.manualRecord, title: "Setup incomplete", message: message)
        showError(message)
        return
    }
    beginAction(ActionID.manualRecord, title: "Preparing capture", message: "Checking permissions and preparing the recorder...")
    
    // Prevent pipeline conflicts
    stopAllContinuousPipelines(reason: .userRequested)
    manualCaptureRevision += 1
    let captureRevision = manualCaptureRevision
    
    // Discard any previous state
    self.manualCaptureTranscript = ""
    self.manualCaptureSuggestion = nil
    self.manualCaptureError = nil
    self.manualCaptureBufferCount = 0
    self.manualCaptureLastBufferTimestamp = nil
    self.manualCaptureSource = settings.manualCaptureSource.rawValue
    
    let source = settings.manualCaptureSource
    
    Task {
        do {
            self.manualCaptureState = .waitingForPermission
            
            if source == .systemAudio {
                // Check Screen Capture Preflight & Probe access
                let probeResult = await ScreenSystemAudioPermissionProbe.shared.probe()
                guard self.manualCaptureRevision == captureRevision else { return }
                let state = determineProbeState(result: probeResult)
                self.systemAudioProbeResult = probeResult
                self.systemAudioPermissionState = state
                
                guard state == .granted else {
                    let message = "System audio permission is required to capture interviewer audio."
                    self.manualCaptureState = .error(message)
                    self.failAction(ActionID.manualRecord, title: "Permission needed", message: message)
                    return
                }
            } else {
                // Microphone permission required
                let micStatus = await permissionService.requestMicrophonePermission()
                guard self.manualCaptureRevision == captureRevision else { return }
                refreshPermissions()
                guard micStatus == .authorized else {
                    let message = "Microphone permission is required to record speech."
                    self.manualCaptureState = .error(message)
                    self.failAction(ActionID.manualRecord, title: "Permission needed", message: message)
                    return
                }
                
            }
            // This bounded manual adapter uses Apple Speech for either source;
            // recognition permission is separate from microphone access.
            let speechStatus = await permissionService.requestSpeechRecognition()
            guard self.manualCaptureRevision == captureRevision else { return }
            refreshPermissions()
            guard speechStatus == .granted else {
                self.manualCaptureState = .error("Speech Recognition permission is required for transcription.")
                self.failAction(ActionID.manualRecord, title: "Permission needed", message: "Speech Recognition permission is required for transcription.")
                return
            }
            
            self.manualCaptureState = .recording
            self.completeAction(ActionID.manualRecord, title: "Recording question", message: "Audio capture is active. Stop when the question is complete.")
            
            // Initialize transcription task in parallel with capture for real-time partial feedback
            try await ManualQuestionTranscriptionService.shared.startTranscription(
                onPartialResult: { [weak self] partialText in
                    guard let self = self else { return }
                    Task { @MainActor in
                        guard self.manualCaptureRevision == captureRevision, self.manualCaptureState == .recording || self.manualCaptureState == .transcribing else { return }
                        self.manualCaptureTranscript = partialText
                    }
                },
                onFinalResult: { [weak self] finalText in
                    guard let self = self else { return }
                    Task { @MainActor in
                        guard self.manualCaptureRevision == captureRevision, self.manualCaptureState == .recording || self.manualCaptureState == .transcribing else { return }
                        self.manualCaptureTranscript = finalText
                    }
                },
                onError: { [weak self] err in
                    guard let self = self else { return }
                    Task { @MainActor in
                        guard self.manualCaptureRevision == captureRevision, self.manualCaptureState == .recording || self.manualCaptureState == .transcribing else { return }
                        self.manualCaptureState = .error(err)
                    }
                }
            )
            guard self.manualCaptureRevision == captureRevision else { return }
            
            try await ManualQuestionCaptureService.shared.startCapture(
                source: source,
                maxDuration: settings.maxManualCaptureSeconds
            ) { [weak self] in
                guard let self = self else { return }
                // Max duration reached handler
                Task { @MainActor in
                    guard self.manualCaptureRevision == captureRevision else { return }
                    self.stopAndTranscribeManualCapture(maxDurationReached: true)
                }
            }
        } catch {
            guard self.manualCaptureRevision == captureRevision else { return }
            self.manualCaptureState = .error(error.localizedDescription)
            self.failAction(ActionID.manualRecord, title: "Capture failed", message: error.localizedDescription)
        }
    }
}

@MainActor
func stopAndTranscribeManualCapture(maxDurationReached: Bool = false) {
    guard self.manualCaptureState == .recording else { return }
    guard !isActionLoading(ActionID.manualStopTranscribe) else { return }
    beginAction(ActionID.manualStopTranscribe, title: "Transcribing", message: "Stopping audio and finalizing the transcript...")
    
    self.manualCaptureState = .stopping
    
    // Cache buffer metrics before stopping stream clears capturedBuffers array
    self.manualCaptureBufferCount = ManualQuestionCaptureService.shared.capturedBufferCount
    self.manualCaptureLastBufferTimestamp = ManualQuestionCaptureService.shared.lastBufferTimestamp
    self.manualCaptureSource = settings.manualCaptureSource.rawValue
    
    // Stop capturing audio
    let buffers = ManualQuestionCaptureService.shared.stopCaptureAndReturnBuffers()
    
    self.manualCaptureState = .transcribing
    let captureRevision = manualCaptureRevision
    
    Task {
        do {
            if maxDurationReached {
                self.manualCaptureError = "Max recording duration reached"
            }
            
            // Feed the remaining buffers to transcription just in case
            for buffer in buffers {
                ManualQuestionTranscriptionService.shared.appendBuffer(buffer)
            }
            
            // End Speech audio and await final transcript or timeout (10s watchdog)
            let finalTranscript = try await ManualQuestionTranscriptionService.shared.endAudioAndFinalize(timeoutSeconds: 10.0)
            guard self.manualCaptureRevision == captureRevision else { return }
            let trimmed = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            
            self.manualCaptureTranscript = trimmed
            
            if trimmed.isEmpty {
                let message = "No speech detected or transcription failed. Try recording again."
                self.manualCaptureState = .error(message)
                self.failAction(ActionID.manualStopTranscribe, title: "Transcription failed", message: message)
                return
            }
            
            self.manualCaptureState = .transcriptReady
            self.completeAction(ActionID.manualStopTranscribe, title: "Transcript ready", message: "Review the question and generate an answer.")
            
            if !settings.showTranscriptBeforeSending && settings.autoSendAfterTranscription {
                sendManualCaptureToAI()
            }
        } catch {
            guard self.manualCaptureRevision == captureRevision else { return }
            self.manualCaptureState = .error(error.localizedDescription)
            self.failAction(ActionID.manualStopTranscribe, title: "Transcription failed", message: error.localizedDescription)
        }
    }
}

@MainActor
func cancelManualCapture() {
    manualCaptureRevision += 1
    beginAction(ActionID.manualCancel, title: "Cancelling", message: "Discarding the current manual capture...")
    ManualQuestionCaptureService.shared.cancelCapture()
    ManualQuestionTranscriptionService.shared.cancel()
    cancelActiveGenerationForStop()
    generationUIState = .idle
    self.manualCaptureState = .idle
    self.manualCaptureTranscript = ""
    self.manualCaptureSuggestion = nil
    self.manualCaptureError = nil
    self.manualCaptureBufferCount = 0
    self.manualCaptureLastBufferTimestamp = nil
    completeAction(ActionID.manualCancel, title: "Recording discarded", message: "Ready to record a new question.")
}

@MainActor
func sendManualCaptureToAI(forceDeepSeek: Bool = false) {
    guard !isActionLoading(ActionID.manualGenerate) else { return }
    guard self.manualCaptureState == .transcriptReady || 
          self.manualCaptureState == .suggestionReady || 
          caseSuggestionError(self.manualCaptureState) else { return }
    
    let rawText = self.manualCaptureTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawText.isEmpty else {
        self.manualCaptureState = .suggestionError("Transcript is empty.")
        failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript is empty.")
        return
    }
    
    // Clean transcript conservatively
    let text = cleanTranscript(rawText)

    let manualGenerationID = UUID().uuidString
    let manualQuestionID = UUID().uuidString
    let manualConsentTicket = persistenceConsent.ticket()
    let frozenAnswerMode = selectedAnswerProviderMode
    // A new opt-in authorizes this operation only, never the previous temporary session.
    let reusableSession = currentSession.flatMap { session in
        !settings.saveTranscriptsLocally || (try? sessionRepository.session(id: session.id)) != nil ? session : nil
    }
    let newSession: InterviewSession? = reusableSession != nil ? nil : settings.saveTranscriptsLocally
        ? (try? createContextBoundSession(mode: .microphone, title: "Manual Capture"))
        : InterviewSession(id: UUID().uuidString, title: "Temporary Manual Capture", startedAt: Date(), mode: .microphone, createdAt: Date(), contextSnapshotID: activeContextSnapshot?.id)
    guard let fallbackSession = reusableSession ?? newSession else {
        self.manualCaptureState = .suggestionError("Could not create an interview session.")
        return
    }
    let manualSessionID = fallbackSession.id
    let manualSource: AudioSourceType = (settings.manualCaptureSource == .systemAudio) ? .systemAudio : .microphone
    // A manually selected source still does not identify a speaker.
    let manualSpeaker: SpeakerRole = .unknown
    let manualUsesLocalQwen = frozenAnswerMode == .localQwenPrimary && !forceDeepSeek
    let activeProviderForManual = activeRealtimeProvider
    let manualDetected = DetectedQuestion(
        id: manualQuestionID,
        sessionID: manualSessionID,
        transcriptSegmentID: nil,
        questionText: text,
        intent: .technical,
        answerStrategy: .directAnswer,
        confidence: 0.95,
        reason: "Manual Capture Triggered",
        shouldTrigger: true,
        questionComplete: true,
        modelName: manualUsesLocalQwen ? selectedQwenModelName : activeProviderForManual?.model ?? "deepseek-v4-flash",
        promptVersion: "v1",
        providerKind: manualUsesLocalQwen ? .ollamaLocal : activeProviderForManual?.kind,
        providerName: manualUsesLocalQwen ? "Ollama Qwen" : activeProviderForManual?.name,
        providerBaseURL: manualUsesLocalQwen ? "http://localhost:11434" : activeProviderForManual?.baseURL,
        latencyMS: nil,
        isLocal: manualUsesLocalQwen || activeProviderForManual?.kind == .ollamaLocal,
        rawJSON: nil,
        createdAt: Date()
    )
    self.currentSession = fallbackSession
    let manualRequestStart = Date()
    
    self.manualCaptureSuggestion = nil
    self.manualCaptureState = .generatingSuggestion
    activateGeneration(
        question: manualDetected,
        generationID: manualGenerationID,
        triggerPath: .manualCapture,
        requestStart: manualRequestStart,
        source: manualSource,
        speaker: manualSpeaker
    )
    setGenerationUIState(.generatingFirstAnswer(questionID: manualQuestionID, generationID: manualGenerationID, triggerPath: .manualCapture), generationID: manualGenerationID)
    beginAction(ActionID.manualGenerate, title: "Generating first answer", message: "Keeping the transcript visible while generating...")

    let manualFallbackTask = Task { [weak self] in
        guard let self else { return }
        do {
            try await self.delayProvider.sleep(nanoseconds: 1_500_000_000)
        } catch {
            return
        }
        guard self.currentGenerationID == manualGenerationID else {
            self.recordStaleGenerationDiscard()
            return
        }
        guard self.manualCaptureSuggestion == nil else { return }
        guard frozenAnswerMode != .localQwenPrimary || forceDeepSeek,
              let manualDetected = self.lastDetectedQuestion,
              manualDetected.id == manualQuestionID,
              manualDetected.taskDescriptor?.decision != nil else { return }

        var fallback = self.makeInitialFirstAnswerFallbackCard(
            cardID: UUID().uuidString,
            question: manualDetected,
            session: fallbackSession,
            requestStart: manualRequestStart
        )
        let elapsed = self.elapsedMS(since: manualRequestStart)
        fallback.firstVisibleAnswerMS = elapsed
        fallback.stageBStatus = "manual_capture_fallback"
        guard self.displaySuggestionIfAligned(
            fallback,
            question: manualDetected,
            generationID: manualGenerationID,
            triggerPath: .manualCapture,
            source: manualSource,
            speaker: manualSpeaker
        ) else { return }
        self.manualCaptureSuggestion = self.currentSuggestion
        self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
        self.manualCaptureState = .suggestionReady
        self.softFallbackUsed = true
        self.softFallbackLatencyMS = elapsed
        self.softFallbackShownAt = Date()
        self.finalVisibleSource = fallback.finalVisibleSource
        self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true)
        self.setGenerationUIState(.showingFallback(questionID: manualQuestionID, generationID: manualGenerationID, triggerPath: .manualCapture), generationID: manualGenerationID)
        self.infoAction(ActionID.manualGenerate, title: "First answer visible", message: "Local first answer is visible while DeepSeek continues.", autoDismissAfter: 3.0)
    }
    registerFallbackWatchdogTask(manualFallbackTask, generationID: manualGenerationID)

    let manualFullCardTimeoutNanoseconds = generationFullCardWatchdogNanoseconds
    let manualFullCardTask = Task { [weak self] in
        guard let self else { return }
        do {
            try await Task.sleep(nanoseconds: manualFullCardTimeoutNanoseconds)
        } catch {
            return
        }
        guard self.currentGenerationID == manualGenerationID else {
            self.recordStaleGenerationDiscard()
            return
        }
        self.cancelActiveStageBTask(generationID: manualGenerationID)
        guard let manualDetected = self.lastDetectedQuestion,
              manualDetected.id == manualQuestionID,
              manualDetected.taskDescriptor?.decision != nil else {
            self.markGenerationFailed(generationID: manualGenerationID, reason: "Manual question classification did not complete.", timeout: true)
            self.manualCaptureState = .suggestionError("Question classification did not complete. Retry is available.")
            return
        }
        if frozenAnswerMode == .localQwenPrimary && !forceDeepSeek {
            self.markGenerationFailed(generationID: manualGenerationID, reason: "Local manual answer timed out.", timeout: true)
            self.manualCaptureState = .suggestionError("Local answer timed out. Retry is available.")
            return
        }
        if self.manualCaptureSuggestion != nil || self.currentSuggestion != nil {
            self.markGenerationFailed(
                generationID: manualGenerationID,
                reason: "Manual capture full answer timed out.",
                timeout: true
            )
            self.warnAction(ActionID.manualGenerate, title: "First answer visible", message: "Full answer is delayed. Retry is available.")
            return
        }
        var fallback = self.makeInitialFirstAnswerFallbackCard(
            cardID: UUID().uuidString,
            question: manualDetected,
            session: fallbackSession,
            requestStart: manualRequestStart
        )
        fallback.caution = "Provider timed out. Local first answer shown; retry when ready."
        guard self.displaySuggestionIfAligned(
            fallback,
            question: manualDetected,
            generationID: manualGenerationID,
            triggerPath: .manualCapture,
            source: manualSource,
            speaker: manualSpeaker
        ) else { return }
        self.manualCaptureSuggestion = self.currentSuggestion
        self.manualCaptureState = .suggestionReady
        self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true)
        self.markGenerationFailed(
            generationID: manualGenerationID,
            reason: "No visible manual answer within 8 seconds.",
            timeout: true
        )
        self.warnAction(ActionID.manualGenerate, title: "Local answer shown", message: "DeepSeek timed out. Retry is available.")
    }
    registerFullCardWatchdogTask(manualFullCardTask, generationID: manualGenerationID)
    
    let manualProviderTask = Task {
        do {
            let customConfig: LLMProviderConfiguration?
            if forceDeepSeek {
                guard let deepSeekConfig = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
                    throw LLMProviderError.notConfigured("DeepSeek provider not found. Please add DeepSeek in settings.")
                }
                customConfig = deepSeekConfig
            } else {
                customConfig = nil
            }
            
            let activeProvider = customConfig ?? activeRealtimeProvider
            var detected = manualDetected
            if !manualUsesLocalQwen {
                detected.modelName = activeProvider?.model ?? detected.modelName
                detected.providerKind = activeProvider?.kind ?? detected.providerKind
                detected.providerName = activeProvider?.name ?? detected.providerName
                detected.providerBaseURL = activeProvider?.baseURL ?? detected.providerBaseURL
                detected.isLocal = activeProvider?.kind == .ollamaLocal
            }
            self.freezeConversationContext(for: &detected)
            let parent = detected.taskDescriptor?.conversationContext
            let frozenSnapshot = fallbackSession.contextSnapshotID.flatMap { try? self.interviewContextRepository.snapshot(id: $0) }
            let decision = try await InterviewQuestionRouter.resolve(
                .init(question: text, questionID: detected.id, contextSnapshotID: frozenSnapshot?.id,
                      parentQuestionID: parent?.questionID, previousQuestion: parent?.questionText, previousAnswer: parent?.answerText),
                provider: self.questionRoutingProvider ?? self.localLLMProviderOverride ?? OllamaQwenProvider(),
                model: self.selectedQwenModelName
            )
            guard !Task.isCancelled, self.isActiveGeneration(manualGenerationID, questionID: detected.id) else { return }
            var task = detected.taskDescriptor ?? InterviewTaskDescriptor(question: text)
            task.apply(decision)
            detected.taskDescriptor = task
            let manualSegment = TranscriptSegment(id: UUID().uuidString, sessionID: manualSessionID,
                source: manualSource, speaker: manualSpeaker, text: rawText)
            detected.transcriptSegmentID = manualSegment.id
            // Establish the actual input/foreign keys before any answer write.
            // The operation's original consent cannot be renewed by a callback.
            if self.persistenceConsent.isCurrent(ticket: manualConsentTicket) {
                try self.persistenceConsent.write(ticket: manualConsentTicket) {
                    try self.transcriptRepository.saveSegment(manualSegment)
                    try self.suggestionRepository.saveDetectedQuestion(detected)
                }
            }
            self.transcriptSegments.append(manualSegment)
            self.lastDetectedQuestion = detected
            
            // gate context to 800 CV / 600 JD words
            let retrievalService = contextRetrievalService!
            let (legacyContext, trace) = try await Task.detached(priority: .userInitiated) {
                try await retrievalService.retrieveContextWithTrace(
                    question: text,
                    intent: .technical,
                    maxCVWords: 800,
                    maxJDWords: 600,
                    strategy: detected.answerStrategy
                )
            }.value
            guard !Task.isCancelled, self.isActiveGeneration(manualGenerationID, questionID: detected.id) else { return }
            let snapshotContext = frozenSnapshot.map { DynamicInterviewContextEngine().retrieveContext(question: text, snapshot: $0).context }
            let context = SnapshotBoundContextPolicy.retrievedContext(snapshot: frozenSnapshot, snapshotContext: snapshotContext, legacyContext: legacyContext)
            let promptSnapshot = PromptContextBuilder.promptSnapshot(question: detected, context: context, transcriptContext: "", cvSummary: "", jdSummary: "", stage: .jsonCard, interviewContextSnapshot: frozenSnapshot)
            let includedChunks = promptSnapshot.ragContextSnapshot.frozenPromptCitations

            if !forceDeepSeek && frozenAnswerMode == .localQwenPrimary {
                let succeeded = try await self.finishWithLocalQwenAnswer(
                    question: detected, session: fallbackSession, transcript: "", context: context,
                    retrievedChunks: includedChunks, cvSummary: "", jdSummary: "",
                    generationID: manualGenerationID, cardID: UUID().uuidString,
                    requestStart: manualRequestStart, triggerPath: .manualCapture,
                    source: manualSource, speaker: manualSpeaker,
                    localProvider: self.localLLMProviderOverride ?? OllamaQwenProvider(), fallbackReason: nil,
                    interviewContextSnapshot: frozenSnapshot
                )
                guard !Task.isCancelled, self.currentGenerationID == manualGenerationID else { return }
                guard succeeded else { throw LLMProviderError.invalidResponse("Local answer did not pass publication checks.") }
                self.manualCaptureSuggestion = self.currentSuggestion
                self.manualCaptureState = .suggestionReady
                self.clearStageBTask(generationID: manualGenerationID)
                self.completeAction(ActionID.manualGenerate, title: "Answer ready", message: "Local answer is visible.")
                return
            }
            
            // empty transcript context
            let transcriptContext = ""
            
            // suggestion timeout interval is kept under the legacy settings key for migration compatibility.
            let timeout = TimeInterval(settings.generationRequestTimeoutSeconds)
            
            let result = try await suggestionGenerationService.generate(
                question: detected,
                context: context,
                transcriptContext: transcriptContext,
                sessionID: manualSessionID,
                timeoutInterval: timeout,
                customProviderConfig: customConfig,
                interviewContextSnapshot: frozenSnapshot
            )
            guard !Task.isCancelled, !self.terminalGenerationIDs.contains(manualGenerationID), self.currentGenerationID == manualGenerationID else {
                self.recordStaleGenerationDiscard()
                return
            }
            self.clearFallbackWatchdogTask(generationID: manualGenerationID)
            
            self.lastSuggestionGenerationProvider = result.response.providerName
            self.lastSuggestionGenerationModel = result.response.modelName
            guard self.displaySuggestionIfAligned(
                result.card,
                question: detected,
                generationID: manualGenerationID,
                triggerPath: .manualCapture,
                source: manualSource,
                speaker: manualSpeaker
            ) else {
                if let visibleSuggestion = self.currentSuggestion,
                   visibleSuggestion.detectedQuestionID == detected.id {
                    self.manualCaptureSuggestion = visibleSuggestion
                    self.manualCaptureState = .suggestionReady
                    self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                    self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true)
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: self.lastAlignmentError.isEmpty ? "Generated answer did not align with the manual question." : self.lastAlignmentError
                    )
                    self.clearStageBTask(generationID: manualGenerationID)
                    self.warnAction(ActionID.manualGenerate, title: "Fallback answer shown", message: "The provider answer was not usable, so a local answer is visible.")
                } else {
                    let message = self.lastAlignmentError.isEmpty ? "Generated answer did not align with the manual question." : self.lastAlignmentError
                    self.manualCaptureState = .suggestionError(message)
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: message,
                        providerError: message
                    )
                    self.clearStageBTask(generationID: manualGenerationID)
                    self.failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript preserved. \(message)")
                }
                return
            }
            self.manualCaptureSuggestion = self.currentSuggestion
            self.manualCaptureState = .suggestionReady
            self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
            self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: false)
            self.markFullCardVisible(generationID: manualGenerationID)
            self.clearStageBTask(generationID: manualGenerationID)
            self.completeAction(ActionID.manualGenerate, title: "Answer ready", message: "Manual capture answer is visible.")
            
            // If a live session is running, persist to database and update lists
            if self.currentSession?.id == manualSessionID {
                // Save detected question and suggestion card
                var savedQuestion = detected
                savedQuestion.latencyMS = result.response.latencyMS
                self.saveDetectedQuestionInBackground(savedQuestion, consentTicket: manualConsentTicket)
                
                var savedCard = result.card
                savedCard.questionID = savedQuestion.id
                
                // Update AppState current suggestions
                self.lastRetrievalTrace = trace
                self.lastDetectedQuestion = savedQuestion
                self.currentSuggestionRetrievedChunks = includedChunks
                guard self.displaySuggestionIfAligned(
                    savedCard,
                    question: savedQuestion,
                    generationID: manualGenerationID,
                    triggerPath: .manualCapture,
                    source: manualSource,
                    speaker: manualSpeaker
                ) else { return }
                savedCard = self.currentSuggestion ?? savedCard
                self.manualCaptureSuggestion = self.currentSuggestion
                self.persistSuggestionInBackground(
                    savedCard,
                    chunks: includedChunks,
                    generationID: manualGenerationID,
                    requestStart: manualRequestStart
                )
                
                // Update diagnostics
                self.updateDiagnostics { diag in
                    diag.apiCallCount += 1
                    diag.lastAPILatencyMS = result.response.latencyMS
                    diag.lastProviderName = result.response.providerName
                    diag.lastProviderModel = result.response.modelName
                    diag.lastRetrievalTrace = trace
                    diag.rawTranscript = rawText
                    diag.cleanedQuestion = text
                }
            } else {
                // Update diagnostics even if session doesn't run
                self.lastRetrievalTrace = trace
                self.currentSuggestionRetrievedChunks = includedChunks
                self.updateDiagnostics { diag in
                    diag.apiCallCount += 1
                    diag.lastAPILatencyMS = result.response.latencyMS
                    diag.lastProviderName = result.response.providerName
                    diag.lastProviderModel = result.response.modelName
                    diag.lastRetrievalTrace = trace
                    diag.rawTranscript = rawText
                    diag.cleanedQuestion = text
                }
            }
        } catch {
            self.clearStageBTask(generationID: manualGenerationID)
            let message = error.localizedDescription
            if self.currentGenerationID == manualGenerationID {
                if self.manualCaptureSuggestion != nil || self.currentSuggestion != nil {
                    self.manualCaptureState = .suggestionReady
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: message,
                        providerError: message,
                        jsonParseError: message.lowercased().contains("json") ? message : nil,
                        timeout: message.lowercased().contains("timed out") || message.lowercased().contains("timeout")
                    )
                    self.warnAction(ActionID.manualGenerate, title: "First answer preserved", message: "Generation failed after a fallback was shown. Retry is available.")
                } else {
                    self.manualCaptureState = .suggestionError(message)
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: message,
                        providerError: message,
                        jsonParseError: message.lowercased().contains("json") ? message : nil,
                        timeout: message.lowercased().contains("timed out") || message.lowercased().contains("timeout")
                    )
                    self.failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript preserved. \(message)")
                }
            } else {
                self.recordStaleGenerationDiscard()
            }
            self.updateDiagnostics { diag in
                diag.lastError = message
                diag.rawTranscript = rawText
                diag.cleanedQuestion = text
            }
        }
    }
    registerStageBTask(manualProviderTask, generationID: manualGenerationID)
}

func caseSuggestionError(_ state: ManualCaptureState) -> Bool {
    if case .suggestionError = state { return true }
    return false
}

func cleanTranscript(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }
    
    let lowercased = text.lowercased()
    
    // Conservative cleanup
    if lowercased.hasSuffix("what you offer") {
        if let range = text.range(of: "what you offer", options: [.caseInsensitive, .backwards]) {
            text.replaceSubrange(range, with: "what do you offer?")
        }
    } else if lowercased == "what you offer" {
        text = "What do you offer?"
    }
    
    if let first = text.first, first.isLowercase {
        text = text.prefix(1).uppercased() + text.dropFirst()
    }
    
    let questionWords = ["what", "why", "how", "who", "when", "where", "which", "are", "is", "do", "does", "did", "can", "could", "would", "should", "will"]
    let firstWord = text.split(separator: " ").first?.lowercased() ?? ""
    if questionWords.contains(firstWord) {
        if !text.hasSuffix("?") && !text.hasSuffix(".") && !text.hasSuffix("!") {
            text += "?"
        }
    }
    
    return text
}

@MainActor
func retryManualCapture() {
    cancelManualCapture()
    completeAction(ActionID.manualRecord, title: "Ready to record", message: "Record a new interviewer question.")
}

@MainActor
func clearManualCapture() {
    cancelManualCapture()
    completeAction(ActionID.manualClear, title: "Manual capture cleared", message: "Ready to record again.")
}

@MainActor
func regenerateManualSuggestion() {
    guard self.manualCaptureState == .transcriptReady || 
          self.manualCaptureState == .suggestionReady || 
          caseSuggestionError(self.manualCaptureState) else { return }
    sendManualCaptureToAI()
}
}
