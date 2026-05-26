import Foundation

final class QuestionDetectionService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func detect(
        transcriptContext: String,
        sessionID: String,
        transcriptSegmentID: String?,
        model: String? = nil
    ) async throws -> (question: DetectedQuestion, response: LLMChatResult) {
        let prompt = PromptLibrary.questionDetector
        let userPrompt = """
        Recent transcript:
        \(ContextBudgeter.limitWords(transcriptContext, maxWords: 800))

        Decide whether the interviewer has asked a complete question or prompt that the candidate should answer now.
        """

        let response = try await llmRouter.chatForRealtime(
            messages: [.system(prompt.text), .user(userPrompt)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0.0)
        )
        let payload = try JSONParsing.decodeObject(QuestionDetectionPayload.self, from: response.content)
        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: sessionID,
            transcriptSegmentID: transcriptSegmentID,
            questionText: payload.questionText,
            intent: payload.intent,
            answerStrategy: payload.answerStrategy,
            confidence: max(0, min(1, payload.confidence)),
            reason: payload.reason,
            shouldTrigger: payload.shouldTrigger,
            questionComplete: payload.questionComplete,
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
        return (question, response)
    }
}
