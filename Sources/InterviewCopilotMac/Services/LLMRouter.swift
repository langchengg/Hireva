import Foundation

final class LLMRouter {
    private let settingsRepository: SettingsRepository
    private let clients: [LLMProviderKind: any LLMClientProtocol]

    init(settingsRepository: SettingsRepository, clients: [LLMProviderKind: any LLMClientProtocol]) {
        self.settingsRepository = settingsRepository
        self.clients = clients
    }

    convenience init(settingsRepository: SettingsRepository, apiKeyStore: APIKeyStore) {
        self.init(
            settingsRepository: settingsRepository,
            clients: [
                .ollamaLocal: OllamaLLMClient(),
                .deepSeek: DeepSeekLLMClient(apiKeyStore: apiKeyStore),
                .openAICompatible: OpenAICompatibleLLMClient(apiKeyStore: apiKeyStore),
                .openAI: OpenAILLMClient(),
                .anthropic: AnthropicLLMClient(),
                .gemini: GeminiLLMClient()
            ]
        )
    }

    func realtimeConfiguration() throws -> LLMProviderConfiguration {
        try settingsRepository.ensureDefaultProviderConfigurations()
        guard let configuration = try settingsRepository.activeRealtimeProvider() else {
            throw LLMProviderError.notConfigured("Realtime LLM provider")
        }
        return configuration
    }

    func recapConfiguration() throws -> LLMProviderConfiguration {
        try settingsRepository.ensureDefaultProviderConfigurations()
        guard let configuration = try settingsRepository.activeRecapProvider() else {
            throw LLMProviderError.notConfigured("Recap LLM provider")
        }
        return configuration
    }

    func realtimeClient() async throws -> any LLMClientProtocol {
        try client(for: realtimeConfiguration())
    }

    func recapClient() async throws -> any LLMClientProtocol {
        try client(for: recapConfiguration())
    }

    func chatForRealtime(
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let configuration = try realtimeConfiguration()
        return try await client(for: configuration).chatCompletion(
            configuration: configuration,
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
    }

    func chatForRecap(
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let configuration = try recapConfiguration()
        return try await client(for: configuration).chatCompletion(
            configuration: configuration,
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
    }

    func chat(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        try await client(for: configuration).chatCompletion(
            configuration: configuration,
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
    }

    func testProvider(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        try await client(for: configuration).testConnection(configuration: configuration)
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        try await client(for: configuration).listModels(configuration: configuration)
    }

    private func client(for configuration: LLMProviderConfiguration) throws -> any LLMClientProtocol {
        guard let client = clients[configuration.kind] else {
            throw LLMProviderError.notConfigured(configuration.kind.displayName)
        }
        return client
    }
}
