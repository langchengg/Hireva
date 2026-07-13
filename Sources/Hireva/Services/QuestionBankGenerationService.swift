import Foundation

final class QuestionBankGenerationService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func generate(prompt: String, provider: LLMProviderConfiguration? = nil) async throws -> LLMChatResult {
        if let provider {
            return try await llmRouter.chat(
                configuration: provider,
                messages: [.system("Generate a concise interview question bank grounded in the provided role context."), .user(prompt)],
                responseFormat: nil,
                options: LLMRequestOptions(temperature: 0.3)
            )
        }
        return try await llmRouter.chatForRecap(
            messages: [.system("Generate a concise interview question bank grounded in the provided role context."), .user(prompt)],
            responseFormat: nil,
            options: LLMRequestOptions(temperature: 0.3)
        )
    }
}
