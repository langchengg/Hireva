import Foundation

struct LocalQuestionHeuristicResult {
    let shouldTrigger: Bool
    let confidence: Double
    let reason: String
}

final class QuestionDetectionService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func isLikelyQuestion(_ text: String) -> LocalQuestionHeuristicResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return LocalQuestionHeuristicResult(shouldTrigger: false, confidence: 0.0, reason: "Empty text")
        }
        
        if trimmed.contains("?") {
            return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.95, reason: "Contains question mark")
        }
        
        // Professional interview prompts
        let prompts = [
            "walk me through",
            "tell me about",
            "give me an example",
            "talk about",
            "describe",
            "explain",
            "elaborate",
            "let's discuss",
            "let’s discuss",
            "i'd like to hear about",
            "i’d like to hear about"
        ]
        
        for prompt in prompts {
            if trimmed.hasPrefix(prompt) || trimmed.contains(" " + prompt) {
                return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.9, reason: "Matches interview prompt: '\(prompt)'")
            }
        }
        
        // Typical question starter words
        let starters = [
            "what", "how", "why", "where", "who", "when", 
            "can you", "could you", "would you", "should you",
            "are you", "do you", "have you", "is there"
        ]
        
        for starter in starters {
            if trimmed.hasPrefix(starter) || trimmed.contains(" " + starter) {
                return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.85, reason: "Matches question starter: '\(starter)'")
            }
        }
        
        return LocalQuestionHeuristicResult(shouldTrigger: false, confidence: 0.0, reason: "No question markers found")
    }

    func detect(
        transcriptContext: String,
        sessionID: String,
        transcriptSegmentID: String?,
        model: String? = nil
    ) async throws -> (question: DetectedQuestion, response: LLMChatResult) {
        let heuristic = isLikelyQuestion(transcriptContext)
        if !heuristic.shouldTrigger {
            let question = DetectedQuestion(
                id: UUID().uuidString,
                sessionID: sessionID,
                transcriptSegmentID: transcriptSegmentID,
                questionText: "",
                intent: .unclear,
                answerStrategy: .directAnswer,
                confidence: 0.0,
                reason: "Bypassed by local question heuristics: \(heuristic.reason)",
                shouldTrigger: false,
                questionComplete: false,
                modelName: "local-heuristic",
                promptVersion: "local-v1",
                providerKind: .ollamaLocal,
                providerName: "LocalHeuristic",
                providerBaseURL: "",
                latencyMS: 0,
                isLocal: true,
                rawJSON: nil,
                createdAt: Date()
            )
            return (question, LLMChatResult(
                content: "{}",
                modelName: "local-heuristic",
                providerKind: .ollamaLocal,
                providerName: "LocalHeuristic",
                baseURL: "",
                latencyMS: 0,
                isLocal: true,
                rawResponse: nil
            ))
        }

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
