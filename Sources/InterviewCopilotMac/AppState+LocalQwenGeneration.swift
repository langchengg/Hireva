import Foundation

struct LocalQwenGenerationError: LocalizedError, Equatable {
    let category: OllamaFailureCategory
    let diagnostic: String

    var errorDescription: String? {
        "Local Qwen request failed: \(category.rawValue)."
    }
}

extension AppState {
    @discardableResult
    func finishWithLocalQwenAnswer(
        question: DetectedQuestion,
        session: InterviewSession,
        transcript: String,
        context: RetrievedContext,
        retrievedChunks: [RetrievedChunk],
        cvSummary: String,
        jdSummary: String,
        generationID: String,
        cardID: String,
        requestStart: Date,
        triggerPath: GenerationTriggerPath,
        source: AudioSourceType?,
        speaker: SpeakerRole?,
        localProvider: any LocalLLMProvider = OllamaQwenProvider(),
        fallbackReason: String?,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
    ) async throws -> Bool {
        ollamaDiagnostics = .empty()
        ollamaDiagnostics.endpoint = "http://localhost:11434/api/chat"
        ollamaDiagnostics.model = selectedQwenModelName
        ollamaDiagnostics.responseSchema = .chatMessageContent
        ollamaDiagnostics.streamMode = false
        ollamaLifecycleEvents = []
        guard isActiveGeneration(generationID, questionID: question.id) else {
            failLocalQwenDiagnostics(.staleGeneration, cancellationReason: "generation_identity_mismatch")
            recordStaleGenerationDiscard()
            return false
        }
        guard localQwenContextMatches(interviewContextSnapshot) else {
            failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
            recordStaleGenerationDiscard()
            return false
        }

        let modelName = selectedQwenModelName
        let snapshotContext = interviewContextSnapshot.map {
            DynamicInterviewContextEngine().retrieveContext(question: question.questionText, snapshot: $0)
        }
        let localPromptContext = snapshotContext?.context ?? context
        let localCVSummary = interviewContextSnapshot.map {
            $0.candidateEvidence.filter(\.isUsable).map(\.statement).joined(separator: "\n")
        } ?? cvSummary
        let localJDSummary = interviewContextSnapshot.map {
            $0.opportunityEvidence.filter(\.isUsable).map(\.statement).joined(separator: "\n")
        } ?? jdSummary
        let snapshotEvidenceIDs = Set(
            (snapshotContext?.candidateEvidenceIDs ?? []) +
                (snapshotContext?.opportunityEvidenceIDs ?? [])
        )
        let localRetrievedChunks = interviewContextSnapshot == nil
            ? retrievedChunks
            : retrievedChunks.filter { snapshotEvidenceIDs.contains($0.id) }
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: localPromptContext,
            transcriptContext: RealtimePromptBudgeter.limitTranscript(transcript),
            cvSummary: localCVSummary,
            jdSummary: localJDSummary,
            stage: .firstAnswer,
            interviewContextSnapshot: interviewContextSnapshot
        )
        let systemPrompt = """
        /no_think
        You are a real-time interview helper running locally. Answer as the candidate in first person.
        Output only a concise spoken answer, 1 to 3 sentences. Do not mention CV, JD, RAG, model names, or metadata.
        State past personal experience only when it is explicit in the selected candidate evidence.
        Do not turn future plans, domain knowledge, or opportunity requirements into completed work or observed events.
        """
        let userPrompt = promptSnapshot.prompt +
            "\n\nAnswer the current question now:"
        let primaryRequest = LocalLLMRequest(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180
        )
        ollamaDiagnostics.requestMessageCount = systemPrompt.isEmpty ? 1 : 2
        ollamaDiagnostics.systemPromptCharacters = systemPrompt.count
        ollamaDiagnostics.userPromptCharacters = userPrompt.count
        ollamaDiagnostics.contextSnapshotMatched = true
        appendOllamaLifecycleEvent(
            "question.accepted",
            question: question,
            session: session,
            generationID: generationID,
            snapshot: interviewContextSnapshot,
            promptSnapshot: promptSnapshot
        )
        appendOllamaLifecycleEvent(
            "context.snapshot.selected",
            question: question,
            session: session,
            generationID: generationID,
            snapshot: interviewContextSnapshot,
            promptSnapshot: promptSnapshot
        )
        appendOllamaLifecycleEvent(
            "candidate.evidence.retrieved",
            question: question,
            session: session,
            generationID: generationID,
            snapshot: interviewContextSnapshot,
            promptSnapshot: promptSnapshot
        )
        appendOllamaLifecycleEvent(
            "opportunity.evidence.retrieved",
            question: question,
            session: session,
            generationID: generationID,
            snapshot: interviewContextSnapshot,
            promptSnapshot: promptSnapshot
        )
        let previousQuestionContext = localQwenPreviousQuestionContext(excluding: question)
        let compactRecoveryRequest = compactLocalQwenRequest(
            question: question,
            context: promptSnapshot.ragContextSnapshot,
            cvSummary: localCVSummary,
            jdSummary: localJDSummary,
            modelName: modelName,
            previousQuestionContext: previousQuestionContext
        )
        let groundedRecoveryRequest = groundedLocalQwenRecoveryRequest(
            question: question,
            context: promptSnapshot.ragContextSnapshot,
            modelName: modelName,
            previousQuestionContext: previousQuestionContext
        )

        var cleanedAnswer = ""
        var lastFailureCategory: OllamaFailureCategory = .providerReturnedNoContent
        var firstContentRecorded = false
        let requests = [primaryRequest, compactRecoveryRequest, groundedRecoveryRequest]
        for requestIndex in requests.indices {
            let request = requests[requestIndex]
            let maxAttempts = requestIndex == 0 ? 2 : 1
            for attempt in 1...maxAttempts {
                var answer = ""
                appendOllamaLifecycleEvent(
                    "ollama.request.started",
                    question: question,
                    session: session,
                    generationID: generationID,
                    snapshot: interviewContextSnapshot,
                    promptSnapshot: promptSnapshot
                )
                do {
                    let tokenStream = try await localProvider.generateAnswer(request: request)
                    for try await token in tokenStream {
                        guard !Task.isCancelled else {
                            failLocalQwenDiagnostics(.requestCancelled, cancellationReason: "task_cancelled")
                            return false
                        }
                        guard isActiveGeneration(generationID, questionID: question.id) else {
                            failLocalQwenDiagnostics(.staleGeneration, cancellationReason: "generation_replaced")
                            recordStaleGenerationDiscard()
                            return false
                        }
                        guard localQwenContextMatches(interviewContextSnapshot) else {
                            failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
                            recordStaleGenerationDiscard()
                            return false
                        }
                        ollamaDiagnostics.chunksReceived += 1
                        if !token.text.isEmpty {
                            ollamaDiagnostics.contentChunksReceived += 1
                            ollamaDiagnostics.rawContentCharacters += token.text.count
                            ollamaDiagnostics.firstContentObserved = true
                            answer += token.text
                            appendOllamaLifecycleEvent(
                                "ollama.response.chunk",
                                question: question,
                                session: session,
                                generationID: generationID,
                                snapshot: interviewContextSnapshot,
                                promptSnapshot: promptSnapshot
                            )
                            if !firstContentRecorded {
                                firstContentRecorded = true
                                appendOllamaLifecycleEvent(
                                    "ollama.first_content",
                                    question: question,
                                    session: session,
                                    generationID: generationID,
                                    snapshot: interviewContextSnapshot,
                                    promptSnapshot: promptSnapshot
                                )
                            }
                        }
                    }
                } catch {
                    if let diagnosticsProvider = localProvider as? LocalLLMDiagnosticsProviding {
                        mergeProviderDiagnostics(diagnosticsProvider.lastGenerationDiagnostics)
                    }
                    let category = OllamaFailureCategory.classify(error)
                    failLocalQwenDiagnostics(category)
                    appendOllamaLifecycleEvent(
                        "answer.request.failed",
                        question: question,
                        session: session,
                        generationID: generationID,
                        snapshot: interviewContextSnapshot,
                        promptSnapshot: promptSnapshot,
                        failureCategory: category
                    )
                    throw LocalQwenGenerationError(category: category, diagnostic: error.localizedDescription)
                }
                if let diagnosticsProvider = localProvider as? LocalLLMDiagnosticsProviding {
                    mergeProviderDiagnostics(diagnosticsProvider.lastGenerationDiagnostics)
                }
                ollamaDiagnostics.streamCompleted = true
                appendOllamaLifecycleEvent(
                    "ollama.stream.completed",
                    question: question,
                    session: session,
                    generationID: generationID,
                    snapshot: interviewContextSnapshot,
                    promptSnapshot: promptSnapshot
                )

                let parsed = LocalQwenAnswerParser.parse(answer)
                cleanedAnswer = parsed.sayFirst
                ollamaDiagnostics.sectionParserResult = parsed.sectionParserResult
                ollamaDiagnostics.parsedContentCharacters = cleanedAnswer.count
                appendOllamaLifecycleEvent(
                    "ollama.answer.parsed",
                    question: question,
                    session: session,
                    generationID: generationID,
                    snapshot: interviewContextSnapshot,
                    promptSnapshot: promptSnapshot,
                    failureCategory: parsed.failureCategory
                )
                appendOllamaLifecycleEvent(
                    "answer.sections.parsed",
                    question: question,
                    session: session,
                    generationID: generationID,
                    snapshot: interviewContextSnapshot,
                    promptSnapshot: promptSnapshot,
                    failureCategory: parsed.failureCategory
                )
                if let parserFailure = parsed.failureCategory {
                    lastFailureCategory = parserFailure
                }
                if !cleanedAnswer.isEmpty {
                    appendOllamaLifecycleEvent(
                        "answer.alignment.started",
                        question: question,
                        session: session,
                        generationID: generationID,
                        snapshot: interviewContextSnapshot,
                        promptSnapshot: promptSnapshot
                    )
                    let validation = validateLocalQwenAnswer(
                        cleanedAnswer,
                        question: question,
                        interviewContextSnapshot: interviewContextSnapshot
                    )
                    ollamaDiagnostics.alignmentDecision = validation.diagnostic
                    appendOllamaLifecycleEvent(
                        "answer.alignment.completed",
                        question: question,
                        session: session,
                        generationID: generationID,
                        snapshot: interviewContextSnapshot,
                        promptSnapshot: promptSnapshot,
                        failureCategory: validation.failureCategory
                    )
                    guard validation.accepted else {
                        lastFailureCategory = validation.failureCategory ?? .alignmentRejectedNonemptyContent
                        markProviderOperation("Local Qwen returned a non-aligned answer; retrying with recovery prompt")
                        cleanedAnswer = ""
                        continue
                    }
                    break
                }
                if attempt < maxAttempts {
                    markProviderOperation("Local Qwen returned an empty stream; retrying once")
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            if !cleanedAnswer.isEmpty {
                break
            }
            if requestIndex == 0 {
                markProviderOperation("Local Qwen returned empty twice; retrying with compact prompt")
            } else if requestIndex == 1 {
                markProviderOperation("Local Qwen compact prompt returned empty; retrying with grounded prompt")
            }
        }
        guard !cleanedAnswer.isEmpty else {
            failLocalQwenDiagnostics(lastFailureCategory)
            throw LocalQwenGenerationError(
                category: lastFailureCategory,
                diagnostic: "Local Qwen exhausted all grounded answer attempts."
            )
        }

        let elapsed = elapsedMS(since: requestStart)
        let isFallback = fallbackReason != nil
        let selectedEvidenceIDs = Set(promptSnapshot.candidateEvidenceIDs)
        let fallbackKeyPoints = interviewContextSnapshot?.candidateEvidence
            .filter { selectedEvidenceIDs.contains($0.id) }
            .map(\.statement) ?? []
        var card = SuggestionCard(
            id: cardID,
            sessionID: session.id,
            questionID: question.id,
            strategy: isFallback ? "Local Qwen Fallback" : "Local Qwen Primary",
            sayFirst: cleanedAnswer,
            keyPoints: localQwenKeyPoints(from: cleanedAnswer, fallback: fallbackKeyPoints),
            followUpReady: ["I can expand on the implementation tradeoffs if useful."],
            confidence: 0.72,
            caution: fallbackReason.map { "Local Qwen fallback used because \($0)." },
            evidenceUsed: localRetrievedChunks.map(\.id),
            riskLevel: .low,
            modelName: modelName,
            promptVersion: "ollama-qwen-v1",
            providerKind: .ollamaLocal,
            providerName: "Ollama Qwen",
            providerBaseURL: "http://localhost:11434",
            latencyMS: elapsed,
            isLocal: true,
            rawJSON: cleanedAnswer,
            createdAt: Date(),
            questionIntent: promptSnapshot.questionIntent,
            promptQuestionText: promptSnapshot.questionTextSnapshot,
            promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion,
            promptContainsPreviousQuestion: promptSnapshot.promptContainsPreviousQuestion,
            previousQuestionIncluded: promptSnapshot.previousQuestionIncluded,
            previousQuestionText: promptSnapshot.previousQuestionText,
            contextBleedRisk: promptSnapshot.contextBleedRisk,
            ragChunkIDs: promptSnapshot.ragChunkIDs,
            ragChunkIntents: promptSnapshot.ragChunkIntents,
            promptTokenEstimate: promptSnapshot.promptTokenEstimate,
            promptContextPreview: promptSnapshot.ragChunkPreviews.joined(separator: "\n"),
            sayFirstSource: AnswerSource.ollamaQwen.rawValue,
            stageATimedOut: false,
            stageBCompleted: true,
            stageBStatus: "completed",
            latencyFirstTokenMS: elapsed,
            latencyFirstVisibleMS: elapsed,
            latencyFullCardMS: elapsed,
            softFallbackUsed: isFallback,
            softFallbackLatencyMS: isFallback ? elapsed : nil,
            deepseekFirstTokenMS: deepseekFirstTokenMS,
            deepseekFirstVisibleMS: deepseekFirstVisibleMS,
            finalVisibleSource: AnswerSource.ollamaQwen.rawValue,
            fallbackReason: fallbackReason
        )
        card.questionText = question.questionText
        card.transcriptSegmentID = question.transcriptSegmentID
        card.generationID = generationID
        card.source = source?.rawValue ?? currentGenerationTelemetry.source
        card.speaker = speaker?.rawValue ?? currentGenerationTelemetry.speaker
        card.triggerPath = triggerPath
        card.firstVisibleAnswerMS = elapsed
        card.firstKeyPointVisibleMS = card.keyPoints.isEmpty ? nil : elapsed
        card.allKeyPointsVisibleMS = card.keyPoints.isEmpty ? nil : elapsed
        card.fullCardVisibleMS = elapsed
        card.ragRetrievalLatencyMS = ragRetrievalLatencyMS
        card.contextSnapshotID = interviewContextSnapshot?.id
        card.candidateProfileID = interviewContextSnapshot?.candidateProfileID
        card.candidateProfileVersion = interviewContextSnapshot?.candidateProfileVersion
        card.opportunityContextID = interviewContextSnapshot?.opportunityContextID
        card.opportunityContextVersion = interviewContextSnapshot?.opportunityContextVersion
        card.domainProfileID = interviewContextSnapshot?.domainProfileID
        card.candidateEvidenceIDs = promptSnapshot.candidateEvidenceIDs
        card.opportunityEvidenceIDs = promptSnapshot.opportunityEvidenceIDs

        guard displaySuggestionIfAligned(
            card,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker
        ) else {
            if !isActiveGeneration(generationID, questionID: question.id) {
                failLocalQwenDiagnostics(.staleGeneration, cancellationReason: "generation_replaced_before_display")
            } else if !localQwenContextMatches(interviewContextSnapshot) {
                failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
            } else {
                failLocalQwenDiagnostics(.alignmentRejectedNonemptyContent)
                throw LocalQwenGenerationError(
                    category: .alignmentRejectedNonemptyContent,
                    diagnostic: lastAlignmentError
                )
            }
            return false
        }

        streamedSayFirst = ""
        currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
        finalVisibleSource = AnswerSource.ollamaQwen.rawValue
        softFallbackUsed = isFallback
        softFallbackLatencyMS = isFallback ? elapsed : nil
        softFallbackShownAt = isFallback ? (softFallbackShownAt ?? Date()) : softFallbackShownAt
        markFirstVisibleAnswer(generationID: generationID, fallback: isFallback)
        ollamaDiagnostics.finalErrorCategory = nil
        ollamaDiagnostics.contextSnapshotMatched = true
        appendOllamaLifecycleEvent(
            "answer.state.updated",
            question: question,
            session: session,
            generationID: generationID,
            snapshot: interviewContextSnapshot,
            promptSnapshot: promptSnapshot
        )
        let finished = finishGenerationWithVisibleCard(
            currentSuggestion ?? card,
            generationID: generationID,
            question: question,
            session: session,
            requestStart: requestStart,
            retrievedChunks: retrievedChunks,
            triggerPath: triggerPath,
            timedOut: false
        )
        if finished {
            appendOllamaLifecycleEvent(
                "answer.ui.rendered",
                question: question,
                session: session,
                generationID: generationID,
                snapshot: interviewContextSnapshot,
                promptSnapshot: promptSnapshot
            )
        }
        return finished
    }

    private func localQwenKeyPoints(from answer: String, fallback: [String]) -> [String] {
        let sentences = answer
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
            .prefix(3)
            .map { sentence -> String in
                sentence.hasSuffix(".") ? sentence : sentence + "."
            }
        if !sentences.isEmpty {
            return Array(sentences)
        }
        return Array(fallback.prefix(3))
    }

    private func validateLocalQwenAnswer(
        _ answer: String,
        question: DetectedQuestion,
        interviewContextSnapshot: InterviewContextSnapshot?
    ) -> LocalQwenAnswerValidationResult {
        guard !QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer),
              QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(answer) == nil else {
            return .rejected(
                category: .alignmentRejectedNonemptyContent,
                diagnostic: "generic_or_incomplete"
            )
        }
        if let snapshot = interviewContextSnapshot {
            let grounding = AnswerClaimValidator().validate(
                answer: answer,
                candidateEvidence: snapshot.candidateEvidence,
                opportunityEvidence: snapshot.opportunityEvidence,
                domainKnowledge: InterviewDomainProfile.profile(
                    for: InterviewDomainID(rawValue: snapshot.domainProfileID) ?? .general
                ).domainKnowledge
            )
            guard grounding.unsupportedClaims.isEmpty else {
                return .rejected(
                    category: .alignmentRejectedNonemptyContent,
                    diagnostic: "unsupported_personal_claim"
                )
            }
        }
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question.questionText,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )
        guard alignment.verdict == .aligned else {
            return .rejected(
                category: .alignmentRejectedNonemptyContent,
                diagnostic: alignment.reason
            )
        }
        return .accepted(alignment.verdict.rawValue)
    }

    private func localQwenContextMatches(_ snapshot: InterviewContextSnapshot?) -> Bool {
        guard let snapshot else { return true }
        guard activeGenerationController?.identity.contextSnapshotID == snapshot.id else { return false }
        if let activeContextSnapshot {
            return activeContextSnapshot.id == snapshot.id
        }
        return currentSession?.contextSnapshotID == snapshot.id
    }

    private func mergeProviderDiagnostics(_ provider: OllamaProviderDiagnostics) {
        guard provider.endpoint != "None" else { return }
        let localChunkCount = ollamaDiagnostics.chunksReceived
        let localContentChunkCount = ollamaDiagnostics.contentChunksReceived
        let localRawCharacters = ollamaDiagnostics.rawContentCharacters
        let localParsedCharacters = ollamaDiagnostics.parsedContentCharacters
        let localSectionParserResult = ollamaDiagnostics.sectionParserResult
        let localAlignmentDecision = ollamaDiagnostics.alignmentDecision
        let localContextMatched = ollamaDiagnostics.contextSnapshotMatched
        ollamaDiagnostics = provider
        ollamaDiagnostics.chunksReceived = max(provider.chunksReceived, localChunkCount)
        ollamaDiagnostics.contentChunksReceived = max(provider.contentChunksReceived, localContentChunkCount)
        ollamaDiagnostics.rawContentCharacters = max(provider.rawContentCharacters, localRawCharacters)
        ollamaDiagnostics.parsedContentCharacters = max(provider.parsedContentCharacters, localParsedCharacters)
        ollamaDiagnostics.sectionParserResult = localSectionParserResult
        ollamaDiagnostics.alignmentDecision = localAlignmentDecision
        ollamaDiagnostics.contextSnapshotMatched = localContextMatched
    }

    private func failLocalQwenDiagnostics(
        _ category: OllamaFailureCategory,
        cancellationReason: String? = nil,
        contextSnapshotMatched: Bool? = nil
    ) {
        ollamaDiagnostics.finalErrorCategory = category
        if let cancellationReason {
            ollamaDiagnostics.cancellationReason = cancellationReason
        }
        if let contextSnapshotMatched {
            ollamaDiagnostics.contextSnapshotMatched = contextSnapshotMatched
        }
    }

    private func appendOllamaLifecycleEvent(
        _ name: String,
        question: DetectedQuestion,
        session: InterviewSession,
        generationID: String,
        snapshot: InterviewContextSnapshot?,
        promptSnapshot: AnswerPromptSnapshot,
        failureCategory: OllamaFailureCategory? = nil
    ) {
        let event = OllamaLifecycleEvent(
            id: UUID().uuidString,
            name: name,
            timestamp: Date(),
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            contextSnapshotID: snapshot?.id,
            candidateProfileID: snapshot?.candidateProfileID,
            candidateProfileVersion: snapshot?.candidateProfileVersion,
            opportunityContextID: snapshot?.opportunityContextID,
            opportunityContextVersion: snapshot?.opportunityContextVersion,
            domainProfileID: snapshot?.domainProfileID,
            model: ollamaDiagnostics.model,
            endpoint: ollamaDiagnostics.endpoint,
            streamMode: ollamaDiagnostics.streamMode,
            requestMessageCount: ollamaDiagnostics.requestMessageCount,
            systemPromptCharacters: ollamaDiagnostics.systemPromptCharacters,
            userPromptCharacters: ollamaDiagnostics.userPromptCharacters,
            candidateEvidenceCount: promptSnapshot.candidateEvidenceIDs.count,
            opportunityEvidenceCount: promptSnapshot.opportunityEvidenceIDs.count,
            dialogueEvidenceCount: promptSnapshot.previousQuestionIncluded ? 1 : 0,
            estimatedPromptTokens: promptSnapshot.promptTokenEstimate,
            responseChunkCount: ollamaDiagnostics.chunksReceived,
            rawContentCharacters: ollamaDiagnostics.rawContentCharacters,
            parsedContentCharacters: ollamaDiagnostics.parsedContentCharacters,
            alignmentDecision: ollamaDiagnostics.alignmentDecision,
            failureCategory: failureCategory ?? ollamaDiagnostics.finalErrorCategory
        )
        ollamaLifecycleEvents.append(event)
        if ollamaLifecycleEvents.count > 40 {
            ollamaLifecycleEvents.removeFirst(ollamaLifecycleEvents.count - 40)
        }
    }

    private func compactLocalQwenRequest(
        question: DetectedQuestion,
        context: RetrievedContext,
        cvSummary: String,
        jdSummary: String,
        modelName: String,
        previousQuestionContext: String?
    ) -> LocalLLMRequest {
        let evidence = ContextBudgeter.limitWords(context.promptText, maxWords: 160)
        let previousContext = previousQuestionContext
            .map { "Previous answered question for pronoun resolution only:\n\($0)" }
            ?? "No previous answered question is available."
        let compactPrompt = """
        /no_think
        Current interview question:
        \(question.questionText)

        Conversation context:
        \(previousContext)

        Candidate/project summary:
        \(ContextBudgeter.limitWords(cvSummary, maxWords: 90))

        Role summary:
        \(ContextBudgeter.limitWords(jdSummary, maxWords: 60))

        Relevant local evidence:
        \(evidence.isEmpty ? "No compact evidence available." : evidence)

        Answer the current question directly as the candidate in 1 to 3 concise spoken sentences.
        Use the conversation context only to resolve pronouns such as it, that, or this.
        State past personal experience only when it is explicit in the candidate/project summary or relevant local evidence.
        Do not turn role requirements or future plans into completed work or observed events.
        Start with "I" and output only the final spoken answer.
        """
        return LocalLLMRequest(
            prompt: compactPrompt,
            systemPrompt: "/no_think You are a concise local interview answer helper. Output only the final answer as the candidate in first person.",
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180
        )
    }

    private func localQwenPreviousQuestionContext(excluding question: DetectedQuestion) -> String? {
        let currentKey = QuestionIntentPromptPolicy.normalizedQuestionText(for: question.questionText)
        let candidates = ([currentSuggestion].compactMap { $0 } + liveSuggestionHistory.reversed())
        for card in candidates {
            let text = (card.questionText ?? card.promptPrimaryQuestion ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard QuestionIntentPromptPolicy.normalizedQuestionText(for: text) != currentKey else { continue }
            return ContextBudgeter.limitWords(text, maxWords: 40)
        }
        return nil
    }

    private func groundedLocalQwenRecoveryRequest(
        question: DetectedQuestion,
        context: RetrievedContext,
        modelName: String,
        previousQuestionContext: String?
    ) -> LocalLLMRequest {
        let previousContext = previousQuestionContext
            .map { "Previous answered question for pronoun resolution only:\n\($0)" }
            ?? "No previous answered question is available."
        let groundedEvidence = ContextBudgeter.limitWords(context.promptText, maxWords: 220)
        let prompt = """
        /no_think
        Question:
        \(question.questionText)

        Previous question context, only if needed for pronouns:
        \(previousContext)

        Selected profile and opportunity evidence:
        \(groundedEvidence.isEmpty ? "No candidate evidence is available. Do not invent a personal answer." : groundedEvidence)

        Answer the current question directly as the candidate in 1 to 3 concise spoken sentences.
        Use only personal facts supported by the selected profile evidence. Treat opportunity requirements as targets, never as completed achievements.
        Do not invent observations, incidents, metrics, outcomes, or completed experiments that are absent from the selected profile evidence.
        Do not mention this prompt or the reference facts.
        Start with "I" and output only the final spoken answer.
        """
        return LocalLLMRequest(
            prompt: prompt,
            systemPrompt: "/no_think You are a concise local interview answer helper. Output only the final answer as the candidate in first person.",
            modelName: modelName,
            temperature: 0.0,
            numPredict: 220
        )
    }

}
