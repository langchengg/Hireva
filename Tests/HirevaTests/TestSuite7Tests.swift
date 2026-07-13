import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct TestSuite7Tests {
    @Test
    @MainActor
    func testSuite7_APIProviderSwitchingAndEmbeddingSettings() async throws {
        let database = try makeTemporaryDatabase()
        let settingsRepo = SettingsRepository(database: database)
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        let router = LLMRouter(settingsRepository: settingsRepo, clients: [
            .deepSeek: FakeLLMClient(kind: .deepSeek),
            .openAICompatible: FakeLLMClient(kind: .openAICompatible)
        ])
        let appState = AppState(database: database, llmRouter: router, keychainService: keychain)

        _ = try settingsRepo.ensureDefaultProviderConfigurations()
        appState.refreshAll()

        let initialRealtime = try #require(appState.activeRealtimeProvider)
        let initialRecap = try #require(appState.activeRecapProvider)
        #expect(initialRealtime.kind == .deepSeek)
        #expect(initialRecap.kind == .deepSeek)
        #expect(!appState.providerConfigurations.contains { $0.kind == .ollamaLocal })

        var custom = LLMProviderConfiguration.openAICompatibleDefault()
        custom.id = UUID()
        custom.name = "Custom API"
        custom.baseURL = "https://api.example.test/v1"
        custom.model = "custom-chat-model"
        custom.apiKeyAccount = "custom.suite7"
        appState.saveProviderConfiguration(custom)

        appState.updateActiveRealtimeProvider(provider: custom, model: nil)
        #expect(appState.activeRealtimeProvider?.kind == .deepSeek)
        #expect(appState.lastProviderSwitchError?.contains("Missing API Key") == true)

        appState.saveAPIKey("sk-suite7-custom-key", for: custom)
        appState.updateActiveRealtimeProvider(provider: custom, model: "custom-chat-model")
        #expect(appState.activeRealtimeProvider?.kind == .openAICompatible)
        #expect(appState.activeRealtimeProvider?.model == "custom-chat-model")
        #expect(appState.activeRecapProvider?.kind == .deepSeek)

        var settings = appState.settings
        settings.enableVectorRAG = true
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingBaseURL = "https://embeddings.example.test/v1"
        settings.embeddingModelName = "text-embedding-3-small"
        settings.embeddingApiKeyAccount = KeychainConstants.defaultEmbeddingAccount
        settings.embeddingDimension = 1536
        appState.saveSettings(settings)
        appState.saveEmbeddingAPIKey("embed-suite7-key", account: KeychainConstants.defaultEmbeddingAccount)

        #expect(appState.embeddingKeyStatus(account: KeychainConstants.defaultEmbeddingAccount) == "****-key")
        #expect(appState.settings.embeddingProviderKind == .openAICompatibleCloud)
        #expect(appState.settings.embeddingBaseURL != "http://localhost:11434")
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestSuite7Database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
