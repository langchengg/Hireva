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
    guard !isShuttingDown, !isActionLoading(ActionID.manualRecord) else { return }
    guard onboardingComplete else {
        let message = liveBlockedReason ?? "Run the readiness check before recording a question."
        failAction(ActionID.manualRecord, title: "Setup incomplete", message: message)
        showError(message)
        return
    }
    manualCaptureController.start(configuration: .init(source: settings.manualCaptureSource,
        maxDuration: settings.maxManualCaptureSeconds,
        showTranscriptBeforeSending: settings.showTranscriptBeforeSending,
        autoSendAfterTranscription: settings.autoSendAfterTranscription,
        requiresOnDeviceRecognition: HirevaVerificationConfiguration.current?.requiresLocalASR ?? false))
}

@MainActor
func stopAndTranscribeManualCapture(maxDurationReached: Bool = false) {
    guard !isActionLoading(ActionID.manualStopTranscribe) else { return }
    manualCaptureController.stopAndTranscribe(maxDurationReached: maxDurationReached)
}

@MainActor
func cancelManualCapture() {
    let manual = manualCaptureController
    let submittedRevision = manual.revision
    let submittedGeneration = generationCoordinator.activeGeneration?.identity
    let submittedRequest = generationCoordinator.activeRequest?.id
    beginAction(ActionID.manualCancel, title: "Cancelling", message: "Discarding the current manual capture...")
    guard manual.revision == submittedRevision,
          generationCoordinator.activeGeneration?.identity == submittedGeneration,
          generationCoordinator.activeRequest?.id == submittedRequest else { return }
    // Revoke this request before idle can synchronously accept a new one.
    cancelActiveGenerationForStop()
    guard manual.revision == submittedRevision,
          generationCoordinator.activeGeneration == nil,
          generationCoordinator.activeRequest == nil else { return }
    _ = manual.cancel()
    @MainActor func stillOwnsCancelPresentation() -> Bool {
        manual.revision == (submittedRevision &+ 1) && manual.state == .idle &&
            generationCoordinator.activeGeneration == nil && generationCoordinator.activeRequest == nil
    }
    guard stillOwnsCancelPresentation() else { return }
    generationUIState = .idle
    guard stillOwnsCancelPresentation() else { return }
    clearActionFeedback(ActionID.manualGenerate)
    guard stillOwnsCancelPresentation() else { return }
    completeAction(ActionID.manualCancel, title: "Recording discarded", message: "Ready to record a new question.")
}

@MainActor
func sendManualCaptureToAI(forceDeepSeek: Bool = false) {
    guard !isShuttingDown else { return }
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
    let frozenSnapshot = fallbackSession.contextSnapshotID.flatMap { try? interviewContextRepository.snapshot(id: $0) }
    let recordedSource = ManualCaptureSource(rawValue: manualCaptureController.source) ?? settings.manualCaptureSource
    let manualSource: AudioSourceType = recordedSource == .systemAudio ? .systemAudio : .microphone
    // A manually selected source still does not identify a speaker.
    let manualSpeaker: SpeakerRole = .unknown
    let manualUsesLocalQwen = frozenAnswerMode == .localQwenPrimary && !forceDeepSeek
    let activeProviderForManual = activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
    let forcedProviderConfiguration = forceDeepSeek ? providerConfigurations.first { $0.kind == .deepSeek } : nil
    let frozenLocalProvider = localLLMProviderOverride ?? OllamaQwenProvider()
    let frozenLocalModelName = selectedQwenModelName
    let frozenRoutingProvider = questionRoutingProvider ?? frozenLocalProvider
    let frozenRetrievalService = contextRetrievalService?.freezeConfiguration()
    let frozenGenerationTimeout = TimeInterval(settings.generationRequestTimeoutSeconds)
    var entryQuestion = DetectedQuestion(
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
        modelName: manualUsesLocalQwen ? frozenLocalModelName : activeProviderForManual?.model ?? "deepseek-v4-flash",
        promptVersion: "v1",
        providerKind: manualUsesLocalQwen ? .ollamaLocal : activeProviderForManual?.kind,
        providerName: manualUsesLocalQwen ? "Ollama Qwen" : activeProviderForManual?.name,
        providerBaseURL: manualUsesLocalQwen ? "http://localhost:11434" : activeProviderForManual?.baseURL,
        latencyMS: nil,
        isLocal: manualUsesLocalQwen || activeProviderForManual?.kind == .ollamaLocal,
        rawJSON: nil,
        createdAt: Date()
    )
    freezeConversationContext(for: &entryQuestion, parentCard: currentSuggestion,
        mode: interviewSessionMode)
    let manualDetected = entryQuestion
    let manualRequestStart = Date()
    let submittedManualIdentity = GenerationIdentity(question: manualDetected,
        generationID: manualGenerationID, promptPrimaryQuestion: manualDetected.questionText,
        contextSnapshotID: fallbackSession.contextSnapshotID)
    
    // This lexical request exists before synchronous presentation can revoke
    // it. The Manual worker remains retained by its existing Stage B owner.
    let manualRequestID = beginGenerationRequest(triggerPath: .manualCapture)
    guard !isShuttingDown, generationCoordinator.isCurrentRequest(manualRequestID) else { return }
    defer { generationCoordinator.finishRequest(requestID: manualRequestID) }
    @MainActor func acceptsManualEntry() -> Bool {
        !isShuttingDown && generationCoordinator.isCurrentRequest(manualRequestID) &&
            currentSession?.id == fallbackSession.id
    }
    self.currentSession = fallbackSession
    guard acceptsManualEntry() else { return }
    self.manualCaptureSuggestion = nil
    guard acceptsManualEntry() else { return }
    self.manualCaptureState = .generatingSuggestion
    guard acceptsManualEntry() else { return }
    activateGeneration(
        question: manualDetected,
        generationID: manualGenerationID,
        triggerPath: .manualCapture,
        requestStart: manualRequestStart,
        source: manualSource,
        speaker: manualSpeaker,
        requestID: manualRequestID,
        providerConfiguration: forceDeepSeek ? forcedProviderConfiguration : activeProviderForManual,
        answerProviderMode: frozenAnswerMode, persistenceTicket: manualConsentTicket,
        submittedIdentity: submittedManualIdentity
    )
    guard acceptsManualEntry(), generationCoordinator.isCurrent(submittedManualIdentity) else { return }
    setGenerationUIState(.generatingFirstAnswer(questionID: manualQuestionID, generationID: manualGenerationID, triggerPath: .manualCapture), generationID: manualGenerationID)
    guard acceptsManualEntry(), generationCoordinator.isCurrent(submittedManualIdentity) else { return }
    beginAction(ActionID.manualGenerate, title: "Generating first answer", message: "Keeping the transcript visible while generating...")
    guard acceptsManualEntry(), generationCoordinator.isCurrent(submittedManualIdentity) else { return }

    guard let manualIdentity = activeGenerationController?.identity,
          manualIdentity.generationID == manualGenerationID else { return }
    let manualFallbackTask = generationCoordinator.launchManualFirstAnswerFallbackDeadline(
        identity: manualIdentity, forceDeepSeek: forceDeepSeek,
        startedAt: manualRequestStart, delayProvider: delayProvider,
        hasManualCard: { [weak self] identity in
            guard let self, !self.generationUIState.isTerminal,
                  self.currentSession?.id == identity.sessionID else { return nil }
            return self.manualCaptureSuggestion != nil
        },
        onFallback: { [weak self] identity, manualDetected, elapsed in
            guard let self else { return }
            @MainActor func acceptsPublication() -> Bool {
                !Task.isCancelled && self.generationCoordinator.canPublish(identity) &&
                    self.currentSession?.id == fallbackSession.id && !self.generationUIState.isTerminal
            }
            guard acceptsPublication() else { return }
            var fallback = self.makeInitialFirstAnswerFallbackCard(
                cardID: UUID().uuidString, question: manualDetected,
                session: fallbackSession, requestStart: manualRequestStart)
            fallback.firstVisibleAnswerMS = elapsed
            fallback.stageBStatus = "manual_capture_fallback"
            guard acceptsPublication(), self.displaySuggestionIfAligned(
                fallback, question: manualDetected, generationID: manualGenerationID,
                triggerPath: .manualCapture, source: manualSource, speaker: manualSpeaker,
                whileCurrent: acceptsPublication), acceptsPublication() else { return }
            self.manualCaptureSuggestion = self.currentSuggestion
            guard acceptsPublication() else { return }
            self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
            guard acceptsPublication() else { return }
            self.manualCaptureState = .suggestionReady
            guard acceptsPublication() else { return }
            self.softFallbackUsed = true
            guard acceptsPublication() else { return }
            self.softFallbackLatencyMS = elapsed
            guard acceptsPublication() else { return }
            self.softFallbackShownAt = Date()
            guard acceptsPublication() else { return }
            self.finalVisibleSource = fallback.finalVisibleSource
            guard acceptsPublication() else { return }
            self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true,
                whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.setGenerationUIState(.showingFallback(questionID: manualQuestionID,
                generationID: manualGenerationID, triggerPath: .manualCapture),
                generationID: manualGenerationID, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.infoAction(ActionID.manualGenerate, title: "First answer visible",
                message: "Local first answer is visible while DeepSeek continues.",
                autoDismissAfter: 3.0, whileCurrent: acceptsPublication)
        })
    if manualFallbackTask != nil {
        updateActiveTaskSummary()
    }

    let manualFullCardTimeoutNanoseconds = generationFullCardWatchdogNanoseconds
    let manualFullCardTask = generationCoordinator.launchManualFullCardDeadline(
        identity: manualIdentity, forceDeepSeek: forceDeepSeek,
        startedAt: manualRequestStart, nanoseconds: manualFullCardTimeoutNanoseconds,
        delayProvider: generationWatchdogDelayProvider,
        presentation: { [weak self] identity in
            guard let self, !self.generationUIState.isTerminal,
                  self.currentSession?.id == identity.sessionID else { return nil }
            return (self.manualCaptureSuggestion, self.currentSuggestion)
        },
        onTimeout: { [weak self] plan, manualDetected in
            guard let self, let identity = plan.identity else { return }
            @MainActor func stillOwnsPresentation() -> Bool {
                self.generationCoordinator.isCurrent(identity) && self.currentSession?.id == identity.sessionID
            }
            @MainActor func acceptsPublication() -> Bool {
                !Task.isCancelled && self.generationCoordinator.canPublish(identity) &&
                    !self.generationUIState.isTerminal && stillOwnsPresentation()
            }
            guard acceptsPublication() else { return }
            let reason = plan.fallbackReason ?? "Manual capture full answer timed out."
            if plan.action == .markProviderFailed {
                self.markGenerationFailed(generationID: manualGenerationID, reason: reason, timeout: true)
                // Terminal commit intentionally cancels this deadline. Its
                // final Manual UI field still requires the exact identity.
                guard stillOwnsPresentation() else { return }
                self.manualCaptureState = .suggestionError(manualDetected == nil
                    ? "Question classification did not complete. Retry is available."
                    : "Local answer timed out. Retry is available.")
                return
            }
            if plan.action == .keepVisibleFirstAnswer {
                self.markGenerationFailed(generationID: manualGenerationID, reason: reason, timeout: true)
                guard stillOwnsPresentation() else { return }
                self.warnAction(ActionID.manualGenerate, title: "First answer visible",
                    message: "Full answer is delayed. Retry is available.", whileCurrent: stillOwnsPresentation)
                return
            }
            guard plan.action == .useSemanticFallback, let manualDetected else { return }
            var fallback = self.makeInitialFirstAnswerFallbackCard(
                cardID: UUID().uuidString, question: manualDetected,
                session: fallbackSession, requestStart: manualRequestStart)
            fallback.caution = "Provider timed out. Local first answer shown; retry when ready."
            guard acceptsPublication(), self.displaySuggestionIfAligned(
                fallback, question: manualDetected, generationID: manualGenerationID,
                triggerPath: .manualCapture, source: manualSource, speaker: manualSpeaker,
                whileCurrent: acceptsPublication), acceptsPublication() else { return }
            self.manualCaptureSuggestion = self.currentSuggestion
            guard acceptsPublication() else { return }
            self.manualCaptureState = .suggestionReady
            guard acceptsPublication() else { return }
            self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true,
                whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.markGenerationFailed(generationID: manualGenerationID, reason: reason, timeout: true)
            guard stillOwnsPresentation() else { return }
            self.warnAction(ActionID.manualGenerate, title: "Local answer shown",
                message: "DeepSeek timed out. Retry is available.", whileCurrent: stillOwnsPresentation)
        })
    if manualFullCardTask != nil { updateActiveTaskSummary() }

    let manualWorkflowTask = generationCoordinator.launchManualWorkflow(
        identity: manualIdentity, operation: { [weak self] manualIdentity in
        guard let self, !Task.isCancelled,
              self.generationCoordinator.canPublish(manualIdentity),
              self.isActiveGeneration(manualGenerationID, questionID: manualQuestionID) else { return }
        @MainActor func stillOwnsManualPresentation() -> Bool {
            self.generationCoordinator.isCurrent(manualIdentity) &&
                self.currentSession?.id == manualIdentity.sessionID &&
                self.currentSession?.contextSnapshotID == manualIdentity.contextSnapshotID
        }
        @MainActor func acceptsManualPublication() -> Bool {
            !Task.isCancelled && self.generationCoordinator.canPublish(manualIdentity) &&
                stillOwnsManualPresentation()
        }
        do {
            let customConfig: LLMProviderConfiguration?
            if forceDeepSeek {
                guard let deepSeekConfig = forcedProviderConfiguration else {
                    throw LLMProviderError.notConfigured("DeepSeek provider not found. Please add DeepSeek in settings.")
                }
                customConfig = deepSeekConfig
            } else {
                customConfig = activeProviderForManual
            }
            
            let activeProvider = customConfig ?? activeProviderForManual
            var detected = manualDetected
            if !manualUsesLocalQwen {
                detected.modelName = activeProvider?.model ?? detected.modelName
                detected.providerKind = activeProvider?.kind ?? detected.providerKind
                detected.providerName = activeProvider?.name ?? detected.providerName
                detected.providerBaseURL = activeProvider?.baseURL ?? detected.providerBaseURL
                detected.isLocal = activeProvider?.kind == .ollamaLocal
            }
            // The submission already captured its parent and dialogue mode.
            // A queued worker must not freeze them again from current UI state.
            let parent = detected.taskDescriptor?.conversationContext
            let decision = try await self.generationCoordinator.routeQuestion(
                identity: manualIdentity,
                input: .init(question: text, questionID: detected.id, contextSnapshotID: frozenSnapshot?.id,
                      parentQuestionID: parent?.questionID, previousQuestion: parent?.questionText, previousAnswer: parent?.answerText),
                provider: frozenRoutingProvider,
                model: frozenLocalModelName
            )
            guard !Task.isCancelled, self.generationCoordinator.canPublish(manualIdentity),
                  self.currentSession?.id == manualIdentity.sessionID else { return }
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
            guard acceptsManualPublication() else { return }
            self.lastDetectedQuestion = detected
            guard acceptsManualPublication() else { return }
            
            // gate context to 800 CV / 600 JD words
            guard let retrievalService = frozenRetrievalService else {
                throw LLMProviderError.notConfigured("Context retrieval")
            }
            // The existing owner retains both the Manual workflow and its
            // exact retrieval child. Frozen query inputs and evidence/UI/DB
            // admission stay at their current boundaries.
            let retrievalStrategy = detected.answerStrategy
            let (legacyContext, trace) = try await self.generationCoordinator.retrieveContext(
                identity: manualIdentity, service: retrievalService, question: text,
                intent: .technical, maxCVWords: 800, maxJDWords: 600,
                strategy: retrievalStrategy)
            guard !Task.isCancelled, self.generationCoordinator.canPublish(manualIdentity),
                  self.currentSession?.id == manualIdentity.sessionID else { return }
            let snapshotContext = frozenSnapshot.map { DynamicInterviewContextEngine().retrieveContext(question: text, snapshot: $0).context }
            let context = SnapshotBoundContextPolicy.retrievedContext(snapshot: frozenSnapshot, snapshotContext: snapshotContext, legacyContext: legacyContext)
            // Retrieval has passed the current manual identity fence. Publish
            // its provenance for local and configured-provider answers alike.
            self.lastRetrievalTrace = trace
            guard acceptsManualPublication() else { return }
            let promptSnapshot = PromptContextBuilder.promptSnapshot(question: detected, context: context, transcriptContext: "", cvSummary: "", jdSummary: "", stage: .jsonCard, interviewContextSnapshot: frozenSnapshot)
            let includedChunks = promptSnapshot.ragContextSnapshot.frozenPromptCitations

            if !forceDeepSeek && frozenAnswerMode == .localQwenPrimary {
                let succeeded = try await self.finishWithLocalQwenAnswer(
                    question: detected, session: fallbackSession, transcript: "", context: context,
                    retrievedChunks: includedChunks, cvSummary: "", jdSummary: "",
                    generationID: manualGenerationID, cardID: UUID().uuidString,
                    requestStart: manualRequestStart, triggerPath: .manualCapture,
                    source: manualSource, speaker: manualSpeaker,
                    localProvider: frozenLocalProvider, modelName: frozenLocalModelName, fallbackReason: nil,
                    interviewContextSnapshot: frozenSnapshot
                )
                // A qualified local answer intentionally terminates/cancels
                // this worker. Terminal UI still needs its complete identity.
                guard stillOwnsManualPresentation() else { return }
                guard succeeded else {
                    guard !Task.isCancelled, !self.terminalGenerationIDs.contains(manualGenerationID) else { return }
                    throw LLMProviderError.invalidResponse("Local answer did not pass publication checks.")
                }
                // Finishing the local answer cancels the registered Stage B task,
                // which is this manual caller. Publish its confirmed terminal
                // answer only while the same question and session still own it.
                guard self.generationUIState == .answerReady(questionID: detected.id, generationID: manualGenerationID, triggerPath: .manualCapture),
                      let completed = self.currentSuggestion,
                      self.visibleCardMatchesGeneration(card: completed, generationID: manualGenerationID,
                          detectedQuestionID: detected.id, promptPrimaryQuestion: detected.questionText) else { return }
                self.manualCaptureSuggestion = completed
                guard stillOwnsManualPresentation() else { return }
                self.manualCaptureState = .suggestionReady
                guard stillOwnsManualPresentation() else { return }
                let finished = self.generationCoordinator.finishManualWorkflow(identity: manualIdentity)
                guard stillOwnsManualPresentation() else { return }
                if finished {
                    self.updateActiveTaskSummary()
                    guard stillOwnsManualPresentation() else { return }
                }
                self.completeAction(ActionID.manualGenerate, title: "Answer ready", message: "Local answer is visible.")
                return
            }
            
            // empty transcript context
            let transcriptContext = ""
            
            // suggestion timeout interval is kept under the legacy settings key for migration compatibility.
            let timeout = frozenGenerationTimeout
            
            let executionContext = GenerationExecutionContext(
                session: fallbackSession, question: detected, generationID: manualGenerationID,
                triggerPath: .manualCapture, providerID: customConfig?.id.uuidString ?? "unconfigured",
                providerModel: customConfig?.model ?? "unconfigured", retrievedContext: context,
                promptSnapshot: promptSnapshot, transcriptSnapshot: transcriptContext,
                startedAt: manualRequestStart, source: manualSource, speaker: manualSpeaker,
                interviewContextSnapshot: frozenSnapshot)
            let result = try await generationCoordinator.generateManualSuggestion(
                context: executionContext, providerConfiguration: customConfig, timeoutInterval: timeout)
            guard acceptsManualPublication() else {
                self.recordStaleGenerationDiscard(attributedTo: manualIdentity)
                return
            }
            self.clearFallbackWatchdogTask(generationID: manualGenerationID)
            guard acceptsManualPublication() else { return }
            self.lastSuggestionGenerationProvider = result.response.providerName
            guard acceptsManualPublication() else { return }
            self.lastSuggestionGenerationModel = result.response.modelName
            guard acceptsManualPublication() else { return }
            let displayed = self.displaySuggestionIfAligned(
                result.card, question: detected, generationID: manualGenerationID,
                triggerPath: .manualCapture, source: manualSource, speaker: manualSpeaker,
                whileCurrent: acceptsManualPublication)
            guard acceptsManualPublication() else { return }
            guard displayed else {
                if let visibleSuggestion = self.currentSuggestion,
                   visibleSuggestion.detectedQuestionID == detected.id {
                    self.manualCaptureSuggestion = visibleSuggestion
                    guard acceptsManualPublication() else { return }
                    self.manualCaptureState = .suggestionReady
                    guard acceptsManualPublication() else { return }
                    self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                    guard acceptsManualPublication() else { return }
                    self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: true,
                        whileCurrent: acceptsManualPublication)
                    guard acceptsManualPublication() else { return }
                    self.markGenerationFailed(generationID: manualGenerationID,
                        reason: self.lastAlignmentError.isEmpty ? "Generated answer did not align with the manual question." : self.lastAlignmentError)
                    guard stillOwnsManualPresentation() else { return }
                    let finished = self.generationCoordinator.finishManualWorkflow(identity: manualIdentity)
                    guard stillOwnsManualPresentation() else { return }
                    if finished {
                        self.updateActiveTaskSummary()
                        guard stillOwnsManualPresentation() else { return }
                    }
                    self.warnAction(ActionID.manualGenerate, title: "Fallback answer shown",
                        message: "The provider answer was not usable, so a local answer is visible.",
                        whileCurrent: stillOwnsManualPresentation)
                } else {
                    let message = self.lastAlignmentError.isEmpty ? "Generated answer did not align with the manual question." : self.lastAlignmentError
                    self.manualCaptureState = .suggestionError(message)
                    guard acceptsManualPublication() else { return }
                    self.markGenerationFailed(generationID: manualGenerationID, reason: message, providerError: message)
                    guard stillOwnsManualPresentation() else { return }
                    let finished = self.generationCoordinator.finishManualWorkflow(identity: manualIdentity)
                    guard stillOwnsManualPresentation() else { return }
                    if finished {
                        self.updateActiveTaskSummary()
                        guard stillOwnsManualPresentation() else { return }
                    }
                    self.failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript preserved. \(message)")
                }
                return
            }
            guard acceptsManualPublication(), let acceptedCard = self.currentSuggestion else { return }
            self.manualCaptureSuggestion = acceptedCard
            guard acceptsManualPublication() else { return }
            self.manualCaptureState = .suggestionReady
            guard acceptsManualPublication() else { return }
            self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
            guard acceptsManualPublication() else { return }
            self.markFirstVisibleAnswer(generationID: manualGenerationID, fallback: false,
                whileCurrent: acceptsManualPublication)
            guard acceptsManualPublication() else { return }
            // Admit this validated card before terminal publication; the actual
            // write still atomically verifies its versioned consent ticket.
            var savedQuestion = detected
            savedQuestion.latencyMS = result.response.latencyMS
            self.saveDetectedQuestionInBackground(savedQuestion, consentTicket: manualConsentTicket)
            guard acceptsManualPublication() else { return }
            self.persistSuggestionInBackground(acceptedCard, chunks: includedChunks,
                generationID: manualGenerationID, requestStart: manualRequestStart)
            guard acceptsManualPublication() else { return }
            self.markFullCardVisible(generationID: manualGenerationID)
            guard stillOwnsManualPresentation() else { return }
            let finished = self.generationCoordinator.finishManualWorkflow(identity: manualIdentity)
            guard stillOwnsManualPresentation() else { return }
            if finished {
                self.updateActiveTaskSummary()
                guard stillOwnsManualPresentation() else { return }
            }
            self.completeAction(ActionID.manualGenerate, title: "Answer ready", message: "Manual capture answer is visible.")
            guard stillOwnsManualPresentation() else { return }
            // Retain the existing same-session terminal refresh and audit. Its
            // lawful old DB admission does not authorize current Q2 UI writes.
            var savedCard = result.card
            savedCard.questionID = savedQuestion.id
            self.lastRetrievalTrace = trace
            guard stillOwnsManualPresentation() else { return }
            self.lastDetectedQuestion = savedQuestion
            guard stillOwnsManualPresentation() else { return }
            self.currentSuggestionRetrievedChunks = includedChunks
            guard stillOwnsManualPresentation() else { return }
            guard self.displaySuggestionIfAligned(savedCard, question: savedQuestion,
                generationID: manualGenerationID, triggerPath: .manualCapture,
                source: manualSource, speaker: manualSpeaker,
                whileCurrent: stillOwnsManualPresentation), stillOwnsManualPresentation() else { return }
            self.manualCaptureSuggestion = self.currentSuggestion
            guard stillOwnsManualPresentation() else { return }
            self.updateDiagnostics { diag in
                diag.apiCallCount += 1
                diag.lastAPILatencyMS = result.response.latencyMS
                diag.lastProviderName = result.response.providerName
                diag.lastProviderModel = result.response.modelName
                diag.rawTranscript = rawText
                diag.cleanedQuestion = text
            }
        } catch {
            let finished = self.generationCoordinator.finishManualWorkflow(identity: manualIdentity)
            guard acceptsManualPublication() else { return }
            if finished {
                self.updateActiveTaskSummary()
                guard acceptsManualPublication() else { return }
            }
            guard !Task.isCancelled,
                  !self.terminalGenerationIDs.contains(manualGenerationID),
                  self.isActiveGeneration(manualGenerationID, questionID: manualQuestionID),
                  self.currentSession?.id == manualSessionID else {
                self.recordStaleGenerationDiscard(attributedTo: manualIdentity)
                return
            }
            let message = error.localizedDescription
            if self.currentGenerationID == manualGenerationID {
                if self.manualCaptureSuggestion != nil || self.currentSuggestion != nil {
                    self.manualCaptureState = .suggestionReady
                    guard acceptsManualPublication() else { return }
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: message,
                        providerError: message,
                        jsonParseError: message.lowercased().contains("json") ? message : nil,
                        timeout: message.lowercased().contains("timed out") || message.lowercased().contains("timeout")
                    )
                    guard stillOwnsManualPresentation() else { return }
                    self.warnAction(ActionID.manualGenerate, title: "First answer preserved", message: "Generation failed after a fallback was shown. Retry is available.", whileCurrent: stillOwnsManualPresentation)
                } else {
                    self.manualCaptureState = .suggestionError(message)
                    guard acceptsManualPublication() else { return }
                    self.markGenerationFailed(
                        generationID: manualGenerationID,
                        reason: message,
                        providerError: message,
                        jsonParseError: message.lowercased().contains("json") ? message : nil,
                        timeout: message.lowercased().contains("timed out") || message.lowercased().contains("timeout")
                    )
                    guard stillOwnsManualPresentation() else { return }
                    self.failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript preserved. \(message)")
                }
            } else {
                self.recordStaleGenerationDiscard(attributedTo: manualIdentity)
            }
            guard stillOwnsManualPresentation() else { return }
            self.updateDiagnostics { diag in
                diag.lastError = message
                diag.rawTranscript = rawText
                diag.cleanedQuestion = text
            }
        }
    }, onExit: { [weak self] identity, cleared in
        guard let self, cleared, self.generationCoordinator.isCurrent(identity) else { return }
        self.updateActiveTaskSummary()
    })
    if manualWorkflowTask != nil { updateActiveTaskSummary() }
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
