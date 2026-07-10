import Foundation

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
        fallbackReason: String?
    ) async throws -> Bool {
        guard isActiveGeneration(generationID, questionID: question.id) else {
            recordStaleGenerationDiscard()
            return false
        }

        let modelName = selectedQwenModelName
        let promptSnapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: RealtimePromptBudgeter.limitTranscript(transcript),
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: .firstAnswer
        )
        let systemPrompt = """
        /no_think
        You are a real-time interview helper running locally. Answer as the candidate in first person.
        Output only a concise spoken answer, 1 to 3 sentences. Do not mention CV, JD, RAG, model names, or metadata.
        """
        let phdGuidance = phdPromptGuidance(for: question.questionText)
        let userPrompt = promptSnapshot.prompt +
            (phdGuidance.isEmpty ? "" : "\n\n\(phdGuidance)") +
            "\n\nAnswer the current question now:"
        let primaryRequest = LocalLLMRequest(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180
        )
        let previousQuestionContext = localQwenPreviousQuestionContext(excluding: question)
        let compactRecoveryRequest = compactLocalQwenRequest(
            question: question,
            context: context,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            modelName: modelName,
            previousQuestionContext: previousQuestionContext
        )
        let groundedRecoveryRequest = groundedLocalQwenRecoveryRequest(
            question: question,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            modelName: modelName,
            previousQuestionContext: previousQuestionContext
        )

        var cleanedAnswer = ""
        let requests = [primaryRequest, compactRecoveryRequest, groundedRecoveryRequest]
        for requestIndex in requests.indices {
            let request = requests[requestIndex]
            let maxAttempts = requestIndex == 0 ? 2 : 1
            for attempt in 1...maxAttempts {
                var answer = ""
                let tokenStream = try await localProvider.generateAnswer(request: request)
                for try await token in tokenStream {
                    guard isActiveGeneration(generationID, questionID: question.id), !Task.isCancelled else {
                        recordStaleGenerationDiscard()
                        return false
                    }
                    answer += token.text
                }

                cleanedAnswer = AnswerQualityValidator.localCleanupAnswer(answer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedAnswer.isEmpty {
                    guard isUsableLocalQwenAnswer(cleanedAnswer, question: question) else {
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
            throw LLMProviderError.emptyResponse(providerName: "Ollama Qwen")
        }

        let elapsed = elapsedMS(since: requestStart)
        let isFallback = fallbackReason != nil
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        var card = SuggestionCard(
            id: cardID,
            sessionID: session.id,
            questionID: question.id,
            strategy: isFallback ? "Local Qwen Fallback" : "Local Qwen Primary",
            sayFirst: cleanedAnswer,
            keyPoints: localQwenKeyPoints(from: cleanedAnswer, fallback: fallback.keyPoints),
            followUpReady: ["I can expand on the implementation tradeoffs if useful."],
            confidence: 0.72,
            caution: fallbackReason.map { "Local Qwen fallback used because \($0)." },
            evidenceUsed: retrievedChunks.map(\.id),
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

        guard displaySuggestionIfAligned(
            card,
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            source: source,
            speaker: speaker
        ) else {
            return false
        }

        streamedSayFirst = ""
        currentSuggestionSetAt = currentSuggestionSetAt ?? Date()
        finalVisibleSource = AnswerSource.ollamaQwen.rawValue
        softFallbackUsed = isFallback
        softFallbackLatencyMS = isFallback ? elapsed : nil
        softFallbackShownAt = isFallback ? (softFallbackShownAt ?? Date()) : softFallbackShownAt
        markFirstVisibleAnswer(generationID: generationID, fallback: isFallback)
        return finishGenerationWithVisibleCard(
            currentSuggestion ?? card,
            generationID: generationID,
            question: question,
            session: session,
            requestStart: requestStart,
            retrievedChunks: retrievedChunks,
            triggerPath: triggerPath,
            timedOut: false
        )
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

    private func isUsableLocalQwenAnswer(_ answer: String, question: DetectedQuestion) -> Bool {
        guard !QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer),
              QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(answer) == nil else {
            return false
        }
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question.questionText,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true
        )
        guard alignment.verdict == .aligned else { return false }
        if interviewContextMode == .phdRobotics,
           PhDInterviewRubricPolicy.rubric(for: question.questionText) != nil {
            return PhDInterviewRubricPolicy.evaluate(question: question.questionText, answer: answer).passed
        }
        return true
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

        \(phdPromptGuidance(for: question.questionText))

        Answer the current question directly as the candidate in 1 to 3 concise spoken sentences.
        Use the conversation context only to resolve pronouns such as it, that, or this.
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
        cvSummary: String,
        jdSummary: String,
        modelName: String,
        previousQuestionContext: String?
    ) -> LocalLLMRequest {
        let fallback = AnswerRelevancePolicy.fallbackAnswer(for: question)
        let previousContext = previousQuestionContext
            .map { "Previous answered question for pronoun resolution only:\n\($0)" }
            ?? "No previous answered question is available."
        let projectFacts = ([fallback.sayFirst] + fallback.keyPoints)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n- ")
        let prompt = """
        /no_think
        Question:
        \(question.questionText)

        Previous question context, only if needed for pronouns:
        \(previousContext)

        Project facts to ground the answer:
        - \(projectFacts.isEmpty ? "LeoRover used perception, localization, navigation, and manipulation handoffs." : projectFacts)

        \(phdPromptGuidance(for: question.questionText))

        Answer the current question directly as the candidate in 1 to 3 concise spoken sentences.
        Use concrete robotics terms from the project facts, especially localization, manipulation, handoff reliability, validation, timing, or recovery when relevant.
        Do not say that context is missing. Do not mention this prompt or the reference facts.
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

    private func phdPromptGuidance(for question: String) -> String {
        guard interviewContextMode == .phdRobotics else { return "" }
        return PhDInterviewRubricPolicy.promptGuidance(for: question)
    }
}
