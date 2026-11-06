import Foundation
import Testing
@testable import Hireva

@MainActor
struct ProviderConnectionOutcomeTests {
    @Test(arguments: [false, true])
    func negativeProviderResultNeverPublishesAConnectedAction(deepSeekEntry: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = SettingsRepository(database: database)
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        try keychain.saveAPIKey("sk-synthetic-negative-provider-result", account: KeychainConstants.deepSeekAccount)
        let configuration = LLMProviderConfiguration.deepSeekDefault()
        try repository.saveProviderConfiguration(configuration)
        let router = LLMRouter(settingsRepository: repository, clients: [.deepSeek: NegativeSettingsProviderClient()])
        let app = AppState(database: database, llmRouter: router,
            permissionService: HermeticPermissionService(), keychainService: keychain, verificationMocksEnabled: false)
        do {
            if deepSeekEntry { app.testDeepSeekConnection() }
            else { app.testProviderConnection(configuration) }
            let task = try #require(app.providerTestTask)
            await task.value
            let actionID = deepSeekEntry ? ActionID.testDeepSeek : ActionID.provider(ActionID.providerTest, configuration.id)
            let feedback = try #require(app.latestActionFeedback(for: actionID))
            #expect(feedback.kind == .error)
            #expect(feedback.message == "Synthetic provider rejected the connection test.")
            #expect(app.diagnostics.lastProviderName != configuration.name)
            #expect(!app.isTestingConnection)
            #expect(!app.isActionLoading(actionID))
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try database.close()
            throw error
        }
    }
}

private final class NegativeSettingsProviderClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: false, message: "Synthetic provider rejected the connection test.", latencyMS: 1, models: [])
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Negative provider tests do not request answers")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}
