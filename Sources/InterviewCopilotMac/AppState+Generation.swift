// Contains generation lifecycle helpers used by AppState.generateSuggestion.
// This extension owns active-generation guards, fallback cards, alignment
// checks, streaming UI publication, and generation diagnostics.
// It must not perform audio capture, question extraction, provider key storage,
// or RAG scoring decisions.
// Known limitation: Stage B can time out under provider latency. If the visible
// first answer is complete and aligned, preserving that fallback is acceptable;
// timeout optimization belongs in a later generation phase.

import Foundation

extension AppState {
// MARK: - Manual Entry Points

func manualAnswerNow() {
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
    guard let session = currentSession ?? (try? sessionRepository.createSession(mode: .mock)) else {
        let message = "Could not create an interview session."
        failAction(ActionID.generateAnswer, title: "Generation failed", message: message)
        showError(message)
        return
    }
    currentSession = session
    let transcript = recentTranscriptText()
    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        let message = "There is no transcript yet. Start Listening first, or use Practice / Developer Testing to inject a test question."
        failAction(ActionID.generateAnswer, title: "No transcript yet", message: message)
        showError(message)
        return
    }

    beginAction(ActionID.generateAnswer, title: "Generating first answer", message: "Transcript is preserved while DeepSeek prepares the answer.")
    activeAITask?.cancel()
    activeAITask = Task { [weak self] in
        guard let self else { return }
        await self.runManualAnswer(session: session, transcript: transcript)
    }
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
          currentGenerationID == controller.generationID,
          generationUIState.isLoadingWithoutVisibleAnswer,
          !visibleAnswerExists,
          let session = currentSession,
          let question = lastDetectedQuestion,
          question.id == controller.questionID
    else { return false }

    let elapsed = elapsedMS(since: controller.startedAt)
    softFallbackUsed = true
    softFallbackLatencyMS = elapsed
    softFallbackShownAt = Date()
    finalVisibleSource = "local_first_answer_fallback"

    var fallbackCard = makeInitialFirstAnswerFallbackCard(
        cardID: UUID().uuidString,
        question: question,
        session: session,
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

    guard displaySuggestionIfAligned(
        fallbackCard,
        question: question,
        generationID: controller.generationID,
        triggerPath: controller.triggerPath
    ) else { return false }
    currentSuggestionSetAt = Date()
    isStreamingSayFirst = false
    isExpandingSuggestionCard = true
    clearFallbackWatchdogTask(generationID: controller.generationID)
    markFirstVisibleAnswer(generationID: controller.generationID, fallback: true)
    setGenerationUIState(
        .showingFallback(
            questionID: question.id,
            generationID: controller.generationID,
            triggerPath: controller.triggerPath
        ),
        generationID: controller.generationID
    )
    infoAction(
        ActionID.generateAnswer,
        title: "First answer visible",
        message: "Kept the current answer visible while ignoring non-question system audio.",
        autoDismissAfter: 3.0
    )
    print("[SystemAudioClassifier] Immediate fallback shown for active generation after ignoring system audio: \(reason)")
    return true
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
    guard isActiveGeneration(generationID, questionID: question.id) else {
        recordStaleGenerationDiscard()
        return false
    }

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
        guard var fallbackCard = currentSuggestion else { return false }
        fallbackCard.stageATimedOut = stageATimedOut
        fallbackCard.stageBCompleted = false
        fallbackCard.stageBStatus = "expanding"
        fallbackCard.caution = caution
        currentSuggestion = fallbackCard
        currentSuggestionRetrievedChunks = retrievedChunks
        persistSuggestionInBackground(
            fallbackCard,
            chunks: retrievedChunks,
            generationID: generationID,
            requestStart: requestStart
        )
        setGenerationUIState(
            .showingFallback(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
            generationID: generationID
        )
        return true
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
        speaker: speaker
    ) else { return false }

    currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
    currentSuggestionRetrievedChunks = retrievedChunks
    isStreamingSayFirst = false
    isExpandingSuggestionCard = true
    markFirstVisibleAnswer(generationID: generationID, fallback: fallback)
    persistSuggestionInBackground(
        visibleCard,
        chunks: retrievedChunks,
        generationID: generationID,
        requestStart: requestStart
    )
    setGenerationUIState(
        fallback
            ? .showingFallback(questionID: question.id, generationID: generationID, triggerPath: triggerPath)
            : .expandingFullAnswer(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
        generationID: generationID
    )
    return true
}

private func runManualAnswer(session: InterviewSession, transcript: String) async {
    do {
        liveState = .detectingQuestion
        let detection = try await questionDetectionService.detect(
            transcriptContext: transcript,
            sessionID: session.id,
            transcriptSegmentID: transcriptSegments.last?.id,
            model: activeRealtimeProvider?.model
        )
        guard !Task.isCancelled else { return }
        self.lastQuestionDetectionProvider = detection.response.providerName
        self.lastQuestionDetectionModel = detection.response.modelName
        saveDetectedQuestionInBackground(detection.question)
        updateDiagnostics {
            $0.lastDetectedQuestionJSON = detection.question.rawJSON
            $0.lastAPILatencyMS = detection.response.latencyMS
            $0.lastProviderName = detection.response.providerName
            $0.lastProviderModel = detection.response.modelName
            $0.apiCallCount += 1
        }

        var question = detection.question
        lastDetectedQuestion = question
        if question.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            question.questionText = transcriptSegments.last?.text ?? transcript
        }
        try await generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: false)
    } catch {
        guard !Task.isCancelled else { return }
        let message = userFacing(error)
        liveState = .error(message)
        failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(message)")
        
        if self.lastFailedTaskType != .suggestionGeneration {
            self.lastFailedTaskType = .questionDetection
            self.lastFailedQuestion = nil
            self.lastFailedTranscriptContext = transcript
            self.lastFailedCVJDContext = nil
            self.lastFailedProviderConfig = activeRealtimeProvider
        }
        
        showError(message)
    }
}

func cancelStageBTask() {
    let hadActiveStageB = stageBTaskActive || stageBTask != nil
    if hadActiveStageB {
        print("[StageB] Cancelled active background Stage B suggestion task.")
    }
    cancelActiveGenerationForStop()
}

// internal for AppState extension access only
func makeInitialFirstAnswerFallbackCard(
    cardID: String,
    question: DetectedQuestion,
    session: InterviewSession,
    requestStart: Date
) -> SuggestionCard {
    let answer = initialFallbackSayFirst(for: question)
    return SuggestionCard(
        id: cardID,
        sessionID: session.id,
        questionID: question.id,
        strategy: "Local First Answer Fallback",
        sayFirst: answer.sayFirst,
        keyPoints: answer.keyPoints,
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
}

private func initialFallbackSayFirst(for question: DetectedQuestion) -> (sayFirst: String, keyPoints: [String]) {
    let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
    return (fallback.sayFirst, fallback.keyPoints)
}

// internal for AppState extension access only
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await GenerationCoordinator.withTimeout(seconds: seconds, operation: operation)
}

// MARK: - Quality Guards

/// Applies local answer cleanup synchronously and, if needed, starts a guarded
/// provider rewrite in the background.
///
/// The immediate return value preserves the current generation flow. The
/// background rewrite may update the UI only if the same generation is still
/// active, so a late cleanup for question 1 cannot overwrite question 2.
func validateAndRewriteIfNeeded(_ card: SuggestionCard, generationID: String) async -> SuggestionCard {
    var updated = card
    
    let locallyCleaned = AnswerQualityValidator.localCleanupAnswer(updated.sayFirst)
    updated.sayFirst = locallyCleaned
    
    let isValid = AnswerQualityValidator.isValid(
        sayFirst: updated.sayFirst,
        keyPoints: updated.keyPoints,
        followUpReady: updated.followUpReady,
        caution: updated.caution
    )
    
    if isValid {
        return updated
    }
    
    print("[QualityValidator] Card fields are invalid. Triggering background provider rewrite. Original say_first length: \(card.sayFirst.count)")
    
    Task { [weak self] in
        guard let self = self else { return }
        let rewritten = await self.providerRewriteAnswer(locallyCleaned)
        
        await MainActor.run {
            guard self.currentGenerationID == generationID, var current = self.currentSuggestion else {
                self.recordStaleGenerationDiscard()
                return
            }
            let expectedPrompt = card.promptPrimaryQuestion ?? card.promptQuestionText ?? card.questionText ?? self.activeGenerationController?.questionTextSnapshot ?? ""
            guard self.visibleCardMatchesGeneration(
                card: current,
                generationID: generationID,
                detectedQuestionID: card.detectedQuestionID,
                promptPrimaryQuestion: expectedPrompt
            ) else {
                self.recordStaleGenerationDiscard()
                return
            }
            current.sayFirst = rewritten
            self.currentSuggestion = current
            self.saveSuggestionSnapshotInBackground(current, chunks: self.currentSuggestionRetrievedChunks)
            print("[QualityValidator] Background provider rewrite complete. Rewritten say_first length: \(rewritten.count)")
        }
    }
    
    return updated
}

private func providerRewriteAnswer(_ sayFirst: String) async -> String {
    let systemPrompt = """
    You are a helpful assistant. You must rewrite the provided text as a natural, first-person spoken interview answer that the candidate can say directly out loud.
    
    Rules:
    - Output ONLY the rewritten spoken answer.
    - Must be in first person (use "I", "my", "I'm").
    - Absolutely no meta-instructions, no commentary, no formatting.
    - Remove all LaTeX commands, braces, backslashes.
    - Remove instruction verbs like "Highlight", "Emphasize", "Use".
    - Extremely concise (1-3 sentences).
    """
    
    let userPrompt = "Rewrite this now: \(sayFirst)"
    
    do {
        if let config = try? llmRouter.realtimeConfiguration() {
            let response = try await llmRouter.chat(
                configuration: config,
                messages: [.system(systemPrompt), .user(userPrompt)],
                responseFormat: .text,
                options: LLMRequestOptions(temperature: 0.1, timeoutInterval: 3.0)
            )
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty && AnswerQualityValidator.isValidField(result, isSayFirst: true) {
                return result
            }
        }
    } catch {
        print("[AppState] Provider answer rewrite failed: \(error.localizedDescription)")
    }
    
    return AnswerQualityValidator.localCleanupAnswer(sayFirst)
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

public var visibleAnswerExists: Bool {
    if let card = currentSuggestion, !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }
    return !streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

public var shouldShowBlockingAnswerSpinner: Bool {
    let elapsed = activeGenerationElapsedMs ?? currentGenerationTelemetry.elapsedMs ?? 0
    return generationUIState.isLoadingWithoutVisibleAnswer && !visibleAnswerExists && elapsed < 1_500
}

public var shouldShowAnswerExpansionStatus: Bool {
    visibleAnswerExists && (generationUIState.isExpandingAfterVisibleAnswer || isExpandingSuggestionCard)
}

var visibleSuggestionState: VisibleSuggestionState? {
    if let card = currentSuggestion,
       let generationID = card.generationID ?? activeGenerationController?.generationID,
       let identity = GenerationIdentity(card: card, generationID: generationID) {
        return VisibleSuggestionState(
            identity: identity,
            questionText: identity.questionText,
            answerText: card.sayFirst,
            status: card.stageBStatus ?? generationUIState.displayName,
            generationErrorText: currentGenerationErrorText,
            card: card
        )
    }
    if let controller = activeGenerationController {
        return VisibleSuggestionState(
            identity: controller.identity,
            questionText: controller.identity.questionText,
            answerText: streamedSayFirst,
            status: generationUIState.displayName,
            generationErrorText: currentGenerationErrorText,
            card: nil
        )
    }
    return nil
}

var currentGenerationErrorText: String? {
    guard let reason = generationUIState.failureReason,
          !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    switch generationUIState {
    case .failed:
        return "Generation failed: \(reason)"
    case .timeout:
        return "Generation timed out: \(reason)"
    case .cancelled:
        return "Generation cancelled: \(reason)"
    case .idle, .preparing, .generatingFirstAnswer, .showingFallback, .streamingAnswer, .expandingFullAnswer, .answerReady:
        return nil
    }
}

var visibleAssistantRenderState: VisibleAssistantRenderState {
    let snapshot = visibleSuggestionState
    let card = currentSuggestion
    let question = snapshot?.questionText ??
        visibleQuestionText(for: card) ??
        (!displayTranscriptText.isEmpty ? displayTranscriptText : lastTranscriptSnippet)
    let answer = snapshot?.answerText.isEmpty == false ? snapshot?.answerText ?? "" :
        (card?.sayFirst.isEmpty == false ? card?.sayFirst ?? "" : streamedSayFirst)
    let points = card?.keyPoints ?? []
    return VisibleAssistantRenderState(
        questionText: question,
        answerText: answer,
        keyPoints: points,
        generationStatus: snapshot?.status ?? generationUIState.displayName,
        generationErrorText: snapshot?.generationErrorText ?? currentGenerationErrorText,
        isGenerating: shouldShowBlockingAnswerSpinner || shouldShowAnswerExpansionStatus || isStreamingSayFirst || providerStreamActive,
        hasAnswerText: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        activeGenerationID: activeGenerationID,
        activeQuestionID: activeQuestionID
    )
}

/// Returns the question that owns the supplied visible card. Detection state may
/// already point at a queued question, so it is only a fallback when no answer
/// card is visible.
func visibleQuestionText(for card: SuggestionCard?) -> String? {
    if card == nil, let snapshot = visibleSuggestionState {
        return snapshot.questionText
    }
    if let cardQuestion = card?.questionText ?? card?.promptPrimaryQuestion ?? card?.promptQuestionText,
       !cardQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return cardQuestion
    }
    if !streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let activeQuestion = activeGenerationController?.questionTextSnapshot,
       !activeQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return activeQuestion
    }
    if let lastDetectedQuestion {
        return lastDetectedQuestion.questionText
    }
    return possibleQuestion?.questionText
}

    // MARK: - Active Generation Lifecycle

    private func cancelActiveGenerationForReplacement() {
    guard var controller = activeGenerationController else {
        cancelLegacyGenerationTaskReferences()
        return
    }

    previousGenerationID = controller.generationID
    persistSupersededAcceptedQuestionSnapshotIfNeeded(controller: controller)
    if generationHasCancellableWork(controller) {
        cancelledGenerationCount += 1
        cancelledPersistenceGenerationIDs.insert(controller.generationID)
        rejectCancelledGenerationPersistence(controller: controller, reason: "generation_replaced")
    }
    controller.cancelAll()
    activeGenerationController = nil
    cancelLegacyGenerationTaskReferences()
    fallbackWatchdogActive = false
    stageBTaskActive = false
    providerStreamActive = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func cancelActiveGenerationForStop() {
    if var controller = activeGenerationController {
        previousGenerationID = controller.generationID
        if generationHasCancellableWork(controller) {
            cancelledGenerationCount += 1
            cancelledPersistenceGenerationIDs.insert(controller.generationID)
            rejectCancelledGenerationPersistence(controller: controller, reason: "generation_stopped")
        }
        controller.cancelAll()
    }
    activeGenerationController = nil
    activeGenerationID = nil
    activeQuestionID = nil
    activeTriggerPath = nil
    activeGenerationStartedAt = nil
    currentGenerationID = nil
    autoSuggestionLaunchPending = false
    suggestionGenerationStarted = false
    isStreamingSayFirst = false
    isExpandingSuggestionCard = false
    cancelLegacyGenerationTaskReferences()
    fallbackWatchdogActive = false
    stageBTaskActive = false
    providerStreamActive = false
    updateActiveTaskSummary()
}

private func generationHasCancellableWork(_ controller: ActiveGenerationController) -> Bool {
    !terminalGenerationIDs.contains(controller.generationID) && !generationUIState.isTerminal
}

private func persistSupersededAcceptedQuestionSnapshotIfNeeded(
    controller: ActiveGenerationController
) {
    guard controller.triggerPath == .autoDetect,
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
    let classified = IntentRouter.transcriptClassification(for: controller.identity.questionText)
    let question = DetectedQuestion(
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
    persistAcceptedQuestionHistorySnapshot(
        for: question,
        session: session,
        stageBStatus: "superseded",
        finalVisibleSource: "local_superseded_question_snapshot",
        caution: "Generation was superseded by a newer accepted question before provider completion.",
        modelName: "local-replaced-generation-snapshot",
        promptVersion: "replaced-generation-snapshot-v1"
    )
}

private func acceptedQuestionHistoryAlreadyExists(sessionID: String, questionID: String) -> Bool {
    if suggestionPersistenceClaims.values.contains(where: { existing in
        existing.identity.sessionID == sessionID &&
            existing.identity.acceptedQuestionID == questionID
    }) {
        return true
    }
    guard let rows = try? suggestionRepository.suggestions(sessionID: sessionID) else {
        return false
    }
    return rows.contains { $0.detectedQuestionID == questionID }
}

private func cancelLegacyGenerationTaskReferences() {
    softFallbackTask?.cancel()
    softFallbackTask = nil
    fullCardWatchdogTask?.cancel()
    fullCardWatchdogTask = nil
    stageBTask?.cancel()
    stageBTask = nil
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
    speaker: SpeakerRole?
) {
    // A new accepted question replaces the entire previous generation
    // controller. This is the main invariant that prevents consecutive
    // questions from sharing watchdogs, streams, or Stage B callbacks.
    cancelActiveGenerationForReplacement()
    currentGenerationID = generationID
    activeGenerationController = ActiveGenerationController(
        identity: GenerationIdentity(
            question: question,
            generationID: generationID,
            promptPrimaryQuestion: question.questionText
        ),
        generationID: generationID,
        questionID: question.id,
        questionTextSnapshot: question.questionText,
        questionIntent: AnswerRelevancePolicy.intent(for: question.questionText),
        triggerPath: triggerPath,
        startedAt: requestStart
    )
    activeGenerationID = generationID
    activeQuestionID = question.id
    activeTriggerPath = triggerPath
    activeGenerationStartedAt = requestStart
    providerStreamActive = false
    stageBTaskActive = false
    fallbackWatchdogActive = false
    currentSuggestion = nil
    currentSuggestionRetrievedChunks = []
    streamedSayFirst = ""
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
    activeGenerationController?.generationID == generationID && currentGenerationID == generationID
}

// internal for AppState extension access only
func isActiveGeneration(_ generationID: String, questionID: String) -> Bool {
    isActiveGeneration(generationID) && activeGenerationController?.questionID == questionID && activeQuestionID == questionID
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
    activeQuestionID = question.id
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
    allowInactiveGeneration: Bool = false
) -> Bool {
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
    let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
        questionText: question.questionText,
        answerText: answerText,
        sayFirst: boundCard.sayFirst,
        stageBCompleted: boundCard.stageBCompleted ?? true
    )
    boundCard.alignmentScore = alignment.score
    boundCard.alignmentVerdict = alignment.verdict
    boundCard.answerIntent = alignment.answerIntent
    boundCard.mismatchReason = alignment.verdict == .mismatched ? alignment.reason : boundCard.mismatchReason

    if alignment.verdict != .aligned {
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
            stageBCompleted: true
        )
        fallbackCard.alignmentScore = fallbackAlignment.score
        fallbackCard.alignmentVerdict = fallbackAlignment.verdict
        fallbackCard.answerIntent = fallbackAlignment.answerIntent
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

    currentSuggestion = boundCard
    recordLifecycleTrace(
        "answer.ui.rendered",
        sessionID: boundCard.sessionID,
        questionID: boundCard.detectedQuestionID,
        generationID: boundCard.generationID,
        text: boundCard.questionText ?? question.questionText
    )
    recordVisibleSuggestionInHistory(boundCard)
    lastAlignmentError = ""
    currentAnswerQuestionIntent = alignment.questionIntent
    currentAnswerIntent = alignment.answerIntent
    currentExpectedThemesMatched = alignment.matchedThemes
    currentSuspectedMismatchReason = ""
    recordSuggestionAlignment(boundCard, question: question, result: alignment)
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
    let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
    return SuggestionCard(
        id: card.id,
        sessionID: card.sessionID,
        questionID: question.id,
        strategy: "Semantic Alignment Fallback",
        sayFirst: fallback.sayFirst,
        keyPoints: fallback.keyPoints,
        followUpReady: card.followUpReady,
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

// internal for AppState extension access only
func registerStageATask(_ task: Task<String, Error>, generationID: String) {
    guard isActiveGeneration(generationID) else {
        task.cancel()
        recordStaleGenerationDiscard()
        return
    }
    activeGenerationController?.stageATask?.cancel()
    activeGenerationController?.stageATask = task
    providerStreamActive = true
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func clearStageATask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.stageATask?.cancel()
    activeGenerationController?.stageATask = nil
    providerStreamActive = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func registerStageATimeoutTask(_ task: Task<Void, Never>, generationID: String) {
    guard isActiveGeneration(generationID) else {
        task.cancel()
        recordStaleGenerationDiscard()
        return
    }
    activeGenerationController?.stageATimeoutTask?.cancel()
    activeGenerationController?.stageATimeoutTask = task
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func clearStageATimeoutTask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.stageATimeoutTask?.cancel()
    activeGenerationController?.stageATimeoutTask = nil
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func registerStageBTask(_ task: Task<Void, Never>, generationID: String) {
    guard isActiveGeneration(generationID) else {
        task.cancel()
        recordStaleGenerationDiscard()
        return
    }
    activeGenerationController?.stageBTask?.cancel()
    activeGenerationController?.stageBTask = task
    stageBTask = task
    stageBTaskActive = true
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func clearStageBTask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.stageBTask = nil
    if stageBTask != nil {
        stageBTask = nil
    }
    stageBTaskActive = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func cancelActiveStageBTask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.stageBTask?.cancel()
    activeGenerationController?.stageBTask = nil
    stageBTask?.cancel()
    stageBTask = nil
    stageBTaskActive = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func registerFallbackWatchdogTask(_ task: Task<Void, Never>, generationID: String) {
    guard isActiveGeneration(generationID) else {
        task.cancel()
        recordStaleGenerationDiscard()
        return
    }
    activeGenerationController?.fallbackWatchdogTask?.cancel()
    activeGenerationController?.fallbackWatchdogTask = task
    softFallbackTask = task
    fallbackWatchdogActive = true
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func clearFallbackWatchdogTask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.fallbackWatchdogTask?.cancel()
    activeGenerationController?.fallbackWatchdogTask = nil
    softFallbackTask = nil
    fallbackWatchdogActive = false
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func registerFullCardWatchdogTask(_ task: Task<Void, Never>, generationID: String) {
    guard isActiveGeneration(generationID) else {
        task.cancel()
        recordStaleGenerationDiscard()
        return
    }
    activeGenerationController?.fullCardWatchdogTask?.cancel()
    activeGenerationController?.fullCardWatchdogTask = task
    fullCardWatchdogTask = task
    updateActiveTaskSummary()
}

private func clearFullCardWatchdogTask(generationID: String) {
    guard isActiveGeneration(generationID) else { return }
    activeGenerationController?.fullCardWatchdogTask?.cancel()
    activeGenerationController?.fullCardWatchdogTask = nil
    fullCardWatchdogTask = nil
    updateActiveTaskSummary()
}

private func beginGenerationUI(
    question: DetectedQuestion,
    generationID: String,
    triggerPath: GenerationTriggerPath,
    source: AudioSourceType?,
    speaker: SpeakerRole?
) {
    generationUIState = .preparing(questionID: question.id, generationID: generationID, triggerPath: triggerPath)
    lastGenerationStateChangeAt = Date()
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
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func setGenerationUIState(_ state: GenerationUIState, generationID: String? = nil) {
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
    if state.isTerminal, let terminalGenerationID = state.generationID ?? generationID {
        terminalGenerationIDs.insert(terminalGenerationID)
    }
    lastGenerationStateChangeAt = Date()
    currentGenerationTelemetry.generationState = state.displayName
    if let reason = state.failureReason {
        currentGenerationTelemetry.failureReason = reason
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
func markFirstVisibleAnswer(generationID: String, fallback: Bool) {
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    let now = Date()
    if currentGenerationTelemetry.firstVisibleAt == nil {
        currentGenerationTelemetry.firstVisibleAt = now
    }
    if fallback {
        currentGenerationTelemetry.fallbackShownAt = currentGenerationTelemetry.fallbackShownAt ?? now
    }
    if currentGenerationTelemetry.questionID == lastTranscriptQuestionGenerationTrace.detectedQuestionID ||
        generationID == lastTranscriptQuestionGenerationTrace.generationID {
        lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated = true
        lastTranscriptQuestionGenerationTrace.generationID = generationID
        lastTranscriptQuestionGenerationTrace.generationTriggered = true
        lastTranscriptQuestionGenerationTrace.currentSuggestionExists = currentSuggestion != nil
        lastTranscriptQuestionGenerationTrace.currentGenerationState = generationUIState.displayName
    }
    firstVisibleStateSetAt = firstVisibleStateSetAt ?? now
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
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    guard !terminalGenerationIDs.contains(generationID) else {
        clearStageATimeoutTask(generationID: generationID)
        clearFullCardWatchdogTask(generationID: generationID)
        clearStageBTask(generationID: generationID)
        return
    }
    currentGenerationTelemetry.fullCardAt = Date()
    providerStreamActive = false
    fallbackWatchdogActive = false
    clearStageATask(generationID: generationID)
    clearStageATimeoutTask(generationID: generationID)
    clearFullCardWatchdogTask(generationID: generationID)
    clearStageBTask(generationID: generationID)
    setGenerationUIState(.answerReady(
        questionID: currentGenerationTelemetry.questionID,
        generationID: generationID,
        triggerPath: currentGenerationTelemetry.triggerPath ?? .manualGenerate
    ), generationID: generationID)
    recordTranscriptRuntimeEvent(.generationCompleted(
        sessionID: currentSuggestion?.sessionID ?? currentSession?.id ?? "",
        questionID: currentGenerationTelemetry.questionID,
        generationID: generationID,
        question: currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? "",
        timestamp: Date()
    ))
    recordLifecycleTrace(
        "answer.stream.completed",
        sessionID: currentSuggestion?.sessionID ?? currentSession?.id,
        questionID: currentGenerationTelemetry.questionID,
        generationID: generationID,
        text: currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? ""
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
    if let generationID, currentGenerationID != generationID {
        recordStaleGenerationDiscard()
        return
    }
    isStreamingSayFirst = false
    isExpandingSuggestionCard = false
    suggestionGenerationStarted = false
    actionLoadingStates[ActionID.generateAnswer] = false
    actionLoadingStates[ActionID.manualGenerate] = false
    currentGenerationTelemetry.failureReason = reason
    currentGenerationTelemetry.providerError = providerError ?? currentGenerationTelemetry.providerError
    currentGenerationTelemetry.jsonParseError = jsonParseError ?? currentGenerationTelemetry.jsonParseError
    let questionID = currentGenerationTelemetry.questionID
    let triggerPath = currentGenerationTelemetry.triggerPath
    if timeout {
        generationUIState = .timeout(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    } else if cancelled {
        generationUIState = .cancelled(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    } else {
        generationUIState = .failed(questionID: questionID, generationID: generationID, triggerPath: triggerPath, reason: reason)
    }
    recordLifecycleTrace(
        "answer.request.failed",
        questionID: questionID,
        generationID: generationID,
        text: activeGenerationController?.questionTextSnapshot ?? currentSuggestion?.questionText ?? "",
        reason: reason,
        cancelled: cancelled
    )
    if let generationID {
        terminalGenerationIDs.insert(generationID)
    }
    lastGenerationStateChangeAt = Date()
    currentGenerationTelemetry.generationState = generationUIState.displayName
    if let generationID {
        clearFallbackWatchdogTask(generationID: generationID)
        clearStageATimeoutTask(generationID: generationID)
        clearFullCardWatchdogTask(generationID: generationID)
        clearStageATask(generationID: generationID)
        clearStageBTask(generationID: generationID)
    }
    updateActiveTaskSummary()
    if timeout {
        recordTranscriptRuntimeEvent(.generationTimedOut(
            sessionID: currentSuggestion?.sessionID ?? currentSession?.id ?? "",
            questionID: questionID,
            generationID: generationID,
            question: currentSuggestion?.questionText ?? activeGenerationController?.questionTextSnapshot ?? "",
            timestamp: Date()
        ))
    }
    processNextQueuedAutoQuestionIfIdle()
}

// internal for AppState extension access only
func recordStaleGenerationDiscard() {
    staleCallbackDiscardCount += 1
    staleAnswerDiscardCount += 1
    currentGenerationTelemetry.staleDiscardCount = staleCallbackDiscardCount
    updateActiveTaskSummary()
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
    guard !card.isPartial,
          !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }

    var historyCard = card
    if historyCard.detectedQuestionID == nil {
        historyCard.detectedQuestionID = historyCard.questionID
    }
    let question = historyCard.questionText ?? historyCard.promptPrimaryQuestion ?? historyCard.promptQuestionText ?? ""
    let alreadyExists = liveSuggestionHistory.contains { $0.id == historyCard.id }
    if let index = liveSuggestionHistory.firstIndex(where: { $0.id == historyCard.id }) {
        liveSuggestionHistory[index] = historyCard
    } else {
        liveSuggestionHistory.append(historyCard)
    }
    liveSuggestionHistory.sort { $0.createdAt < $1.createdAt }
    if liveSuggestionHistory.count > 20 {
        liveSuggestionHistory.removeFirst(liveSuggestionHistory.count - 20)
    }
    if selectedSessionID == historyCard.sessionID {
        selectedSessionSuggestions = liveSuggestionHistory
    }
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
        liveSuggestionHistory = rows
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

private func restoreCaptureAfterGenerationIfNeeded(
    session: InterviewSession,
    generationID: String,
    reason: String
) {
    if currentSession?.id == session.id &&
        currentCaptureRuntimeState == .generating &&
        stopReason == nil &&
        currentGenerationID == generationID &&
        anyCaptureRunning {
        liveState = .listening
        currentCaptureRuntimeState = .listening
        addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: reason)
    } else if currentGenerationID == generationID &&
                liveState == .generatingSuggestion &&
                !anyCaptureRunning {
        liveState = .stopped
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
    triggerPath: GenerationTriggerPath
) {
    let timeoutNanoseconds = generationFullCardWatchdogNanoseconds
    let task = Task.detached(priority: .userInitiated) { [weak self] in
        do {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
            return
        }
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard self.currentGenerationID == generationID else {
                self.recordStaleGenerationDiscard()
                return
            }

            let elapsed = self.elapsedMS(since: requestStart)
            if var current = self.currentSuggestion, !current.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard self.visibleCardMatchesGeneration(
                    card: current,
                    generationID: generationID,
                    detectedQuestionID: question.id,
                    promptPrimaryQuestion: question.questionText
                ) else {
	                    self.recordStaleGenerationDiscard()
	                    return
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
                self.warnAction(ActionID.generateAnswer, title: "First answer visible", message: "Full answer is delayed. You can retry, but the visible answer remains available.")
                return
            }

            let streamed = self.streamedSayFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            if !streamed.isEmpty {
                var streamCard = self.makeInitialFirstAnswerFallbackCard(
                    cardID: cardID,
                    question: question,
                    session: session,
                    requestStart: requestStart
                )
                streamCard.strategy = "DeepSeek First Answer"
                streamCard.sayFirst = streamed
                streamCard.caution = "DeepSeek first-answer stream did not finish; the visible answer was saved."
                streamCard.modelName = self.activeRealtimeProvider?.model ?? streamCard.modelName
                streamCard.providerKind = self.activeRealtimeProvider?.kind
                streamCard.providerName = self.activeRealtimeProvider?.name ?? "DeepSeek"
                streamCard.providerBaseURL = self.activeRealtimeProvider?.baseURL ?? "https://api.deepseek.com"
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
                self.currentGenerationTelemetry.failureReason = "Full answer timed out after \(elapsed) ms."
                self.warnAction(ActionID.generateAnswer, title: "First answer visible", message: "Full answer is delayed. You can retry, but the visible answer remains available.")
                return
            }

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
            ) else { return }
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
                reason: "No visible answer within 8 seconds.",
                timeout: true
            )
            self.cancelActiveStageBTask(generationID: generationID)
            self.restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "generationFullCardTimeout")
            self.warnAction(ActionID.generateAnswer, title: "Local answer shown", message: "DeepSeek timed out. The fallback answer is visible; retry is available.")
        }
    }
    registerFullCardWatchdogTask(task, generationID: generationID)
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
        modelName: activeRealtimeProvider?.model ?? "deepseek-v4-flash",
        promptVersion: "section-stream-v1",
        providerKind: activeRealtimeProvider?.kind,
        providerName: activeRealtimeProvider?.name ?? "DeepSeek",
        providerBaseURL: activeRealtimeProvider?.baseURL ?? "https://api.deepseek.com",
        latencyMS: nowMS,
        isLocal: false,
        rawJSON: nil,
        createdAt: Date()
    )

    if !sections.strategy.isEmpty {
        card.strategy = sections.strategy
    }

    if !sections.sayFirst.isEmpty {
        let source = card.sayFirstSource ?? ""
        let isFallback = source.contains("fallback")
        if card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isFallback && !preserveExistingSayFirst) {
            card.sayFirst = sections.sayFirst
            card.sayFirstSource = "deepseek_section_stream"
            card.finalVisibleSource = "deepseek_section_stream"
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
    if sections.hasVisibleContent {
        card.stageBFirstSectionMS = card.stageBFirstSectionMS ?? nowMS
    }
    if markFullCardVisible {
        card.fullCardVisibleMS = nowMS
        card.latencyFullCardMS = nowMS
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        card.latencyMS = nowMS
    }
    card.softFallbackUsed = softFallbackUsed
    card.softFallbackLatencyMS = softFallbackLatencyMS
    card.deepseekFirstTokenMS = deepseekFirstTokenMS
    card.deepseekFirstVisibleMS = deepseekFirstVisibleMS
    card.ragRetrievalLatencyMS = ragRetrievalLatencyMS
    return card
}

// internal for AppState extension access only
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
) {
    guard currentGenerationID == generationID else {
        recordStaleGenerationDiscard()
        return
    }
    guard !terminalGenerationIDs.contains(generationID),
          !generationUIState.isTerminal else {
        return
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
    ) else { return }
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
    if markFullCardVisible {
        self.markFullCardVisible(generationID: generationID)
    }
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
    guard isActiveGeneration(generationID, questionID: question.id) else {
        recordStaleGenerationDiscard()
        return false
    }
    guard visibleCardMatchesGeneration(
        card: card,
        generationID: generationID,
        detectedQuestionID: question.id,
        promptPrimaryQuestion: question.questionText
    ) else {
        recordStaleGenerationDiscard()
        return false
    }

    var finalCard = card
    if timedOut,
       let incompleteReason = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(card.sayFirst) {
        recordTranscriptRuntimeEvent(.partialAnswerRejectedIncomplete(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            reason: "timed-out visible card: \(incompleteReason)",
            timestamp: Date()
        ))
        var fallback = makeInitialFirstAnswerFallbackCard(
            cardID: card.id,
            question: question,
            session: session,
            requestStart: requestStart
        )
        fallback.questionText = question.questionText
        fallback.transcriptSegmentID = question.transcriptSegmentID
        fallback.generationID = generationID
        fallback.source = card.source ?? currentGenerationTelemetry.source
        fallback.speaker = card.speaker ?? currentGenerationTelemetry.speaker
        fallback.triggerPath = card.triggerPath ?? triggerPath
        fallback.promptQuestionText = card.promptQuestionText ?? question.questionText
        fallback.promptPrimaryQuestion = card.promptPrimaryQuestion ?? question.questionText
        fallback.promptContainsPreviousQuestion = card.promptContainsPreviousQuestion
        fallback.previousQuestionIncluded = card.previousQuestionIncluded
        fallback.previousQuestionText = card.previousQuestionText
        fallback.contextBleedRisk = card.contextBleedRisk
        fallback.ragChunkIDs = card.ragChunkIDs
        fallback.ragChunkIntents = card.ragChunkIntents
        fallback.promptTokenEstimate = card.promptTokenEstimate
        fallback.promptContextPreview = card.promptContextPreview
        fallback.stageATimedOut = card.stageATimedOut ?? false
        fallback.stageBCompleted = false
        fallback.stageBStatus = "timed_out"
        fallback.caution = "Provider answer was incomplete after timeout, so a local first answer was saved."
        fallback.sayFirstSource = "local_timeout_fallback"
        fallback.finalVisibleSource = "local_timeout_fallback"
        fallback.latencyFirstTokenMS = card.latencyFirstTokenMS
        fallback.latencyFirstVisibleMS = card.latencyFirstVisibleMS
        fallback.firstVisibleAnswerMS = card.firstVisibleAnswerMS ?? elapsedMS(since: requestStart)
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
    fallbackWatchdogActive = false
    clearStageATimeoutTask(generationID: generationID)
    clearFullCardWatchdogTask(generationID: generationID)
    clearStageBTask(generationID: generationID)

    persistSuggestionInBackground(
        finalCard,
        chunks: retrievedChunks,
        generationID: generationID,
        requestStart: requestStart
    )
    setGenerationUIState(
        .answerReady(questionID: question.id, generationID: generationID, triggerPath: triggerPath),
        generationID: generationID
    )
    currentGenerationTelemetry.fullCardAt = currentGenerationTelemetry.fullCardAt ?? Date()
    completeAction(ActionID.generateAnswer, title: "Answer ready", message: "First answer is visible.")
    restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: timedOut ? "generationTimedOutWithVisibleAnswer" : "generationVisibleAnswerReady")

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
        ) else { return true }
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
/// Applies a previously planned Stage B result to AppState-owned UI, task, and
/// persistence state.
///
/// `GenerationCoordinator` decides only what should happen; this method remains
/// the side-effect boundary for visible cards, alignment guards, persistence,
/// and capture-state restoration.
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

    publishStreamingSections(
        sections,
        cardID: cardID,
        generationID: generationID,
        question: question,
        session: session,
        requestStart: requestStart,
        stageBStreamStartedMS: stageBStreamStartedMS,
        preserveExistingSayFirst: preserveFallbackSayFirst,
        markFullCardVisible: true
    )

    guard var finalCard = currentSuggestion else {
        throw LLMProviderError.emptyResponse(providerName: activeRealtimeProvider?.name ?? "Realtime provider")
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
    finalCard.softFallbackUsed = softFallbackUsed
    finalCard.softFallbackLatencyMS = softFallbackLatencyMS
    finalCard.deepseekFirstTokenMS = deepseekFirstTokenMS
    finalCard.deepseekFirstVisibleMS = deepseekFirstVisibleMS
    finalCard.finalVisibleSource = finalVisibleSource ?? finalCard.finalVisibleSource ?? (softFallbackUsed ? "rag_template_soft_fallback" : "deepseek_section_stream")
    finalCard.ragRetrievalLatencyMS = ragRetrievalLatencyMS

    if let segmentID = question.transcriptSegmentID {
        let transcriptRepository = transcriptRepository
        markSQLiteOperation("Loading transcript timing in background")
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
        lastSQLiteOperation = "Loaded transcript timing"
        finalCard.questionASRFirstPartialMS = timing.firstPartial
        finalCard.questionASRFinalMS = timing.final
        finalCard.questionASRBestSelectedMS = timing.best
    }

    let validatedCard = await validateAndRewriteIfNeeded(finalCard, generationID: generationID)
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
    markFullCardVisible(generationID: generationID)
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
func persistSuggestionInBackground(
    _ card: SuggestionCard,
    chunks: [RetrievedChunk],
    generationID: String,
    requestStart: Date
) {
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
        return
    }
    let persistenceGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card)
    guard persistenceGuard.accepted else {
        if let fallback = localTimeoutFallbackForRejectedPersistence(
            card: card,
            result: persistenceGuard,
            generationID: generationID,
            requestStart: requestStart
        ) {
            currentSuggestion = fallback
            recordVisibleSuggestionInHistory(fallback)
            persistSuggestionInBackground(
                fallback,
                chunks: chunks,
                generationID: generationID,
                requestStart: requestStart
            )
            return
        }
        recordSuggestionPersistenceRejected(persistenceGuard, generationID: generationID)
        return
    }
    let sanitizedCard = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
        card,
        result: persistenceGuard
    )
    guard claimSuggestionPersistence(sanitizedCard, generationID: generationID) else {
        return
    }
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
        guard currentGenerationID == generationID else { return }
        let message = "Suggestion is visible, but saving it failed: Simulated suggestion persistence failure."
        errorMessage = message
        currentGenerationTelemetry.dbError = message
        lastSQLiteOperation = "Suggestion save failed: simulated"
        warnAction(ActionID.generateAnswer, title: "Answer visible", message: "Saving failed, but the answer remains visible.")
        return
    }
    Task.detached(priority: .utility) { [weak self, sanitizedCard] in
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
            let detachedGuard = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(persistedCard)
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
            try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks)
            let persistedID = persistedCard.id
            let persistedSessionID = persistedCard.sessionID
            let persistedDBMS = persistedCard.dbPersistedMS
            let persistedQuestionID = persistedCard.detectedQuestionID
            let persistedPrompt = persistedCard.promptPrimaryQuestion ?? persistedCard.promptQuestionText ?? persistedCard.questionText ?? ""
            await MainActor.run { [weak self, persistedID, persistedSessionID, persistedDBMS, persistedQuestionID, persistedPrompt] in
                guard let self = self else { return }
                self.lastSQLiteOperation = "Saved suggestion card"
                self.streamPersistedAt = Date()
                self.refreshLiveSuggestionHistory(sessionID: persistedSessionID, latestQuestion: persistedPrompt)
                if self.markSuggestionPersistenceSucceededOnce(cardID: persistedID, generationID: generationID) {
                    self.recordTranscriptRuntimeEvent(.persistenceSucceeded(
                        sessionID: persistedSessionID,
                        questionID: persistedQuestionID,
                        generationID: generationID,
                        question: persistedPrompt,
                        timestamp: Date()
                    ))
                    self.recordTranscriptRuntimeEvent(.queuedAnswerPersisted(
                        sessionID: persistedSessionID,
                        questionID: persistedQuestionID,
                        generationID: generationID,
                        question: persistedPrompt,
                        timestamp: Date()
                    ))
                }
                guard self.currentGenerationID == generationID else {
                    self.recordStaleGenerationDiscard()
                    return
                }
                self.currentGenerationTelemetry.dbPersistedAt = Date()
                if let current = self.currentSuggestion,
                   current.id == persistedID,
                   self.visibleCardMatchesGeneration(
                        card: current,
                        generationID: generationID,
                        detectedQuestionID: persistedQuestionID,
                        promptPrimaryQuestion: persistedPrompt
                   ) {
                    self.currentSuggestion?.dbPersistedMS = persistedDBMS
                }
                self.refreshLatencyAverages()
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
        identity.normalizedQuestionText
    ].joined(separator: "|")

    let sameOwnerClaim = suggestionPersistenceClaims.values.contains { existing in
        existing.cardID == card.id &&
            existing.identity.acceptedQuestionID == identity.acceptedQuestionID &&
            existing.identity.generationID == identity.generationID
    }
    if sameOwnerClaim {
        return true
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
func isAnswerRelevantEnoughForLivePreview(_ text: String, question: DetectedQuestion) -> Bool {
    let cleaned = cleanedFirstAnswerStreamText(text)
    guard cleaned.count >= 24 else { return false }
    let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
        questionText: question.questionText,
        answerText: cleaned
    )
    if alignment.verdict == .mismatched {
        currentAnswerQuestionIntent = alignment.questionIntent
        currentAnswerIntent = alignment.answerIntent
        currentExpectedThemesMatched = alignment.matchedThemes
        currentSuspectedMismatchReason = alignment.reason
        return false
    }
    if alignment.verdict == .aligned || alignment.verdict == .weaklyAligned {
        currentAnswerQuestionIntent = alignment.questionIntent
        currentAnswerIntent = alignment.answerIntent
        currentExpectedThemesMatched = alignment.matchedThemes
        currentSuspectedMismatchReason = ""
        return true
    }
    return AnswerRelevancePolicy.intent(for: question.questionText) == .generic && isSpecificAnswer(cleaned)
}
}
