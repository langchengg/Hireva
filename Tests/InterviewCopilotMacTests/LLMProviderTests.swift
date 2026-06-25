import Foundation
import Security
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct LLMProviderTests {
    @Test
    func providerConfigurationStorageCreatesDefaultsAndActiveSelections() throws {
        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)

        let providers = try repository.ensureDefaultProviderConfigurations()
        let realtime = try #require(try repository.activeRealtimeProvider())
        let recap = try #require(try repository.activeRecapProvider())

        #expect(providers.contains { $0.kind == .deepSeek && $0.apiKeyAccount == "deepseek.default" })
        #expect(providers.contains { $0.kind == .openAICompatible })
        #expect(!providers.contains { $0.kind == .ollamaLocal })
        #expect(!providers.contains { $0.baseURL.contains("localhost:11434") })
        #expect(realtime.kind == .deepSeek)
        #expect(recap.kind == .deepSeek)
    }

    @Test
    func appSettingsDefaultsDisableLocalEmbeddings() throws {
        let settings = AppSettings.default

        #expect(settings.embeddingProviderKind == .disabled)
        #expect(settings.embeddingModelName != "nomic-embed-text")
        #expect(settings.embeddingBaseURL != "http://localhost:11434")
        #expect(settings.enableVectorRAG == false)
    }

    @Test
    func legacyLocalProviderRowsAreHiddenAndActiveSelectionMigratesToDeepSeek() throws {
        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let legacyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let now = DateCoding.string(from: Date())

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO llm_provider_configurations (
                    id, name, kind, base_url, model, api_key_account,
                    is_default_for_realtime, is_default_for_recap, supports_json_mode,
                    supports_streaming, supports_thinking, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    legacyID.uuidString,
                    "Local Ollama",
                    LLMProviderKind.ollamaLocal.rawValue,
                    "http://localhost:11434",
                    "gemma4:26b",
                    nil,
                    true,
                    true,
                    true,
                    true,
                    false,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO app_settings (key, value, updated_at)
                VALUES ('active_realtime_provider_id', ?, ?), ('active_recap_provider_id', ?, ?)
                """,
                arguments: [legacyID.uuidString, now, legacyID.uuidString, now]
            )
        }

        let providers = try repository.ensureDefaultProviderConfigurations()
        let realtime = try #require(try repository.activeRealtimeProvider())
        let recap = try #require(try repository.activeRecapProvider())
        let legacyRows = try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM llm_provider_configurations WHERE kind = ?",
                arguments: [LLMProviderKind.ollamaLocal.rawValue]
            ) ?? 0
        }

        #expect(legacyRows == 1)
        #expect(!providers.contains { $0.kind == .ollamaLocal })
        #expect(!providers.contains { $0.baseURL.contains("localhost:11434") })
        #expect(try repository.providerConfiguration(id: legacyID) == nil)
        #expect(realtime.kind == .deepSeek)
        #expect(recap.kind == .deepSeek)
    }

    @Test
    func legacyEmbeddingSettingsJSONIsMigratedAwayFromLocalProviderValues() throws {
        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let now = DateCoding.string(from: Date())
        let legacyJSON = """
        {
          "embeddingProviderKind": "localOllama",
          "embeddingBaseURL": "http://localhost:11434",
          "embeddingModelName": "nomic-embed-text",
          "embeddingApiKeyAccount": "embedding.default",
          "ollamaRequestTimeoutSeconds": 120
        }
        """

        try database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, value, updated_at) VALUES ('app_settings', ?, ?)",
                arguments: [legacyJSON, now]
            )
        }

        let settings = try repository.loadSettings()
        let rewritten = try #require(try database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = 'app_settings'")
        })

        #expect(settings.embeddingProviderKind == .disabled)
        #expect(settings.embeddingModelName == "text-embedding-3-small")
        #expect(settings.generationRequestTimeoutSeconds == 120)
        #expect(!rewritten.contains("localOllama"))
        #expect(!rewritten.contains("nomic-embed-text"))
        #expect(!rewritten.contains("localhost:11434"))
        #expect(!rewritten.contains("ollamaRequestTimeoutSeconds"))
        #expect(rewritten.contains("generationRequestTimeoutSeconds"))
    }

    @Test
    func openAICompatibleMissingAPIKeyReturnsProviderError() async {
        let keyStore = InMemoryAPIKeyStore()
        let client = OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: makeMockSession())
        var configuration = LLMProviderConfiguration.openAICompatibleDefault()
        configuration.name = "Custom API"
        configuration.apiKeyAccount = "custom.test"

        await #expect(throws: LLMProviderError.missingAPIKey(providerName: configuration.name)) {
            _ = try await client.chatCompletion(
                configuration: configuration,
                messages: [.user("Hi")],
                responseFormat: .jsonObject,
                options: .default
            )
        }
    }

    @Test
    func openAICompatibleRequestAppliesConfiguredTimeout() throws {
        let keyStore = InMemoryAPIKeyStore()
        try keyStore.saveAPIKey("sk-timeout-test", account: "custom.test")
        let client = OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: makeMockSession())
        let configuration = configuredOpenAICompatibleProvider()

        let request = try client.makeURLRequest(
            configuration: configuration,
            messages: [.user("Hi")],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(timeoutInterval: 2.75)
        )

        #expect(request.timeoutInterval == 2.75)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-timeout-test")
    }

    @Test
    func openAICompatibleMapsHTTPFailuresToProviderErrors() async throws {
        let cases: [(Int, LLMProviderError)] = [
            (401, .invalidAPIKey(providerName: "Custom API")),
            (403, .invalidAPIKey(providerName: "Custom API")),
            (429, .rateLimited(providerName: "Custom API")),
            (500, .serverError(providerName: "Custom API", statusCode: 500, body: #"{"error":"server"}"#))
        ]

        for (statusCode, expectedError) in cases {
            MockURLProtocol.handlers = [
                "https://openai-compatible.test": { request in
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(#"{"error":"server"}"#.utf8))
                }
            ]

            let (client, configuration) = try makeConfiguredOpenAICompatibleClient()
            do {
                _ = try await client.chatCompletion(
                    configuration: configuration,
                    messages: [.user("Hi")],
                    responseFormat: .jsonObject,
                    options: .default
                )
                Issue.record("Expected provider error for HTTP \(statusCode).")
            } catch let error as LLMProviderError {
                #expect(error == expectedError)
            } catch {
                Issue.record("Expected LLMProviderError, got \(error).")
            }
        }
    }

    @Test
    func openAICompatibleMapsNetworkAndMalformedResponsesToVisibleErrors() async throws {
        MockURLProtocol.handlers = [
            "https://openai-compatible.test": { _ in
                throw URLError(.notConnectedToInternet)
            }
        ]
        var configured = try makeConfiguredOpenAICompatibleClient()

        do {
            _ = try await configured.client.chatCompletion(
                configuration: configured.configuration,
                messages: [.user("Hi")],
                responseFormat: .jsonObject,
                options: .default
            )
            Issue.record("Expected network failure.")
        } catch let error as LLMProviderError {
            guard case .networkFailure(let providerName, let message) = error else {
                Issue.record("Expected networkFailure, got \(error).")
                return
            }
            #expect(providerName == "Custom API")
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected LLMProviderError, got \(error).")
        }

        MockURLProtocol.handlers = [
            "https://openai-compatible.test": { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("not-json".utf8))
            }
        ]
        configured = try makeConfiguredOpenAICompatibleClient()

        await #expect(throws: LLMProviderError.invalidResponse("Could not decode OpenAI-compatible chat response.")) {
            _ = try await configured.client.chatCompletion(
                configuration: configured.configuration,
                messages: [.user("Hi")],
                responseFormat: .jsonObject,
                options: .default
            )
        }
    }

    @Test
    func routerUsesActiveRealtimeProviderConfiguration() async throws {
        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let providers = try repository.ensureDefaultProviderConfigurations()
        let deepSeek = try #require(providers.first { $0.kind == .deepSeek })
        try repository.setActiveRealtimeProvider(id: deepSeek.id)

        let fake = FakeLLMClient(kind: .deepSeek)
        let router = LLMRouter(settingsRepository: repository, clients: [.deepSeek: fake])

        let result = try await router.chatForRealtime(
            messages: [.user("Hello")],
            responseFormat: .jsonObject,
            options: .default
        )

        #expect(result.providerKind == .deepSeek)
        #expect(result.modelName == deepSeek.model)
        #expect(fake.lastConfiguration?.id == deepSeek.id)
    }

    @Test
    @MainActor
    func quickSwitcherRejectsMissingCloudKeyAndAllowsConfiguredProvider() async throws {
        let database = try makeTemporaryDatabase()
        let settingsRepo = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settingsRepo, apiKeyStore: keychain)

        let appState = AppState(database: database, llmRouter: router, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        _ = try settingsRepo.ensureDefaultProviderConfigurations()
        appState.refreshAll()

        let initialRealtime = try #require(appState.activeRealtimeProvider)
        #expect(initialRealtime.kind == .deepSeek)

        var customProvider = LLMProviderConfiguration.openAICompatibleDefault()
        customProvider.id = UUID()
        customProvider.name = "Custom API"
        customProvider.baseURL = "https://api.example.test/v1"
        customProvider.model = "api-model"
        customProvider.apiKeyAccount = "custom.test"
        appState.saveProviderConfiguration(customProvider)

        appState.updateActiveRealtimeProvider(provider: customProvider, model: nil)
        #expect(appState.activeRealtimeProvider?.kind == .deepSeek)
        #expect(appState.lastProviderSwitchError?.contains("Missing API Key") == true)

        appState.saveAPIKey("sk-test-key-1234", for: customProvider)
        appState.updateActiveRealtimeProvider(provider: customProvider, model: nil)
        #expect(appState.activeRealtimeProvider?.kind == .openAICompatible)
        #expect(appState.activeRealtimeProvider?.model == "api-model")
        #expect(appState.lastProviderSwitchError == nil)
    }

    @Test
    @MainActor
    func keychainDiagnosticsAndKeyMasking() throws {
        #expect(KeychainService.maskKey("sk-abcdef123456") == "sk-****3456")
        #expect(KeychainService.maskKey("my-other-secret-key-1234") == "****1234")
        #expect(KeychainService.maskKey("short") == "****hort")
        #expect(KeychainService.maskKey("") == "None")
        #expect(KeychainService.keyLengthCategory("") == "empty")
        #expect(KeychainService.keyLengthCategory("sk-short") == "short")
        #expect(KeychainService.keyLengthCategory("sk-abcdefghijklmnopqrstuvwxyz") == "present")

        let mockStore = InMemoryMockKeychainStore()
        let keychain = KeychainService(store: mockStore)

        try keychain.saveAPIKey("sk-test-key-123", account: "deepseek.default")
        #expect(keychain.hasAPIKey(account: "deepseek.default") == true)
        #expect(keychain.lastWriteStatus == "Success")

        let loaded = try keychain.loadAPIKey(account: "deepseek.default")
        #expect(loaded == "sk-test-key-123")
        #expect(keychain.lastReadStatus == "Success")

        try keychain.deleteAPIKey(account: "deepseek.default")
        #expect(keychain.hasAPIKey(account: "deepseek.default") == false)
        #expect(keychain.lastWriteStatus == "Deleted")
    }

    @Test
    @MainActor
    func settingsSavedDeepSeekKeyMakesProductStatusConfigured() throws {
        let database = try makeTemporaryDatabase()
        let settingsRepo = SettingsRepository(database: database)
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        let router = LLMRouter(settingsRepository: settingsRepo, apiKeyStore: keychain)
        let appState = AppState(database: database, llmRouter: router, keychainService: keychain)
        appState.refreshAll()

        let deepSeek = try #require(appState.providerConfigurations.first { $0.kind == .deepSeek })
        #expect(deepSeek.apiKeyAccount == KeychainConstants.deepSeekAccount)
        #expect(appState.deepSeekProviderConfigured)
        #expect(appState.deepSeekCredentialSource == "Keychain")
        #expect(appState.deepSeekConfigured == false)
        #expect(appState.keychainDeepSeekKeyExists == false)
        #expect(appState.keychainDeepSeekKeyLengthCategory == "empty")
        #expect(appState.lastProviderConfigError == "missing_keychain_credential")

        appState.saveAPIKey("sk-abcdefghijklmnopqrstuvwxyz", for: deepSeek)

        #expect(appState.deepSeekConfigured)
        #expect(appState.keychainDeepSeekKeyExists)
        #expect(appState.keychainDeepSeekKeyLengthCategory == "present")
        #expect(appState.lastProviderConfigError == "none")
        #expect(appState.activeRealtimeProvider?.kind == .deepSeek)
        #expect(try keychain.loadAPIKey(account: KeychainConstants.deepSeekAccount)?.isEmpty == false)
    }

    @Test
    func legacyDeepSeekKeychainItemMigratesToCanonicalAccount() throws {
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data("sk-legacy-abcdefghijklmnopqrstuvwxyz".utf8),
            service: "com.langcheng.InterviewCopilotMac",
            account: "DeepSeekAPIKey"
        )
        let keychain = KeychainService(store: store)

        keychain.performMigrationIfNeeded()

        #expect(keychain.legacyItemFound)
        #expect(keychain.legacyItemCount == 1)
        #expect(keychain.migrationPerformed)
        #expect(keychain.hasAPIKey(account: KeychainConstants.deepSeekAccount))
        #expect(try keychain.loadAPIKey(account: KeychainConstants.deepSeekAccount)?.isEmpty == false)
        #expect(try store.loadGenericPassword(service: "com.langcheng.InterviewCopilotMac", account: "DeepSeekAPIKey") != nil)
    }

    @Test
    func generationRequestUsesSameDeepSeekCredentialAccountAsSettings() throws {
        final class TrackingAPIKeyStore: APIKeyStore {
            var requestedAccounts: [String] = []

            func saveAPIKey(_ apiKey: String, account: String) throws {}
            func deleteAPIKey(account: String) throws {}

            func loadAPIKey(account: String) throws -> String? {
                requestedAccounts.append(account)
                return "sk-generation-abcdefghijklmnopqrstuvwxyz"
            }
        }

        let keyStore = TrackingAPIKeyStore()
        let client = OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: makeMockSession())
        let provider = LLMProviderConfiguration.deepSeekDefault()

        _ = try client.makeURLRequest(
            configuration: provider,
            messages: [.user("Hi")],
            responseFormat: nil,
            options: .default
        )

        #expect(provider.apiKeyAccount == KeychainConstants.deepSeekAccount)
        #expect(keyStore.requestedAccounts == [KeychainConstants.deepSeekAccount])
    }

    @Test
    @MainActor
    func keychainAuthorizationFailureShowsReauthorizationWarning() throws {
        final class AuthorizationFailingKeychainStore: KeychainStore {
            func saveGenericPassword(data: Data, service: String, account: String) throws {
                throw KeychainError.unexpectedStatus(errSecAuthFailed)
            }

            func loadGenericPassword(service: String, account: String) throws -> String? {
                throw KeychainError.unexpectedStatus(errSecAuthFailed)
            }

            func deleteGenericPassword(service: String, account: String) throws {}
        }

        let keychain = KeychainService(store: AuthorizationFailingKeychainStore())
        let state = keychain.apiKeyAccessState(account: KeychainConstants.deepSeekAccount)
        guard case .authorizationRequired(let message) = state else {
            Issue.record("Expected authorizationRequired but got \(state)")
            return
        }
        #expect(message.contains("signing identity changed"))
        #expect(keychain.lastReadStatus.contains("re-authorization"))

        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database, keychainService: keychain)

        #expect(appState.keychainDeepSeekKeyExists == false)
        #expect(appState.keychainMaskedKey == "Needs re-authorization")
        #expect(appState.keychainAuthorizationWarning?.contains("signing identity changed") == true)
        #expect(appState.keychainMismatchStatus.contains("re-authorization"))
        #expect(appState.hasAPIKey == false)
    }

    @Test
    @MainActor
    func embeddingKeyStoredUnderProviderAccount() throws {
        let mockStore = InMemoryMockKeychainStore()
        let keychain = KeychainService(store: mockStore)
        try keychain.saveAPIKey("embed-key-123456", account: KeychainConstants.defaultEmbeddingAccount)

        #expect(keychain.hasAPIKey(account: KeychainConstants.defaultEmbeddingAccount))
        let loaded = try #require(try keychain.loadAPIKey(account: KeychainConstants.defaultEmbeddingAccount))
        #expect(KeychainService.maskKey(loaded) == "****3456")
    }

    @Test
    @MainActor
    func keychainNonDestructiveLegacyMigrationAndMismatchDetection() throws {
        let mockStore = InMemoryMockKeychainStore()
        let keychain = KeychainService(store: mockStore)

        let legacyService = "InterviewCopilotMac"
        let legacyAccount = "DeepSeekAPIKey"
        let rawKey = "sk-legacy-12345678"
        try mockStore.saveGenericPassword(data: Data(rawKey.utf8), service: legacyService, account: legacyAccount)

        keychain.performMigrationIfNeeded()

        #expect(keychain.legacyItemFound == true)
        #expect(keychain.legacyItemCount == 1)
        #expect(keychain.migrationPerformed == true)

        let copiedKey = try mockStore.loadGenericPassword(service: KeychainConstants.service, account: KeychainConstants.deepSeekAccount)
        #expect(copiedKey == rawKey)

        let preservedKey = try mockStore.loadGenericPassword(service: legacyService, account: legacyAccount)
        #expect(preservedKey == rawKey)

        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database, keychainService: keychain)

        #expect(appState.keychainDeepSeekKeyExists == true)
        #expect(appState.keychainLegacyItemFound == true)
        #expect(appState.keychainMigrationPerformed == false)
        #expect(appState.keychainMaskedKey == "sk-****5678")
        #expect(appState.keychainMismatchStatus == "✅ DeepSeek API Key loaded successfully")

        let emptyMockStore = InMemoryMockKeychainStore()
        let freshKeychain = KeychainService(store: emptyMockStore)
        try emptyMockStore.saveGenericPassword(data: Data("sk-legacy-9999".utf8), service: "InterviewCopilotMac", account: "DeepSeekAPIKey")

        let appState2 = AppState(database: database, keychainService: freshKeychain)
        try freshKeychain.deleteAPIKey(account: KeychainConstants.deepSeekAccount)
        appState2.refreshAll()

        #expect(appState2.keychainDeepSeekKeyExists == false)
        #expect(appState2.keychainMismatchStatus == "⚠️ Legacy key found, migration available")
    }

    @Test
    @MainActor
    func immediateRefreshOnSavingAPIKey() throws {
        let database = try makeTemporaryDatabase()
        let mockStore = InMemoryMockKeychainStore()
        let keychain = KeychainService(store: mockStore)
        let appState = AppState(database: database, keychainService: keychain)

        let initialConfig = appState.providerConfigurations.first(where: { $0.kind == .deepSeek })!
        #expect(appState.keychainDeepSeekKeyExists == false)

        appState.saveAPIKey("sk-newly-saved-key-8888", for: initialConfig)

        #expect(appState.keychainDeepSeekKeyExists == true)
        #expect(appState.keychainMaskedKey == "sk-****8888")
        #expect(appState.keychainMismatchStatus == "✅ DeepSeek API Key loaded successfully")
        #expect(appState.hasAPIKey == true)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func configuredOpenAICompatibleProvider() -> LLMProviderConfiguration {
        var configuration = LLMProviderConfiguration.openAICompatibleDefault()
        configuration.name = "Custom API"
        configuration.baseURL = "https://openai-compatible.test/v1"
        configuration.apiKeyAccount = "custom.test"
        return configuration
    }

    private func makeConfiguredOpenAICompatibleClient() throws -> (client: OpenAICompatibleLLMClient, configuration: LLMProviderConfiguration) {
        let keyStore = InMemoryAPIKeyStore()
        try keyStore.saveAPIKey("sk-test-key", account: "custom.test")
        return (
            OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: makeMockSession()),
            configuredOpenAICompatibleProvider()
        )
    }
}

final class InMemoryAPIKeyStore: APIKeyStore {
    var keys: [String: String] = [:]

    func saveAPIKey(_ apiKey: String, account: String) throws {
        keys[account] = apiKey
    }

    func loadAPIKey(account: String) throws -> String? {
        keys[account]
    }

    func deleteAPIKey(account: String) throws {
        keys.removeValue(forKey: account)
    }
}

final class FakeLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind
    var lastConfiguration: LLMProviderConfiguration?

    init(kind: LLMProviderKind) {
        self.providerKind = kind
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        lastConfiguration = configuration
        return LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        lastConfiguration = configuration
        return LLMChatResult(
            content: #"{"ok":true}"#,
            modelName: configuration.model,
            providerKind: configuration.kind,
            providerName: configuration.name,
            baseURL: configuration.baseURL,
            latencyMS: 1,
            isLocal: false,
            rawResponse: nil
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        lastConfiguration = configuration
        return []
    }
}
