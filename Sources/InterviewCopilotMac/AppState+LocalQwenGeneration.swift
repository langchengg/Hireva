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
        You are a real-time interview helper running locally. Answer as the candidate in first person.
        Output only a concise spoken answer, 1 to 3 sentences. Do not mention CV, JD, RAG, model names, or metadata.
        """
        let userPrompt = promptSnapshot.prompt + "\n\nAnswer the current question now:"
        let localRequest = LocalLLMRequest(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            modelName: modelName,
            temperature: 0.1,
            numPredict: 180
        )

        var cleanedAnswer = ""
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            var answer = ""
            let tokenStream = try await localProvider.generateAnswer(request: localRequest)
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
                break
            }
            if attempt < maxAttempts {
                markProviderOperation("Local Qwen returned an empty stream; retrying once")
                try await Task.sleep(nanoseconds: 150_000_000)
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
}
