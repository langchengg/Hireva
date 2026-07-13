import Foundation

final class RecapGenerationService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func generate(
        session: InterviewSession,
        transcript: [TranscriptSegment],
        context: RetrievedContext,
        model: String? = nil
    ) async throws -> (recap: RecapReport, response: LLMChatResult) {
        let prompt = PromptLibrary.recap
        let transcriptText = ContextBudgeter.limitWords(
            transcript.map { "\($0.speaker.displayName): \($0.text)" }.joined(separator: "\n"),
            maxWords: 2_000
        )
        let userPrompt = """
        Session title: \(session.title)

        Relevant local evidence:
        \(context.promptText)

        Transcript:
        \(transcriptText)
        """

        let response = try await llmRouter.chatForRecap(
            messages: [.system(prompt.text), .user(userPrompt)],
            responseFormat: nil,
            options: LLMRequestOptions(temperature: 0.3)
        )
        return (
            RecapReport(
                id: UUID().uuidString,
                sessionID: session.id,
                markdown: response.content,
                modelName: response.modelName,
                promptVersion: prompt.versionTag,
                providerKind: response.providerKind,
                providerName: response.providerName,
                providerBaseURL: response.baseURL,
                latencyMS: response.latencyMS,
                isLocal: response.isLocal,
                createdAt: Date()
            ),
            response
        )
    }
}
