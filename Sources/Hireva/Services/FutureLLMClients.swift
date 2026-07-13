import Foundation

final class OpenAILLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .openAI

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        throw LLMProviderError.notConfigured("OpenAI")
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("OpenAI")
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}

final class AnthropicLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .anthropic

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        throw LLMProviderError.notConfigured("Anthropic")
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Anthropic")
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}

final class GeminiLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .gemini

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        throw LLMProviderError.notConfigured("Gemini")
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Gemini")
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}
