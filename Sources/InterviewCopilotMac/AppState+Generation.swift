import Foundation

extension AppState {
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
    if var current = self.currentSuggestion, hadActiveStageB {
        current.stageBCompleted = false
        current.stageBStatus = "cancelled"
        current.caution = "Full answer cancelled by user action."
        self.currentSuggestion = current
        saveSuggestionSnapshotInBackground(current, chunks: self.currentSuggestionRetrievedChunks)
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
    
    print("[QualityValidator] Card fields are invalid. Triggering background provider rewrite. Original say_first: \(card.sayFirst)")
    
    Task { [weak self] in
        guard let self = self else { return }
        let rewritten = await self.providerRewriteAnswer(locallyCleaned)
        
        await MainActor.run {
            if self.currentGenerationID == generationID, var current = self.currentSuggestion {
                current.sayFirst = rewritten
                self.currentSuggestion = current
                self.saveSuggestionSnapshotInBackground(current, chunks: self.currentSuggestionRetrievedChunks)
                print("[QualityValidator] Background provider rewrite complete! Rewritten say_first: \(rewritten)")
            }
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

private func cancelActiveGenerationForReplacement() {
    guard var controller = activeGenerationController else {
        cancelLegacyGenerationTaskReferences()
        return
    }

    previousGenerationID = controller.generationID
    cancelledGenerationCount += 1
    persistVisibleSuggestionBeforeReplacement(controller: controller)
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
        cancelledGenerationCount += 1
        persistVisibleSuggestionBeforeReplacement(controller: controller)
        controller.cancelAll()
    }
    activeGenerationController = nil
    activeGenerationID = nil
    activeQuestionID = nil
    activeTriggerPath = nil
    activeGenerationStartedAt = nil
    currentGenerationID = nil
    cancelLegacyGenerationTaskReferences()
    fallbackWatchdogActive = false
    stageBTaskActive = false
    providerStreamActive = false
    updateActiveTaskSummary()
}

private func cancelLegacyGenerationTaskReferences() {
    softFallbackTask?.cancel()
    softFallbackTask = nil
    fullCardWatchdogTask?.cancel()
    fullCardWatchdogTask = nil
    stageBTask?.cancel()
    stageBTask = nil
}

private func persistVisibleSuggestionBeforeReplacement(controller: ActiveGenerationController) {
    guard let current = currentSuggestion,
          current.questionID == controller.questionID,
          !current.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let chunks = currentSuggestionRetrievedChunks
    saveSuggestionSnapshotInBackground(current, chunks: chunks)
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
    cancelActiveGenerationForReplacement()
    currentGenerationID = generationID
    activeGenerationController = ActiveGenerationController(
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
        triggerPath: activeTriggerPath ?? .manualGenerate,
        allowInactiveGeneration: true
    )
}

func setActiveQuestionForTesting(_ question: DetectedQuestion) {
    activeQuestionID = question.id
    lastDetectedQuestion = question
}

@discardableResult
// internal for AppState extension access only
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
            recordAlignmentMismatch(
                "Stale answer discarded: generation/question no longer active for question \(question.id).",
                stale: true
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

    if let snapshot = boundCard.questionText,
       !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       normalizedBindingText(snapshot) != normalizedBindingText(question.questionText) {
        recordAlignmentMismatch("Suggestion question text snapshot does not match detected question text.")
        return false
    }

    boundCard.questionText = question.questionText
    boundCard.transcriptSegmentID = boundCard.transcriptSegmentID ?? question.transcriptSegmentID
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

    if alignment.verdict == .mismatched {
        currentAnswerQuestionIntent = alignment.questionIntent
        currentAnswerIntent = alignment.answerIntent
        currentExpectedThemesMatched = alignment.matchedThemes
        currentSuspectedMismatchReason = alignment.reason
        recordSuggestionAlignment(boundCard, question: question, result: alignment)
        recordAlignmentMismatch("Generated answer did not align with question; using fallback. \(alignment.reason)")
        if let existing = currentSuggestion,
           existing.detectedQuestionID == question.id,
           !existing.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            stageBCompleted: fallbackCard.stageBCompleted ?? true
        )
        fallbackCard.alignmentScore = fallbackAlignment.score
        fallbackCard.alignmentVerdict = fallbackAlignment.verdict
        fallbackCard.answerIntent = fallbackAlignment.answerIntent
        currentSuggestion = fallbackCard
        recordSuggestionAlignment(fallbackCard, question: question, result: fallbackAlignment)
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
    lastAlignmentError = ""
    currentAnswerQuestionIntent = alignment.questionIntent
    currentAnswerIntent = alignment.answerIntent
    currentExpectedThemesMatched = alignment.matchedThemes
    currentSuspectedMismatchReason = ""
    recordSuggestionAlignment(boundCard, question: question, result: alignment)
    return true
}

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
        stageBCompleted: false,
        stageBStatus: "semantic_mismatch",
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

private func cancelActiveStageBTask(generationID: String) {
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
    generationUIState = state
    lastGenerationStateChangeAt = Date()
    currentGenerationTelemetry.generationState = state.displayName
    if let reason = state.failureReason {
        currentGenerationTelemetry.failureReason = reason
    }
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func applyPromptSnapshotDiagnostics(_ promptSnapshot: AnswerPromptSnapshot) {
    currentAnswerQuestionIntent = promptSnapshot.questionIntent
    currentPromptQuestionText = promptSnapshot.questionTextSnapshot
    currentPromptPrimaryQuestion = promptSnapshot.promptPrimaryQuestion
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
    currentGenerationTelemetry.fullCardAt = Date()
    clearFullCardWatchdogTask(generationID: generationID)
    clearStageBTask(generationID: generationID)
    setGenerationUIState(.answerReady(
        questionID: currentGenerationTelemetry.questionID,
        generationID: generationID,
        triggerPath: currentGenerationTelemetry.triggerPath ?? .manualGenerate
    ), generationID: generationID)
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
    lastGenerationStateChangeAt = Date()
    currentGenerationTelemetry.generationState = generationUIState.displayName
    if let generationID {
        clearFallbackWatchdogTask(generationID: generationID)
        clearFullCardWatchdogTask(generationID: generationID)
        clearStageATask(generationID: generationID)
        clearStageBTask(generationID: generationID)
    }
    updateActiveTaskSummary()
}

// internal for AppState extension access only
func recordStaleGenerationDiscard() {
    staleCallbackDiscardCount += 1
    staleAnswerDiscardCount += 1
    currentGenerationTelemetry.staleDiscardCount = staleCallbackDiscardCount
    updateActiveTaskSummary()
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
    } else if liveState == .generatingSuggestion && !anyCaptureRunning {
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
                current.stageBCompleted = false
                current.stageBStatus = "timed_out"
                current.caution = current.caution ?? "Full answer is delayed. The first answer is still safe to use."
                self.currentSuggestion = current
                self.isStreamingSayFirst = false
                self.isExpandingSuggestionCard = false
                self.suggestionGenerationStarted = false
                self.cancelActiveStageBTask(generationID: generationID)
                self.currentGenerationTelemetry.failureReason = "Full answer timed out after \(elapsed) ms."
                self.setGenerationUIState(.timeout(
                    questionID: question.id,
                    generationID: generationID,
                    triggerPath: triggerPath,
                    reason: "Full answer timed out after \(elapsed) ms."
                ), generationID: generationID)
                self.restoreCaptureAfterGenerationIfNeeded(session: session, generationID: generationID, reason: "generationFullCardTimeout")
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
    let card = applyStreamingSections(
        sections,
        to: currentSuggestion,
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
func persistSuggestionInBackground(
    _ card: SuggestionCard,
    chunks: [RetrievedChunk],
    generationID: String,
    requestStart: Date
) {
    let repository = suggestionRepository
    let simulateFailure = simulateSuggestionPersistenceFailure
    let simulatedDelay = simulatedSuggestionPersistenceDelayNanoseconds
    markSQLiteOperation("Saving suggestion card in background")
    if simulateFailure {
        guard currentGenerationID == generationID else { return }
        let message = "Suggestion is visible, but saving it failed: Simulated suggestion persistence failure."
        errorMessage = message
        currentGenerationTelemetry.dbError = message
        lastSQLiteOperation = "Suggestion save failed: simulated"
        warnAction(ActionID.generateAnswer, title: "Answer visible", message: "Saving failed, but the answer remains visible.")
        return
    }
    Task.detached(priority: .utility) { [weak self] in
        var persistedCard = card
        do {
            if simulatedDelay > 0 {
                try await Task.sleep(nanoseconds: simulatedDelay)
            }
            try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks)
            persistedCard.dbPersistedMS = Int(Date().timeIntervalSince(requestStart) * 1000)
            try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks)
            let persistedID = persistedCard.id
            let persistedDBMS = persistedCard.dbPersistedMS
            await MainActor.run { [weak self, persistedID, persistedDBMS] in
                guard let self = self, self.currentGenerationID == generationID else { return }
                self.lastSQLiteOperation = "Saved suggestion card"
                self.streamPersistedAt = Date()
                self.currentGenerationTelemetry.dbPersistedAt = Date()
                if self.currentSuggestion?.id == persistedID {
                    self.currentSuggestion?.dbPersistedMS = persistedDBMS
                }
                self.refreshLatencyAverages()
            }
        } catch {
            let message = "Suggestion is visible, but saving it failed: \(error.localizedDescription)"
            await MainActor.run { [weak self, message] in
                guard let self = self, self.currentGenerationID == generationID else { return }
                self.lastSQLiteOperation = "Suggestion save failed: \(error.localizedDescription)"
                self.errorMessage = message
                self.currentGenerationTelemetry.dbError = message
                self.warnAction(ActionID.generateAnswer, title: "Answer visible", message: "Saving failed, but the answer remains visible.")
            }
        }
    }
}

public func isSpecificAnswer(_ text: String) -> Bool {
    GenerationCoordinator.isSpecificAnswer(text)
}

// internal for AppState extension access only
func isAnswerRelevantEnoughForLivePreview(_ text: String, question: DetectedQuestion) -> Bool {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
