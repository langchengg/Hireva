// Provider-facing suggestion generation service.
// This service builds prompts, calls the active LLM router, and parses provider
// output into SuggestionCard values. It must not own AppState UI mutation,
// capture lifecycle, active-generation cancellation, or key storage.

import Foundation

/// Thin service for LLM suggestion calls and response parsing.
///
/// AppState owns when a generation starts and whether its result is still
/// current. This service should remain unaware of live UI state.
final class SuggestionGenerationService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    /// Generates a full JSON-backed suggestion card for one frozen question.
    ///
    /// The question snapshot and prompt metadata are copied onto the card so
    /// alignment checks and DB queries can verify that the visible answer was
    /// produced for the same primary question.
    func generate(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        sessionID: String,
        model: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        customProviderConfig: LLMProviderConfiguration? = nil
    ) async throws -> (card: SuggestionCard, response: LLMChatResult) {
        let prompt = PromptLibrary.suggestionGenerator
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: "Use only the selected local evidence below.",
            jdSummary: "Use only the selected local evidence below.",
            stage: .jsonCard
        )
        let userPrompt = snapshot.prompt + "\n\nGenerate one concise suggestion card. Use only the evidence above."

        let response: LLMChatResult
        if let customConfig = customProviderConfig {
            response = try await llmRouter.chat(
                configuration: customConfig,
                messages: [.system(prompt.text), .user(userPrompt)],
                responseFormat: .jsonObject,
                options: LLMRequestOptions(temperature: 0.2, timeoutInterval: timeoutInterval)
            )
        } else {
            response = try await llmRouter.chatForRealtime(
                messages: [.system(prompt.text), .user(userPrompt)],
                responseFormat: .jsonObject,
                options: LLMRequestOptions(temperature: 0.2, timeoutInterval: timeoutInterval)
            )
        }

        var payload: SuggestionCardPayload

        do {
            payload = try JSONParsing.decodeObject(SuggestionCardPayload.self, from: response.content)
        } catch {
            // Build a parse fallback from provider text. This preserves a
            // visible answer path while downstream alignment still decides
            // whether it can be shown for the current question.
            payload = makeFallbackPayload(from: response.content, error: error)
        }

        let card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: sessionID,
            questionID: question.id,
            strategy: payload.strategy,
            sayFirst: payload.sayFirst,
            keyPoints: payload.keyPoints,
            followUpReady: payload.followUpReady,
            confidence: max(0, min(1, payload.confidence)),
            caution: payload.caution,
            evidenceUsed: payload.evidenceUsed ?? [],
            riskLevel: payload.riskLevel,
            modelName: response.modelName,
            promptVersion: prompt.versionTag,
            providerKind: response.providerKind,
            providerName: response.providerName,
            providerBaseURL: response.baseURL,
            latencyMS: response.latencyMS,
            isLocal: response.isLocal,
            rawJSON: response.content,
            createdAt: Date(),
            questionIntent: snapshot.questionIntent,
            promptQuestionText: snapshot.questionTextSnapshot,
            promptPrimaryQuestion: snapshot.promptPrimaryQuestion,
            promptContainsPreviousQuestion: snapshot.promptContainsPreviousQuestion,
            previousQuestionIncluded: snapshot.previousQuestionIncluded,
            previousQuestionText: snapshot.previousQuestionText,
            contextBleedRisk: snapshot.contextBleedRisk,
            ragChunkIDs: snapshot.ragChunkIDs,
            ragChunkIntents: snapshot.ragChunkIntents,
            promptTokenEstimate: snapshot.promptTokenEstimate,
            promptContextPreview: snapshot.ragChunkPreviews.joined(separator: "\n")
        )
        return (card, response)
    }

    func generateFastSayFirstStream(
        question: DetectedQuestion,
        context: RetrievedContext,
        cvSummary: String,
        jdSummary: String,
        customProviderConfig: LLMProviderConfiguration? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        let systemPrompt = """
        You are a real-time interview helper. Based ONLY on the provided local evidence, generate a natural first-person spoken opening response (1 to 3 concise sentences) that the candidate can say directly out loud.
        
        Strict Constraints:
        - Output ONLY the first-person spoken answer.
        - Do not include any meta-instructions (do not use "Highlight", "Emphasize", "Use", "Mention", "Focus").
        - Speak directly as the candidate (use "I", "my", "I'm" instead of "The candidate", "Highlight...").
        - Absolutely no markdown, no JSON, no LaTeX commands (no braces, backslashes).
        - No mention of "CV", "JD", "RAG", "context", or "evidence".
        - Must be natural, directly sayable, and fluid.
        - The CURRENT QUESTION TO ANSWER in the user prompt is the primary task. Context is subordinate.
        """
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: "",
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: .firstAnswer
        )
        let userPrompt = snapshot.prompt + "\n\nGenerate the single opening answer now:"
        
        let config = try customProviderConfig ?? llmRouter.realtimeConfiguration()
        return try llmRouter.chatStream(
            configuration: config,
            messages: [.system(systemPrompt), .user(userPrompt)],
            responseFormat: .text,
            options: LLMRequestOptions(temperature: 0.1, stream: true)
        )
    }

    func generateFullCard(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        sessionID: String,
        cvSummary: String,
        jdSummary: String,
        customProviderConfig: LLMProviderConfiguration? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> (card: SuggestionCard, response: LLMChatResult) {
        let systemPrompt = """
        You are an AI interview copilot. Generate concise, truthful, glanceable suggestion cards grounded only in the provided CV/JD context. Do not fabricate. Return valid JSON only.

        Truthfulness constraints:
        - Do not invent projects, employers, metrics, publications, degrees, work experience, technologies, results, or claims not supported by the provided CV/JD context.
        - If evidence is missing, say how to answer safely instead of making up an achievement.
        - Keep the output concise enough to glance at during a live interview.
        - Do not produce a long essay.

        Strict Content & Voice Constraints:
        - "say_first" MUST be a natural, fluid, first-person spoken answer that the candidate can say directly out loud (use "I", "my", "I'm").
        - Absolutely NO LaTeX commands, braces, or backslashes in any field.
        - Absolutely NO meta-instructions or instructional verbs like "Highlight...", "Emphasize...", "Use...", "Mention...", "focus on..." in say_first, key_points, follow_up_ready, or caution.
        - Do not mention "CV", "JD", "RAG", "evidence", or "context" in visible candidate answer fields.
        - The CURRENT QUESTION TO ANSWER in the user prompt is the primary task. Context is subordinate.

        Answer Policy & Formatting Guidelines:
        Your output MUST be a valid JSON object matching this schema:
        {
          "strategy": string,
          "say_first": string,
          "key_points": [string],
          "follow_up_ready": [string],
          "confidence": number,
          "caution": string,
          "evidence_used": [string],
          "risk_level": "low" | "medium" | "high"
        }
        """
        
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: transcriptContext,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: .fullAnswer
        )
        let userPrompt = snapshot.prompt + "\n\nGenerate the JSON suggestion card now:"
        
        let config = try customProviderConfig ?? llmRouter.realtimeConfiguration()
        let response = try await llmRouter.chat(
            configuration: config,
            messages: [.system(systemPrompt), .user(userPrompt)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0.2, stream: false, timeoutInterval: timeoutInterval)
        )
        
        var payload: SuggestionCardPayload
        do {
            payload = try JSONParsing.decodeObject(SuggestionCardPayload.self, from: response.content)
        } catch {
            payload = makeFallbackPayload(from: response.content, error: error)
        }
        
        let card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: sessionID,
            questionID: question.id,
            strategy: payload.strategy,
            sayFirst: payload.sayFirst,
            keyPoints: payload.keyPoints,
            followUpReady: payload.followUpReady,
            confidence: max(0, min(1, payload.confidence)),
            caution: payload.caution,
            evidenceUsed: payload.evidenceUsed ?? [],
            riskLevel: payload.riskLevel,
            modelName: response.modelName,
            promptVersion: "optimized-v1",
            providerKind: response.providerKind,
            providerName: response.providerName,
            providerBaseURL: response.baseURL,
            latencyMS: response.latencyMS,
            isLocal: response.isLocal,
            rawJSON: response.content,
            createdAt: Date(),
            questionIntent: snapshot.questionIntent,
            promptQuestionText: snapshot.questionTextSnapshot,
            promptPrimaryQuestion: snapshot.promptPrimaryQuestion,
            promptContainsPreviousQuestion: snapshot.promptContainsPreviousQuestion,
            previousQuestionIncluded: snapshot.previousQuestionIncluded,
            previousQuestionText: snapshot.previousQuestionText,
            contextBleedRisk: snapshot.contextBleedRisk,
            ragChunkIDs: snapshot.ragChunkIDs,
            ragChunkIntents: snapshot.ragChunkIntents,
            promptTokenEstimate: snapshot.promptTokenEstimate,
            promptContextPreview: snapshot.ragChunkPreviews.joined(separator: "\n")
        )
        
        return (card, response)
    }

    func generateFullCardSectionStream(
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        sessionID: String,
        cvSummary: String,
        jdSummary: String,
        customProviderConfig: LLMProviderConfiguration? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        let systemPrompt = """
        You are an AI interview copilot. Generate concise, truthful, glanceable suggestion card sections grounded only in the provided CV/JD context. Do not fabricate.

        Return plain text sections only, using this exact format:
        STRATEGY:
        ...

        SAY_FIRST:
        ...

        KEY_POINTS:
        - ...
        - ...
        - ...

        FOLLOW_UP_READY:
        - ...
        - ...

        CAUTION:
        ...

        Rules:
        - Stream the sections in order.
        - Keep SAY_FIRST first-person and directly speakable.
        - Keep each key point short.
        - Do not use JSON, markdown fences, source IDs, scores, diagnostics, or raw CV/JD formatting.
        - Do not mention "CV", "JD", "RAG", "context", or "evidence" in visible candidate fields.
        - If evidence is missing, say how to answer safely.
        - Absolutely no LaTeX commands, braces, or backslashes.
        - The CURRENT QUESTION TO ANSWER in the user prompt is the primary task. Context is subordinate.
        """
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: RealtimePromptBudgeter.limitTranscript(transcriptContext),
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            stage: .sectionStream
        )
        let userPrompt = snapshot.prompt + "\n\nStream the section response now."

        let config = try customProviderConfig ?? llmRouter.realtimeConfiguration()
        return try llmRouter.chatStream(
            configuration: config,
            messages: [.system(systemPrompt), .user(userPrompt)],
            responseFormat: .text,
            options: LLMRequestOptions(temperature: 0.2, stream: true, timeoutInterval: 15.0)
        )
    }

    private func makeFallbackPayload(from rawText: String, error: Error) -> SuggestionCardPayload {
        let cleanedText = rawText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        let sentences = cleanedText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            
        let sayFirst: String
        if !sentences.isEmpty {
            let firstTwo = sentences.prefix(2).joined(separator: ". ") + "."
            sayFirst = firstTwo
        } else {
            sayFirst = ""
        }
        
        var keyPoints: [String] = []
        let lines = cleanedText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") {
                let point = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !point.isEmpty {
                    keyPoints.append(point)
                }
            }
        }
        
        if keyPoints.isEmpty {
            keyPoints = sentences.suffix(max(0, sentences.count - 2)).map { $0 + "." }
        }
        if keyPoints.count > 4 {
            keyPoints = Array(keyPoints.prefix(4))
        }
        if keyPoints.isEmpty {
            keyPoints = []
        }
        
        return SuggestionCardPayload(
            strategy: "Direct Answer",
            sayFirst: sayFirst,
            keyPoints: keyPoints,
            followUpReady: [],
            confidence: 0.5,
            caution: "Generated from non-JSON model output. Original error: \(error.localizedDescription)",
            evidenceUsed: [],
            riskLevel: .medium
        )
    }
}
