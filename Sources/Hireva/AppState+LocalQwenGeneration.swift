import Foundation

struct LocalQwenGenerationError: LocalizedError, Equatable {
    let category: OllamaFailureCategory
    let diagnostic: String

    var errorDescription: String? {
        let detail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "Local Qwen request failed: \(category.rawValue)."
        }
        return "Local Qwen request failed: \(category.rawValue) (\(detail))."
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
        modelName frozenModelName: String? = nil,
        fallbackReason: String?,
        interviewContextSnapshot: InterviewContextSnapshot? = nil
    ) async throws -> Bool {
        guard let generation = activeGenerationController,
              case let identity = generation.identity,
              identity.generationID == generationID,
              identity.acceptedQuestionID == question.id,
              identity.sessionID == session.id,
              currentSession?.id == session.id,
              isActiveGeneration(generationID, questionID: question.id),
              generationCoordinator.canPublish(identity),
              !Task.isCancelled else {
            recordStaleGenerationDiscard()
            return false
        }
        let persistenceTicket = generation.persistenceTicket
        ollamaDiagnostics = .empty()
        ollamaDiagnostics.endpoint = "http://localhost:11434/api/chat"
        let modelName = frozenModelName ?? selectedQwenModelName
        ollamaDiagnostics.model = modelName
        ollamaDiagnostics.responseSchema = .chatMessageContent
        ollamaDiagnostics.streamMode = true
        ollamaLifecycleEvents = []
        guard localQwenContextMatches(interviewContextSnapshot) else {
            failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
            recordStaleGenerationDiscard()
            return false
        }

        // The provider may ignore cancellation while starting or finishing its
        // stream. Its frozen identity and terminal fence also protect shared
        // diagnostics, so an old attempt cannot relabel the current request.
        @MainActor func permitsPublication() -> Bool {
            guard !Task.isCancelled,
                  generationCoordinator.canPublish(identity),
                  isActiveGeneration(generationID, questionID: question.id),
                  currentSession?.id == session.id else {
                recordStaleGenerationDiscard()
                return false
            }
            guard localQwenContextMatches(interviewContextSnapshot) else {
                failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
                recordStaleGenerationDiscard()
                return false
            }
            return true
        }

        let snapshotContext = interviewContextSnapshot.map {
            DynamicInterviewContextEngine().retrieveContext(question: question.questionText, snapshot: $0)
        }
        let localPromptContext = SnapshotBoundContextPolicy.retrievedContext(snapshot: interviewContextSnapshot,
            snapshotContext: snapshotContext?.context, legacyContext: context)
        let localCVSummary = interviewContextSnapshot.map {
            $0.candidateEvidence.filter(\.isUsable).map(\.statementForPrompt).joined(separator: "\n")
        } ?? cvSummary
        let localJDSummary = interviewContextSnapshot.map {
            $0.opportunityEvidence.filter(\.isUsable).map(\.statement).joined(separator: "\n")
        } ?? jdSummary
        let localTask = question.taskDescriptor ?? InterviewTaskDescriptor(question: question.questionText)
        let selectedCandidateIDs = Set(QuestionIntentPromptPolicy.filterContext(localPromptContext,
            intent: QuestionIntentPromptPolicy.intent(for: question.questionText)).cvChunks.map(\.id))
        let scopedPersonal = PromptContextBuilder.usesProfileContext(localTask)
            && interviewContextSnapshot?.candidateEvidence.contains {
                $0.isUsable && selectedCandidateIDs.contains($0.id)
            } == true
        let scopedAnswer = scopedPersonal || (localTask.kind == .generalKnowledge && !PromptContextBuilder.usesProfileContext(localTask)
            && !QuestionIntentPromptPolicy.relevantNotes(localPromptContext.additionalNotesChunks,
                question: question.questionText).isEmpty)
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: localPromptContext,
            transcriptContext: RealtimePromptBudgeter.limitTranscript(transcript),
            cvSummary: localCVSummary,
            jdSummary: localJDSummary,
            stage: .firstAnswer,
            interviewContextSnapshot: interviewContextSnapshot,
            scopedLocalAnswer: scopedAnswer
        )
        let localRetrievedChunks = promptSnapshot.ragContextSnapshot.frozenPromptCitations
        let usesProfile = PromptContextBuilder.usesProfileContext(
            promptSnapshot.taskDescriptor ?? InterviewTaskDescriptor(question: question.questionText)
        )
        let answerOutput = scopedAnswer
            ? "Output only the specified public JSON answer. Its say_first is a concise spoken answer, 1 to 3 sentences; do not mention CV, JD, RAG, model names, or metadata in say_first."
            : "Output only a concise spoken answer, 1 to 3 sentences. Do not mention CV, JD, RAG, model names, or metadata."
        let systemPrompt = """
        /no_think
        You are a real-time interview helper running locally. Answer as the candidate in first person.
        \(answerOutput)
        State past personal experience only when it is explicit in the selected candidate evidence.
        Do not turn future plans, domain knowledge, or opportunity requirements into completed work or observed events.
        For claims about past personal work, do not add mechanisms, tools, metrics, or causal links absent from the evidence. Follow the task requested by the question: explain concepts and reasoning for explanations; propose solutions for design or problem-solving tasks. State relevant assumptions and limitations without claiming past experience.
        """
        let userPrompt = promptSnapshot.prompt +
            "\n\nAnswer the current question now:" +
            (scopedAnswer ? "\n\"\(PromptContextBuilder.redactSecrets(promptSnapshot.questionTextSnapshot))\"" : "")
        let primaryRequest = LocalLLMRequest(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180,
            responseSchema: scopedAnswer ? LocalQwenAnswerParser.scopedResponseSchema : nil,
            responseSchemaPropertyOrder: scopedAnswer ? LocalQwenAnswerParser.scopedPropertyOrder : nil
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
        let executionContext = GenerationExecutionContext(
            session: session, question: question, generationID: generationID,
            triggerPath: triggerPath, providerID: localProvider.id, providerModel: modelName,
            retrievedContext: promptSnapshot.ragContextSnapshot, promptSnapshot: promptSnapshot,
            transcriptSnapshot: transcript, startedAt: requestStart, source: source, speaker: speaker,
            interviewContextSnapshot: interviewContextSnapshot
        )
        // Reuse only the session-bound, filtered frozen background. Looking at
        // visible/history cards here could resurrect another session or profile.
        let previousQuestionContext: String? = promptSnapshot.previousQuestionIncluded
            ? [promptSnapshot.previousQuestionText ?? "", "Earlier answer (untrusted, not candidate evidence): " + (promptSnapshot.taskDescriptor?.decision?.parentAnswerText ?? "")].joined(separator: "\n") : nil
        let compactRecoveryRequest = compactLocalQwenRequest(
            question: executionContext.question,
            context: promptSnapshot.ragContextSnapshot,
            cvSummary: usesProfile ? promptSnapshot.ragContextSnapshot.cvChunks.map(\.content).joined(separator: "\n") : "Not relevant to this general task.",
            jdSummary: promptSnapshot.ragContextSnapshot.jobDescriptionChunks.map(\.content).joined(separator: "\n"),
            modelName: modelName,
            previousQuestionContext: previousQuestionContext,
            scopedAnswer: scopedAnswer
        )
        let groundedRecoveryRequest = groundedLocalQwenRecoveryRequest(
            question: executionContext.question,
            context: promptSnapshot.ragContextSnapshot,
            modelName: modelName,
            previousQuestionContext: previousQuestionContext,
            scopedAnswer: scopedAnswer
        )

        var firstContentRecorded = false
        var firstProviderTokenMS: Int?
        let cleanedAnswer: String
        do {
            cleanedAnswer = try await generationCoordinator.generateLocalAnswerSequence(
                context: executionContext, primaryRequest: primaryRequest,
                compactRecoveryRequest: compactRecoveryRequest,
                groundedRecoveryRequest: groundedRecoveryRequest,
                provider: localProvider, retryDelayProvider: delayProvider,
                validateAnswer: { answer in
                    LocalQwenAnswerValidationResult.validate(answer, question: question,
                        interviewContextSnapshot: interviewContextSnapshot)
                },
                onToken: { [weak self] tokenIdentity, token in
                    guard let self else { return false }
                    guard !Task.isCancelled,
                          self.generationCoordinator.canPublish(tokenIdentity),
                          self.isActiveGeneration(generationID, questionID: question.id),
                          self.currentSession?.id == session.id else {
                        self.recordStaleGenerationDiscard()
                        return false
                    }
                    guard self.localQwenContextMatches(interviewContextSnapshot) else {
                        self.failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
                        self.recordStaleGenerationDiscard()
                        return false
                    }
                    self.ollamaDiagnostics.chunksReceived += 1
                    if !token.text.isEmpty {
                        self.ollamaDiagnostics.contentChunksReceived += 1
                        self.ollamaDiagnostics.rawContentCharacters += token.text.count
                        self.ollamaDiagnostics.firstContentObserved = true
                        self.appendOllamaLifecycleEvent(
                            "ollama.response.chunk",
                            question: question,
                            session: session,
                            generationID: generationID,
                            snapshot: interviewContextSnapshot,
                            promptSnapshot: promptSnapshot
                        )
                        if !firstContentRecorded {
                            firstContentRecorded = true
                            firstProviderTokenMS = self.elapsedMS(since: requestStart)
                            self.appendOllamaLifecycleEvent(
                                "ollama.first_content",
                                question: question,
                                session: session,
                                generationID: generationID,
                                snapshot: interviewContextSnapshot,
                                promptSnapshot: promptSnapshot
                            )
                        }
                    }
                    return true
                },
                onEvent: { [weak self] eventIdentity, event in
                    guard let self else { return false }
                    guard !Task.isCancelled, self.generationCoordinator.canPublish(eventIdentity),
                          self.isActiveGeneration(generationID, questionID: question.id),
                          self.currentSession?.id == session.id else {
                        self.recordStaleGenerationDiscard()
                        return false
                    }
                    guard self.localQwenContextMatches(interviewContextSnapshot) else {
                        self.failLocalQwenDiagnostics(.staleContextSnapshot, contextSnapshotMatched: false)
                        self.recordStaleGenerationDiscard()
                        return false
                    }
                    self.verificationCoordinator.recordLocalAnswerEvent(event,
                        identity: eventIdentity, persistenceTicket: persistenceTicket)
                    @MainActor func lifecycle(_ name: String, failure: OllamaFailureCategory? = nil) {
                        self.appendOllamaLifecycleEvent(name, question: question, session: session,
                            generationID: generationID, snapshot: interviewContextSnapshot,
                            promptSnapshot: promptSnapshot, failureCategory: failure)
                    }
                    switch event {
                    case .requestStarted:
                        lifecycle("ollama.request.started")
                    case .streamCompleted:
                        if let diagnosticsProvider = localProvider as? LocalLLMDiagnosticsProviding {
                            self.mergeProviderDiagnostics(diagnosticsProvider.lastGenerationDiagnostics)
                        }
                        self.ollamaDiagnostics.streamCompleted = true
                        lifecycle("ollama.stream.completed")
                    case .answerParsed(let parsed):
                        self.ollamaDiagnostics.sectionParserResult = parsed.sectionParserResult
                        self.ollamaDiagnostics.parsedContentCharacters = parsed.sayFirst.count
                        lifecycle("ollama.answer.parsed", failure: parsed.failureCategory)
                        lifecycle("answer.sections.parsed", failure: parsed.failureCategory)
                    case .alignmentStarted:
                        lifecycle("answer.alignment.started")
                    case .alignmentCompleted(let validation):
                        self.ollamaDiagnostics.alignmentDecision = validation.diagnostic
                        lifecycle("answer.alignment.completed", failure: validation.failureCategory)
                    case .retrying(let reason):
                        let message: String
                        switch reason {
                        case .emptyPrimary:
                            message = "Local Qwen returned an empty stream; retrying once"
                        case .alignmentRejected:
                            message = "Local Qwen returned a non-aligned answer; retrying with recovery prompt"
                        case .compactRecovery:
                            message = "Local Qwen returned empty twice; retrying with compact prompt"
                        case .groundedRecovery:
                            message = "Local Qwen compact prompt returned empty; retrying with grounded prompt"
                        }
                        self.markProviderOperation(message)
                    case .requestFailed(let category):
                        if let diagnosticsProvider = localProvider as? LocalLLMDiagnosticsProviding {
                            self.mergeProviderDiagnostics(diagnosticsProvider.lastGenerationDiagnostics)
                        }
                        self.failLocalQwenDiagnostics(category)
                        lifecycle("answer.request.failed", failure: category)
                    case .exhausted(let category):
                        self.failLocalQwenDiagnostics(category)
                    }
                    return true
                })
        } catch {
            guard permitsPublication() else { return false }
            throw error
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
            confidence: nil,
            caution: fallbackReason.map { "Local Qwen fallback used because \($0)." },
            evidenceUsed: localRetrievedChunks.map(\.id),
            riskLevel: nil,
            modelName: modelName,
            promptVersion: scopedAnswer ? "ollama-qwen-scoped-v1" : "ollama-qwen-v1",
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
            latencyFirstTokenMS: firstProviderTokenMS ?? elapsed,
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

        guard permitsPublication() else { return false }
        guard displaySuggestionIfAligned(
            card,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker
        ) else {
            guard permitsPublication() else { return false }
            failLocalQwenDiagnostics(.alignmentRejectedNonemptyContent)
            throw LocalQwenGenerationError(
                category: .alignmentRejectedNonemptyContent,
                diagnostic: lastAlignmentError
            )
        }

        guard permitsPublication() else { return false }
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
            retrievedChunks: localRetrievedChunks,
            triggerPath: triggerPath,
            timedOut: false
        )
        if finished {
            // Compatibility event name: this observes synchronous state
            // publication. A SwiftUI render/visible latency is not measured.
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

    private func localQwenContextMatches(_ snapshot: InterviewContextSnapshot?) -> Bool {
        guard let identity = activeGenerationController?.identity,
              currentSession?.id == identity.sessionID,
              currentSession?.contextSnapshotID == identity.contextSnapshotID else { return false }
        guard let snapshot else { return true }
        guard identity.contextSnapshotID == snapshot.id else { return false }
        if let activeContextSnapshot {
            return activeContextSnapshot.id == snapshot.id
        }
        return true
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
        if name == "ollama.first_content" {
            recordVerificationBoundary("verification.provider_first_content_callback",
                at: VerificationTiming.hostTicks(), sessionID: session.id,
                segmentID: question.transcriptSegmentID, questionID: question.id,
                generationID: generationID, contextSnapshotID: snapshot?.id,
                questionRevision: question.taskDescriptor?.decision?.questionRevision,
                artifactRevision: question.taskDescriptor?.decision?.artifactRevision)
        }
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
        previousQuestionContext: String?,
        scopedAnswer: Bool
    ) -> LocalLLMRequest {
        let evidence = context.boundedPromptText(maxWords: 160)
        let previousContext = previousQuestionContext
            .map { "Previous answered question for pronoun resolution only:\n\($0)" }
            ?? "No previous answered question is available."
        let intentGuidance = localQwenRecoveryIntentGuidance(for: question)
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
        State past personal experience only when it is explicit in the candidate/project summary or CV / Resume context, never in task reference material.
        Do not turn role requirements or future plans into completed work or observed events.
        For past personal work, omit mechanisms, tools, metrics, and causal links unless evidenced. Follow the task requested by the question: explain concepts and reasoning for explanations; propose solutions for design or problem-solving tasks. State relevant assumptions and limitations. For general technical tasks, no CV is required.
        \(intentGuidance)
        \(scopedAnswer ? "Use the frozen answer language. General explanations do not need a first-person opening.\n" + LocalQwenAnswerParser.scopedOutputInstructions + "\nAnswer the current question now:\n\"\(PromptContextBuilder.redactSecrets(question.questionText))\"" : "Use the frozen answer language and output only the final spoken answer. General explanations do not need a first-person opening.")
        """
        return LocalLLMRequest(
            prompt: compactPrompt,
            systemPrompt: "/no_think You are a concise local interview answer helper. " + (scopedAnswer ? "Output only the specified public JSON answer.\n" : "Output only the final answer as the candidate in first person.\n") + (question.taskDescriptor?.answerPromptPolicy ?? ""),
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180,
            responseSchema: scopedAnswer ? LocalQwenAnswerParser.scopedResponseSchema : nil,
            responseSchemaPropertyOrder: scopedAnswer ? LocalQwenAnswerParser.scopedPropertyOrder : nil
        )
    }

    private func groundedLocalQwenRecoveryRequest(
        question: DetectedQuestion,
        context: RetrievedContext,
        modelName: String,
        previousQuestionContext: String?,
        scopedAnswer: Bool
    ) -> LocalLLMRequest {
        let previousContext = previousQuestionContext
            .map { "Previous answered question for pronoun resolution only:\n\($0)" }
            ?? "No previous answered question is available."
        let groundedEvidence = context.boundedPromptText(maxWords: 220)
        let intentGuidance = localQwenRecoveryIntentGuidance(for: question)
        let prompt = """
        /no_think
        Question:
        \(question.questionText)

        Previous question context, only if needed for pronouns:
        \(previousContext)

        Selected candidate, opportunity, and separately labeled task reference material:
        \(groundedEvidence.isEmpty ? "No candidate evidence is available. Do not invent a personal answer." : groundedEvidence)

        Answer the current question directly as the candidate in 1 to 3 concise spoken sentences.
        Use only personal facts supported by the selected profile evidence. Treat opportunity requirements as targets, never as completed achievements.
        Do not invent observations, incidents, metrics, outcomes, or completed experiments that are absent from the selected profile evidence.
        Do not infer mechanisms, tools, or causal links for past personal work. General technical solutions may use domain knowledge and explicit assumptions; no CV is required.
        \(intentGuidance)
        Do not mention this prompt or the reference facts.
        \(scopedAnswer ? "Use the frozen answer language. General explanations do not need a first-person opening.\n" + LocalQwenAnswerParser.scopedOutputInstructions + "\nAnswer the current question now:\n\"\(PromptContextBuilder.redactSecrets(question.questionText))\"" : "Use the frozen answer language and output only the final spoken answer. General explanations do not need a first-person opening.")
        """
        return LocalLLMRequest(
            prompt: prompt,
            systemPrompt: "/no_think You are a concise local interview answer helper. " + (scopedAnswer ? "Output only the specified public JSON answer.\n" : "Output only the final answer as the candidate in first person.\n") + (question.taskDescriptor?.answerPromptPolicy ?? ""),
            modelName: modelName,
            temperature: 0.0,
            numPredict: 220,
            responseSchema: scopedAnswer ? LocalQwenAnswerParser.scopedResponseSchema : nil,
            responseSchemaPropertyOrder: scopedAnswer ? LocalQwenAnswerParser.scopedPropertyOrder : nil
        )
    }

    private func localQwenRecoveryIntentGuidance(for question: DetectedQuestion) -> String {
        if let task = question.taskDescriptor, task.decision != nil {
            return task.answerPromptPolicy
        }
        let lower = question.questionText.lowercased()
        if lower.contains("weakness") || lower.contains("development area") {
            return """
            This asks for a weakness or development area. Name that topic explicitly in the first sentence.
            If the selected candidate evidence does not state a weakness, describe a prospective development priority using conditional or future language instead of inventing a current deficiency or past event.
            Tie the development action and validation method to the selected candidate evidence, without adding unsupported tools, metrics, outcomes, or personal history.
            """
        }
        if lower.contains("support"),
           lower.contains("improve") || lower.contains("develop") || lower.contains("grow") || lower.contains("help") {
            return """
            This asks for a future support preference, not a past achievement or support already received.
            Name the desired support directly, use conditional or future language, and explain how you would use it to identify a gap or validate progress.
            Do not claim that you already received mentoring, feedback, access, training, or an outcome unless the selected candidate evidence explicitly states it.
            """
        }
        switch IntentRouter.answerIntent(for: question.questionText) {
        case .technicalTradeoff:
            return """
            This is a trade-off question. Name the competing constraints, then explicitly state what you would choose, prioritize, recommend, or propose and explain the consequence or rationale.
            """
        case .improvementPlan:
            return """
            This is a future improvement-plan question. Explicitly name the current question topic, state the first priority, give only future actions supported by the selected profile evidence, and explain how success would be validated.
            Do not describe future actions as completed experience. Do not add any number, metric, target, tool, mechanism, or outcome that is not literally present in the selected profile evidence.
            """
        default:
            return ""
        }
    }

}
