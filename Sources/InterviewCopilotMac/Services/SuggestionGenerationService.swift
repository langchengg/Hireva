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
        model: String? = nil
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

        let response = try await llmRouter.chatForRealtime(
            messages: [.system(prompt.text), .user(userPrompt)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0.2)
        )
        let payload = try JSONParsing.decodeObject(SuggestionCardPayload.self, from: response.content)
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
}
