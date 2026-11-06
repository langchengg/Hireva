// Contains generation lifecycle helpers used by AppState.generateSuggestion.
// GenerationCoordinator owns request/task identities. This compatibility
// extension retains fallback policy, UI/evidence checks and persistence gates.
// It must not perform audio capture, provider key storage,
// or RAG scoring decisions.
// Known limitation: Stage B can time out under provider latency. If the visible
// first answer is complete and aligned, preserving that fallback is acceptable;
// timeout optimization belongs in a later generation phase.

import Foundation

extension AppState {
var shouldUseFirstAnswerFallbackWatchdogsForCurrentProvider: Bool {
    generationAnswerProviderMode != .localQwenPrimary
}

var generationProviderConfiguration: LLMProviderConfiguration? {
    if let owner = activeGenerationController { return owner.providerConfiguration }
    return activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
}

var generationAnswerProviderMode: AnswerProviderMode {
    activeGenerationController?.answerProviderMode ?? selectedAnswerProviderMode
}

func beginGenerationRequest(triggerPath: GenerationTriggerPath) -> String {
    // A synchronous cancellation observer can already submit the newer request.
    // An unadmitted token must never alias that request's authority.
    guard cancelActiveGenerationForReplacement() else { return UUID().uuidString }
    return generationCoordinator.beginRequest(triggerPath: triggerPath)
}

func startGenerationRequest(
    triggerPath: GenerationTriggerPath,
    operation: @escaping @MainActor (String) async -> Void
) {
    guard !isShuttingDown else { return }
    guard cancelActiveGenerationForReplacement() else { return }
    generationCoordinator.launchRequest(triggerPath: triggerPath, operation: operation)
}

// MARK: - Manual Entry Points

func manualAnswerNow() {
    guard !isShuttingDown else { return }
    guard !isActionLoading(ActionID.generateAnswer) else { return }
    guard liveState.canAnswerNow else {
        warnAction(ActionID.generateAnswer, title: "Answer already running", message: "Wait for the current generation to finish before retrying.")
        return
    }
    guard onboardingComplete else {
        let message = liveBlockedReason ?? "Run the readiness check before generating an answer."
        failAction(ActionID.generateAnswer, title: "Setup incomplete", message: message)
        showError(message)
        return
    }
    guard let session = currentSession ?? (try? createContextBoundSession(mode: .mock)) else {
        let message = "Could not create an interview session."
        failAction(ActionID.generateAnswer, title: "Generation failed", message: message)
        showError(message)
        return
    }
    currentSession = session
    let transcript = recentTranscriptText()
    let capturedSegments = Array(transcriptSegments.suffix(18))
    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        let message = "There is no transcript yet. Start Listening first, or use Practice / Developer Testing to inject a test question."
        failAction(ActionID.generateAnswer, title: "No transcript yet", message: message)
        showError(message)
        return
    }

    let answerMode = selectedAnswerProviderMode
    let providerConfiguration = activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
    let parentCard = currentSuggestion
    let parentMode = interviewSessionMode
    let localProvider = localLLMProviderOverride ?? OllamaQwenProvider()
    let localModelName = selectedQwenModelName
    let prefetchAdmission = liveRAGPrefetch.cacheAdmission
    let retrievalService = contextRetrievalService?.freezeConfiguration()
    let localDetection: Result<(question: DetectedQuestion, response: LLMChatResult), Error>? =
        answerMode == .localQwenPrimary
            ? Result { try makeLocalManualDetection(session: session, capturedSegments: capturedSegments) }
            : nil
    beginAction(ActionID.generateAnswer, title: "Generating first answer", message: "Transcript is preserved while the provider prepares the answer.")
    startGenerationRequest(triggerPath: .manualGenerate) { [weak self] requestID in
        guard let self else { return }
        await self.runManualAnswer(session: session, transcript: transcript,
            capturedSegments: capturedSegments, localDetection: localDetection,
            localProvider: localProvider, localModelName: localModelName,
            answerMode: answerMode, providerConfiguration: providerConfiguration,
            retrievalService: retrievalService, prefetchAdmission: prefetchAdmission, parentCard: parentCard,
            parentMode: parentMode, requestID: requestID)
    }
}

func answerCurrentQuestionOrTranscriptNow() {
    if hasAcceptedVisibleQuestionForManualGeneration {
        regenerateVisibleSuggestion()
        return
    }
    manualAnswerNow()
}

private var hasAcceptedVisibleQuestionForManualGeneration: Bool {
    guard let questionText = visibleQuestionText(for: currentSuggestion)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !questionText.isEmpty
    else {
        return false
    }
    return currentSuggestion != nil ||
        activeGenerationController != nil ||
        lastDetectedQuestion != nil
}

func regenerateVisibleSuggestion() {
    guard !isShuttingDown else { return }
    guard !isActionLoading(ActionID.generateAnswer) else { return }
    guard liveState.canAnswerNow else {
        warnAction(ActionID.generateAnswer, title: "Answer already running", message: "Wait for the current generation to finish before retrying.")
        return
    }
    guard onboardingComplete else {
        let message = liveBlockedReason ?? "Run the readiness check before regenerating an answer."
        failAction(ActionID.generateAnswer, title: "Setup incomplete", message: message)
        showError(message)
        return
    }
    guard let session = currentSession ?? (try? createContextBoundSession(mode: .mock)) else {
        let message = "Could not create an interview session."
        failAction(ActionID.generateAnswer, title: "Generation failed", message: message)
        showError(message)
        return
    }

    let visibleCard = currentSuggestion
    guard let questionText = visibleQuestionText(for: visibleCard)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !questionText.isEmpty else {
        let message = "There is no current question to regenerate."
        failAction(ActionID.generateAnswer, title: "No current question", message: message)
        showError(message)
        return
    }

    currentSession = session
    let source = visibleCard?.source.flatMap(AudioSourceType.init(rawValue:)) ??
        AudioSourceType(rawValue: lastDetectedQuestionSource)
    let speaker = visibleCard?.speaker.flatMap(SpeakerRole.init(rawValue:)) ??
        SpeakerRole(rawValue: lastDetectedQuestionSpeaker)
    let oldGenerationID = visibleCard?.generationID ?? activeGenerationController?.generationID ?? activeGenerationID
    let baseQuestion = lastDetectedQuestion
    var question = DetectedQuestion(
        id: visibleCard?.detectedQuestionID ?? activeGenerationController?.questionID ?? baseQuestion?.id ?? UUID().uuidString,
        sessionID: session.id,
        transcriptSegmentID: visibleCard?.transcriptSegmentID ?? baseQuestion?.transcriptSegmentID,
        questionText: questionText,
        intent: baseQuestion?.intent ?? .technical,
        answerStrategy: baseQuestion?.answerStrategy ?? .directAnswer,
        confidence: baseQuestion?.confidence ?? 1.0,
        reason: "Regenerating the current visible question.",
        shouldTrigger: true,
        questionComplete: true,
        modelName: "visible-question-regenerate",
        promptVersion: "visible-question-regenerate-v1",
        providerKind: nil,
        providerName: "Visible Question",
        providerBaseURL: nil,
        latencyMS: 0,
        isLocal: true,
        rawJSON: nil,
        createdAt: Date(),
        ingressIdentity: visibleCard?.ingressIdentity ?? baseQuestion?.ingressIdentity
    )
    if let baseQuestion, baseQuestion.id == question.id, baseQuestion.sessionID == session.id,
       baseQuestion.questionText == questionText {
        question.taskDescriptor = baseQuestion.taskDescriptor
    } else if let stored = try? suggestionRepository.questions(sessionID: session.id).first(where: { $0.id == question.id && $0.questionText == questionText }) {
        question.taskDescriptor = stored.taskDescriptor
    }
    let transcript = questionText
    let answerMode = selectedAnswerProviderMode
    let providerConfiguration = activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
    let localProvider = localLLMProviderOverride ?? OllamaQwenProvider()
    let localModelName = selectedQwenModelName
    let prefetchAdmission = liveRAGPrefetch.cacheAdmission
    let retrievalService = contextRetrievalService?.freezeConfiguration()
    freezeConversationContext(for: &question)
    let consentTicket = persistenceConsent.ticket()

    lastRegenerateQuestionID = question.id
    lastRegenerateSourceTextKind = "accepted_question"
    lastRegenerateOldGenerationID = oldGenerationID
    lastRegenerateNewGenerationID = nil
    lastRegenerateRejectionReason = ""
    recordLifecycleTrace(
        "regenerate.requested",
        sessionID: session.id,
        questionID: question.id,
        generationID: oldGenerationID,
        text: questionText,
        reason: "sourceTextKind=accepted_question"
    )

    beginAction(ActionID.generateAnswer, title: "Regenerating first answer", message: "Using the current visible question.")
    startGenerationRequest(triggerPath: .manualGenerate) { [weak self] requestID in
        guard let self else { return }
        do {
            guard !Task.isCancelled, self.generationCoordinator.isCurrentRequest(requestID),
                  self.currentSession?.id == session.id,
                  self.currentSession?.contextSnapshotID == session.contextSnapshotID else { return }
            if self.persistenceConsent.isCurrent(ticket: consentTicket) {
                try self.persistenceConsent.write(ticket: consentTicket) {
                    try self.suggestionRepository.saveRegeneratedQuestion(question)
                }
            }
            guard !Task.isCancelled, self.generationCoordinator.isCurrentRequest(requestID),
                  self.currentSession?.id == session.id,
                  self.currentSession?.contextSnapshotID == session.contextSnapshotID else { return }
            try await self.generateSuggestion(
                for: question,
                session: session,
                transcript: transcript,
                autoGenerated: false,
                triggerPath: .manualGenerate,
                source: source,
                speaker: speaker,
                requestID: requestID,
                localProvider: localProvider,
                localModelName: localModelName,
                answerMode: answerMode,
                providerConfiguration: providerConfiguration,
                retrievalService: retrievalService,
                prefetchAdmission: prefetchAdmission,
                consentTicket: consentTicket
            )
        } catch {
            @MainActor func acceptsFailure() -> Bool {
                !Task.isCancelled && !self.isShuttingDown && self.generationCoordinator.isCurrentRequest(requestID) &&
                    self.currentSession?.id == session.id && self.currentSession?.contextSnapshotID == session.contextSnapshotID
            }
            guard acceptsFailure() else { return }
            let message = self.userFacing(error)
            if let rejected = error as? RuntimeQuestionRejectedError {
                self.lastRegenerateRejectionReason = rejected.reason.rawValue
            } else {
                self.lastRegenerateRejectionReason = message
            }
            guard acceptsFailure() else { return }
            self.liveState = .error(message)
            guard acceptsFailure() else { return }
            self.failGenerationNonBlocking(message: "Current question preserved. \(message)", whileCurrent: acceptsFailure)
        }
    }
}

// internal for AppState extension access only
func markProviderStreamOwnership(
    _ card: inout SuggestionCard,
    source: String = "deepseek_stream",
    modelName: String? = nil
) {
    let provider = generationProviderConfiguration
    let fallbackProvider = LLMProviderConfiguration.deepSeekDefault(model: modelName ?? provider?.model ?? "deepseek-v4-flash")
    let resolvedProvider = provider ?? fallbackProvider

    card.modelName = modelName ?? resolvedProvider.model
    card.providerKind = resolvedProvider.kind
    card.providerName = resolvedProvider.name
    card.providerBaseURL = resolvedProvider.baseURL
    card.isLocal = false
    card.sayFirstSource = source
    card.finalVisibleSource = source
    card.softFallbackUsed = false
    card.softFallbackLatencyMS = nil
    softFallbackUsed = false
    softFallbackLatencyMS = nil
    finalVisibleSource = source
}

// MARK: - Visible Fallbacks

// internal for AppState extension access only
func showDuplicateQuestionNotice(for question: DetectedQuestion, session: InterviewSession) {
    let card = SuggestionCard(
        id: UUID().uuidString,
        sessionID: session.id,
        questionID: question.id,
        strategy: "Similar question already answered",
        sayFirst: "I’ve already answered a very similar question. I would briefly refer back to that answer and add one new detail if needed.",
        keyPoints: ["Reuse the previous answer", "Add one fresh detail", "Keep it concise"],
        followUpReady: [],
        confidence: 0.72,
        caution: nil,
        evidenceUsed: [],
        riskLevel: .low,
        modelName: "duplicate-question-notice",
        promptVersion: "duplicate-question-notice-v1",
        providerKind: .openAICompatible,
        providerName: "Local Question Extractor",
        providerBaseURL: "",
        latencyMS: 0,
        isLocal: true,
        rawJSON: nil,
        createdAt: Date(),
        sayFirstSource: "duplicate_question_notice"
    )
    if displaySuggestionIfAligned(
        card,
        question: question,
        generationID: nil,
        triggerPath: .autoDetect,
        source: .systemAudio,
        speaker: SpeakerRole(rawValue: lastDetectedQuestionSpeaker),
        allowInactiveGeneration: true
    ) {
        currentSuggestionSetAt = Date()
        generationUIState = .idle
        lastTranscriptQuestionGenerationTrace.currentSuggestionExists = true
    }
}

// internal for AppState extension access only
@discardableResult
func showImmediateFallbackForActiveGenerationIfNeeded(reason: String) -> Bool {
    guard let controller = activeGenerationController,
          let session = currentSession,
          let question = lastDetectedQuestion,
          question.id == controller.questionID else { return false }
    let identity = controller.identity
    let providerMode = generationAnswerProviderMode
    @MainActor func acceptsPublication() -> Bool {
        !Task.isCancelled && generationCoordinator.canPublish(identity) &&
            currentSession?.id == session.id
    }
    let admitted = generationCoordinator.applyImmediateFirstAnswerFallback(
        identity: identity, providerModeIfUnspecified: providerMode,
        presentation: { [weak self] _ in
            guard let self, acceptsPublication() else { return nil }
            return (self.generationUIState.isLoadingWithoutVisibleAnswer, self.visibleAnswerExists)
        },
        onFallback: { [weak self] admittedIdentity, elapsed, retireWatchdog in
            guard let self, admittedIdentity == identity, acceptsPublication() else { return false }
            self.softFallbackUsed = true
            guard acceptsPublication() else { return false }
            self.softFallbackLatencyMS = elapsed
            guard acceptsPublication() else { return false }
            self.softFallbackShownAt = Date()
            guard acceptsPublication() else { return false }
            self.finalVisibleSource = "local_first_answer_fallback"
            guard acceptsPublication() else { return false }

            var fallbackCard = self.makeInitialFirstAnswerFallbackCard(
                cardID: UUID().uuidString, question: question, session: session,
                requestStart: controller.startedAt
            )
            fallbackCard.firstVisibleAnswerMS = elapsed
            if !fallbackCard.keyPoints.isEmpty {
                fallbackCard.firstKeyPointVisibleMS = elapsed
                fallbackCard.allKeyPointsVisibleMS = elapsed
            }
            if !fallbackCard.followUpReady.isEmpty {
                fallbackCard.followUpVisibleMS = elapsed
            }
            guard acceptsPublication(), self.displaySuggestionIfAligned(
                fallbackCard, question: question, generationID: identity.generationID,
                triggerPath: controller.triggerPath, whileCurrent: acceptsPublication
            ), acceptsPublication() else { return false }
            self.currentSuggestionSetAt = Date()
            guard acceptsPublication() else { return false }
            self.isStreamingSayFirst = false
            guard acceptsPublication() else { return false }
            self.isExpandingSuggestionCard = true
            guard acceptsPublication(), retireWatchdog(), acceptsPublication() else { return false }
            self.markFirstVisibleAnswer(generationID: identity.generationID, fallback: true,
                whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return false }
            self.setGenerationUIState(
                .showingFallback(questionID: question.id, generationID: identity.generationID,
                    triggerPath: controller.triggerPath),
                generationID: identity.generationID, whileCurrent: acceptsPublication
            )
            guard acceptsPublication() else { return false }
            self.infoAction(ActionID.generateAnswer, title: "First answer visible",
                message: "Kept the current answer visible while ignoring non-question system audio.",
                autoDismissAfter: 3.0, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return false }
            print("[SystemAudioClassifier] Immediate fallback shown for active generation after ignoring system audio: \(reason)")
            return true
        }
    )
    if !admitted, (controller.answerProviderMode ?? providerMode) == .localQwenPrimary, acceptsPublication() {
        recordLifecycleTrace("fallback.skipped", questionID: identity.acceptedQuestionID,
            generationID: identity.generationID, text: lastDetectedQuestionText,
            reason: "local_qwen_primary_no_template_fallback", skipped: true)
    }
    return admitted
}

// internal for AppState extension access only
func applyPendingIgnoredSystemAudioFallbackIfNeeded(for question: DetectedQuestion) {
    guard let pending = pendingIgnoredSystemAudioFallback else { return }
    guard pending.questionID == question.id else {
        pendingIgnoredSystemAudioFallback = nil
        return
    }
    pendingIgnoredSystemAudioFallback = nil
    _ = showImmediateFallbackForActiveGenerationIfNeeded(reason: pending.reason)
}

// internal for AppState extension access only
@discardableResult
func replaceIncompleteVisibleAnswerWithFallbackIfNeeded(
    card: SuggestionCard,
    question: DetectedQuestion,
    session: InterviewSession,
    generationID: String,
    requestStart: Date,
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType? = nil,
    speaker: SpeakerRole? = nil,
    reason: String
) -> Bool {
    guard let incompleteReason = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(card.sayFirst) else {
        return false
    }
    recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
        sessionID: session.id,
        questionID: question.id,
        generationID: generationID,
        question: question.questionText,
        reason: "\(reason): \(incompleteReason)",
        timestamp: Date()
    ))
    var fallbackCard = makeInitialFirstAnswerFallbackCard(
        cardID: card.id,
        question: question,
        session: session,
        requestStart: requestStart
    )
    let elapsed = elapsedMS(since: requestStart)
    fallbackCard.firstVisibleAnswerMS = card.firstVisibleAnswerMS ?? elapsed
    fallbackCard.stageBCompleted = true
    fallbackCard.stageBStatus = "incomplete_stream_fallback"
    fallbackCard.caution = "Provider answer was incomplete, so a local first answer is shown."
    fallbackCard.sayFirstSource = "local_incomplete_stream_fallback"
    fallbackCard.finalVisibleSource = "local_incomplete_stream_fallback"
    guard displaySuggestionIfAligned(
        fallbackCard,
        question: question,
        generationID: generationID,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker
    ) else { return false }
    currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
    isStreamingSayFirst = false
    isExpandingSuggestionCard = true
    softFallbackUsed = true
    softFallbackLatencyMS = softFallbackLatencyMS ?? elapsed
    softFallbackShownAt = softFallbackShownAt ?? Date()
    finalVisibleSource = fallbackCard.finalVisibleSource
    markFirstVisibleAnswer(generationID: generationID, fallback: true)
    setGenerationUIState(.showingFallback(questionID: question.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
    recordTranscriptRuntimeEvent(.fallbackUsedForIncompleteStream(
        sessionID: session.id,
        questionID: question.id,
        generationID: generationID,
        question: question.questionText,
        reason: incompleteReason,
        timestamp: Date()
    ))
    return true
}

// Synchronous UI/evidence application for a frozen Stage A deadline. The
// coordinator owns the deadline task and the successful-application marker.
func preserveStageAAnswerWhileExpansionContinues(
    context: GenerationExecutionContext,
    cardID: String,
    answerProviderConfiguration: LLMProviderConfiguration?,
    fallbackProviderModel: String,
    generationRetrievedChunks: [RetrievedChunk]
) -> Bool {
    let generationID = context.generationID
    let localQuestion = context.question
    let localSession = context.session
    let requestStart = context.startedAt
    let triggerPath = context.triggerPath
    let telemetrySource = context.source
    let telemetrySpeaker = context.speaker
    guard self.generationCoordinator.canPublish(context.identity),
          !self.generationUIState.isTerminal, !Task.isCancelled else {
        return false
    }

    if self.generationCoordinator.hasPreservedStageADeadlineAnswer(identity: context.identity) { return true }

    let streamed = self.streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines)
    var eligibleCard: SuggestionCard?
    if let current = self.currentSuggestion,
       self.visibleCardMatchesGeneration(
            card: current, generationID: generationID,
            detectedQuestionID: localQuestion.id,
            promptPrimaryQuestion: localQuestion.questionText
       ),
       QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(current.sayFirst) == nil,
       QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(current).accepted {
        eligibleCard = current
    } else if !streamed.isEmpty {
        var providerCard = self.makeRAGFallbackCard(context: context, cardID: cardID, isSoft: true)
        providerCard.strategy = "DeepSeek First Answer"
        providerCard.sayFirst = AnswerQualityValidator.localCleanupAnswer(streamed)
        providerCard.keyPoints = []
        providerCard.followUpReady = []
        providerCard.modelName = answerProviderConfiguration?.model ?? fallbackProviderModel
        providerCard.providerKind = answerProviderConfiguration?.kind
        providerCard.providerName = answerProviderConfiguration?.name ?? "DeepSeek"
        providerCard.providerBaseURL = answerProviderConfiguration?.baseURL ?? "https://api.deepseek.com"
        providerCard.isLocal = false
        providerCard.generationID = generationID
        providerCard.questionText = localQuestion.questionText
        providerCard.transcriptSegmentID = localQuestion.transcriptSegmentID
        providerCard.source = telemetrySource?.rawValue
        providerCard.speaker = telemetrySpeaker?.rawValue
        providerCard.triggerPath = triggerPath
        self.markProviderStreamOwnership(&providerCard, source: "deepseek_stream_timeout", modelName: providerCard.modelName)
        providerCard.stageATimedOut = true
        providerCard.deepseekFirstTokenMS = self.deepseekFirstTokenMS
        providerCard.deepseekFirstVisibleMS = self.deepseekFirstVisibleMS
        providerCard.firstVisibleAnswerMS = self.deepseekFirstVisibleMS ?? self.elapsedMS(since: requestStart)
        eligibleCard = self.completeSubstantiveProviderFirstAnswerAfterTimeout(
            providerCard, question: localQuestion, requestStart: requestStart
        )
    }

    // A Stage A deadline does not end Stage B. An incomplete or absent
    // provider preview needs the existing grounded fallback while that
    // expansion remains active, rather than a whole-request failure.
    var card = eligibleCard ?? self.makeRAGFallbackCard(context: context, cardID: cardID, isSoft: self.stageBTask != nil)
    card.sayFirst = AnswerQualityValidator.localCleanupAnswer(card.sayFirst)
    let fallback = card.isLocal || card.sayFirstSource?.contains("fallback") == true
    if fallback {
        self.softFallbackUsed = true
        guard self.generationCoordinator.canPublish(context.identity) else { return false }
        self.softFallbackLatencyMS = card.softFallbackLatencyMS ?? self.elapsedMS(since: requestStart)
        guard self.generationCoordinator.canPublish(context.identity) else { return false }
        self.softFallbackShownAt = self.softFallbackShownAt ?? Date()
        guard self.generationCoordinator.canPublish(context.identity) else { return false }
    }
    let preserved = self.preserveVisibleFirstAnswerWhileStageBContinues(
        card, generationID: generationID, question: localQuestion,
        session: localSession, requestStart: requestStart,
        retrievedChunks: generationRetrievedChunks, triggerPath: triggerPath,
        source: telemetrySource, speaker: telemetrySpeaker,
        caution: "DeepSeek first-answer stream did not finish; keeping the visible answer while the full answer expands.",
        stageATimedOut: card.stageATimedOut ?? !fallback, fallback: fallback
    )
    // The owner marker publishes synchronously. Its observer may activate a
    // replacement, so old presentation cleanup must use the returned admission.
    guard preserved,
          self.generationCoordinator.recordPreservedStageADeadlineAnswer(identity: context.identity),
          self.generationCoordinator.canPublish(context.identity) else { return false }
    self.streamedSayFirst = ""
    guard self.generationCoordinator.canPublish(context.identity) else { return false }
    self.finalVisibleSource = self.currentSuggestion?.finalVisibleSource
    return self.generationCoordinator.canPublish(context.identity)
}

// internal for AppState extension access only
@discardableResult
func preserveVisibleFirstAnswerWhileStageBContinues(
    _ card: SuggestionCard,
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    retrievedChunks: [RetrievedChunk],
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType?,
    speaker: SpeakerRole?,
    caution: String,
    stageATimedOut: Bool,
    fallback: Bool
) -> Bool {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID, identity.acceptedQuestionID == question.id,
          generationCoordinator.canPublish(identity) else {
        recordStaleGenerationDiscard()
        return false
    }
    let whileCurrent = { self.generationCoordinator.canPublish(identity) }

    if replaceIncompleteVisibleAnswerWithFallbackIfNeeded(
        card: card,
        question: question,
        session: session,
        generationID: generationID,
        requestStart: requestStart,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker,
        reason: caution
    ) {
        guard whileCurrent(), var fallbackCard = currentSuggestion else { return false }
        fallbackCard.stageATimedOut = stageATimedOut
        fallbackCard.stageBCompleted = false
        fallbackCard.stageBStatus = "expanding"
        fallbackCard.caution = caution
        currentSuggestion = fallbackCard
        guard whileCurrent() else { return false }
        currentSuggestionRetrievedChunks = retrievedChunks
        setGenerationUIState(
            .showingFallback(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
            generationID: generationID, whileCurrent: whileCurrent
        )
        return whileCurrent()
    }

    var visibleCard = card
    visibleCard.stageATimedOut = stageATimedOut
    visibleCard.stageBCompleted = false
    visibleCard.stageBStatus = "expanding"
    visibleCard.caution = visibleCard.caution ?? caution
    visibleCard.latencyFirstTokenMS = visibleCard.latencyFirstTokenMS ?? deepseekFirstTokenMS
    visibleCard.latencyFirstVisibleMS = visibleCard.latencyFirstVisibleMS ?? deepseekFirstVisibleMS
    visibleCard.deepseekFirstTokenMS = visibleCard.deepseekFirstTokenMS ?? deepseekFirstTokenMS
    visibleCard.deepseekFirstVisibleMS = visibleCard.deepseekFirstVisibleMS ?? deepseekFirstVisibleMS
    visibleCard.firstVisibleAnswerMS = visibleCard.firstVisibleAnswerMS ?? deepseekFirstVisibleMS ?? elapsedMS(since: requestStart)
    if visibleCard.keyPoints.isEmpty {
        visibleCard.keyPoints = AnswerRelevancePolicy.fallbackAnswer(for: question).keyPoints
    }
    if !visibleCard.keyPoints.isEmpty {
        visibleCard.firstKeyPointVisibleMS = visibleCard.firstKeyPointVisibleMS ?? visibleCard.firstVisibleAnswerMS
    }

    guard displaySuggestionIfAligned(
        visibleCard,
        question: question,
        generationID: generationID,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker,
        whileCurrent: whileCurrent
    ) else { return false }

    currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
    guard whileCurrent() else { return false }
    currentSuggestionRetrievedChunks = retrievedChunks
    guard whileCurrent() else { return false }
    isStreamingSayFirst = false
    guard whileCurrent() else { return false }
    isExpandingSuggestionCard = true
    guard whileCurrent() else { return false }
    markFirstVisibleAnswer(generationID: generationID, fallback: fallback, whileCurrent: whileCurrent)
    guard whileCurrent() else { return false }
    // Keep the visible answer while expansion still owns the request. Claim
    // its logical persistence key at terminal completion (or an explicit
    // superseded-history boundary), so this provisional status cannot prevent
    // the final card and its source/timeout metadata from being saved.
    setGenerationUIState(
        fallback
            ? .showingFallback(questionID: question.id, generationID: generationID, triggerPath: triggerPath)
            : .expandingFullAnswer(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
        generationID: generationID, whileCurrent: whileCurrent
    )
    return whileCurrent()
}

private func makeLocalManualDetection(session: InterviewSession, capturedSegments: [TranscriptSegment]) throws
    -> (question: DetectedQuestion, response: LLMChatResult) {
    // Resolve raw input and its parent synchronously at the user action. The
    // queued request must not bind whichever card becomes visible afterwards.
    let extracted = capturedSegments.reversed()
        .compactMap { segment in
            SystemAudioQuestionExtractor.extract(from: segment.text, allowContextDependent: true).last
                .map { (candidate: $0, segmentID: segment.id) }
        }
        .first
    guard let extracted else {
        throw RuntimeQuestionRejectedError(reason: .pipelineRejected,
            diagnostic: "No complete question was found by local question extraction. Review the transcript and try again.")
    }
    let candidate = extracted.candidate
    let payload = """
    {"should_trigger":true,"question_complete":true,"question_text":\(JSONParsing.jsonString(candidate.text)),"intent":"\(candidate.intent.rawValue)","answer_strategy":"\(candidate.answerStrategy.rawValue)","confidence":\(candidate.confidence),"reason":"Local-only Answer Now question extraction."}
    """
    var question = DetectedQuestion(id: UUID().uuidString, sessionID: session.id,
        transcriptSegmentID: extracted.segmentID, questionText: candidate.text,
        intent: candidate.intent, answerStrategy: candidate.answerStrategy,
        confidence: candidate.confidence, reason: "Local-only Answer Now question extraction.",
        shouldTrigger: true, questionComplete: true, modelName: "local-question-extractor",
        promptVersion: "local-extractor-v1", providerKind: .openAICompatible,
        providerName: "Local Question Extractor", providerBaseURL: "", latencyMS: 0,
        isLocal: true, rawJSON: payload, createdAt: Date())
    freezeConversationContext(for: &question)
    return (question, LLMChatResult(content: payload, modelName: "local-question-extractor",
        providerKind: .openAICompatible, providerName: "Local Question Extractor",
        baseURL: "", latencyMS: 0, isLocal: true, rawResponse: payload))
}

private func runManualAnswer(session: InterviewSession, transcript: String,
    capturedSegments: [TranscriptSegment],
    localDetection: Result<(question: DetectedQuestion, response: LLMChatResult), Error>?,
    localProvider: any LocalLLMProvider, localModelName: String,
    answerMode: AnswerProviderMode, providerConfiguration: LLMProviderConfiguration?,
    retrievalService: (any ContextRetrievalService)?,
    prefetchAdmission: LiveRAGPrefetch.CacheAdmission?,
    parentCard: SuggestionCard?, parentMode: InterviewSessionMode,
    requestID: String) async {
    do {
        liveState = .detectingQuestion
        let detection: (question: DetectedQuestion, response: LLMChatResult)
        if let localDetection {
            detection = try localDetection.get()
        } else {
            guard let providerConfiguration else {
                throw LLMProviderError.notConfigured("Realtime LLM provider")
            }
            detection = try await questionDetectionService.detect(
                transcriptContext: transcript,
                sessionID: session.id,
                transcriptSegmentID: capturedSegments.last?.id,
                model: providerConfiguration.model,
                providerConfiguration: providerConfiguration
            )
        }
        guard !Task.isCancelled, generationCoordinator.isCurrentRequest(requestID) else { return }
        self.lastQuestionDetectionProvider = detection.response.providerName
        self.lastQuestionDetectionModel = detection.response.modelName
        var question = detection.question
        if localDetection == nil {
            freezeConversationContext(for: &question, parentCard: parentCard, mode: parentMode)
        }
        saveDetectedQuestionInBackground(question)
        updateDiagnostics {
            $0.lastDetectedQuestionJSON = detection.question.rawJSON
            $0.lastAPILatencyMS = detection.response.latencyMS
            $0.lastProviderName = detection.response.providerName
            $0.lastProviderModel = detection.response.modelName
            if !detection.response.isLocal { $0.apiCallCount += 1 }
        }

        lastDetectedQuestion = question
        if question.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            question.questionText = capturedSegments.last?.text ?? transcript
        }
        let segment = capturedSegments.first { $0.id == question.transcriptSegmentID }
        try await generateSuggestion(for: question, session: session, transcript: transcript,
            autoGenerated: false, source: segment?.source, speaker: segment?.speaker,
            requestID: requestID, localProvider: localProvider, localModelName: localModelName,
            answerMode: answerMode, providerConfiguration: providerConfiguration,
            retrievalService: retrievalService, prefetchAdmission: prefetchAdmission)
    } catch {
        func acceptsFailure() -> Bool {
            !Task.isCancelled && !isShuttingDown && generationCoordinator.isCurrentRequest(requestID) &&
                currentSession?.id == session.id && currentSession?.contextSnapshotID == session.contextSnapshotID
        }
        guard acceptsFailure() else { return }
        let message = userFacing(error)
        liveState = .error(message)
        guard acceptsFailure() else { return }
        failGenerationNonBlocking(message: "Transcript preserved. \(message)", whileCurrent: acceptsFailure)
        guard acceptsFailure() else { return }
        
        
    }
}

func cancelStageBTask() {
    let hadActiveStageB = stageBTaskActive
    if hadActiveStageB {
        print("[StageB] Cancelled active background Stage B suggestion task.")
    }
    cancelActiveGenerationForStop()
}

// The frozen execution context carries question, session, prompt and evidence
// identities. This synchronous application boundary keeps its repository and
// display-timing reads out of the deadline task's captured dependencies.
func makeRAGFallbackCard(context: GenerationExecutionContext, cardID: String, isSoft: Bool) -> SuggestionCard {
    let localQuestion = context.question
    let localSession = context.session
    let generationSnapshot = context.interviewContextSnapshot
    let promptSnapshot = context.promptSnapshot
    let requestStart = context.startedAt
    let allowsProfileFallback = PromptContextBuilder.usesProfileContext(
        promptSnapshot.taskDescriptor ?? InterviewTaskDescriptor(question: localQuestion.questionText)
    )
    // Computation uses the already-frozen value. Display admission below still
    // checks that this snapshot exists, and persistence separately checks consent.
    let grounded: (result: GroundedFallbackResult, snapshot: InterviewContextSnapshot)?
    if allowsProfileFallback, let snapshot = generationSnapshot {
        let result = DynamicInterviewContextEngine().profileSafeFallback(
            question: localQuestion.questionText, snapshot: snapshot
        )
        grounded = result.status == .grounded && result.unsupportedClaims.isEmpty
            ? (result, snapshot) : nil
    } else {
        grounded = nil
    }
    let selectedEvidenceIDs: Set<String> = Set(grounded?.result.candidateEvidenceIDs ?? [])
    let keyPoints: [String] = grounded?.snapshot.candidateEvidence
        .filter { selectedEvidenceIDs.contains($0.id) }
        .map(\.statement) ?? []
    let intent = AnswerRelevancePolicy.intent(for: localQuestion.questionText)

    var card = SuggestionCard(
        id: cardID,
        sessionID: localSession.id,
        questionID: localQuestion.id,
        strategy: isSoft ? "RAG Template Soft Fallback (DeepSeek Delay)" : "RAG Template Fallback (DeepSeek Timeout)",
        sayFirst: grounded?.result.answer ?? "",
        keyPoints: keyPoints,
        followUpReady: ["How does this align with the role requirements?"],
        confidence: 0.5,
        caution: isSoft ? "Fast local answer shown; DeepSeek still generating..." : "Fast fallback shown; DeepSeek still expanding...",
        evidenceUsed: (grounded?.result.candidateEvidenceIDs ?? []) + (grounded?.result.opportunityEvidenceIDs ?? []),
        riskLevel: .medium,
        modelName: "rag-fallback",
        promptVersion: "fallback-v1",
        providerKind: nil,
        providerName: "RAG Template Fallback",
        providerBaseURL: "",
        latencyMS: Int(Date().timeIntervalSince(requestStart) * 1000),
        isLocal: true,
        rawJSON: nil,
        createdAt: Date(),
        questionIntent: intent,
        promptQuestionText: localQuestion.questionText,
        promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion,
        promptContainsPreviousQuestion: promptSnapshot.promptContainsPreviousQuestion,
        previousQuestionIncluded: promptSnapshot.previousQuestionIncluded,
        previousQuestionText: promptSnapshot.previousQuestionText,
        contextBleedRisk: promptSnapshot.contextBleedRisk,
        ragChunkIDs: promptSnapshot.ragChunkIDs,
        ragChunkIntents: promptSnapshot.ragChunkIntents,
        promptTokenEstimate: promptSnapshot.promptTokenEstimate,
        promptContextPreview: promptSnapshot.ragChunkPreviews.joined(separator: "\n"),
        sayFirstSource: isSoft ? "rag_template_soft_fallback" : "rag_template_fallback",
        stageATimedOut: !isSoft,
        stageBCompleted: false,
        stageBStatus: "skipped",
        latencyFirstTokenMS: deepseekFirstTokenMS,
        latencyFirstVisibleMS: deepseekFirstVisibleMS,
        latencyFullCardMS: nil,
        softFallbackUsed: isSoft,
        softFallbackLatencyMS: isSoft ? Int(Date().timeIntervalSince(requestStart) * 1000) : nil,
        deepseekFirstTokenMS: deepseekFirstTokenMS,
        deepseekFirstVisibleMS: deepseekFirstVisibleMS,
        finalVisibleSource: isSoft ? "rag_template_soft_fallback" : "rag_template_fallback"
    )
    card.contextSnapshotID = generationSnapshot?.id
    card.candidateProfileID = generationSnapshot?.candidateProfileID
    card.candidateProfileVersion = generationSnapshot?.candidateProfileVersion
    card.opportunityContextID = generationSnapshot?.opportunityContextID
    card.opportunityContextVersion = generationSnapshot?.opportunityContextVersion
    card.domainProfileID = generationSnapshot?.domainProfileID
    card.candidateEvidenceIDs = grounded?.result.candidateEvidenceIDs ?? []
    card.opportunityEvidenceIDs = grounded?.result.opportunityEvidenceIDs ?? []
    card.groundingDecision = grounded?.result.groundingDecision ?? "context_snapshot_missing"
    card.unsupportedClaimCount = grounded?.result.unsupportedClaims.count ?? 0
    card.contextIsolationStatus = grounded == nil ? "missing" : "matched"
    return card
}

// internal for AppState extension access only
func makeInitialFirstAnswerFallbackCard(
    cardID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date
) -> SuggestionCard {
    let grounded = groundedFallback(
        for: question.questionText,
        contextSnapshotID: session.contextSnapshotID ?? activeGenerationController?.identity.contextSnapshotID,
        task: question.taskDescriptor
    )
    let answer = grounded?.result.answer ?? ""
    let keyPoints: [String] = grounded.map { grounded in
        let selected = Set(grounded.result.candidateEvidenceIDs)
        return grounded.snapshot.candidateEvidence.filter { selected.contains($0.id) }.map(\.statement)
    } ?? []
    var card = SuggestionCard(
        id: cardID,
        sessionID: session.id,
        questionID: question.id,
        strategy: "Local First Answer Fallback",
        sayFirst: answer,
        keyPoints: keyPoints,
        followUpReady: ["I can expand with a concrete example if helpful."],
        confidence: 0.45,
        caution: "Fast local answer shown while the full answer is still generating.",
        evidenceUsed: [],
        riskLevel: .medium,
        modelName: "local-first-answer-fallback",
        promptVersion: "local-first-answer-v1",
        providerKind: nil,
        providerName: "Local First Answer Fallback",
        providerBaseURL: "",
        latencyMS: Int(Date().timeIntervalSince(requestStart) * 1000),
        isLocal: true,
        rawJSON: nil,
        createdAt: Date(),
        questionIntent: AnswerRelevancePolicy.intent(for: question.questionText),
        promptQuestionText: question.questionText,
        promptPrimaryQuestion: question.questionText,
        promptContainsPreviousQuestion: false,
        previousQuestionIncluded: false,
        previousQuestionText: nil,
        contextBleedRisk: .low,
        ragChunkIDs: [],
        ragChunkIntents: [],
        promptTokenEstimate: AnswerRelevancePolicy.estimateTokens(question.questionText),
        sayFirstSource: "local_first_answer_fallback",
        stageATimedOut: false,
        stageBCompleted: false,
        stageBStatus: "expanding",
        latencyFirstTokenMS: nil,
        latencyFirstVisibleMS: nil,
        latencyFullCardMS: nil,
        softFallbackUsed: true,
        softFallbackLatencyMS: Int(Date().timeIntervalSince(requestStart) * 1000),
        deepseekFirstTokenMS: nil,
        deepseekFirstVisibleMS: nil,
        finalVisibleSource: "local_first_answer_fallback"
    )
    if let grounded {
        card.contextSnapshotID = grounded.snapshot.id
        card.candidateProfileID = grounded.snapshot.candidateProfileID
        card.candidateProfileVersion = grounded.snapshot.candidateProfileVersion
        card.opportunityContextID = grounded.snapshot.opportunityContextID
        card.opportunityContextVersion = grounded.snapshot.opportunityContextVersion
        card.domainProfileID = grounded.snapshot.domainProfileID
        card.candidateEvidenceIDs = grounded.result.candidateEvidenceIDs
        card.opportunityEvidenceIDs = grounded.result.opportunityEvidenceIDs
        card.groundingDecision = grounded.result.groundingDecision
        card.unsupportedClaimCount = grounded.result.unsupportedClaims.count
        card.contextIsolationStatus = "matched"
    } else {
        card.groundingDecision = "context_snapshot_missing"
        card.unsupportedClaimCount = 0
        card.contextIsolationStatus = "missing"
    }
    return card
}

// internal for AppState extension access only
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await GenerationCoordinator.withTimeout(
        seconds: seconds,
        delayProvider: generationWatchdogDelayProvider,
        operation: operation
    )
}

// MARK: - Quality Guards

/// Formatting cleanup stays local and has no publication or persistence side
/// effects. Provider repair belongs to the existing owned generation/retry path,
/// whose result passes the frozen question, evidence and persistence gates.
/// The legacy signature is retained for existing callers.
func validateAndRewriteIfNeeded(_ card: SuggestionCard, generationID: String) async -> SuggestionCard {
    var updated = card
    updated.sayFirst = AnswerQualityValidator.localCleanupAnswer(card.sayFirst)
    return updated
}

// internal for AppState extension access only
func elapsedMS(since start: Date) -> Int {
    GenerationCoordinator.elapsedMS(since: start)
}

public var activeGenerationElapsedMs: Int? {
    guard let activeGenerationStartedAt else { return nil }
    return elapsedMS(since: activeGenerationStartedAt)
}

public var currentSpinnerVisible: Bool {
    shouldShowBlockingAnswerSpinner
}

public var visibleAnswerExists: Bool { liveInterview.visibleAnswerExists }

public var shouldShowBlockingAnswerSpinner: Bool {
    liveInterview.shouldShowBlockingAnswerSpinner(generationState: generationUIState,
        elapsedMS: activeGenerationElapsedMs ?? currentGenerationTelemetry.elapsedMs ?? 0)
}

public var shouldShowAnswerExpansionStatus: Bool {
    liveInterview.shouldShowAnswerExpansionStatus(generationState: generationUIState,
        isExpanding: isExpandingSuggestionCard)
}

var visibleSuggestionState: VisibleSuggestionState? {
    liveInterview.visibleSuggestionState(activeIdentity: activeGenerationController?.identity,
        generationState: generationUIState)
}

var currentGenerationErrorText: String? {
    liveInterview.generationErrorText(for: generationUIState)
}

var visibleAssistantRenderState: VisibleAssistantRenderState {
    liveInterview.renderState(activeIdentity: activeGenerationController?.identity,
        generationState: generationUIState,
        elapsedMS: activeGenerationElapsedMs ?? currentGenerationTelemetry.elapsedMs ?? 0,
        isStreaming: isStreamingSayFirst, isExpanding: isExpandingSuggestionCard,
        providerStreamActive: providerStreamActive)
}

private func displayableAnswerText(_ text: String) -> String {
    liveInterview.displayableAnswerText(text)
}

private func hasDisplayableSayFirst(_ card: SuggestionCard) -> Bool {
    !liveInterview.displayableAnswerText(card.sayFirst).isEmpty
}

func visibleQuestionText(for card: SuggestionCard?) -> String? {
    liveInterview.visibleQuestionText(for: card,
        activeIdentity: activeGenerationController?.identity, generationState: generationUIState)
}

    // MARK: - Active Generation Lifecycle

    @discardableResult
    private func cancelActiveGenerationForReplacement() -> Bool {
    guard let controller = activeGenerationController else {
        generationCoordinator.invalidateAndCancel()
        return generationCoordinator.activeGeneration == nil && generationCoordinator.activeRequest == nil
    }

    let identity = controller.identity
    let requestID = generationCoordinator.activeRequest?.id
    previousGenerationID = controller.generationID
    guard generationCoordinator.isCurrent(identity),
          generationCoordinator.activeRequest?.id == requestID else { return false }
    let hasCancellableWork = generationHasCancellableWork(controller)
    let hasCompletedVisibleCard = generationUIState.isTerminal && currentSuggestion.map { visible in
        visibleCardMatchesGeneration(
            card: visible,
            generationID: controller.generationID,
            detectedQuestionID: controller.questionID,
            promptPrimaryQuestion: controller.questionTextSnapshot
        )
    } == true
    var revokedPersistenceOwnership = false
    if hasCancellableWork {
        cancelledGenerationCount += 1
        guard generationCoordinator.isCurrent(identity),
              generationCoordinator.activeRequest?.id == requestID else { return false }
    }
    if hasCancellableWork && !hasCompletedVisibleCard {
        revokedPersistenceOwnership = cancelledPersistenceGenerationIDs.insert(controller.generationID).inserted
        releaseUnpersistedSuggestionPersistenceClaims(forGenerationID: controller.generationID)
    }
    persistSupersededAcceptedQuestionSnapshotIfNeeded(controller: controller)
    if revokedPersistenceOwnership {
        rejectCancelledGenerationPersistence(controller: controller, reason: "generation_replaced")
    }
    guard generationCoordinator.isCurrent(identity),
          generationCoordinator.activeRequest?.id == requestID else { return false }
    generationCoordinator.invalidateAndCancel()
    // The owner has committed invalidation before its notification. Respect a
    // replacement admitted by that subscriber instead of revoking it again.
    guard generationCoordinator.activeGeneration == nil,
          generationCoordinator.activeRequest == nil else { return false }
    guard generationCoordinator.activeGeneration == nil,
          generationCoordinator.activeRequest == nil else { return false }
    providerStreamActive = false
    guard generationCoordinator.activeGeneration == nil,
          generationCoordinator.activeRequest == nil else { return false }
    updateActiveTaskSummary()
    return generationCoordinator.activeGeneration == nil && generationCoordinator.activeRequest == nil
}

// internal for AppState extension access only
@discardableResult
func cancelActiveGenerationForStop() -> Bool {
    let identity = generationCoordinator.activeGeneration?.identity
    let requestID = generationCoordinator.activeRequest?.id
    @MainActor func stillTargetsOriginal() -> Bool {
        generationCoordinator.activeGeneration?.identity == identity &&
            generationCoordinator.activeRequest?.id == requestID
    }
    @MainActor func stillOwnsRevokedPresentation() -> Bool {
        generationCoordinator.activeGeneration == nil && generationCoordinator.activeRequest == nil
    }
    if let controller = activeGenerationController {
        previousGenerationID = controller.generationID
        guard stillTargetsOriginal() else { return false }
        if generationHasCancellableWork(controller) {
            cancelledGenerationCount += 1
            guard stillTargetsOriginal() else { return false }
            cancelledPersistenceGenerationIDs.insert(controller.generationID)
            rejectCancelledGenerationPersistence(controller: controller, reason: "generation_stopped")
            guard stillTargetsOriginal() else { return false }
        }
    }
    guard stillTargetsOriginal() else { return false }
    generationCoordinator.invalidateAndCancel()
    guard stillOwnsRevokedPresentation() else { return false }
    suggestionGenerationStarted = false
    guard stillOwnsRevokedPresentation() else { return false }
    isStreamingSayFirst = false
    guard stillOwnsRevokedPresentation() else { return false }
    isExpandingSuggestionCard = false
    guard stillOwnsRevokedPresentation() else { return false }
    providerStreamActive = false
    guard stillOwnsRevokedPresentation() else { return false }
    updateActiveTaskSummary()
    return stillOwnsRevokedPresentation()
}

// A context change invalidates the whole answer request, including the
// top-level task that may still be waiting inside URLSession.
@discardableResult
func cancelActiveGenerationForContextChange() -> Bool {
    guard cancelActiveGenerationForStop() else { return false }
    @MainActor func stillOwnsRevokedPresentation() -> Bool {
        generationCoordinator.activeGeneration == nil && generationCoordinator.activeRequest == nil
    }
    // Revoking an answer request does not stop continuous capture. Restore
    // only states owned by that request, using the actual capture resources.
    let captureIsListening = anyCaptureRunning && stopReason == nil
    if liveState == .detectingQuestion || liveState == .generatingSuggestion {
        liveState = captureIsListening ? .listening : .ready
        guard stillOwnsRevokedPresentation() else { return false }
    }
    if currentCaptureRuntimeState == .generating {
        currentCaptureRuntimeState = captureIsListening ? .listening : .stopped(reason: stopReason)
        guard stillOwnsRevokedPresentation() else { return false }
    }
    currentSuggestion = nil
    guard stillOwnsRevokedPresentation() else { return false }
    currentSuggestionRetrievedChunks = []
    guard stillOwnsRevokedPresentation() else { return false }
    streamedSayFirst = ""
    guard stillOwnsRevokedPresentation() else { return false }
    generationUIState = .idle
    guard stillOwnsRevokedPresentation() else { return false }
    currentGenerationTelemetry = .idle
    guard stillOwnsRevokedPresentation() else { return false }
    clearActionFeedback(ActionID.generateAnswer)
    guard stillOwnsRevokedPresentation() else { return false }
    clearActionFeedback(ActionID.manualGenerate)
    guard stillOwnsRevokedPresentation() else { return false }
    clearActionFeedback(ActionID.floatingRegenerate)
    guard stillOwnsRevokedPresentation() else { return false }
    lastGenerationStateChangeAt = Date()
    guard stillOwnsRevokedPresentation() else { return false }
    updateActiveTaskSummary()
    return stillOwnsRevokedPresentation()
}

private func generationHasCancellableWork(_ controller: ActiveGenerationController) -> Bool {
    if controller.stageATask != nil ||
        controller.stageATimeoutTask != nil ||
        controller.stageBTask != nil ||
        controller.fallbackWatchdogTask != nil ||
        controller.fullCardWatchdogTask != nil {
        return true
    }
    return !terminalGenerationIDs.contains(controller.generationID) && !generationUIState.isTerminal
}

private func persistSupersededAcceptedQuestionSnapshotIfNeeded(
    controller: ActiveGenerationController
) {
    guard persistenceConsent.isCurrent(ticket: controller.persistenceTicket),
          controller.triggerPath == .autoDetect,
          let session = currentSession,
          session.id == controller.identity.sessionID else {
        return
    }
    guard !acceptedQuestionHistoryAlreadyExists(
        sessionID: session.id,
        questionID: controller.identity.acceptedQuestionID
    ) else {
        return
    }
    if generationUIState.isTerminal,
       let visible = currentSuggestion,
       visibleCardMatchesGeneration(
            card: visible,
            generationID: controller.generationID,
            detectedQuestionID: controller.questionID,
            promptPrimaryQuestion: controller.questionTextSnapshot
       ) {
        // The validated visible card already owns an asynchronous persistence
        // claim. Let that write finish instead of inserting a lower-fidelity
        // superseded snapshot for the same accepted question.
        return
    }
    let classified = IntentRouter.transcriptClassification(for: controller.identity.questionText)
    var question = DetectedQuestion(
        id: controller.identity.acceptedQuestionID,
        sessionID: controller.identity.sessionID,
        transcriptSegmentID: controller.identity.ingressIdentity?.sourceSegmentID,
        questionText: controller.identity.questionText,
        intent: classified.intent,
        answerStrategy: classified.strategy,
        confidence: max(classified.confidence, 0.72),
        reason: "Saved local history snapshot when a newer accepted question replaced active generation.",
        shouldTrigger: true,
        questionComplete: true,
        modelName: "local-replaced-generation-snapshot",
        promptVersion: "replaced-generation-snapshot-v1",
        providerKind: nil,
        providerName: "Local Question Snapshot",
        providerBaseURL: "",
        latencyMS: 0,
        isLocal: true,
        rawJSON: nil,
        createdAt: controller.startedAt,
        ingressIdentity: controller.identity.ingressIdentity
    )
    question.taskDescriptor = controller.questionSnapshot?.taskDescriptor
    persistAcceptedQuestionHistorySnapshot(
        for: question,
        session: session,
        stageBStatus: "superseded",
        finalVisibleSource: "local_superseded_question_snapshot",
        caution: "Local question snapshot retained after replacement; this record does not contain an accepted provider answer.",
        modelName: "local-replaced-generation-snapshot",
        promptVersion: "replaced-generation-snapshot-v1",
        stageBCompleted: false,
        softFallbackUsed: false,
        consentTicket: controller.persistenceTicket
    )
}

// internal for AppState extension access only
func supersedeActiveGenerationForQueuedQuestion() {
    guard let controller = activeGenerationController else { return }
    let generationID = controller.generationID
    let questionID = controller.questionID
    let triggerPath = controller.triggerPath

    setGenerationUIState(
        .cancelled(
            questionID: questionID,
            generationID: generationID,
            triggerPath: triggerPath,
            reason: "Superseded by a newer accepted interviewer question before an answer became visible."
        ),
        generationID: generationID
    )
    guard generationCoordinator.isCurrent(controller.identity),
          cancelActiveGenerationForReplacement() else { return }
    suggestionGenerationStarted = false
    isStreamingSayFirst = false
    isExpandingSuggestionCard = false
    providerStreamActive = false
    actionLoadingStates[ActionID.generateAnswer] = false
    updateActiveTaskSummary()
}

private func acceptedQuestionHistoryAlreadyExists(sessionID: String, questionID: String) -> Bool {
    guard let rows = try? suggestionRepository.suggestions(sessionID: sessionID) else {
        return false
    }
    return rows.contains { $0.detectedQuestionID == questionID }
}

private func releaseUnpersistedSuggestionPersistenceClaims(forGenerationID generationID: String) {
    suggestionPersistenceClaims = suggestionPersistenceClaims.filter {
        let identity = $0.value.identity
        guard identity.generationID == generationID else { return true }
        return acceptedQuestionHistoryAlreadyExists(
            sessionID: identity.sessionID,
            questionID: identity.acceptedQuestionID
        )
    }
}

private func rejectCancelledGenerationPersistence(
    controller: ActiveGenerationController,
    reason: String
) {
    let current = currentSuggestion
    recordTranscriptRuntimeEvent(.cancelledGenerationPersistenceRejected(
        sessionID: current?.sessionID ?? currentSession?.id ?? "",
        questionID: controller.questionID ?? current?.detectedQuestionID,
        generationID: controller.generationID,
        question: controller.questionTextSnapshot,
        reason: reason,
        timestamp: Date()
    ))
}

// internal for AppState extension access only
@discardableResult
func rejectCancelledPersistenceIfNeeded(
    card: SuggestionCard,
    generationID: String?,
    sourceCallback: String
) -> Bool {
    guard let generationID,
          cancelledPersistenceGenerationIDs.contains(generationID)
    else { return false }
    recordTranscriptRuntimeEvent(.cancelledGenerationPersistenceRejected(
        sessionID: card.sessionID,
        questionID: card.detectedQuestionID ?? card.questionID,
        generationID: generationID,
        question: card.questionText ?? card.promptPrimaryQuestion ?? card.promptQuestionText ?? "",
        reason: "cancelled_before_\(sourceCallback)",
        timestamp: Date()
    ))
    return true
}

// internal for AppState extension access only
func activateGeneration(
    question: DetectedQuestion,
    generationID: String,
    triggerPath: GenerationTriggerPath,
    requestStart: Date,
    source: AudioSourceType?,
    speaker: SpeakerRole?,
    requestID: String? = nil,
    providerConfiguration: LLMProviderConfiguration? = nil,
    answerProviderMode: AnswerProviderMode? = nil,
    persistenceTicket submittedTicket: Int? = nil,
    submittedIdentity: GenerationIdentity? = nil
) {
    if let submittedIdentity {
        let expected = GenerationIdentity(question: question, generationID: generationID,
            promptPrimaryQuestion: question.questionText, contextSnapshotID: submittedIdentity.contextSnapshotID)
        guard expected == submittedIdentity else { return }
    }
    // A new accepted question replaces the entire previous generation
    // controller. This is the main invariant that prevents consecutive
    // questions from sharing watchdogs, streams, or Stage B callbacks.
    if let requestID {
        guard generationCoordinator.isCurrentRequest(requestID) else { return }
    } else {
        guard cancelActiveGenerationForReplacement() else { return }
    }
    // An explicit submission also freezes absence. Do not borrow a later
    // context or configured provider when the original captured value was nil.
    let identity = submittedIdentity ?? GenerationIdentity(
        question: question,
        generationID: generationID,
        promptPrimaryQuestion: question.questionText,
        contextSnapshotID: activeContextSnapshot?.id ?? currentSession?.contextSnapshotID
    )
    let capturedProvider = submittedIdentity != nil
        ? providerConfiguration
        : providerConfiguration ?? activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
    generationCoordinator.activate(
        identity: identity,
        persistenceTicket: submittedTicket ?? persistenceConsent.ticket(),
        triggerPath: triggerPath,
        startedAt: requestStart,
        providerConfiguration: capturedProvider,
        answerProviderMode: answerProviderMode ?? selectedAnswerProviderMode,
        questionSnapshot: question
    )
    // Committed owner publication can synchronously accept a newer request.
    // Admission must be checked again before resetting its presentation.
    guard generationCoordinator.isCurrent(identity) else { return }
    providerStreamActive = false
    guard generationCoordinator.isCurrent(identity) else { return }
    currentSuggestion = nil
    guard generationCoordinator.isCurrent(identity) else { return }
    currentSuggestionRetrievedChunks = []
    guard generationCoordinator.isCurrent(identity) else { return }
    streamedSayFirst = ""
    guard generationCoordinator.isCurrent(identity) else { return }
    currentAnswerQuestionIntent = AnswerRelevancePolicy.intent(for: question.questionText)
    currentPromptQuestionText = question.questionText
    currentPromptPrimaryQuestion = question.questionText
    currentPromptContainsPreviousQuestion = false
    currentPreviousQuestionIncluded = false
    currentPreviousQuestionText = ""
    currentContextBleedRisk = .low
    currentRAGChunkIDs = []
    currentRAGChunkIntents = []
    currentFirstQuestionSuppressedReason = ""
    currentPromptTokenEstimate = nil
    currentPromptContextPreviews = []
    updateActiveTaskSummary()
    guard generationCoordinator.isCurrent(identity) else { return }
    beginGenerationUI(
        question: question,
        generationID: generationID,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker
    )
}

// internal for AppState extension access only
func isActiveGeneration(_ generationID: String) -> Bool {
    generationCoordinator.isCurrent(generationID)
}

// internal for AppState extension access only
func isActiveGeneration(_ generationID: String, questionID: String) -> Bool {
    isActiveGeneration(generationID) && activeGenerationController?.questionID == questionID && activeQuestionID == questionID
}

func isActiveGeneration(_ identity: GenerationIdentity) -> Bool {
    generationCoordinator.isCurrent(identity)
}

// Terminal UI is a valid completed outcome. This fence protects only the
// current request/session presentation; it deliberately does not use canPublish.
func ownsCurrentGenerationPresentation(_ identity: GenerationIdentity, requestID: String?) -> Bool {
    !isShuttingDown && generationCoordinator.isCurrent(identity) &&
        generationCoordinator.activeRequest?.id == requestID &&
        currentSession?.id == identity.sessionID &&
        currentSession?.contextSnapshotID == identity.contextSnapshotID
}

// internal for AppState extension access only
func visibleCardMatchesGeneration(
    card: SuggestionCard,
    generationID: String,
    detectedQuestionID: String?,
    promptPrimaryQuestion: String
) -> Bool {
    guard currentGenerationID == generationID else { return false }
    if let controller = activeGenerationController {
        guard controller.generationID == generationID else { return false }
        if let detectedQuestionID, controller.questionID != detectedQuestionID {
            return false
        }
        let controllerQuestion = normalizedBindingText(controller.questionTextSnapshot)
        let expectedQuestion = normalizedBindingText(promptPrimaryQuestion)
        if !controllerQuestion.isEmpty, !expectedQuestion.isEmpty, controllerQuestion != expectedQuestion {
            return false
        }
        if controller.identity.sessionID != card.sessionID {
            return false
        }
        if let cardSnapshotID = card.contextSnapshotID,
           controller.identity.contextSnapshotID != cardSnapshotID {
            return false
        }
        if let cardIntent = card.questionIntent,
           controller.identity.questionIntent != cardIntent {
            return false
        }
    }

    if let cardGenerationID = card.generationID, cardGenerationID != generationID {
        return false
    }

    if let detectedQuestionID, let cardQuestionID = card.detectedQuestionID, cardQuestionID != detectedQuestionID {
        return false
    }

    let expectedPrompt = normalizedBindingText(promptPrimaryQuestion)
    guard !expectedPrompt.isEmpty else { return false }
    let snapshots = [card.questionText, card.promptQuestionText, card.promptPrimaryQuestion]
    for snapshot in snapshots {
        guard let snapshot else { continue }
        let normalized = normalizedBindingText(snapshot)
        if !normalized.isEmpty, normalized != expectedPrompt {
            return false
        }
    }
    return true
}

@discardableResult
func applySuggestionIfAlignedForTesting(
    _ card: SuggestionCard,
    question: DetectedQuestion,
    generationID: String?
) -> Bool {
    displaySuggestionIfAligned(
        card,
        question: question,
        generationID: generationID,
        triggerPath: card.triggerPath ?? activeTriggerPath ?? .manualGenerate,
        allowInactiveGeneration: true
    )
}

func setActiveQuestionForTesting(_ question: DetectedQuestion) {
    lastDetectedQuestion = question
}

@discardableResult
// internal for AppState extension access only
/// Validates and binds a generated card before it is allowed to become the
/// current visible answer.
///
/// This is the last defense against stale async callbacks and context bleed:
/// the card's detected question and question text must match the current
/// question, and the visible say-first answer must be semantically relevant.
/// Clear technical questions should not end with an `unknown` alignment verdict.
func displaySuggestionIfAligned(
    _ card: SuggestionCard,
    question: DetectedQuestion,
    generationID: String?,
    triggerPath: GenerationTriggerPath?,
    source: AudioSourceType? = nil,
    speaker: SpeakerRole? = nil,
    allowInactiveGeneration: Bool = false,
    whileCurrent: (() -> Bool)? = nil
) -> Bool {
    guard whileCurrent?() != false else { return false }
    if !allowInactiveGeneration,
       let currentSession,
       currentSession.id != card.sessionID {
        recordStaleGenerationResultRejected(
            sessionID: card.sessionID,
            oldGenerationID: generationID,
            oldQuestionText: question.questionText,
            reason: "provider_result_session_not_current",
            oldAcceptedQuestionID: question.id,
            sourceCallback: "provider_display"
        )
        return false
    }
    if let generationID, !allowInactiveGeneration {
        guard isActiveGeneration(generationID, questionID: question.id) else {
            recordStaleGenerationResultRejected(
                sessionID: card.sessionID,
                oldGenerationID: generationID,
                oldQuestionText: question.questionText,
                reason: "provider_result_generation_or_question_not_active",
                oldAcceptedQuestionID: question.id,
                sourceCallback: "provider_display"
            )
            recordAlignmentMismatch(
                "Stale answer discarded: generation/question no longer active for question \(question.id)."
            )
            return false
        }
    }

    var boundCard = card
    if boundCard.detectedQuestionID == nil {
        boundCard.detectedQuestionID = question.id
    }
    guard boundCard.detectedQuestionID == question.id else {
        recordAlignmentMismatch(
            "Suggestion question mismatch: card question \(boundCard.detectedQuestionID ?? "nil") does not match current question \(question.id)."
        )
        return false
    }

    if let generationID,
       let cardGenerationID = boundCard.generationID,
       cardGenerationID != generationID {
        recordStaleGenerationResultRejected(
            sessionID: card.sessionID,
            oldGenerationID: cardGenerationID,
            oldQuestionText: boundCard.questionText ?? question.questionText,
            reason: "provider_result_generation_id_mismatch",
            oldAcceptedQuestionID: boundCard.detectedQuestionID ?? question.id,
            sourceCallback: "provider_display"
        )
        recordAlignmentMismatch(
            "Suggestion generation mismatch: card generation \(cardGenerationID) does not match active generation \(generationID)."
        )
        return false
    }

    if let snapshot = boundCard.questionText,
       !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       normalizedBindingText(snapshot) != normalizedBindingText(question.questionText) {
        recordAlignmentMismatch("Suggestion question text snapshot does not match detected question text.")
        return false
    }

    if let snapshot = boundCard.promptQuestionText,
       !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       normalizedBindingText(snapshot) != normalizedBindingText(question.questionText) {
        recordAlignmentMismatch("Suggestion prompt question text does not match detected question text.")
        return false
    }

    if let snapshot = boundCard.promptPrimaryQuestion,
       !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       normalizedBindingText(snapshot) != normalizedBindingText(question.questionText) {
        recordAlignmentMismatch("Suggestion prompt primary question does not match detected question text.")
        return false
    }

    // Persist the question snapshot that actually controlled this answer.
    // Runtime acceptance relies on question_text == prompt_primary_question for
    // generated cards so later DB queries can detect context bleed.
    boundCard.questionText = question.questionText
    boundCard.questionDecision = question.taskDescriptor?.decision
    boundCard.transcriptSegmentID = boundCard.transcriptSegmentID ?? question.transcriptSegmentID
    boundCard.ingressIdentity = boundCard.ingressIdentity ?? question.ingressIdentity
    boundCard.generationID = boundCard.generationID ?? generationID
    boundCard.source = boundCard.source ?? source?.rawValue ?? currentGenerationTelemetry.source
    boundCard.speaker = boundCard.speaker ?? speaker?.rawValue ?? currentGenerationTelemetry.speaker
    boundCard.triggerPath = boundCard.triggerPath ?? triggerPath ?? activeTriggerPath
    boundCard.questionIntent = boundCard.questionIntent ?? AnswerRelevancePolicy.intent(for: question.questionText)
    boundCard.promptQuestionText = boundCard.promptQuestionText ?? question.questionText
    boundCard.promptPrimaryQuestion = boundCard.promptPrimaryQuestion ?? boundCard.promptQuestionText ?? question.questionText
    boundCard.promptContainsPreviousQuestion = boundCard.promptContainsPreviousQuestion ?? currentPromptContainsPreviousQuestion
    boundCard.previousQuestionIncluded = boundCard.previousQuestionIncluded ?? currentPreviousQuestionIncluded
    boundCard.previousQuestionText = boundCard.previousQuestionText ?? (currentPreviousQuestionText.isEmpty ? nil : currentPreviousQuestionText)
    boundCard.contextBleedRisk = boundCard.contextBleedRisk ?? currentContextBleedRisk
    if boundCard.ragChunkIDs.isEmpty {
        boundCard.ragChunkIDs = currentRAGChunkIDs
    }
    if boundCard.ragChunkIntents.isEmpty {
        boundCard.ragChunkIntents = currentRAGChunkIntents
    }
    boundCard.firstQuestionSuppressedReason = boundCard.firstQuestionSuppressedReason ?? (currentFirstQuestionSuppressedReason.isEmpty ? nil : currentFirstQuestionSuppressedReason)
    let expectedSnapshotID = boundCard.contextSnapshotID ?? activeGenerationController?.identity.contextSnapshotID
    let boundSnapshot = expectedSnapshotID.flatMap { try? interviewContextRepository.snapshot(id: $0) }
    if expectedSnapshotID != nil, boundSnapshot == nil {
        boundCard.contextIsolationStatus = "snapshot_missing"
        recordAlignmentMismatch("Suggestion context snapshot could not be loaded.")
        return false
    }
    if let snapshot = boundSnapshot {
        boundCard.contextSnapshotID = snapshot.id
        boundCard.candidateProfileID = snapshot.candidateProfileID
        boundCard.candidateProfileVersion = snapshot.candidateProfileVersion
        boundCard.opportunityContextID = snapshot.opportunityContextID
        boundCard.opportunityContextVersion = snapshot.opportunityContextVersion
        boundCard.domainProfileID = snapshot.domainProfileID
        if boundCard.candidateEvidenceIDs.isEmpty {
            boundCard.candidateEvidenceIDs = currentRAGChunkIDs.filter { id in snapshot.candidateEvidence.contains(where: { $0.id == id }) }
        }
        if boundCard.opportunityEvidenceIDs.isEmpty {
            boundCard.opportunityEvidenceIDs = currentRAGChunkIDs.filter { id in snapshot.opportunityEvidence.contains(where: { $0.id == id }) }
        }
        boundCard.contextIsolationStatus = "matched"
    }

    if let generationID, !allowInactiveGeneration,
       !visibleCardMatchesGeneration(
            card: boundCard,
            generationID: generationID,
            detectedQuestionID: question.id,
            promptPrimaryQuestion: question.questionText
       ) {
        recordAlignmentMismatch(
            "Suggestion binding mismatch: visible card does not match active generation/question snapshot.",
            stale: true
        )
        return false
    }

    // `say_first` is visible before Stage B completes, so it must be relevant
    // on its own. This is especially important for model-comparison questions
    // where generic "I would explain..." output is not usable in an interview.
    let answerText = ([boundCard.sayFirst] + boundCard.keyPoints + boundCard.followUpReady).joined(separator: " ")
    // Preserve field boundaries: joining a bullet ending in "evidence" with a
    // separate "I can explain..." item invents a personal claim that neither
    // field contains. Alignment can still use the combined answer above.
    let allVisibleClaims = ([boundCard.sayFirst] + boundCard.keyPoints + boundCard.followUpReady
        + [boundCard.strategy, boundCard.caution ?? ""] + boundCard.evidenceUsed).joined(separator: "\n")
    do {
        // Missing personal evidence permits a factual gap/clarification response.
        // Every actual personal claim is still checked below, including nil snapshots.


        let grounding = AnswerClaimValidator().validate(
            answer: allVisibleClaims,
            candidateEvidence: question.taskDescriptor?.decision?.usesCandidateEvidence == false ? [] : (boundSnapshot?.candidateEvidence ?? []),
            opportunityEvidence: boundSnapshot?.opportunityEvidence ?? [],
            domainKnowledge: InterviewDomainProfile.profile(
                for: InterviewDomainID(rawValue: boundSnapshot?.domainProfileID ?? "") ?? .general
            ).domainKnowledge
        )
        boundCard.groundingDecision = grounding.groundingDecision
        boundCard.unsupportedClaimCount = grounding.unsupportedClaims.count
        if boundCard.candidateEvidenceIDs.isEmpty {
            boundCard.candidateEvidenceIDs = grounding.supportingCandidateEvidenceIDs
        }
        guard grounding.unsupportedClaims.isEmpty else {
            recordAlignmentMismatch("Provider answer rejected because it contained unsupported personal claims.")
            return false
        }
    }
    let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
        questionText: question.questionText,
        answerText: answerText,
        sayFirst: boundCard.sayFirst,
        stageBCompleted: boundCard.stageBCompleted ?? true,
        decision: question.taskDescriptor?.decision
    )
    let effectiveAlignmentPassed = alignment.verdict == .aligned
    let effectiveAlignment = alignment
    boundCard.alignmentScore = effectiveAlignment.score
    boundCard.alignmentVerdict = effectiveAlignment.verdict
    boundCard.answerIntent = effectiveAlignment.answerIntent
    boundCard.mismatchReason = effectiveAlignmentPassed
        ? nil
        : (alignment.verdict == .mismatched ? alignment.reason : boundCard.mismatchReason)

    if !effectiveAlignmentPassed {
        currentAnswerQuestionIntent = alignment.questionIntent
        currentAnswerIntent = alignment.answerIntent
        currentExpectedThemesMatched = alignment.matchedThemes
        currentSuspectedMismatchReason = alignment.reason
        recordSuggestionAlignment(boundCard, question: question, result: alignment)
        if let incompleteReason = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(boundCard.sayFirst) {
            recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
                sessionID: boundCard.sessionID,
                questionID: question.id,
                generationID: generationID,
                question: question.questionText,
                reason: incompleteReason,
                timestamp: Date()
            ))
        }
        if alignment.reason.localizedCaseInsensitiveContains("wrong project grounding") {
            recordTranscriptRuntimeEvent(.answerRejectedWrongProjectGrounding(
                sessionID: boundCard.sessionID,
                questionID: question.id,
                generationID: generationID,
                question: question.questionText,
                reason: alignment.reason,
                timestamp: Date()
            ))
        }
        recordAlignmentMismatch("Generated answer did not align with question; using fallback. \(alignment.reason)")
        if generationAnswerProviderMode == .localQwenPrimary ||
            boundCard.finalVisibleSource == AnswerSource.ollamaQwen.rawValue ||
            boundCard.sayFirstSource == AnswerSource.ollamaQwen.rawValue {
            recordLifecycleTrace(
                "semantic_fallback.skipped",
                sessionID: boundCard.sessionID,
                questionID: question.id,
                generationID: generationID,
                text: question.questionText,
                reason: "local_qwen_primary_requires_ollama_qwen_source",
                skipped: true
            )
            return false
        }
        if let existing = currentSuggestion,
           existing.detectedQuestionID == question.id,
           !existing.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(existing).accepted {
            return false
        }

        var fallbackCard = makeSemanticFallbackCard(
            replacing: boundCard,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker,
            mismatchReason: alignment.reason
        )
        let fallbackText = ([fallbackCard.sayFirst] + fallbackCard.keyPoints + fallbackCard.followUpReady).joined(separator: " ")
        let fallbackAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question.questionText,
            answerText: fallbackText,
            sayFirst: fallbackCard.sayFirst,
            stageBCompleted: true,
        decision: question.taskDescriptor?.decision
        )
        fallbackCard.alignmentScore = fallbackAlignment.score
        fallbackCard.alignmentVerdict = fallbackAlignment.verdict
        fallbackCard.answerIntent = fallbackAlignment.answerIntent
        fallbackCard.mismatchReason = fallbackAlignment.verdict == .mismatched ? fallbackAlignment.reason : fallbackCard.mismatchReason
        guard hasDisplayableSayFirst(fallbackCard) else {
            recordSuggestionAlignment(fallbackCard, question: question, result: fallbackAlignment)
            recordAlignmentMismatch("Semantic fallback did not align with question; keeping non-answer state. No displayable fallback Say First was available.")
            return false
        }
        guard fallbackAlignment.verdict == .aligned else {
            recordSuggestionAlignment(fallbackCard, question: question, result: fallbackAlignment)
            recordAlignmentMismatch("Semantic fallback did not align with question; keeping non-answer state. \(fallbackAlignment.reason)")
            if let generationID, isActiveGeneration(generationID), !(boundCard.isLocal || boundCard.stageBCompleted == false) {
                let rejectedReason = "Low-confidence answer rejected. Retry available."
                providerStreamActive = false
                isStreamingSayFirst = false
                isExpandingSuggestionCard = false
                clearStageATask(generationID: generationID)
                clearStageATimeoutTask(generationID: generationID)
                clearStageBTask(generationID: generationID)
                clearFullCardWatchdogTask(generationID: generationID)
                setGenerationUIState(
                    .lowConfidenceRejected(
                        questionID: question.id,
                        generationID: generationID,
                        triggerPath: triggerPath ?? activeTriggerPath,
                        reason: rejectedReason
                    ),
                    generationID: generationID
                )
                failAction(ActionID.generateAnswer, title: "Low-confidence answer rejected", message: rejectedReason)
            }
            return false
        }
        let fallbackClaims = AnswerClaimValidator().validate(answer: fallbackText,
            candidateEvidence: question.taskDescriptor?.decision?.usesCandidateEvidence == false ? [] : (boundSnapshot?.candidateEvidence ?? []),
            opportunityEvidence: boundSnapshot?.opportunityEvidence ?? [], domainKnowledge: [])
        guard fallbackClaims.unsupportedClaims.isEmpty, fallbackCard.unsupportedClaimCount == 0 else {
            recordAlignmentMismatch("Semantic fallback rejected unsupported personal claims before publication.")
            return false
        }
        currentSuggestion = fallbackCard
        recordVisibleSuggestionInHistory(fallbackCard)
        recordSuggestionAlignment(fallbackCard, question: question, result: fallbackAlignment)
        if QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(boundCard.sayFirst) != nil {
            recordTranscriptRuntimeEvent(.fallbackUsedForIncompleteStream(
                sessionID: boundCard.sessionID,
                questionID: question.id,
                generationID: generationID,
                question: question.questionText,
                reason: alignment.reason,
                timestamp: Date()
            ))
        }
        currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
        if let generationID, isActiveGeneration(generationID) {
            softFallbackUsed = true
            softFallbackShownAt = softFallbackShownAt ?? Date()
            softFallbackLatencyMS = softFallbackLatencyMS ?? activeGenerationStartedAt.map { elapsedMS(since: $0) }
            finalVisibleSource = "semantic_intent_fallback"
            isStreamingSayFirst = false
            streamedSayFirst = ""
            markFirstVisibleAnswer(generationID: generationID, fallback: true)
            setGenerationUIState(
                .showingFallback(
                    questionID: question.id,
                    generationID: generationID,
                    triggerPath: triggerPath ?? activeTriggerPath ?? .manualGenerate
                ),
                generationID: generationID
            )
        }
        return false
    }

    guard hasDisplayableSayFirst(boundCard) else {
        recordSuggestionAlignment(boundCard, question: question, result: alignment)
        recordAlignmentMismatch("Aligned answer rejected because it had no displayable Say First content.")
        return false
    }

    guard whileCurrent?() != false else { return false }
    currentSuggestion = boundCard
    guard whileCurrent?() != false else { return false }
    recordVerificationCardPublication(boundCard, at: VerificationTiming.hostTicks())
    recordVisibleSuggestionInHistory(boundCard)
    guard whileCurrent?() != false else { return false }
    lastAlignmentError = ""
    guard whileCurrent?() != false else { return false }
    currentAnswerQuestionIntent = effectiveAlignment.questionIntent
    guard whileCurrent?() != false else { return false }
    currentAnswerIntent = effectiveAlignment.answerIntent
    guard whileCurrent?() != false else { return false }
    currentExpectedThemesMatched = effectiveAlignment.matchedThemes
    guard whileCurrent?() != false else { return false }
    currentSuspectedMismatchReason = ""
    guard whileCurrent?() != false else { return false }
    recordSuggestionAlignment(boundCard, question: question, result: effectiveAlignment)
    guard whileCurrent?() != false else { return false }
    return true
}

/// Builds a complete local answer when provider output is mismatched,
/// incomplete, or too generic for the current question.
///
/// Fallbacks must directly answer the current question and preserve binding
/// metadata so the DB and UI can show why provider output was rejected.
private func makeSemanticFallbackCard(
    replacing card: SuggestionCard,
    question: DetectedQuestion,
    generationID: String?,
    triggerPath: GenerationTriggerPath?,
    source: AudioSourceType?,
    speaker: SpeakerRole?,
    mismatchReason: String
) -> SuggestionCard {
    let grounded = groundedFallback(
        for: question.questionText,
        contextSnapshotID: card.contextSnapshotID ?? activeGenerationController?.identity.contextSnapshotID,
        task: question.taskDescriptor
    )
    let selected = Set(grounded?.result.candidateEvidenceIDs ?? [])
    let keyPoints: [String] = grounded?.snapshot.candidateEvidence.filter { selected.contains($0.id) }.map(\.statement) ?? []
    var fallbackCard = SuggestionCard(
        id: card.id,
        sessionID: card.sessionID,
        questionID: question.id,
        strategy: "Semantic Alignment Fallback",
        sayFirst: grounded?.result.answer ?? "",
        keyPoints: keyPoints,
        followUpReady: [],
        confidence: min(card.confidence ?? 0.6, 0.7),
        caution: "Generated answer did not align with question; using fallback.",
        evidenceUsed: card.evidenceUsed,
        riskLevel: .medium,
        modelName: "semantic-intent-fallback",
        promptVersion: "semantic-fallback-v1",
        providerKind: nil,
        providerName: "Semantic Alignment Fallback",
        providerBaseURL: "",
        latencyMS: card.latencyMS,
        isLocal: true,
        rawJSON: card.rawJSON,
        createdAt: Date(),
        questionText: question.questionText,
        transcriptSegmentID: question.transcriptSegmentID,
        generationID: generationID,
        source: source?.rawValue ?? card.source,
        speaker: speaker?.rawValue ?? card.speaker,
        triggerPath: triggerPath ?? card.triggerPath,
        questionIntent: AnswerRelevancePolicy.intent(for: question.questionText),
        promptQuestionText: question.questionText,
        promptPrimaryQuestion: card.promptPrimaryQuestion ?? card.promptQuestionText ?? question.questionText,
        promptContainsPreviousQuestion: card.promptContainsPreviousQuestion,
        previousQuestionIncluded: card.previousQuestionIncluded,
        previousQuestionText: card.previousQuestionText,
        contextBleedRisk: card.contextBleedRisk,
        ragChunkIDs: card.ragChunkIDs,
        ragChunkIntents: card.ragChunkIntents,
        firstQuestionSuppressedReason: card.firstQuestionSuppressedReason,
        promptTokenEstimate: card.promptTokenEstimate,
        promptContextPreview: card.promptContextPreview,
        mismatchReason: mismatchReason,
        sayFirstSource: "semantic_intent_fallback",
        stageATimedOut: card.stageATimedOut,
        stageBCompleted: true,
        stageBStatus: "semantic_fallback",
        latencyFirstTokenMS: card.latencyFirstTokenMS,
        latencyFirstVisibleMS: card.latencyFirstVisibleMS,
        latencyFullCardMS: card.latencyFullCardMS,
        softFallbackUsed: true,
        softFallbackLatencyMS: card.softFallbackLatencyMS,
        deepseekFirstTokenMS: card.deepseekFirstTokenMS,
        deepseekFirstVisibleMS: card.deepseekFirstVisibleMS,
        finalVisibleSource: "semantic_intent_fallback",
        ragRetrievalLatencyMS: card.ragRetrievalLatencyMS,
        questionASRFirstPartialMS: card.questionASRFirstPartialMS,
        questionASRFinalMS: card.questionASRFinalMS,
        questionASRBestSelectedMS: card.questionASRBestSelectedMS,
        firstVisibleAnswerMS: card.firstVisibleAnswerMS,
        firstKeyPointVisibleMS: card.firstKeyPointVisibleMS,
        allKeyPointsVisibleMS: card.allKeyPointsVisibleMS,
        followUpVisibleMS: card.followUpVisibleMS,
        fullCardVisibleMS: card.fullCardVisibleMS,
        dbPersistedMS: card.dbPersistedMS,
        stageBStreamStartedMS: card.stageBStreamStartedMS,
        stageBFirstSectionMS: card.stageBFirstSectionMS
    )
    if let grounded {
        fallbackCard.contextSnapshotID = grounded.snapshot.id
        fallbackCard.candidateProfileID = grounded.snapshot.candidateProfileID
        fallbackCard.candidateProfileVersion = grounded.snapshot.candidateProfileVersion
        fallbackCard.opportunityContextID = grounded.snapshot.opportunityContextID
        fallbackCard.opportunityContextVersion = grounded.snapshot.opportunityContextVersion
        fallbackCard.domainProfileID = grounded.snapshot.domainProfileID
        fallbackCard.candidateEvidenceIDs = grounded.result.candidateEvidenceIDs
        fallbackCard.opportunityEvidenceIDs = grounded.result.opportunityEvidenceIDs
        fallbackCard.groundingDecision = grounded.result.groundingDecision
        fallbackCard.unsupportedClaimCount = grounded.result.unsupportedClaims.count
        fallbackCard.contextIsolationStatus = "matched"
    } else {
        fallbackCard.groundingDecision = "context_snapshot_missing"
        fallbackCard.unsupportedClaimCount = 0
        fallbackCard.contextIsolationStatus = "missing"
    }
    return fallbackCard
}

private func recordAlignmentMismatch(_ message: String, stale: Bool = false) {
    answerQuestionMismatchCount += 1
    if stale {
        staleAnswerDiscardCount += 1
    }
    lastAlignmentError = message
    currentSuspectedMismatchReason = message
    updateActiveTaskSummary()
}

private func recordSuggestionAlignment(
    _ card: SuggestionCard,
    question: DetectedQuestion,
    result: AnswerAlignmentResult
) {
    let record = SuggestionAlignmentRecord(
        id: card.id,
        detectedQuestionID: card.detectedQuestionID,
        questionText: question.questionText,
        sayFirstPreview: String(card.sayFirst.prefix(220)),
        alignmentScore: result.score,
        alignmentVerdict: result.verdict,
        answerIntent: result.answerIntent,
        expectedThemesMatched: result.matchedThemes,
        suspectedMismatchReason: result.verdict == .mismatched ? result.reason : ""
    )
    recentSuggestionAlignments.insert(record, at: 0)
    if recentSuggestionAlignments.count > 12 {
        recentSuggestionAlignments.removeLast(recentSuggestionAlignments.count - 12)
    }
}

// Only synchronous UI/provenance projection remains here. The coordinator
// consumes the provider and owns its task; weak callbacks hold no AppState
// across an await. Throttling is private to this MainActor callback instance.
func launchProviderFirstAnswer(
    context: GenerationExecutionContext,
    providerQuestion: DetectedQuestion,
    providerContext: RetrievedContext,
    cvSummary: String,
    jdSummary: String,
    providerConfiguration: LLMProviderConfiguration?,
    trigger: StageBTrigger
) -> Task<String, Error>? {
    let generationID = context.generationID
    let question = providerQuestion
    var throttle = StreamingUpdateThrottle()
    let acceptsPublication: @MainActor (GenerationIdentity) -> Bool = { [weak self] identity in
        guard let self else { return false }
        return self.generationCoordinator.canPublish(identity) &&
            !self.generationUIState.isTerminal && !Task.isCancelled
    }
    // Decide relevance without publishing, then admit each diagnostic update.
    // This closure owns no state and captures AppState only weakly.
    let publishPreviewRelevance: @MainActor (String, GenerationIdentity) -> Bool? = { [weak self] text, identity in
        guard let self, acceptsPublication(identity) else { return nil }
        let result = self.evaluatedLivePreviewRelevance(text, question: question)
        if let alignment = result.alignment, alignment.verdict != .unknown {
            self.currentAnswerQuestionIntent = alignment.questionIntent
            guard acceptsPublication(identity) else { return nil }
            self.currentAnswerIntent = alignment.answerIntent
            guard acceptsPublication(identity) else { return nil }
            self.currentExpectedThemesMatched = alignment.matchedThemes
            guard acceptsPublication(identity) else { return nil }
            self.currentSuspectedMismatchReason = alignment.verdict == .mismatched ? alignment.reason : ""
            guard acceptsPublication(identity) else { return nil }
        }
        return result.relevant
    }
    let task = generationCoordinator.launchStageAFirstAnswer(
        context: context, providerQuestion: providerQuestion, providerContext: providerContext,
        cvSummary: cvSummary, jdSummary: jdSummary, providerConfiguration: providerConfiguration,
        onStarted: { [weak self] _ in
            self?.markProviderOperation("Stage A first-answer stream started")
        },
        onToken: { [weak self] identity, token, collected in
            guard let self, acceptsPublication(identity) else { return false }
            if self.streamFirstTokenAt == nil {
                self.streamFirstTokenAt = Date()
                guard acceptsPublication(identity) else { return false }
                self.currentGenerationTelemetry.firstDeepSeekTokenAt = self.streamFirstTokenAt
                guard acceptsPublication(identity) else { return false }
                self.deepseekFirstTokenMS = Int(Date().timeIntervalSince(context.startedAt) * 1000)
                guard acceptsPublication(identity) else { return false }
                self.recordLifecycleTrace("answer.first_token", sessionID: context.session.id,
                    questionID: question.id, generationID: generationID, text: question.questionText)
                guard acceptsPublication(identity) else { return false }
            }
            let cleaned = self.cleanedFirstAnswerStreamText(collected)
            var forcePublish = false
            if self.streamFirstVisibleTextAt == nil {
                let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
                if wordCount >= 3 || cleaned.count >= 10 {
                    guard let relevant = publishPreviewRelevance(cleaned, identity) else { return false }
                    if relevant {
                        self.streamFirstVisibleTextAt = Date()
                        guard acceptsPublication(identity) else { return false }
                        self.firstVisibleStateSetAt = Date()
                        guard acceptsPublication(identity) else { return false }
                        self.deepseekFirstVisibleMS = Int(Date().timeIntervalSince(context.startedAt) * 1000)
                        guard acceptsPublication(identity) else { return false }
                        self.markFirstVisibleAnswer(generationID: generationID, fallback: false,
                            whileCurrent: { acceptsPublication(identity) })
                        guard acceptsPublication(identity) else { return false }
                        self.setGenerationUIState(.streamingAnswer(questionID: question.id,
                            generationID: generationID, triggerPath: context.triggerPath), generationID: generationID,
                            whileCurrent: { acceptsPublication(identity) })
                        guard acceptsPublication(identity) else { return false }
                        self.infoAction(ActionID.generateAnswer, title: "First answer visible",
                            message: "DeepSeek first answer is streaming.", autoDismissAfter: 2.5,
                            whileCurrent: { acceptsPublication(identity) })
                        guard acceptsPublication(identity) else { return false }
                        forcePublish = true
                        trigger.trigger()
                        guard acceptsPublication(identity) else { return false }
                    }
                }
            }
            if throttle.shouldPublish(characterCount: cleaned.count, force: forcePublish) {
                guard let relevant = publishPreviewRelevance(cleaned, identity) else { return false }
                self.streamedSayFirst = relevant ? cleaned : ""
                guard acceptsPublication(identity) else { return false }
                if relevant && self.streamedSayFirstSetAt == nil && !cleaned.isEmpty {
                    self.streamedSayFirstSetAt = Date()
                    guard acceptsPublication(identity) else { return false }
                }
            }
            if self.streamFirstSentenceAt == nil &&
               (token.contains(".") || token.contains("!") || token.contains("?")) {
                self.streamFirstSentenceAt = Date()
                guard acceptsPublication(identity) else { return false }
            }
            return acceptsPublication(identity)
        },
        onCompleted: { [weak self] identity, collected in
            guard let self, acceptsPublication(identity) else { return nil }
            let cleaned = self.cleanedFirstAnswerStreamText(collected)
            guard let relevant = publishPreviewRelevance(cleaned, identity) else { return nil }
            self.streamedSayFirst = relevant ? cleaned : ""
            guard acceptsPublication(identity) else { return nil }
            if relevant && self.streamedSayFirstSetAt == nil && !cleaned.isEmpty {
                self.streamedSayFirstSetAt = Date()
                guard acceptsPublication(identity) else { return nil }
            }
            self.streamFullResponseAt = Date()
            guard acceptsPublication(identity) else { return nil }
            return cleaned
        },
        onRejected: { [weak self] identity in self?.recordStaleGenerationDiscard(attributedTo: identity) },
        onExit: { trigger.trigger() }
    )
    if task != nil, acceptsPublication(context.identity) {
        providerStreamActive = true
        guard acceptsPublication(context.identity) else { return task }
        updateActiveTaskSummary()
    }
    return task
}

// Provider consumption belongs to the coordinator. These callbacks retain
// only the live UI/evidence/DB boundary, with the application's exact frozen
// service inputs and existing publication checks preserved.
func launchProviderExpansion(
    context: GenerationExecutionContext,
    providerQuestion: DetectedQuestion,
    providerContext: RetrievedContext,
    cvSummary: String,
    jdSummary: String,
    providerConfiguration: LLMProviderConfiguration?,
    cardID: String,
    retrievedChunks: [RetrievedChunk],
    trigger: StageBTrigger
) -> Task<Void, Never>? {
    let generationID = context.generationID
    let question = providerQuestion
    let session = context.session
    let requestStart = context.startedAt
    let triggerPath = context.triggerPath
    let source = context.source
    let speaker = context.speaker
    var activeFallback = false
    var throttle = StreamingUpdateThrottle()
    let task = generationCoordinator.launchStageBExpansion(
        context: context, providerQuestion: providerQuestion, providerContext: providerContext,
        cvSummary: cvSummary, jdSummary: jdSummary, providerConfiguration: providerConfiguration,
        trigger: trigger, deadlineDelayProvider: generationWatchdogDelayProvider,
        onStarted: { [weak self] identity in
            guard let self, self.generationCoordinator.canPublish(identity) else { return }
            self.diagnosticsState.beginStageBWorkerTrace(generationID: generationID)
        },
        onReady: { [weak self] identity in
            guard let self, self.generationCoordinator.canPublish(identity), !Task.isCancelled else { return }
            if self.visibleAnswerExists {
                self.setGenerationUIState(.expandingFullAnswer(questionID: question.id,
                    generationID: generationID, triggerPath: triggerPath), generationID: generationID)
            }
            activeFallback = self.softFallbackUsed || self.currentSuggestion?.sayFirstSource == "rag_template_fallback" ||
                self.currentSuggestion?.sayFirstSource == "rag_template_soft_fallback"
        },
        onSections: { [weak self] identity, sections, streamStartedMS in
            guard let self, self.generationCoordinator.canPublish(identity),
                  !self.generationUIState.isTerminal, !Task.isCancelled else { return }
            let force = self.currentSuggestion?.firstKeyPointVisibleMS == nil && !sections.keyPoints.isEmpty
            guard throttle.shouldPublish(characterCount: sections.characterCount, force: force) else { return }
            let preserve = self.softFallbackUsed && (self.userInteractedWithCard ||
                (!sections.sayFirst.isEmpty && !self.isSpecificAnswer(sections.sayFirst)))
            // A rejected preview remains unpublished; the owned stream continues.
            self.publishStreamingSections(sections, cardID: cardID, generationID: generationID,
                question: question, session: session, requestStart: requestStart,
                stageBStreamStartedMS: streamStartedMS, preserveExistingSayFirst: preserve)
        },
        onFallbackResult: { [weak self] identity, result in
            guard let self, self.generationCoordinator.canPublish(identity), !Task.isCancelled else { return false }
            let decision = self.generationCoordinator.interpretStageBResult(
                generationID: generationID, detectedQuestionID: question.id,
                activeGenerationID: self.currentGenerationID, questionText: question.questionText,
                providerResult: result, sections: result.parsedSections, sawStreamingSections: false,
                visibleSayFirst: self.currentSuggestion?.sayFirst, visibleAnswerExists: self.visibleAnswerExists,
                identity: identity, questionDecision: question.taskDescriptor?.decision)
            let plan = self.generationCoordinator.makeStageBApplicationPlan(from: decision,
                visibleSuggestion: self.currentSuggestion, activeGenerationID: self.currentGenerationID,
                activeQuestionID: self.activeQuestionID)
            if plan.action == .discardStaleResult { self.recordStaleGenerationDiscard(); return false }
            if let caution = result.safeDiagnostics["caution"],
               caution.localizedCaseInsensitiveContains("non-JSON") || caution.localizedCaseInsensitiveContains("JSON") {
                self.currentGenerationTelemetry.jsonParseError = caution
            }
            return true
        },
        onCompleted: { [weak self] identity, result, sections, sawStreamingSections, streamStartedMS in
            guard let self, self.generationCoordinator.canPublish(identity),
                  !self.generationUIState.isTerminal, !Task.isCancelled else { return }
            // These UI timing fields retain their existing Stage A meaning.
            // The raw sections remain a separate input to evidence validation.
            let completed = GenerationProviderResult(identity: identity, sayFirst: result.sayFirst,
                keyPoints: result.keyPoints, followUp: result.followUp, parsedSections: result.parsedSections,
                latencyMS: result.latencyMS, firstTokenMS: self.deepseekFirstTokenMS,
                firstVisibleMS: self.deepseekFirstVisibleMS, providerStatus: .completed, errorClassification: nil)
            let decision = self.generationCoordinator.interpretStageBResult(
                generationID: generationID, detectedQuestionID: question.id,
                activeGenerationID: self.currentGenerationID, questionText: question.questionText,
                providerResult: completed, sections: sections, sawStreamingSections: sawStreamingSections,
                visibleSayFirst: self.currentSuggestion?.sayFirst, visibleAnswerExists: self.visibleAnswerExists,
                identity: identity, questionDecision: question.taskDescriptor?.decision)
            let plan = self.generationCoordinator.makeStageBApplicationPlan(from: decision,
                visibleSuggestion: self.currentSuggestion, activeGenerationID: self.currentGenerationID,
                activeQuestionID: self.activeQuestionID)
            let preserve = self.softFallbackUsed && (self.userInteractedWithCard ||
                (!sections.sayFirst.isEmpty && !self.isSpecificAnswer(sections.sayFirst)))
            try await self.applyStageBApplicationPlan(plan, sections: sections, cardID: cardID,
                generationID: generationID, question: question, session: session, requestStart: requestStart,
                stageBStreamStartedMS: streamStartedMS, retrievedChunks: retrievedChunks,
                triggerPath: triggerPath, source: source, speaker: speaker, preserveFallbackSayFirst: preserve)
        },
        onFailure: { [weak self] identity, error in
            guard let self, self.generationCoordinator.canPublish(identity),
                  !self.generationUIState.isTerminal, !Task.isCancelled else { return }
            self.updateActiveTaskSummary()
            self.handleProviderExpansionFailure(error, activeFallback: activeFallback,
                context: context, question: question, retrievedChunks: retrievedChunks)
        },
        onRejected: { [weak self] identity in self?.recordStaleGenerationDiscard(attributedTo: identity) },
        onPhase: { [weak self] identity, phase, tokenReceived in
            guard let self, self.generationCoordinator.isCurrent(identity) else { return }
            if phase == 3 { self.markProviderOperation("Stage B section stream started") }
            if phase == 7 { self.markProviderOperation("Stage B full-card fallback started") }
            self.diagnosticsState.recordStageBWorkerPhase(generationID: generationID,
                phase: phase, tokenReceived: tokenReceived)
        },
        onExit: { [weak self] identity, cleared in
            guard let self, self.generationCoordinator.isCurrent(identity),
                  cleared || self.generationCoordinator.stageBTask == nil else { return }
            self.diagnosticsState.finishStageBWorkerTrace(generationID: generationID)
            if cleared { self.updateActiveTaskSummary() }
        })
    if task != nil { updateActiveTaskSummary() }
    return task
}

private func handleProviderExpansionFailure(
    _ error: Error,
    activeFallback: Bool,
    context: GenerationExecutionContext,
    question localQuestion: DetectedQuestion,
    retrievedChunks: [RetrievedChunk]
) {
    let generationID = context.generationID
    let localSession = context.session
    let requestStart = context.startedAt
    let triggerPath = context.triggerPath
    let telemetrySource = context.source
    let telemetrySpeaker = context.speaker
    print("[StreamingASR] Stage B Full SuggestionCard failed or timed out: code=\((error as NSError).code)")
    let errorMessage = error.localizedDescription
    let timedOut = errorMessage.lowercased().contains("timed out") || errorMessage.lowercased().contains("timeout")
    let jsonParseError = errorMessage.lowercased().contains("json") ? errorMessage : nil
    markGenerationFailed(
        generationID: generationID,
        reason: errorMessage,
        providerError: errorMessage,
        jsonParseError: jsonParseError,
        timeout: timedOut,
        cancelled: error is CancellationError
    )
    guard generationCoordinator.isCurrent(context.identity) else { return }

    // Only restore .listening if safety conditions are met
    if currentSession?.id == localSession.id &&
       currentCaptureRuntimeState == .generating &&
       stopReason == nil &&
       currentGenerationID == generationID &&
       anyCaptureRunning {
        liveState = .listening
        currentCaptureRuntimeState = .listening
        addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: "generationFailed")
    } else {
        print("[CaptureState] Bypassed restoring listening on error: sessionID=\(currentSession?.id ?? "nil"), state=\(currentCaptureRuntimeState), stopReason=\(String(describing: stopReason)), generationID=\(String(describing: currentGenerationID)), anyCaptureRunning=\(anyCaptureRunning)")
    }

    if let current = currentSuggestion {
        guard visibleCardMatchesGeneration(
            card: current,
            generationID: generationID,
            detectedQuestionID: localQuestion.id,
            promptPrimaryQuestion: localQuestion.questionText
        ) else {
            recordStaleGenerationDiscard()
            return
        }
        if let completed = completeSubstantiveProviderFirstAnswerAfterTimeout(
            current,
            question: localQuestion,
            requestStart: requestStart
        ) {
            currentSuggestion = completed
            guard generationCoordinator.isCurrent(context.identity) else { return }
            persistSuggestionInBackground(
                completed,
                chunks: retrievedChunks,
                generationID: generationID,
                requestStart: requestStart
            )
            warnAction(ActionID.generateAnswer, title: "First answer preserved", message: "Full answer expansion failed. The DeepSeek answer was kept.",
                whileCurrent: { self.generationCoordinator.isCurrent(context.identity) })
            return
        }
        if replaceIncompleteVisibleAnswerWithFallbackIfNeeded(
            card: current,
            question: localQuestion,
            session: localSession,
            generationID: generationID,
            requestStart: requestStart,
            triggerPath: triggerPath,
            source: telemetrySource,
            speaker: telemetrySpeaker,
            reason: "Stage B failed or timed out"
        ) {
            guard generationCoordinator.isCurrent(context.identity) else { return }
            if let fallback = currentSuggestion {
                persistSuggestionInBackground(
                    fallback,
                    chunks: retrievedChunks,
                    generationID: generationID,
                    requestStart: requestStart
                )
            }
            warnAction(ActionID.generateAnswer, title: "Local answer shown", message: "DeepSeek returned an incomplete answer. The fallback answer was kept.",
                whileCurrent: { self.generationCoordinator.isCurrent(context.identity) })
            return
        }
        var updated = current
        updated.stageBCompleted = false
        updated.stageBStatus = error is CancellationError ? "cancelled" : "timed_out"
        updated.caution = "DeepSeek full card generation failed/timed out. Showing opener only."
        if activeFallback {
            updated.caution = "Fast fallback is visible. Full answer expansion failed or timed out."
        }
        currentSuggestion = updated
        guard generationCoordinator.isCurrent(context.identity) else { return }
        persistSuggestionInBackground(
            updated,
            chunks: retrievedChunks,
            generationID: generationID,
            requestStart: requestStart
        )
        warnAction(ActionID.generateAnswer, title: "First answer preserved", message: "Full answer expansion failed. The visible answer was kept.",
            whileCurrent: { self.generationCoordinator.isCurrent(context.identity) })
    } else {
        failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(userFacing(error))")
    }
}

// internal for AppState extension access only
func registerStageATask(_ task: Task<String, Error>, generationID: String) {
    guard generationCoordinator.registerStageATask(task, generationID: generationID) else {
        recordStaleGenerationDiscard()
        return
    }
    providerStreamActive = true
    updateActiveTaskSummary()
}

func clearStageATask(generationID: String) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else { return }
    generationCoordinator.clearStageATask(generationID: generationID)
    guard generationCoordinator.isCurrent(identity), generationCoordinator.stageATask == nil else { return }
    providerStreamActive = false
    updateActiveTaskSummary()
}

func clearStageATimeoutTask(generationID: String) {
    generationCoordinator.clearTask(role: .stageATimeout, generationID: generationID)
    updateActiveTaskSummary()
}

func registerStageBTask(_ task: Task<Void, Never>, generationID: String) {
    guard registerGenerationTask(task, role: .stageB, generationID: generationID) else { return }
    updateActiveTaskSummary()
}

func clearStageBTask(generationID: String) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else { return }
    generationCoordinator.clearTask(role: .stageB, generationID: generationID, cancel: false)
    guard generationCoordinator.isCurrent(identity), generationCoordinator.stageBTask == nil else { return }
    updateActiveTaskSummary()
}

func cancelActiveStageBTask(generationID: String) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else { return }
    generationCoordinator.clearTask(role: .stageB, generationID: generationID)
    guard generationCoordinator.isCurrent(identity), generationCoordinator.stageBTask == nil else { return }
    updateActiveTaskSummary()
}

func registerFallbackWatchdogTask(_ task: Task<Void, Never>, generationID: String) {
    guard registerGenerationTask(task, role: .fallbackWatchdog, generationID: generationID) else { return }
    updateActiveTaskSummary()
}

func clearFallbackWatchdogTask(generationID: String) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else { return }
    generationCoordinator.clearTask(role: .fallbackWatchdog, generationID: generationID)
    guard generationCoordinator.isCurrent(identity), generationCoordinator.fallbackWatchdogTask == nil else { return }
    updateActiveTaskSummary()
}

private func clearFullCardWatchdogTask(generationID: String) {
    generationCoordinator.clearTask(role: .fullCardWatchdog, generationID: generationID)
    updateActiveTaskSummary()
}

@discardableResult
private func registerGenerationTask(_ task: Task<Void, Never>, role: GenerationCoordinator.TaskRole, generationID: String) -> Bool {
    guard generationCoordinator.registerTask(task, role: role, generationID: generationID) else {
        recordStaleGenerationDiscard()
        return false
    }
    updateActiveTaskSummary()
    return true
}

private func beginGenerationUI(
    question: DetectedQuestion,
    generationID: String,
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType?,
    speaker: SpeakerRole?
) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID,
          identity.acceptedQuestionID == question.id else { return }
    generationUIState = .preparing(questionID: question.id, generationID: generationID, triggerPath: triggerPath)
    guard generationCoordinator.isCurrent(identity) else { return }
    lastGenerationStateChangeAt = Date()
    guard generationCoordinator.isCurrent(identity) else { return }
    currentGenerationTelemetry = GenerationTelemetry(
        questionID: question.id,
        generationID: generationID,
        source: source?.rawValue,
        speaker: speaker?.rawValue,
        triggerPath: triggerPath,
        generationState: generationUIState.displayName,
        startedAt: Date(),
        firstVisibleAt: nil,
        fallbackShownAt: nil,
        firstDeepSeekTokenAt: nil,
        firstKeyPointAt: nil,
        fullCardAt: nil,
        dbPersistedAt: nil,
        failureReason: nil,
        wasStaleDiscarded: false,
        duplicateSuppressionCount: currentGenerationTelemetry.duplicateSuppressionCount,
        staleDiscardCount: currentGenerationTelemetry.staleDiscardCount,
        providerError: nil,
        jsonParseError: nil,
        dbError: nil
    )
    guard generationCoordinator.isCurrent(identity) else { return }
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func setGenerationUIState(
    _ state: GenerationUIState, generationID: String? = nil,
    whileCurrent: (() -> Bool)? = nil
) {
    guard whileCurrent?() != false else { return }
    let identity = activeGenerationController?.identity
    if let generationID, currentGenerationID != generationID {
        recordStaleGenerationDiscard()
        return
    }
    if let generationID,
       terminalGenerationIDs.contains(generationID),
       !state.isTerminal {
        recordStaleGenerationDiscard()
        return
    }
    generationUIState = state
    if let identity, !generationCoordinator.isCurrent(identity) { return }
    guard whileCurrent?() != false else { return }
    if state.isTerminal, let terminalGenerationID = state.generationID ?? generationID {
        generationCoordinator.markTerminal(generationID: terminalGenerationID)
    }
    // The terminal fence belongs to the old history; its synchronous observer
    // may already have installed the next presentation/telemetry snapshot.
    if let identity, !generationCoordinator.isCurrent(identity) { return }
    guard whileCurrent?() != false else { return }
    lastGenerationStateChangeAt = Date()
    if let identity, !generationCoordinator.isCurrent(identity) { return }
    guard whileCurrent?() != false else { return }
    currentGenerationTelemetry.generationState = state.displayName
    if let identity, !generationCoordinator.isCurrent(identity) { return }
    guard whileCurrent?() != false else { return }
    if let reason = state.failureReason {
        currentGenerationTelemetry.failureReason = reason
        if let identity, !generationCoordinator.isCurrent(identity) { return }
        guard whileCurrent?() != false else { return }
    }
    recordLifecycleTrace(
        "answer.state.updated",
        questionID: state.questionID,
        generationID: state.generationID ?? generationID,
        text: activeGenerationController?.questionTextSnapshot ?? currentSuggestion?.questionText ?? "",
        reason: state.failureReason ?? "",
        cancelled: {
            if case .cancelled = state { return true }
            return false
        }()
    )
    if let identity, !generationCoordinator.isCurrent(identity) { return }
    guard whileCurrent?() != false else { return }
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func applyPromptSnapshotDiagnostics(
    _ promptSnapshot: AnswerPromptSnapshot,
    providerRequest: GenerationProviderRequest? = nil
) {
    currentAnswerQuestionIntent = promptSnapshot.questionIntent
    currentPromptQuestionText = promptSnapshot.questionTextSnapshot
    currentPromptPrimaryQuestion = providerRequest?.promptPrimaryQuestion ?? promptSnapshot.promptPrimaryQuestion
    currentPromptContainsPreviousQuestion = promptSnapshot.promptContainsPreviousQuestion
    currentPreviousQuestionIncluded = promptSnapshot.previousQuestionIncluded
    currentPreviousQuestionText = promptSnapshot.previousQuestionText ?? ""
    currentContextBleedRisk = promptSnapshot.contextBleedRisk
    currentRAGChunkIDs = promptSnapshot.ragChunkIDs
    currentRAGChunkIntents = promptSnapshot.ragChunkIntents
    currentPromptTokenEstimate = promptSnapshot.promptTokenEstimate
    currentPromptContextPreviews = promptSnapshot.ragChunkPreviews
}

// internal for AppState extension access only
func markFirstVisibleAnswer(
    generationID: String, fallback: Bool, whileCurrent: (() -> Bool)? = nil
) {
    guard whileCurrent?() != false else { return }
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    let now = Date()
    if currentGenerationTelemetry.firstVisibleAt == nil {
        currentGenerationTelemetry.firstVisibleAt = now
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
    }
    if fallback {
        currentGenerationTelemetry.fallbackShownAt = currentGenerationTelemetry.fallbackShownAt ?? now
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
    }
    if currentGenerationTelemetry.questionID == lastTranscriptQuestionGenerationTrace.detectedQuestionID ||
        generationID == lastTranscriptQuestionGenerationTrace.generationID {
        lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated = true
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
        lastTranscriptQuestionGenerationTrace.generationID = generationID
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
        lastTranscriptQuestionGenerationTrace.generationTriggered = true
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
        lastTranscriptQuestionGenerationTrace.currentSuggestionExists = currentSuggestion != nil
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
        lastTranscriptQuestionGenerationTrace.currentGenerationState = generationUIState.displayName
        guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
    }
    guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
    firstVisibleStateSetAt = firstVisibleStateSetAt ?? now
    guard generationCoordinator.isCurrent(identity), whileCurrent?() != false else { return }
    actionLoadingStates[ActionID.generateAnswer] = false
}

private func markFirstKeyPointVisible(generationID: String) {
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    currentGenerationTelemetry.firstKeyPointAt = currentGenerationTelemetry.firstKeyPointAt ?? Date()
}

// internal for AppState extension access only
func markFullCardVisible(generationID: String) {
    guard var captured = generationCoordinator.activeGeneration,
          captured.generationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    let identity = captured.identity
    let requestID = generationCoordinator.activeRequest?.id
    let triggerPath = captured.triggerPath
    @MainActor func ownsPresentation() -> Bool {
        generationCoordinator.ownsProviderTaskSnapshot(captured, requestID: requestID) &&
            currentSession?.id == identity.sessionID &&
            currentSession?.contextSnapshotID == identity.contextSnapshotID
    }
    guard ownsPresentation() else { return }
    if terminalGenerationIDs.contains(generationID) {
        // Preserve the existing repeated-terminal contract: clear its captured
        // deadlines/expansion, without cancelling a retained first-answer child.
        if let retired = generationCoordinator.retireFinishedProviderTasks(
            captured: captured, requestID: requestID, cancelExpansion: false, retireFirstAnswer: false) {
            captured = retired
            guard ownsPresentation() else { return }
            updateActiveTaskSummary()
        }
        return
    }
    currentGenerationTelemetry.fullCardAt = Date()
    guard ownsPresentation() else { return }
    providerStreamActive = false
    guard ownsPresentation() else { return }
    guard let retired = generationCoordinator.retireFinishedProviderTasks(
        captured: captured, requestID: requestID, cancelExpansion: false) else { return }
    captured = retired
    guard ownsPresentation() else { return }
    updateActiveTaskSummary()
    guard ownsPresentation() else { return }
    setGenerationUIState(.answerReady(
        questionID: identity.acceptedQuestionID,
        generationID: generationID,
        triggerPath: triggerPath
    ), generationID: generationID, whileCurrent: { ownsPresentation() })
    guard ownsPresentation() else { return }
    recordTranscriptRuntimeEvent(.generationCompleted(
        sessionID: identity.sessionID,
        questionID: identity.acceptedQuestionID,
        generationID: generationID,
        question: identity.questionText,
        timestamp: Date()
    ))
    guard ownsPresentation() else { return }
    recordLifecycleTrace(
        "answer.stream.completed",
        sessionID: identity.sessionID,
        questionID: identity.acceptedQuestionID,
        generationID: generationID,
        text: identity.questionText
    )
}

// internal for AppState extension access only
func markGenerationFailed(
    generationID: String?,
    reason: String,
    providerError: String? = nil,
    jsonParseError: String? = nil,
    timeout: Bool = false,
    cancelled: Bool = false
) {
    var captured = generationCoordinator.activeGeneration
    let requestID = generationCoordinator.activeRequest?.id
    let sessionID = currentSession?.id
    let contextID = currentSession?.contextSnapshotID
    @MainActor func ownsPresentation() -> Bool {
        guard generationCoordinator.activeRequest?.id == requestID,
              currentSession?.id == sessionID, currentSession?.contextSnapshotID == contextID else { return false }
        if let captured {
            return ownsCurrentGenerationPresentation(captured.identity, requestID: requestID) &&
                generationCoordinator.ownsProviderTaskSnapshot(captured, requestID: requestID)
        }
        return generationCoordinator.activeGeneration == nil
    }
    if let generationID, currentGenerationID != generationID {
        recordStaleGenerationDiscard()
        return
    }
    // The same owned identity can receive repeated provider/timeout cleanup.
    // Once terminal, its UI outcome and one-time diagnostics stay immutable.
    if let generationID, terminalGenerationIDs.contains(generationID) { return }
    guard ownsPresentation() else { return }
    let questionID = currentGenerationTelemetry.questionID
    let triggerPath = currentGenerationTelemetry.triggerPath
    let questionText = captured?.identity.questionText ?? currentSuggestion?.questionText ?? ""
    let eventSessionID = currentSuggestion?.sessionID ?? sessionID ?? ""
    isStreamingSayFirst = false
    guard ownsPresentation() else { return }
    isExpandingSuggestionCard = false
    guard ownsPresentation() else { return }
    suggestionGenerationStarted = false
    guard ownsPresentation() else { return }
    actionLoadingStates[ActionID.generateAnswer] = false
    guard ownsPresentation() else { return }
    actionLoadingStates[ActionID.manualGenerate] = false
    guard ownsPresentation() else { return }
    currentGenerationTelemetry.failureReason = reason
    guard ownsPresentation() else { return }
    currentGenerationTelemetry.providerError = providerError ?? currentGenerationTelemetry.providerError
    guard ownsPresentation() else { return }
    currentGenerationTelemetry.jsonParseError = jsonParseError ?? currentGenerationTelemetry.jsonParseError
    guard ownsPresentation() else { return }
    if timeout {
        generationUIState = .timeout(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    } else if cancelled {
        generationUIState = .cancelled(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    } else {
        generationUIState = .failed(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    }
    guard ownsPresentation() else { return }
    recordLifecycleTrace(
        "answer.request.failed",
        questionID: questionID,
        generationID: generationID,
        text: questionText,
        reason: reason,
        cancelled: cancelled
    )
    guard ownsPresentation() else { return }
    if let generationID {
        generationCoordinator.markTerminal(generationID: generationID)
        guard ownsPresentation() else { return }
    }
    lastGenerationStateChangeAt = Date()
    guard ownsPresentation() else { return }
    currentGenerationTelemetry.generationState = generationUIState.displayName
    guard ownsPresentation() else { return }
    if generationID != nil, let original = captured {
        guard let retired = generationCoordinator.retireFinishedProviderTasks(
            captured: original, requestID: requestID, cancelExpansion: true) else { return }
        captured = retired
        guard ownsPresentation() else { return }
        providerStreamActive = false
        guard ownsPresentation() else { return }
    }
    updateActiveTaskSummary()
    guard ownsPresentation() else { return }
    if timeout {
        recordTranscriptRuntimeEvent(.generationTimedOut(
            sessionID: eventSessionID,
            questionID: questionID,
            generationID: generationID,
            question: questionText,
            timestamp: Date()
        ))
        guard ownsPresentation() else { return }
    }
    if let generationID, let session = currentSession {
        restoreCaptureAfterGenerationIfNeeded(
            session: session,
            generationID: generationID,
            reason: timeout ? "generationFullCardTimeout" : "generationFailed"
        )
        guard ownsPresentation() else { return }
    }
    processNextQueuedAutoQuestionIfIdle()
}

// internal for AppState extension access only
func recordStaleGenerationDiscard(
    attributedTo identity: GenerationIdentity? = nil,
    sourceCallback: String = #function,
    sourceFile: String = #fileID,
    sourceLine: Int = #line,
    reason: String = "stale_answer_result",
    countsAsDiscardedAnswer: Bool = true
) {
    staleCallbackDiscardCount += 1
    // A successfully admitted historical write can finish after UI ownership
    // changes. Skipping its optional refresh discards no answer and must not
    // attach an older completion to the current generation's telemetry.
    if countsAsDiscardedAnswer {
        staleAnswerDiscardCount += 1
        // Cumulative audit counts remain visible even when their source is
        // obsolete or unknown. Only an explicitly frozen current identity may
        // project them into the current generation. Both counter and telemetry
        // publication can synchronously replace that identity.
        if let identity, generationCoordinator.isCurrent(identity),
           currentSession?.id == identity.sessionID {
            currentGenerationTelemetry.staleDiscardCount = staleCallbackDiscardCount
            if generationCoordinator.isCurrent(identity), currentSession?.id == identity.sessionID {
                updateActiveTaskSummary()
            }
        }
    }
    // Attribution contains identities and control state only. Keep stdout
    // limited to isolated test/automation processes; no transcript or answer.
    if isRunningUnderTestOrAutomation() {
        let metadata: [String: Any] = [
            "event": "stale_generation_discard",
            "source_callback": sourceCallback,
            "source_file": sourceFile,
            "source_line": sourceLine,
            "reason": reason,
            "counts_as_discarded_answer": countsAsDiscardedAnswer,
            "attributed_generation_id": identity?.generationID ?? "",
            "attributed_question_id": identity?.acceptedQuestionID ?? "",
            "attributed_context_id": identity?.contextSnapshotID ?? "",
            "current_generation_id": currentGenerationID ?? "",
            "active_question_id": activeQuestionID ?? "",
            "current_session_id": currentSession?.id ?? "",
            "task_cancelled": Task.isCancelled,
            "terminal": generationUIState.isTerminal,
            "stale_callback_discard_count": staleCallbackDiscardCount,
            "stale_answer_discard_count": staleAnswerDiscardCount
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            print("[GenerationOwnership] " + String(decoding: data, as: UTF8.self))
        }
    }
}

// internal for AppState extension access only
func recordStaleGenerationResultRejected(
    sessionID: String,
    oldGenerationID: String?,
    oldQuestionText: String,
    reason: String,
    oldAcceptedQuestionID: String? = nil,
    sourceCallback: String = "unknown"
) {
    let currentController = activeGenerationController
    let currentGeneration = currentController?.generationID ?? currentGenerationID
    let currentQuestionID = currentController?.questionID ?? activeQuestionID
    let currentQuestionText = currentController?.questionTextSnapshot ?? currentSuggestion?.questionText ?? ""
    recordStaleGenerationDiscard()
    recordTranscriptRuntimeEvent(.staleGenerationResultRejected(
        sessionID: sessionID,
        oldGenerationID: oldGenerationID,
        currentGenerationID: currentGeneration,
        oldAcceptedQuestionID: oldAcceptedQuestionID,
        currentAcceptedQuestionID: currentQuestionID,
        oldQuestionText: oldQuestionText,
        currentQuestionText: currentQuestionText,
        sourceCallback: sourceCallback,
        reason: reason,
        timestamp: Date()
    ))
    if !currentQuestionText.isEmpty,
       SemanticDuplicateKeyBuilder.key(for: oldQuestionText) != SemanticDuplicateKeyBuilder.key(for: currentQuestionText) {
        recordTranscriptRuntimeEvent(.currentCardRegressionRejected(
            sessionID: sessionID,
            oldGenerationID: oldGenerationID,
            currentGenerationID: currentGeneration,
            oldAcceptedQuestionID: oldAcceptedQuestionID,
            currentAcceptedQuestionID: currentQuestionID,
            oldQuestionText: oldQuestionText,
            currentQuestionText: currentQuestionText,
            sourceCallback: sourceCallback,
            reason: reason,
            timestamp: Date()
        ))
    }
}

// internal for AppState extension access only
func recordDuplicateSuppression() {
    suggestionGenerationStarted = false
    isStreamingSayFirst = false
    if !visibleAnswerExists {
        isExpandingSuggestionCard = false
        generationUIState = .idle
    }
    currentGenerationTelemetry.duplicateSuppressionCount += 1
    duplicateSuppressionCount += 1
    actionLoadingStates[ActionID.generateAnswer] = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func recordVisibleSuggestionInHistory(_ card: SuggestionCard) {
    guard let result = liveInterview.recordVisibleCardInHistory(card) else { return }
    let historyCard = result.card
    let question = historyCard.questionText ?? historyCard.promptPrimaryQuestion ?? historyCard.promptQuestionText ?? ""
    let alreadyExists = !result.didAppend
    if selectedSessionID == historyCard.sessionID {
        selectedSessionSuggestions = liveSuggestionHistory
    }
    // Publishing a validated card changes visible answer state independently
    // of the loading-state machine (which may transition later in the stream).
    recordLifecycleTrace(
        "answer.state.updated",
        sessionID: historyCard.sessionID,
        questionID: historyCard.detectedQuestionID,
        generationID: historyCard.generationID,
        text: question,
        reason: "validated_card_published"
    )
    recordTranscriptRuntimeEvent(.visibleCurrentSuggestionUpdated(
        sessionID: historyCard.sessionID,
        questionID: historyCard.detectedQuestionID,
        generationID: historyCard.generationID,
        question: question,
        timestamp: Date()
    ))
    recordLifecycleTrace(
        "answer.ui.rendered",
        sessionID: historyCard.sessionID,
        questionID: historyCard.detectedQuestionID,
        generationID: historyCard.generationID,
        text: question
    )
    if !alreadyExists {
        recordTranscriptRuntimeEvent(.questionHistoryAppended(
            sessionID: historyCard.sessionID,
            questionID: historyCard.detectedQuestionID,
            generationID: historyCard.generationID,
            question: question,
            timestamp: Date()
        ))
    }
}

// internal for AppState extension access only
func refreshLiveSuggestionHistory(sessionID: String, latestQuestion: String) {
    do {
        let rows = try suggestionRepository.suggestions(sessionID: sessionID)
        if currentSession?.id == sessionID {
            liveSuggestionHistory = rows
        }
        if selectedSessionID == sessionID {
            selectedSessionSuggestions = rows
        }
        recordTranscriptRuntimeEvent(.uiHistoryRefresh(
            sessionID: sessionID,
            question: latestQuestion,
            count: rows.count,
            timestamp: Date()
        ))
    } catch {
        lastSQLiteOperation = "Suggestion history refresh failed: \(error.localizedDescription)"
    }
}

// Provider failures belong to the generation that initiated them. A completed
// stale callback may be recorded diagnostically, but must not escape to the
// caller and become a global UI alert for the newer question.
func shouldPropagateGenerationFailure(generationID: String, questionID: String) -> Bool {
    isActiveGeneration(generationID, questionID: questionID)
}

private func restoreCaptureAfterGenerationIfNeeded(
    session: InterviewSession,
    generationID: String,
    reason: String
) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID else { return }
    let requestID = generationCoordinator.activeRequest?.id
    func ownsCapturePresentation() -> Bool {
        identity.sessionID == session.id &&
            ownsCurrentGenerationPresentation(identity, requestID: requestID)
    }
    guard ownsCapturePresentation() else { return }
    if currentSession?.id == session.id &&
        currentCaptureRuntimeState == .generating &&
        stopReason == nil &&
        currentGenerationID == generationID &&
        anyCaptureRunning {
        liveState = .listening
        guard ownsCapturePresentation() else { return }
        currentCaptureRuntimeState = .listening
        guard ownsCapturePresentation() else { return }
        addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: reason)
    } else if currentGenerationID == generationID &&
                liveState == .generatingSuggestion &&
                !anyCaptureRunning {
        liveState = .stopped
        guard ownsCapturePresentation() else { return }
        if currentCaptureRuntimeState == .generating {
            currentCaptureRuntimeState = .stopped(reason: stopReason)
        }
    }
}

// internal for AppState extension access only
func startFullCardWatchdog(
    generationID: String,
    cardID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    triggerPath: GenerationTriggerPath,
    delayProvider: (any DelayProvider)? = nil
) {
    guard let identity = activeGenerationController?.identity,
          identity.generationID == generationID,
          identity.acceptedQuestionID == question.id,
          identity.sessionID == session.id,
          generationCoordinator.canPublish(identity) else { return }
    let timeoutNanoseconds = generationFullCardWatchdogNanoseconds
    let watchdogDelay = delayProvider ?? generationWatchdogDelayProvider
    let task = generationCoordinator.launchFullCardDeadline(
        identity: identity, startedAt: requestStart,
        nanoseconds: timeoutNanoseconds, delayProvider: watchdogDelay,
        presentation: { [weak self] identity in
            guard let self, !self.generationUIState.isTerminal,
                  self.currentSession?.id == identity.sessionID else { return nil }
            return (self.currentSuggestion, self.streamedSayFirst)
        },
        onTimeout: { [weak self] plan, visibleCard, streamed, elapsed in
            guard let self, let identity = plan.identity else { return }
            // Sleep may have returned while terminal completion was queued on
            // this actor. Fence every side effect, including timeout diagnostics.
            guard !Task.isCancelled,
                  self.generationCoordinator.canPublish(identity),
                  !self.generationUIState.isTerminal,
                  self.currentSession?.id == identity.sessionID else { return }

            if plan.action == .markProviderFailed {
                self.markGenerationFailed(generationID: generationID,
                    reason: "No validated local answer before the full-answer deadline (\(elapsed) ms).",
                    timeout: true)
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID,
                    reason: "generationFullCardTimeout")
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.warnAction(ActionID.generateAnswer, title: "Answer timed out",
                    message: "No validated answer is available. Transcript preserved; retry when ready.",
                    whileCurrent: { self.generationCoordinator.isCurrent(identity) && self.currentSession?.id == identity.sessionID })
                return
            }

            if plan.action == .keepVisibleFirstAnswer, var current = visibleCard {
                guard self.visibleCardMatchesGeneration(
                    card: current,
                    generationID: generationID,
                    detectedQuestionID: question.id,
                    promptPrimaryQuestion: question.questionText
                ) else {
	                    self.recordStaleGenerationDiscard()
	                    return
	                }
                if let completed = self.completeSubstantiveProviderFirstAnswerAfterTimeout(
                    current,
                    question: question,
                    requestStart: requestStart
                ) {
                    current = completed
                    self.currentSuggestion = completed
                }
                if self.replaceIncompleteVisibleAnswerWithFallbackIfNeeded(
                    card: current,
                    question: question,
                    session: session,
                    generationID: generationID,
                    requestStart: requestStart,
                    triggerPath: triggerPath,
                    reason: "full-card watchdog timeout"
                ) {
                    if var fallback = self.currentSuggestion {
                        fallback.stageBCompleted = false
                        fallback.stageBStatus = "timed_out"
                        _ = self.finishGenerationWithVisibleCard(
                            fallback,
                            generationID: generationID,
                            question: question,
                            session: session,
                            requestStart: requestStart,
                            retrievedChunks: self.currentSuggestionRetrievedChunks,
                            triggerPath: triggerPath,
                            timedOut: true
                        )
                        guard self.generationCoordinator.isCurrent(identity) else { return }
                    }
                    self.currentGenerationTelemetry.failureReason = "Full answer timed out after \(elapsed) ms."
                    self.warnAction(ActionID.generateAnswer, title: "Local answer shown", message: "DeepSeek returned an incomplete answer. The fallback answer is visible.")
                    return
                }
                current.stageBCompleted = false
                current.stageBStatus = "timed_out"
                current.caution = current.caution ?? "Full answer is delayed. The first answer is still safe to use."
                self.currentSuggestion = current
                self.currentGenerationTelemetry.failureReason = "Full answer timed out after \(elapsed) ms."
                _ = self.finishGenerationWithVisibleCard(
                    current,
                    generationID: generationID,
                    question: question,
                    session: session,
                    requestStart: requestStart,
                    retrievedChunks: self.currentSuggestionRetrievedChunks,
                    triggerPath: triggerPath,
                    timedOut: true
                )
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.warnAction(ActionID.generateAnswer, title: "First answer visible", message: "Full answer is delayed. You can retry, but the visible answer remains available.")
                return
            }

            if plan.action == .keepVisibleFirstAnswer {
                var streamCard = self.makeInitialFirstAnswerFallbackCard(
                    cardID: cardID,
                    question: question,
                    session: session,
                    requestStart: requestStart
                )
                streamCard.strategy = "DeepSeek First Answer"
                streamCard.sayFirst = streamed
                streamCard.caution = "DeepSeek first-answer stream did not finish; the visible answer was saved."
                streamCard.modelName = self.generationProviderConfiguration?.model ?? streamCard.modelName
                streamCard.providerKind = self.generationProviderConfiguration?.kind
                streamCard.providerName = self.generationProviderConfiguration?.name ?? "DeepSeek"
                streamCard.providerBaseURL = self.generationProviderConfiguration?.baseURL ?? "https://api.deepseek.com"
                streamCard.latencyMS = elapsed
                streamCard.isLocal = false
                streamCard.questionText = question.questionText
                streamCard.transcriptSegmentID = question.transcriptSegmentID
                streamCard.generationID = generationID
                streamCard.source = self.currentGenerationTelemetry.source
                streamCard.speaker = self.currentGenerationTelemetry.speaker
                streamCard.triggerPath = triggerPath
                streamCard.sayFirstSource = "deepseek_stream_timeout"
                streamCard.stageATimedOut = true
                streamCard.stageBCompleted = false
                streamCard.stageBStatus = "timed_out"
                streamCard.latencyFirstTokenMS = self.deepseekFirstTokenMS
                streamCard.latencyFirstVisibleMS = self.deepseekFirstVisibleMS
                streamCard.deepseekFirstTokenMS = self.deepseekFirstTokenMS
                streamCard.deepseekFirstVisibleMS = self.deepseekFirstVisibleMS
                streamCard.finalVisibleSource = "deepseek_stream_timeout"
                streamCard.firstVisibleAnswerMS = self.deepseekFirstVisibleMS ?? elapsed
                if streamCard.keyPoints.isEmpty {
                    streamCard.keyPoints = AnswerRelevancePolicy.fallbackAnswer(for: question).keyPoints
                }
                if !streamCard.keyPoints.isEmpty {
                    streamCard.firstKeyPointVisibleMS = streamCard.firstVisibleAnswerMS
                    streamCard.allKeyPointsVisibleMS = streamCard.firstVisibleAnswerMS
                }
                if !streamCard.followUpReady.isEmpty {
                    streamCard.followUpVisibleMS = streamCard.firstVisibleAnswerMS
                }
                _ = self.finishGenerationWithVisibleCard(
                    streamCard,
                    generationID: generationID,
                    question: question,
                    session: session,
                    requestStart: requestStart,
                    retrievedChunks: self.currentSuggestionRetrievedChunks,
                    triggerPath: triggerPath,
                    timedOut: true
                )
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.currentGenerationTelemetry.failureReason = "Full answer timed out after \(elapsed) ms."
                self.warnAction(ActionID.generateAnswer, title: "First answer visible", message: "Full answer is delayed. You can retry, but the visible answer remains available.")
                return
            }

            guard plan.action == .useSemanticFallback else { return }
            var fallbackCard = self.makeInitialFirstAnswerFallbackCard(
                cardID: cardID,
                question: question,
                session: session,
                requestStart: requestStart
            )
            fallbackCard.firstVisibleAnswerMS = elapsed
            fallbackCard.stageBStatus = "timed_out"
            fallbackCard.caution = "Provider timed out. Local first answer shown; retry when ready."
            guard self.displaySuggestionIfAligned(
                fallbackCard,
                question: question,
                generationID: generationID,
                triggerPath: triggerPath
            ) else {
                // Rejecting a fallback preserves the evidence boundary, but
                // must still end this expired request and fence late tokens.
                self.markGenerationFailed(
                    generationID: generationID,
                    reason: "No validated answer before the full-answer deadline (\(elapsed) ms).",
                    timeout: true
                )
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "generationFullCardTimeout")
                guard self.generationCoordinator.isCurrent(identity) else { return }
                self.warnAction(ActionID.generateAnswer, title: "Answer timed out", message: "No validated answer is available. Transcript preserved; retry when ready.")
                return
            }
            self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
            self.softFallbackUsed = true
            self.softFallbackLatencyMS = elapsed
            self.softFallbackShownAt = self.softFallbackShownAt ?? Date()
            self.finalVisibleSource = fallbackCard.finalVisibleSource
            self.markFirstVisibleAnswer(generationID: generationID, fallback: true)
            self.persistSuggestionInBackground(
                fallbackCard,
                chunks: self.currentSuggestionRetrievedChunks,
                generationID: generationID,
                requestStart: requestStart
            )
            self.markGenerationFailed(
                generationID: generationID,
                reason: "No provider answer before the full-answer deadline (\(elapsed) ms).",
                timeout: true
            )
            guard self.generationCoordinator.isCurrent(identity) else { return }
            self.cancelActiveStageBTask(generationID: generationID)
            self.restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "generationFullCardTimeout")
            guard self.generationCoordinator.isCurrent(identity) else { return }
            self.warnAction(ActionID.generateAnswer, title: "Local answer shown", message: "DeepSeek timed out. The fallback answer is visible; retry is available.")
        })
    if task != nil { updateActiveTaskSummary() }
}

private func applyStreamingSections(
    _ sections: StreamingSuggestionSections,
    to current: SuggestionCard?,
    cardID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    stageBStreamStartedMS: Int?,
    preserveExistingSayFirst: Bool = false,
    markFullCardVisible: Bool
) -> SuggestionCard {
    let nowMS = elapsedMS(since: requestStart)
    var card = current ?? SuggestionCard(
        id: cardID,
        sessionID: session.id,
        questionID: question.id,
        strategy: sections.strategy.isEmpty ? "Direct Answer" : sections.strategy,
        sayFirst: "",
        keyPoints: [],
        followUpReady: [],
        confidence: 0.8,
        caution: nil,
        evidenceUsed: [],
        riskLevel: .low,
        modelName: generationProviderConfiguration?.model ?? "deepseek-v4-flash",
        promptVersion: "section-stream-v1",
        providerKind: generationProviderConfiguration?.kind,
        providerName: generationProviderConfiguration?.name ?? "DeepSeek",
        providerBaseURL: generationProviderConfiguration?.baseURL ?? "https://api.deepseek.com",
        latencyMS: nowMS,
        isLocal: false,
        rawJSON: nil,
        createdAt: Date()
    )

    if !sections.strategy.isEmpty {
        card.strategy = sections.strategy
    }

    if !sections.sayFirst.isEmpty {
        // A cumulative provider section can grow beyond its first complete
        // sentence. Apply the new text through the same publication gate;
        // preserving it unconditionally silently dropped later answer clauses.
        let keepsCompleteFirstAnswer = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(card.sayFirst) == nil
            && QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(sections.sayFirst) != nil
        if !keepsCompleteFirstAnswer && (card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !preserveExistingSayFirst) {
            card.sayFirst = sections.sayFirst
            markProviderStreamOwnership(&card)
        }
    }

    if !sections.keyPoints.isEmpty {
        card.keyPoints = sections.keyPoints
        if card.firstKeyPointVisibleMS == nil {
            card.firstKeyPointVisibleMS = nowMS
        }
        if markFullCardVisible || sections.keyPoints.count >= 2 {
            card.allKeyPointsVisibleMS = card.allKeyPointsVisibleMS ?? nowMS
        }
    }
    if card.keyPoints.isEmpty,
       !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let providerKeyPoints = providerOwnedKeyPoints(from: card.sayFirst),
       !providerKeyPoints.isEmpty {
        card.keyPoints = providerKeyPoints
        card.firstKeyPointVisibleMS = card.firstKeyPointVisibleMS ?? nowMS
        if markFullCardVisible || providerKeyPoints.count >= 2 {
            card.allKeyPointsVisibleMS = card.allKeyPointsVisibleMS ?? nowMS
        }
    }

    if !sections.followUpReady.isEmpty {
        card.followUpReady = sections.followUpReady
        card.followUpVisibleMS = card.followUpVisibleMS ?? nowMS
    }

    if !sections.caution.isEmpty {
        card.caution = sections.caution
    }

    if !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        card.firstVisibleAnswerMS = card.firstVisibleAnswerMS ?? card.latencyFirstVisibleMS ?? deepseekFirstVisibleMS ?? nowMS
        card.latencyFirstVisibleMS = card.latencyFirstVisibleMS ?? card.firstVisibleAnswerMS
    }

    card.stageBStreamStartedMS = card.stageBStreamStartedMS ?? stageBStreamStartedMS
    if card.stageBCompleted == nil {
        card.stageBCompleted = markFullCardVisible
        card.stageBStatus = markFullCardVisible ? "completed" : "streaming"
    }
    if sections.hasVisibleContent {
        card.stageBFirstSectionMS = card.stageBFirstSectionMS ?? nowMS
        if card.sayFirstSource == "deepseek_stream" {
            markProviderStreamOwnership(&card)
        }
    }
    if markFullCardVisible {
        card.fullCardVisibleMS = nowMS
        card.latencyFullCardMS = nowMS
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        card.latencyMS = nowMS
    }
    if card.finalVisibleSource == "deepseek_stream" {
        card.softFallbackUsed = false
        card.softFallbackLatencyMS = nil
    } else {
        card.softFallbackUsed = softFallbackUsed
        card.softFallbackLatencyMS = softFallbackLatencyMS
    }
    card.deepseekFirstTokenMS = deepseekFirstTokenMS
    card.deepseekFirstVisibleMS = deepseekFirstVisibleMS
    card.ragRetrievalLatencyMS = ragRetrievalLatencyMS
    return card
}

private func providerOwnedKeyPoints(from answerText: String) -> [String]? {
    let cleaned = answerText
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count >= 80 else { return nil }

    let sentenceCandidates = cleaned
        .components(separatedBy: CharacterSet(charactersIn: ".!?"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.count >= 24 }

    let candidates: [String]
    if sentenceCandidates.count >= 2 {
        candidates = sentenceCandidates
    } else {
        candidates = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { phrase in
                phrase
                    .replacingOccurrences(
                        of: #"(?i)\s+(?:which|that|while|enabling|so|then)\s+"#,
                        with: "|||",
                        options: .regularExpression
                    )
                    .components(separatedBy: "|||")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 24 }
    }

    let keyPoints = candidates
        .map { providerOwnedKeyPointText($0) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { result, point in
            if !result.contains(where: { $0.caseInsensitiveCompare(point) == .orderedSame }) {
                result.append(point)
            }
        }
        .prefix(3)

    return keyPoints.isEmpty ? nil : Array(keyPoints)
}

private func providerOwnedKeyPointText(_ text: String) -> String {
    var point = text
        .replacingOccurrences(of: #"^(?i)(i|we)\s+(handled|used|built|created|connected|made|started|focused on)\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"^(?i)(by|and|which|that|while|enabling|so|then)\s+"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !point.isEmpty else { return "" }
    point = String(point.prefix(1)).uppercased() + String(point.dropFirst())
    if !point.hasSuffix(".") {
        point += "."
    }
    return point
}

// internal for AppState extension access only
func completeSubstantiveProviderFirstAnswerAfterTimeout(
    _ card: SuggestionCard,
    question: DetectedQuestion,
    requestStart: Date
) -> SuggestionCard? {
    guard isProviderOwnedTimeoutCandidate(card),
          let sayFirst = substantiveProviderSayFirst(card.sayFirst)
    else {
        return nil
    }

    var completed = card
    completed.sayFirst = sayFirst
    markProviderStreamOwnership(
        &completed,
        source: "deepseek_stream",
        modelName: completed.modelName
    )
    if completed.keyPoints.isEmpty,
       let providerKeyPoints = providerOwnedKeyPoints(from: sayFirst),
       !providerKeyPoints.isEmpty {
        completed.keyPoints = providerKeyPoints
    }

    let alignmentText = ([completed.sayFirst] + completed.keyPoints + completed.followUpReady).joined(separator: " ")
    let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
        questionText: question.questionText,
        answerText: alignmentText,
        sayFirst: completed.sayFirst,
        stageBCompleted: true,
        decision: question.taskDescriptor?.decision
    )
    guard alignment.verdict == .aligned else {
        return nil
    }

    let elapsed = elapsedMS(since: requestStart)
    completed.stageBCompleted = true
    completed.stageBStatus = "completed"
    completed.caution = completed.caution ?? "Full answer expansion timed out; the DeepSeek first answer was kept."
    completed.alignmentScore = alignment.score
    completed.alignmentVerdict = alignment.verdict
    completed.answerIntent = alignment.answerIntent
    completed.mismatchReason = nil
    completed.firstVisibleAnswerMS = completed.firstVisibleAnswerMS ?? completed.deepseekFirstVisibleMS ?? elapsed
    completed.fullCardVisibleMS = completed.fullCardVisibleMS ?? completed.firstVisibleAnswerMS
    completed.latencyFirstVisibleMS = completed.latencyFirstVisibleMS ?? completed.firstVisibleAnswerMS
    completed.latencyFullCardMS = completed.latencyFullCardMS ?? completed.fullCardVisibleMS
    completed.latencyMS = completed.latencyMS ?? elapsed
    completed.deepseekFirstTokenMS = completed.deepseekFirstTokenMS ?? deepseekFirstTokenMS
    completed.deepseekFirstVisibleMS = completed.deepseekFirstVisibleMS ?? deepseekFirstVisibleMS
    if !completed.keyPoints.isEmpty {
        completed.firstKeyPointVisibleMS = completed.firstKeyPointVisibleMS ?? completed.firstVisibleAnswerMS
        completed.allKeyPointsVisibleMS = completed.allKeyPointsVisibleMS ?? completed.firstVisibleAnswerMS
    }
    return completed
}

private func isProviderOwnedTimeoutCandidate(_ card: SuggestionCard) -> Bool {
    let sources = [card.sayFirstSource, card.finalVisibleSource]
        .compactMap { $0?.lowercased() }
    if sources.contains(where: { $0.contains("local_") || $0.contains("fallback") && !$0.contains("deepseek") }) {
        return false
    }
    return card.isLocal == false ||
        card.providerName?.localizedCaseInsensitiveContains("DeepSeek") == true ||
        sources.contains(where: { $0.contains("deepseek_stream") })
}

private func substantiveProviderSayFirst(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 140 else { return nil }
    let words = trimmed.split(whereSeparator: \.isWhitespace)
    guard words.count >= 24 else { return nil }

    switch QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(trimmed) {
    case nil:
        return trimmed
    case "missing terminal punctuation":
        guard let lastWord = words.last?.lowercased(),
              !["and", "or", "to", "the", "a", "an", "with", "for", "from", "of", "in", "on", "by"].contains(String(lastWord))
        else {
            return nil
        }
        return trimmed + "."
    default:
        return nil
    }
}

// internal for AppState extension access only
@discardableResult
func publishStreamingSections(
    _ sections: StreamingSuggestionSections,
    cardID: String,
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    stageBStreamStartedMS: Int?,
    preserveExistingSayFirst: Bool = false,
    markFullCardVisible: Bool = false
) -> Bool {
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard()
        return false
    }
    guard !terminalGenerationIDs.contains(generationID),
          !generationUIState.isTerminal else {
        return false
    }
    let currentForUpdate: SuggestionCard?
    if let currentSuggestion {
        if visibleCardMatchesGeneration(
            card: currentSuggestion,
            generationID: generationID,
            detectedQuestionID: question.id,
            promptPrimaryQuestion: question.questionText
        ) {
            currentForUpdate = currentSuggestion
        } else {
            recordStaleGenerationDiscard()
            currentForUpdate = nil
        }
    } else {
        currentForUpdate = nil
    }
    let card = applyStreamingSections(
        sections,
        to: currentForUpdate,
        cardID: cardID,
        question: question,
        session: session,
        requestStart: requestStart,
        stageBStreamStartedMS: stageBStreamStartedMS,
        preserveExistingSayFirst: preserveExistingSayFirst,
        markFullCardVisible: markFullCardVisible
    )
    guard displaySuggestionIfAligned(
        card,
        question: question,
        generationID: generationID,
        triggerPath: currentGenerationTelemetry.triggerPath,
        source: AudioSourceType(rawValue: currentGenerationTelemetry.source ?? ""),
        speaker: SpeakerRole(rawValue: currentGenerationTelemetry.speaker ?? "")
    ) else { return false }
    if currentSuggestionSetAt == nil {
        currentSuggestionSetAt = Date()
    }
    isExpandingSuggestionCard = !markFullCardVisible
    if !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        markFirstVisibleAnswer(generationID: generationID, fallback: false)
        setGenerationUIState(.expandingFullAnswer(
            questionID: question.id,
            generationID: generationID,
            triggerPath: currentGenerationTelemetry.triggerPath ?? .manualGenerate
        ), generationID: generationID)
    }
    if !card.keyPoints.isEmpty {
        markFirstKeyPointVisible(generationID: generationID)
    }
    // A full snapshot still precedes the apply caller's awaited checks and
    // persistence admission. That caller commits the terminal state afterwards.
    return true
}

// internal for AppState extension access only
@discardableResult
func finishGenerationWithVisibleCard(
    _ card: SuggestionCard,
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    retrievedChunks: [RetrievedChunk],
    triggerPath: GenerationTriggerPath,
    timedOut: Bool
) -> Bool {
    guard let identity = activeGenerationController?.identity,
          isActiveGeneration(generationID, questionID: question.id) else {
        recordStaleGenerationDiscard()
        return false
    }
    guard !terminalGenerationIDs.contains(generationID),
          !generationUIState.isTerminal else { return false }
    guard visibleCardMatchesGeneration(
        card: card,
        generationID: generationID,
        detectedQuestionID: question.id,
        promptPrimaryQuestion: question.questionText
    ) else {
        recordStaleGenerationDiscard()
        return false
    }

    var finalCard = timedOut
        ? (completeSubstantiveProviderFirstAnswerAfterTimeout(
            card,
            question: question,
            requestStart: requestStart
        ) ?? card)
        : card
    if timedOut,
       let incompleteReason = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(finalCard.sayFirst) {
        recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            reason: "timed-out visible card: \(incompleteReason)",
            timestamp: Date()
        ))
        var fallback = makeInitialFirstAnswerFallbackCard(
            cardID: finalCard.id,
            question: question,
            session: session,
            requestStart: requestStart
        )
        fallback.questionText = question.questionText
        fallback.transcriptSegmentID = question.transcriptSegmentID
        fallback.generationID = generationID
        fallback.source = finalCard.source ?? currentGenerationTelemetry.source
        fallback.speaker = finalCard.speaker ?? currentGenerationTelemetry.speaker
        fallback.triggerPath = finalCard.triggerPath ?? triggerPath
        fallback.promptQuestionText = finalCard.promptQuestionText ?? question.questionText
        fallback.promptPrimaryQuestion = finalCard.promptPrimaryQuestion ?? question.questionText
        fallback.promptContainsPreviousQuestion = finalCard.promptContainsPreviousQuestion
        fallback.previousQuestionIncluded = finalCard.previousQuestionIncluded
        fallback.previousQuestionText = finalCard.previousQuestionText
        fallback.contextBleedRisk = finalCard.contextBleedRisk
        fallback.ragChunkIDs = finalCard.ragChunkIDs
        fallback.ragChunkIntents = finalCard.ragChunkIntents
        fallback.promptTokenEstimate = finalCard.promptTokenEstimate
        fallback.promptContextPreview = finalCard.promptContextPreview
        fallback.stageATimedOut = finalCard.stageATimedOut ?? false
        fallback.stageBCompleted = false
        fallback.stageBStatus = "timed_out"
        fallback.caution = "Provider answer was incomplete after timeout, so a local first answer was saved."
        fallback.sayFirstSource = "local_timeout_fallback"
        fallback.finalVisibleSource = "local_timeout_fallback"
        fallback.latencyFirstTokenMS = finalCard.latencyFirstTokenMS
        fallback.latencyFirstVisibleMS = finalCard.latencyFirstVisibleMS
        fallback.firstVisibleAnswerMS = finalCard.firstVisibleAnswerMS ?? elapsedMS(since: requestStart)
        if !fallback.keyPoints.isEmpty {
            fallback.firstKeyPointVisibleMS = fallback.firstVisibleAnswerMS
            fallback.allKeyPointsVisibleMS = fallback.firstVisibleAnswerMS
        }
        if !fallback.followUpReady.isEmpty {
            fallback.followUpVisibleMS = fallback.firstVisibleAnswerMS
        }
        finalCard = fallback
    }

    currentSuggestion = finalCard
    recordVisibleSuggestionInHistory(finalCard)
    currentSuggestionRetrievedChunks = retrievedChunks
    isStreamingSayFirst = false
    isExpandingSuggestionCard = false
    suggestionGenerationStarted = false
    providerStreamActive = false
    clearStageATimeoutTask(generationID: generationID)
    clearFullCardWatchdogTask(generationID: generationID)
    // A terminal decision may come from a watchdog or a different provider.
    // Releasing its handle must also ask the still-running expansion to stop.
    cancelActiveStageBTask(generationID: generationID)

    persistSuggestionInBackground(
        finalCard,
        chunks: retrievedChunks,
        generationID: generationID,
        requestStart: requestStart
    )
    if finalCard.stageBStatus == "needs_personal_evidence" {
        setGenerationUIState(.needsInput(questionID: question.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
        guard generationCoordinator.isCurrent(identity) else { return true }
        warnAction(ActionID.generateAnswer, title: "Personal facts needed", message: "Confirm the missing facts before generating a personal answer.")
        restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "personal_input_needed")
        processNextQueuedAutoQuestionIfIdle()
        return true
    }
    setGenerationUIState(
        .answerReady(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
        generationID: generationID
    )
    // Persistence was already admitted for the validated old card. A terminal
    // subscriber may install Q2; retain Q1 history without completing Q2's UI.
    guard generationCoordinator.isCurrent(identity) else { return true }
    currentGenerationTelemetry.fullCardAt = currentGenerationTelemetry.fullCardAt ?? Date()
    completeAction(ActionID.generateAnswer, title: "Answer ready", message: "First answer is visible.")
    guard generationCoordinator.isCurrent(identity) else { return true }

    if timedOut {
        recordTranscriptRuntimeEvent(.generationTimedOut(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            timestamp: Date()
        ))
        recordLifecycleTrace(
            "answer.stream.completed",
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            text: question.questionText,
            reason: "visible_answer_ready_after_timeout"
        )
    } else {
        recordTranscriptRuntimeEvent(.generationCompleted(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            timestamp: Date()
        ))
        recordLifecycleTrace(
            "answer.stream.completed",
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            text: question.questionText
        )
    }
    refreshLatencyAverages()
    restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: timedOut ? "generationTimedOutWithVisibleAnswer" : "generationVisibleAnswerReady")
    guard generationCoordinator.isCurrent(identity) else { return true }
    processNextQueuedAutoQuestionIfIdle()
    return true
}

private func stageBStatus(for plan: StageBApplicationPlan) -> (status: String, timedOut: Bool) {
    switch plan.safeDiagnostics["stageBClassification"] {
    case StageBResultClassification.timedOut.rawValue:
        return ("timed_out", true)
    case StageBResultClassification.providerFailure.rawValue:
        return ("provider_failed", false)
    case StageBResultClassification.noSections.rawValue:
        return ("first_answer_only", false)
    case StageBResultClassification.fallbackRequired.rawValue:
        return ("semantic_fallback", false)
    default:
        return ("first_answer_only", false)
    }
}

private func providerFirstAnswerCanCompleteStageB(_ card: SuggestionCard, plan: StageBApplicationPlan) -> Bool {
    guard plan.safeDiagnostics["providerStatus"] == GenerationProviderStatus.completed.rawValue else {
        return false
    }
    guard card.finalVisibleSource == "deepseek_stream",
          card.sayFirstSource == "deepseek_stream",
          card.isLocal == false,
          card.softFallbackUsed != true
    else {
        return false
    }
    return QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card).accepted
}

private func completeProviderFirstAnswerAfterStageBRejection(
    _ card: inout SuggestionCard,
    plan: StageBApplicationPlan,
    requestStart: Date
) {
    markProviderStreamOwnership(&card)
    card.stageBCompleted = true
    card.stageBStatus = "completed"
    let visibleMS = elapsedMS(since: requestStart)
    card.fullCardVisibleMS = card.fullCardVisibleMS ?? visibleMS
    card.latencyFullCardMS = card.latencyFullCardMS ?? card.fullCardVisibleMS
    card.latencyMS = card.latencyMS ?? visibleMS
    if let reason = plan.fallbackReason, !reason.isEmpty {
        card.caution = card.caution ?? "Provider first answer kept; full answer expansion was not used. \(reason)"
    }
}

// internal for AppState extension access only
@discardableResult
func finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    triggerPath: GenerationTriggerPath
) -> Bool {
    guard !pendingAcceptedQuestions.isEmpty,
          visibleAnswerExists,
          var current = currentSuggestion,
          isActiveGeneration(generationID, questionID: question.id)
    else {
        return false
    }
    guard visibleCardMatchesGeneration(
        card: current,
        generationID: generationID,
        detectedQuestionID: question.id,
        promptPrimaryQuestion: question.questionText
    ) else {
        recordStaleGenerationDiscard()
        return false
    }

    current.stageBCompleted = false
    current.stageBStatus = "queued_next_question"
    current.caution = current.caution ?? "First answer saved so the next interviewer question can be answered."
    currentSuggestion = current
    cancelActiveStageBTask(generationID: generationID)
    return finishGenerationWithVisibleCard(
        current,
        generationID: generationID,
        question: question,
        session: session,
        requestStart: requestStart,
        retrievedChunks: currentSuggestionRetrievedChunks,
        triggerPath: triggerPath,
        timedOut: false
    )
}

@discardableResult
private func applyTerminalStageBPlanIfNeeded(
    _ plan: StageBApplicationPlan,
    cardID: String,
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    retrievedChunks: [RetrievedChunk],
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType?,
    speaker: SpeakerRole?
) -> Bool {
    let requestIDBeforeTerminalApplication = generationCoordinator.activeRequest?.id
    switch plan.action {
    case .applyFullCard:
        return false
    case .discardStaleResult:
        recordStaleGenerationDiscard()
        return true
    case .keepVisibleFirstAnswer, .markProviderFailed:
        guard var current = currentSuggestion else {
            return false
        }
        guard visibleCardMatchesGeneration(
            card: current,
            generationID: generationID,
            detectedQuestionID: question.id,
            promptPrimaryQuestion: question.questionText
        ) else {
            recordStaleGenerationDiscard()
            return true
        }
        let terminal = stageBStatus(for: plan)
        current.stageBCompleted = false
        current.stageBStatus = terminal.status
        current.caution = plan.fallbackReason ?? current.caution ?? "The first answer is visible. Full answer expansion did not add a safer card."
        return finishGenerationWithVisibleCard(
            current,
            generationID: generationID,
            question: question,
            session: session,
            requestStart: requestStart,
            retrievedChunks: retrievedChunks,
            triggerPath: triggerPath,
            timedOut: terminal.timedOut
        )
    case .useSemanticFallback:
        if var current = currentSuggestion,
           visibleCardMatchesGeneration(
                card: current,
                generationID: generationID,
                detectedQuestionID: question.id,
                promptPrimaryQuestion: question.questionText
           ),
           !current.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(current.sayFirst) == nil,
           QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(current).accepted {
            let terminal = stageBStatus(for: plan)
            if providerFirstAnswerCanCompleteStageB(current, plan: plan) {
                completeProviderFirstAnswerAfterStageBRejection(
                    &current,
                    plan: plan,
                    requestStart: requestStart
                )
            } else {
                current.stageBCompleted = false
                current.stageBStatus = terminal.status
                current.caution = plan.fallbackReason ?? current.caution ?? "The first answer is visible. Full answer expansion did not add a safer card."
            }
            return finishGenerationWithVisibleCard(
                current,
                generationID: generationID,
                question: question,
                session: session,
                requestStart: requestStart,
                retrievedChunks: retrievedChunks,
                triggerPath: triggerPath,
                timedOut: terminal.timedOut
            )
        }
        var fallbackCard = makeInitialFirstAnswerFallbackCard(
            cardID: cardID,
            question: question,
            session: session,
            requestStart: requestStart
        )
        fallbackCard.stageBCompleted = false
        fallbackCard.stageBStatus = "semantic_fallback"
        fallbackCard.caution = plan.fallbackReason ?? "Full answer expansion was not aligned, so a local first answer is shown."
        fallbackCard.sayFirstSource = "local_semantic_stage_b_fallback"
        fallbackCard.finalVisibleSource = "local_semantic_stage_b_fallback"
        guard displaySuggestionIfAligned(
            fallbackCard,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker
        ) else {
            // Display can reject the proposed card while retaining a qualified
            // first answer or publishing a separately validated semantic fallback.
            // A completed plan must still produce a terminal outcome.
            guard isActiveGeneration(generationID, questionID: question.id),
                  !generationUIState.isTerminal else { return true }
            if let visible = currentSuggestion,
               visibleCardMatchesGeneration(card: visible, generationID: generationID,
                    detectedQuestionID: question.id, promptPrimaryQuestion: question.questionText),
               QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(visible.sayFirst) == nil,
               QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(visible).accepted {
                return finishGenerationWithVisibleCard(visible, generationID: generationID,
                    question: question, session: session, requestStart: requestStart,
                    retrievedChunks: retrievedChunks, triggerPath: triggerPath, timedOut: false)
            }
            guard let rejectedIdentity = plan.identity,
                  ownsCurrentGenerationPresentation(rejectedIdentity, requestID: requestIDBeforeTerminalApplication) else { return true }
            let reason = "No validated answer remained after full answer publication was rejected."
            failAction(ActionID.generateAnswer, title: "Answer rejected", message: "Transcript preserved. Retry when ready.")
            guard ownsCurrentGenerationPresentation(rejectedIdentity, requestID: requestIDBeforeTerminalApplication) else { return true }
            markGenerationFailed(generationID: generationID, reason: reason)
            guard ownsCurrentGenerationPresentation(rejectedIdentity, requestID: requestIDBeforeTerminalApplication) else { return true }
            restoreCaptureAfterGenerationIfNeeded(session: session,
                generationID: generationID, reason: "publication_rejected")
            return true
        }
        currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
        markFirstVisibleAnswer(generationID: generationID, fallback: true)
        return finishGenerationWithVisibleCard(
            fallbackCard,
            generationID: generationID,
            question: question,
            session: session,
            requestStart: requestStart,
            retrievedChunks: retrievedChunks,
            triggerPath: triggerPath,
            timedOut: false
        )
    }
}

// internal for AppState extension access only
/// Applies a planned Stage B result at the UI/evidence and persistence boundary.
///
/// The coordinator owns task handles and publication identity. This method
/// retains the distinct display/write checks and capture-state restoration.
func applyStageBApplicationPlan(
    _ plan: StageBApplicationPlan,
    sections: StreamingSuggestionSections,
    cardID: String,
    generationID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date,
    stageBStreamStartedMS: Int?,
    retrievedChunks: [RetrievedChunk],
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType?,
    speaker: SpeakerRole?,
    preserveFallbackSayFirst: Bool
) async throws {
    guard plan.generationID == generationID,
          isActiveGeneration(generationID, questionID: question.id),
          plan.detectedQuestionID == nil || plan.detectedQuestionID == question.id,
          let planIdentity = plan.identity,
          planIdentity.mismatchReason(comparedTo: activeGenerationController?.identity ?? GenerationIdentity(
              question: question,
              generationID: generationID,
              promptPrimaryQuestion: question.questionText
          )) == nil
    else {
        recordStaleGenerationResultRejected(
            sessionID: session.id,
            oldGenerationID: plan.generationID,
            oldQuestionText: question.questionText,
            reason: "stage_b_identity_mismatch",
            oldAcceptedQuestionID: plan.detectedQuestionID ?? question.id,
            sourceCallback: "stage_b_application"
        )
        return
    }

    guard generationCoordinator.canPublish(planIdentity),
          !generationUIState.isTerminal else { return }
    let requestIDBeforeApplication = generationCoordinator.activeRequest?.id

    if plan.action == .discardStaleResult {
        recordStaleGenerationResultRejected(
            sessionID: session.id,
            oldGenerationID: plan.generationID,
            oldQuestionText: question.questionText,
            reason: plan.fallbackReason ?? "stage_b_result_inactive",
            oldAcceptedQuestionID: plan.detectedQuestionID ?? question.id,
            sourceCallback: "stage_b_application"
        )
        return
    }

    if applyTerminalStageBPlanIfNeeded(
        plan,
        cardID: cardID,
        generationID: generationID,
        question: question,
        session: session,
        requestStart: requestStart,
        retrievedChunks: retrievedChunks,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker
    ) {
        return
    }

    guard publishStreamingSections(
        sections,
        cardID: cardID,
        generationID: generationID,
        question: question,
        session: session,
        requestStart: requestStart,
        stageBStreamStartedMS: stageBStreamStartedMS,
        preserveExistingSayFirst: preserveFallbackSayFirst,
        markFullCardVisible: true
    ) else {
        // A rejected final expansion must terminate its owned work. Keep only
        // the previously validated first answer; never relabel a terminal
        // fallback or leave the UI and question queue waiting indefinitely.
        guard isActiveGeneration(generationID, questionID: question.id),
              !terminalGenerationIDs.contains(generationID),
              !generationUIState.isTerminal else { return }
        let rejectedPlan = StageBApplicationPlan(
            generationID: generationID,
            detectedQuestionID: question.id,
            action: .useSemanticFallback,
            fallbackReason: "Full answer expansion did not pass publication checks.",
            shouldPersist: true,
            shouldUpdateVisibleCard: true,
            safeDiagnostics: plan.safeDiagnostics,
            identity: plan.identity
        )
        _ = applyTerminalStageBPlanIfNeeded(
            rejectedPlan, cardID: cardID, generationID: generationID,
            question: question, session: session, requestStart: requestStart,
            retrievedChunks: retrievedChunks, triggerPath: triggerPath,
            source: source, speaker: speaker
        )
        guard ownsCurrentGenerationPresentation(planIdentity, requestID: requestIDBeforeApplication) else { return }
        if !generationUIState.isTerminal {
            markGenerationFailed(generationID: generationID, reason: "Answer did not pass publication checks.")
            guard ownsCurrentGenerationPresentation(planIdentity, requestID: requestIDBeforeApplication) else { return }
            restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "publication_rejected")
            guard ownsCurrentGenerationPresentation(planIdentity, requestID: requestIDBeforeApplication) else { return }
            processNextQueuedAutoQuestionIfIdle()
        }
        return
    }

    guard var finalCard = currentSuggestion else {
        throw LLMProviderError.emptyResponse(providerName: generationProviderConfiguration?.name ?? "Realtime provider")
    }
    guard visibleCardMatchesGeneration(
        card: finalCard,
        generationID: generationID,
        detectedQuestionID: question.id,
        promptPrimaryQuestion: question.questionText
    ) else {
        recordStaleGenerationDiscard()
        return
    }

    finalCard.id = cardID
    finalCard.stageATimedOut = finalCard.stageATimedOut ?? false
    finalCard.stageBCompleted = true
    finalCard.stageBStatus = "completed"
    finalCard.latencyFirstTokenMS = deepseekFirstTokenMS
    finalCard.latencyFirstVisibleMS = finalCard.latencyFirstVisibleMS ?? deepseekFirstVisibleMS
    finalCard.firstVisibleAnswerMS = finalCard.firstVisibleAnswerMS ?? finalCard.latencyFirstVisibleMS
    finalCard.deepseekFirstTokenMS = deepseekFirstTokenMS
    finalCard.deepseekFirstVisibleMS = deepseekFirstVisibleMS
    if finalCard.sayFirstSource == "deepseek_stream" {
        markProviderStreamOwnership(&finalCard)
    }
    finalCard.ragRetrievalLatencyMS = ragRetrievalLatencyMS

    if let segmentID = question.transcriptSegmentID {
        let transcriptRepository = transcriptRepository
        markSQLiteOperation("Loading transcript timing in background")
        diagnosticsState.recordStageBWorkerPhase(generationID: generationID, phase: 20)
        let timing = await Task.detached(priority: .utility) {
            guard let segment = try? transcriptRepository.segmentByID(segmentID) else {
                return (firstPartial: Optional<Int>.none, final: Optional<Int>.none, best: Optional<Int>.none)
            }
            return (
                firstPartial: segment.asrFirstPartialMS,
                final: segment.asrFinalMS,
                best: segment.asrBestSelectedMS
            )
        }.value
        guard isActiveGeneration(generationID), !Task.isCancelled else {
            recordStaleGenerationDiscard()
            return
        }
        diagnosticsState.recordStageBWorkerPhase(generationID: generationID, phase: 21)
        lastSQLiteOperation = "Loaded transcript timing"
        finalCard.questionASRFirstPartialMS = timing.firstPartial
        finalCard.questionASRFinalMS = timing.final
        finalCard.questionASRBestSelectedMS = timing.best
    }

    diagnosticsState.recordStageBWorkerPhase(generationID: generationID, phase: 22)
    let validatedCard = await validateAndRewriteIfNeeded(finalCard, generationID: generationID)
    diagnosticsState.recordStageBWorkerPhase(generationID: generationID, phase: 23)
    guard isActiveGeneration(generationID), !Task.isCancelled else {
        recordStaleGenerationDiscard()
        return
    }
    guard visibleCardMatchesGeneration(
        card: finalCard,
        generationID: generationID,
        detectedQuestionID: question.id,
        promptPrimaryQuestion: question.questionText
    ) else {
        recordStaleGenerationDiscard()
        return
    }
    guard displaySuggestionIfAligned(
        validatedCard,
        question: question,
        generationID: generationID,
        triggerPath: triggerPath,
        source: source,
        speaker: speaker
    ) else {
        if let fallback = currentSuggestion,
           visibleCardMatchesGeneration(
                card: fallback,
                generationID: generationID,
                detectedQuestionID: question.id,
                promptPrimaryQuestion: question.questionText
           ),
           QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(fallback).accepted {
            currentSuggestionRetrievedChunks = retrievedChunks
            _ = finishGenerationWithVisibleCard(
                fallback,
                generationID: generationID,
                question: question,
                session: session,
                requestStart: requestStart,
                retrievedChunks: retrievedChunks,
                triggerPath: triggerPath,
                timedOut: false
            )
        }
        return
    }

    currentSuggestionRetrievedChunks = retrievedChunks
    isExpandingSuggestionCard = false
    suggestionGenerationStarted = false
    persistSuggestionInBackground(
        validatedCard,
        chunks: retrievedChunks,
        generationID: generationID,
        requestStart: requestStart
    )
    diagnosticsState.recordStageBWorkerPhase(generationID: generationID, phase: 24)
    markFullCardVisible(generationID: generationID)
    guard generationCoordinator.isCurrent(planIdentity) else { return }
    completeAction(ActionID.generateAnswer, title: "Answer ready", message: "First answer and key points are visible.")

    // Preserve the exact post-success capture-state rules from the inline Stage B
    // branch so this refactor does not alter listening/ready transitions.
    if currentSession?.id == session.id &&
       currentCaptureRuntimeState == .generating &&
       stopReason == nil &&
       currentGenerationID == generationID &&
       anyCaptureRunning {
        liveState = .listening
        currentCaptureRuntimeState = .listening
        addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: "generationSuccess")
    } else if currentGenerationID == generationID && !anyCaptureRunning {
        liveState = .ready
        currentCaptureRuntimeState = .stopped(reason: stopReason)
    } else {
        print("[CaptureState] Bypassed restoring listening: sessionID=\(currentSession?.id ?? "nil"), state=\(currentCaptureRuntimeState), stopReason=\(String(describing: stopReason)), generationID=\(String(describing: currentGenerationID)), anyCaptureRunning=\(anyCaptureRunning)")
    }

    refreshLatencyAverages()

    print("[StreamingASR] Stage B Full SuggestionCard completed and merged successfully!")
    processNextQueuedAutoQuestionIfIdle()
}

// internal for AppState extension access only
@discardableResult
func persistSuggestionInBackground(
    _ card: SuggestionCard,
    chunks: [RetrievedChunk],
    generationID: String,
    requestStart: Date,
    beforeCompletionPublication: (@Sendable () async -> Void)? = nil
) -> Task<Void, Never>? {
    guard !isShuttingDown else { return nil }
    guard let owner = activeGenerationController, owner.generationID == generationID,
          persistenceConsent.isCurrent(ticket: owner.persistenceTicket) else {
        lastSQLiteOperation = "Skipped suggestion save: persistence consent revoked"
        return nil
    }
    var card = card
    // Use the already validated publication's frozen decision. Do not resolve
    // again in detached persistence or substitute another question's decision.
    if let visible = currentSuggestion, visible.id == card.id,
       visible.sessionID == card.sessionID, visible.questionID == card.questionID,
       visible.generationID == generationID {
        card.questionDecision = visible.questionDecision
    }
    let expectedPrompt = card.promptPrimaryQuestion ?? card.promptQuestionText ?? card.questionText ?? activeGenerationController?.questionTextSnapshot ?? ""
    guard visibleCardMatchesGeneration(
        card: card,
        generationID: generationID,
        detectedQuestionID: card.detectedQuestionID,
        promptPrimaryQuestion: expectedPrompt
    ) else {
        recordTranscriptRuntimeEvent(.persistenceRejected(
            sessionID: card.sessionID,
            questionID: card.detectedQuestionID ?? card.questionID,
            generationID: generationID,
            question: card.questionText ?? expectedPrompt,
            reason: "persistence_rejected_stale_generation",
            timestamp: Date()
        ))
        recordStaleGenerationResultRejected(
            sessionID: card.sessionID,
            oldGenerationID: generationID,
            oldQuestionText: card.questionText ?? expectedPrompt,
            reason: "persistence_identity_mismatch",
            oldAcceptedQuestionID: card.detectedQuestionID,
            sourceCallback: "persistence"
        )
        return nil
    }
    let persistenceGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(
        card
    )
    guard persistenceGuard.accepted else {
        if let fallback = localTimeoutFallbackForRejectedPersistence(
            card: card,
            result: persistenceGuard,
            generationID: generationID,
            requestStart: requestStart
        ) {
            currentSuggestion = fallback
            recordVisibleSuggestionInHistory(fallback)
            return persistSuggestionInBackground(
                fallback,
                chunks: chunks,
                generationID: generationID,
                requestStart: requestStart,
                beforeCompletionPublication: beforeCompletionPublication
            )
        }
        recordSuggestionPersistenceRejected(persistenceGuard, generationID: generationID)
        return nil
    }
    let sanitizedCard = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
        card,
        result: persistenceGuard
    )
    guard claimSuggestionPersistence(sanitizedCard, generationID: generationID) else {
        return nil
    }
    let consent = persistenceConsent
    let consentTicket = owner.persistenceTicket
    let repository = suggestionRepository
    let simulateFailure = simulateSuggestionPersistenceFailure
    let simulatedDelay = simulatedSuggestionPersistenceDelayNanoseconds
    recordTranscriptRuntimeEvent(.persistenceStarted(
        sessionID: sanitizedCard.sessionID,
        questionID: sanitizedCard.detectedQuestionID,
        generationID: generationID,
        question: sanitizedCard.questionText ?? expectedPrompt,
        timestamp: Date()
    ))
    markSQLiteOperation("Saving suggestion card in background")
    if simulateFailure {
        recordTranscriptRuntimeEvent(.persistenceRejected(
            sessionID: sanitizedCard.sessionID,
            questionID: sanitizedCard.detectedQuestionID,
            generationID: generationID,
            question: sanitizedCard.questionText ?? expectedPrompt,
            reason: "persistence_failed_sqlite_error",
            timestamp: Date()
        ))
        guard currentGenerationID == generationID else { return nil }
        let message = "Suggestion is visible, but saving it failed: Simulated suggestion persistence failure."
        errorMessage = message
        currentGenerationTelemetry.dbError = message
        lastSQLiteOperation = "Suggestion save failed: simulated"
        warnAction(ActionID.generateAnswer, title: "Answer visible", message: "Saving failed, but the answer remains visible.")
        return nil
    }
    let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self, sanitizedCard] in
        var persistedCard = sanitizedCard
        do {
            if simulatedDelay > 0 {
                try await Task.sleep(nanoseconds: simulatedDelay)
            }
            guard let self else { return }
            guard !Task.isCancelled else {
                await self.rejectCancelledPersistenceIfNeeded(
                    card: persistedCard,
                    generationID: generationID,
                    sourceCallback: "detached_persistence_task"
                )
                return
            }
            guard !(await self.rejectCancelledPersistenceIfNeeded(
                card: persistedCard,
                generationID: generationID,
                sourceCallback: "detached_persistence_validation"
            )) else { return }
            let detachedGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(
                persistedCard
            )
            guard detachedGuard.accepted else {
                await MainActor.run { [weak self] in
                    self?.recordSuggestionPersistenceRejected(detachedGuard, generationID: generationID)
                }
                return
            }
            persistedCard = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
                persistedCard,
                result: detachedGuard
            )
            persistedCard.dbPersistedMS = Int(Date().timeIntervalSince(requestStart) * 1000)
            guard !(await self.rejectCancelledPersistenceIfNeeded(
                card: persistedCard,
                generationID: generationID,
                sourceCallback: "sqlite_save"
            )) else { return }
            try consent.write(ticket: consentTicket) { try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks) }
            let verificationCommit = VerificationTimingEvent.card("verification.db_commit.answer",
                at: VerificationTiming.hostTicks(), card: persistedCard)
            // This optional boundary lets isolated tests order a successful
            // historical write against a new request, then join this real task.
            // The atomic consent/write scope has already ended before the await.
            if let beforeCompletionPublication { await beforeCompletionPublication() }
            let completedCard = persistedCard
            await MainActor.run { [weak self, completedCard] in
                if let self, let verificationCommit {
                    self.diagnosticsState.recordVerificationTiming(verificationCommit,
                        mode: self.settings.effectiveDiagnosticTraceMode)
                }
                self?.applyPersistedSuggestionCompletion(completedCard, generationID: generationID)
            }
        } catch {
            let message = "Suggestion is visible, but saving it failed: \(error.localizedDescription)"
            await MainActor.run { [weak self, message] in
                guard let self = self else { return }
                self.recordTranscriptRuntimeEvent(.persistenceRejected(
                    sessionID: sanitizedCard.sessionID,
                    questionID: sanitizedCard.detectedQuestionID,
                    generationID: generationID,
                    question: sanitizedCard.questionText ?? sanitizedCard.promptPrimaryQuestion ?? "",
                    reason: "persistence_failed_sqlite_error",
                    timestamp: Date()
                ))
                guard self.currentGenerationID == generationID else { return }
                self.lastSQLiteOperation = "Suggestion save failed: \(error.localizedDescription)"
                self.errorMessage = message
                self.currentGenerationTelemetry.dbError = message
                self.warnAction(ActionID.generateAnswer, title: "Answer visible", message: "Saving failed, but the answer remains visible.")
            }
        }
    }
    generationCoordinator.retainAdmittedPersistenceUntilExit(task)
    return task
}

// A successful write is a historical fact even when a newer request owns UI.
// Keep its audit admission separate from the optional refresh of current UI.
private func applyPersistedSuggestionCompletion(_ persistedCard: SuggestionCard, generationID: String) {
    let persistedID = persistedCard.id
    let persistedSessionID = persistedCard.sessionID
    let persistedDBMS = persistedCard.dbPersistedMS
    let persistedQuestionID = persistedCard.detectedQuestionID
    let persistedPrompt = persistedCard.promptPrimaryQuestion ?? persistedCard.promptQuestionText ?? persistedCard.questionText ?? ""
    if markSuggestionPersistenceSucceededOnce(cardID: persistedID, generationID: generationID) {
        recordTranscriptRuntimeEvent(.persistenceSucceeded(
            sessionID: persistedSessionID,
            questionID: persistedQuestionID,
            generationID: generationID,
            question: persistedPrompt,
            timestamp: Date()
        ))
        recordTranscriptRuntimeEvent(.queuedAnswerPersisted(
            sessionID: persistedSessionID,
            questionID: persistedQuestionID,
            generationID: generationID,
            question: persistedPrompt,
            timestamp: Date()
        ))
    }
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard(
            reason: "persisted_refresh_generation_not_current",
            countsAsDiscardedAnswer: false
        )
        return
    }
    guard currentSession?.id == persistedSessionID else {
        recordStaleGenerationDiscard(
            reason: "persisted_refresh_session_not_current",
            countsAsDiscardedAnswer: false
        )
        return
    }
    lastSQLiteOperation = "Saved suggestion card"
    streamPersistedAt = Date()
    refreshLiveSuggestionHistory(sessionID: persistedSessionID, latestQuestion: persistedPrompt)
    currentGenerationTelemetry.dbPersistedAt = Date()
    if let current = currentSuggestion,
       current.id == persistedID,
       visibleCardMatchesGeneration(
            card: current,
            generationID: generationID,
            detectedQuestionID: persistedQuestionID,
            promptPrimaryQuestion: persistedPrompt
       ) {
        currentSuggestion?.dbPersistedMS = persistedDBMS
    }
    refreshLatencyAverages()
}

private func localTimeoutFallbackForRejectedPersistence(
    card: SuggestionCard,
    result: QuestionPersistenceGuardResult,
    generationID: String,
    requestStart: Date
) -> SuggestionCard? {
    guard card.finalVisibleSource != "local_timeout_fallback" else { return nil }
    switch result.reason {
    case .some(.emptyAnswer), .some(.incompleteAnswer), .some(.partialCard),
         .some(.weakAlignment), .some(.unknownAlignment), .some(.mismatchedAlignment),
         .some(.interviewerQuestionsIncomplete), .some(.unrelatedTechnicalTradeoff):
        break
    default:
        return nil
    }

    guard let question = lastDetectedQuestion,
          question.id == (card.detectedQuestionID ?? card.questionID),
          let session = currentSession,
          session.id == card.sessionID,
          isActiveGeneration(generationID, questionID: question.id)
    else {
        return nil
    }

    func isLocalFallbackCarrier(_ candidate: SuggestionCard) -> Bool {
        let visibleSource = candidate.finalVisibleSource ?? ""
        let sayFirstSource = candidate.sayFirstSource ?? ""
        return candidate.stageBStatus == "timed_out" ||
            candidate.stageATimedOut == true ||
            candidate.isLocal ||
            visibleSource.contains("timeout") ||
            visibleSource == "local_incomplete_stream_fallback" ||
            visibleSource == "semantic_intent_fallback" ||
            visibleSource == "local_semantic_stage_b_fallback" ||
            sayFirstSource == "local_first_answer_fallback" ||
            sayFirstSource == "local_incomplete_stream_fallback" ||
            sayFirstSource == "semantic_intent_fallback" ||
            sayFirstSource == "local_semantic_stage_b_fallback" ||
            candidate.providerName == "Local First Answer Fallback" ||
            candidate.providerName == "Semantic Alignment Fallback"
    }

    func matchesCurrentQuestion(_ candidate: SuggestionCard) -> Bool {
        guard candidate.sessionID == session.id else { return false }
        if let candidateGenerationID = candidate.generationID,
           candidateGenerationID != generationID {
            return false
        }
        if let candidateQuestionID = candidate.detectedQuestionID ?? candidate.questionID,
           candidateQuestionID != question.id {
            return false
        }
        let expected = normalizedBindingText(question.questionText)
        guard !expected.isEmpty else { return false }
        for snapshot in [candidate.questionText, candidate.promptQuestionText, candidate.promptPrimaryQuestion] {
            guard let snapshot else { continue }
            let normalized = normalizedBindingText(snapshot)
            guard normalized.isEmpty || normalized == expected else {
                return false
            }
        }
        return true
    }

    let visibleFallback = currentSuggestion.flatMap { visible -> SuggestionCard? in
        guard visible.finalVisibleSource != "local_timeout_fallback",
              isLocalFallbackCarrier(visible),
              matchesCurrentQuestion(visible)
        else { return nil }
        return visible
    }
    let sourceCard: SuggestionCard
    if let visibleFallback {
        sourceCard = visibleFallback
    } else if isLocalFallbackCarrier(card) {
        sourceCard = card
    } else {
        return nil
    }

    recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
        sessionID: session.id,
        questionID: question.id,
        generationID: generationID,
        question: question.questionText,
        reason: "persistence fallback: \(result.diagnostic)",
        timestamp: Date()
    ))

    var fallback = makeInitialFirstAnswerFallbackCard(
        cardID: sourceCard.id,
        question: question,
        session: session,
        requestStart: requestStart
    )
    fallback.createdAt = sourceCard.createdAt
    fallback.questionText = question.questionText
    fallback.transcriptSegmentID = question.transcriptSegmentID
    fallback.generationID = generationID
    fallback.source = sourceCard.source ?? currentGenerationTelemetry.source
    fallback.speaker = sourceCard.speaker ?? currentGenerationTelemetry.speaker
    fallback.triggerPath = sourceCard.triggerPath ?? activeGenerationController?.triggerPath
    fallback.promptQuestionText = sourceCard.promptQuestionText ?? question.questionText
    fallback.promptPrimaryQuestion = sourceCard.promptPrimaryQuestion ?? question.questionText
    fallback.promptContainsPreviousQuestion = sourceCard.promptContainsPreviousQuestion
    fallback.previousQuestionIncluded = sourceCard.previousQuestionIncluded
    fallback.previousQuestionText = sourceCard.previousQuestionText
    fallback.contextBleedRisk = sourceCard.contextBleedRisk
    fallback.ragChunkIDs = sourceCard.ragChunkIDs
    fallback.ragChunkIntents = sourceCard.ragChunkIntents
    fallback.promptTokenEstimate = sourceCard.promptTokenEstimate
    fallback.promptContextPreview = sourceCard.promptContextPreview
    fallback.stageATimedOut = sourceCard.stageATimedOut ?? true
    fallback.stageBCompleted = false
    fallback.stageBStatus = "timed_out"
    fallback.caution = "Provider answer was incomplete after timeout, so a local first answer was saved."
    fallback.sayFirstSource = "local_timeout_fallback"
    fallback.finalVisibleSource = "local_timeout_fallback"
    fallback.latencyMS = sourceCard.latencyMS
    fallback.latencyFirstTokenMS = sourceCard.latencyFirstTokenMS
    fallback.latencyFirstVisibleMS = sourceCard.latencyFirstVisibleMS
    fallback.firstVisibleAnswerMS = sourceCard.firstVisibleAnswerMS ?? elapsedMS(since: requestStart)
    if !fallback.keyPoints.isEmpty {
        fallback.firstKeyPointVisibleMS = fallback.firstVisibleAnswerMS
        fallback.allKeyPointsVisibleMS = fallback.firstVisibleAnswerMS
    }
    if !fallback.followUpReady.isEmpty {
        fallback.followUpVisibleMS = fallback.firstVisibleAnswerMS
    }
    fallback.deepseekFirstTokenMS = sourceCard.deepseekFirstTokenMS
    fallback.deepseekFirstVisibleMS = sourceCard.deepseekFirstVisibleMS
    fallback.softFallbackUsed = true
    fallback.softFallbackLatencyMS = sourceCard.softFallbackLatencyMS
    fallback.dbPersistedMS = sourceCard.dbPersistedMS
    return fallback
}

// internal for AppState extension access only
@discardableResult
func claimSuggestionPersistence(_ card: SuggestionCard, generationID: String?) -> Bool {
    guard settings.saveTranscriptsLocally else { return false }
    if card.stageBStatus == "cancelled" {
        recordTranscriptRuntimeEvent(.cancelledGenerationPersistenceRejected(
            sessionID: card.sessionID,
            questionID: card.detectedQuestionID,
            generationID: generationID ?? card.generationID,
            question: card.questionText ?? card.promptPrimaryQuestion ?? "",
            reason: "cancelled_card_is_not_final",
            timestamp: Date()
        ))
        lastSQLiteOperation = "Suggestion save blocked: cancelled generation"
        return false
    }
    guard let generationID = generationID ?? card.generationID,
          let identity = GenerationIdentity(card: card, generationID: generationID) else {
        let question = card.questionText ?? card.promptPrimaryQuestion ?? card.promptQuestionText ?? ""
        recordTranscriptRuntimeEvent(.persistenceRejected(
            sessionID: card.sessionID,
            questionID: card.detectedQuestionID,
            generationID: generationID ?? card.generationID,
            question: question,
            reason: "persistence_rejected_missing_generation_identity",
            timestamp: Date()
        ))
        lastSQLiteOperation = "Suggestion save blocked: missing generation identity"
        return false
    }
    let logicalKey = [
        identity.sessionID,
        identity.contextSnapshotID ?? "legacy-context",
        identity.normalizedQuestionText
    ].joined(separator: "|")

    if let sameQuestionClaim = suggestionPersistenceClaims.values.first(where: { existing in
        existing.identity.acceptedQuestionID == identity.acceptedQuestionID
    }) {
        if lastRegenerateQuestionID == identity.acceptedQuestionID,
           lastRegenerateNewGenerationID == identity.generationID {
            suggestionPersistenceClaims[logicalKey] = SuggestionPersistenceClaim(
                cardID: card.id,
                identity: identity
            )
            return true
        }
        // A semantic fallback and a late provider response can use different card
        // or helper-generation IDs while still belonging to one accepted question.
        // Keep the first persistence owner without misreporting an internal rewrite
        // as a replay of a previously accepted question.
        return sameQuestionClaim.identity.generationID == identity.generationID &&
            sameQuestionClaim.cardID == card.id
    }

    if suggestionPersistenceClaims[logicalKey] != nil {
        guard intentionalRepeatQuestionIDs.contains(identity.acceptedQuestionID) else {
            let reason = "same_normalized_question_without_intentional_repeat"
            recordTranscriptRuntimeEvent(.duplicatePersistenceRejected(
                sessionID: identity.sessionID,
                questionID: identity.acceptedQuestionID,
                generationID: identity.generationID,
                question: identity.questionText,
                normalizedQuestion: identity.normalizedQuestionText,
                reason: reason,
                timestamp: Date()
            ))
            lastSQLiteOperation = "Suggestion save blocked: duplicate persistence"
            return false
        }
        suggestionPersistenceClaims["\(logicalKey)|intentional:\(identity.acceptedQuestionID)"] = SuggestionPersistenceClaim(
            cardID: card.id,
            identity: identity
        )
        return true
    }

    suggestionPersistenceClaims[logicalKey] = SuggestionPersistenceClaim(
        cardID: card.id,
        identity: identity
    )
    return true
}

// internal for AppState extension access only
func markSuggestionPersistenceSucceededOnce(cardID: String, generationID: String?) -> Bool {
    let owner = "\(cardID)|\(generationID ?? "no-generation")"
    return successfulSuggestionPersistenceOwners.insert(owner).inserted
}

// internal for AppState extension access only
func recordSuggestionPersistenceRejected(
    _ result: QuestionPersistenceGuardResult,
    generationID: String
) {
    guard currentGenerationID == generationID else { return }
    let reason = result.reason?.rawValue ?? "rejected_pre_persistence_guard"
    lastSQLiteOperation = "Suggestion save blocked: \(reason)"
    lastAlignmentError = result.diagnostic
    currentGenerationTelemetry.dbError = result.diagnostic
    recordTranscriptRuntimeEvent(.persistenceRejected(
        sessionID: currentSuggestion?.sessionID ?? currentSession?.id ?? "",
        questionID: activeQuestionID,
        generationID: generationID,
        question: result.candidate?.text ?? currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? "",
        reason: persistenceTraceReason(for: result),
        timestamp: Date()
    ))
    if result.reason == .incompleteAnswer {
        recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
            sessionID: currentSuggestion?.sessionID ?? currentSession?.id ?? "",
            questionID: activeQuestionID,
            generationID: generationID,
            question: result.candidate?.text ?? currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? "",
            reason: result.diagnostic,
            timestamp: Date()
        ))
    }
    if result.diagnostic.localizedCaseInsensitiveContains("wrong project grounding") {
        recordTranscriptRuntimeEvent(.answerRejectedWrongProjectGrounding(
            sessionID: currentSuggestion?.sessionID ?? currentSession?.id ?? "",
            questionID: activeQuestionID,
            generationID: generationID,
            question: result.candidate?.text ?? currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? "",
            reason: result.diagnostic,
            timestamp: Date()
        ))
    }
}

private func persistenceTraceReason(for result: QuestionPersistenceGuardResult) -> String {
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

public func isSpecificAnswer(_ text: String) -> Bool {
    GenerationCoordinator.isSpecificAnswer(text)
}

// internal for AppState extension access only
func cleanedFirstAnswerStreamText(_ text: String) -> String {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = cleaned.range(of: "SAY_FIRST:", options: [.caseInsensitive]) {
        cleaned = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let sectionMarkers = [
        "\nKEY_POINTS:", " KEY_POINTS:",
        "\nKEY POINTS:", " KEY POINTS:",
        "\nFOLLOW_UP:", " FOLLOW_UP:",
        "\nFOLLOW UP:", " FOLLOW UP:",
        "\nSOURCES:", " SOURCES:"
    ]
    for marker in sectionMarkers {
        if let range = cleaned.range(of: marker, options: [.caseInsensitive]) {
            cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }
    return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
}

// internal for AppState extension access only
func evaluatedLivePreviewRelevance(
    _ text: String, question: DetectedQuestion
) -> (relevant: Bool, alignment: AnswerAlignmentResult?) {
    let cleaned = cleanedFirstAnswerStreamText(text)
    guard cleaned.count >= 24 else { return (false, nil) }
    let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
        questionText: question.questionText,
        answerText: cleaned,
        decision: question.taskDescriptor?.decision
    )
    if alignment.verdict == .mismatched { return (false, alignment) }
    if alignment.verdict == .aligned || alignment.verdict == .weaklyAligned { return (true, alignment) }
    return (AnswerRelevancePolicy.intent(for: question.questionText) == .generic && isSpecificAnswer(cleaned), alignment)
}

func isAnswerRelevantEnoughForLivePreview(_ text: String, question: DetectedQuestion) -> Bool {
    let result = evaluatedLivePreviewRelevance(text, question: question)
    if let alignment = result.alignment, alignment.verdict != .unknown {
        currentAnswerQuestionIntent = alignment.questionIntent
        currentAnswerIntent = alignment.answerIntent
        currentExpectedThemesMatched = alignment.matchedThemes
        currentSuspectedMismatchReason = alignment.verdict == .mismatched ? alignment.reason : ""
    }
    return result.relevant
}
}
