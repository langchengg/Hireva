import Foundation

final class RoleFitAnalyzer {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func analyze(prompt: String, provider: LLMProviderConfiguration? = nil) async throws -> LLMChatResult {
        if let provider {
            return try await llmRouter.chat(
                configuration: provider,
                messages: [.system("Analyze candidate-role fit truthfully."), .user(prompt)],
                responseFormat: nil,
                options: LLMRequestOptions(temperature: 0.2)
            )
        }
        return try await llmRouter.chatForRecap(
            messages: [.system("Analyze candidate-role fit truthfully."), .user(prompt)],
            responseFormat: nil,
            options: LLMRequestOptions(temperature: 0.2)
        )
    }
}
