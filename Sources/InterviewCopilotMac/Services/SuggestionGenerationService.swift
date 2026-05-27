import Foundation

final class SuggestionGenerationService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

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
        let userPrompt = """
        Detected question:
        \(question.questionText)

        Intent: \(question.intent.rawValue)
        Answer strategy: \(question.answerStrategy.rawValue)

        Local evidence:
        \(context.promptText.isEmpty ? "No matching CV/JD chunks were found. Say how to answer safely without fabricating." : context.promptText)

        Recent transcript:
        \(ContextBudgeter.limitWords(transcriptContext, maxWords: 800))

        Generate one concise suggestion card. Use only the evidence above.
        """

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
            await MainActor.run {
                OllamaDiagnostics.shared.jsonParseSuccess = true
                OllamaDiagnostics.shared.jsonParseFailureReason = nil
                OllamaDiagnostics.shared.fallbackCardUsed = false
            }
        } catch {
            let localFailureReason = error.localizedDescription
            
            // Build fallback payload
            payload = makeFallbackPayload(from: response.content, error: error)
            
            await MainActor.run {
                OllamaDiagnostics.shared.jsonParseSuccess = false
                OllamaDiagnostics.shared.jsonParseFailureReason = localFailureReason
                OllamaDiagnostics.shared.fallbackCardUsed = true
            }
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
            createdAt: Date()
        )
        return (card, response)
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
            sayFirst = "To answer this, focus on explaining key requirements and relevant experience."
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
            keyPoints = ["Refer to CV experiences details.", "Grasp core requirements in the JD."]
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
