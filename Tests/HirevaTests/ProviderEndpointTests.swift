import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct ProviderEndpointTests {
    @Test
    func canonicalizesSchemeHostDefaultPortAndSafeBasePath() throws {
        let cloud = try ProviderEndpoint(
            "HTTPS://API.Example.COM:443/v1/",
            policy: .openAICompatible
        )
        let local = try ProviderEndpoint(
            "HTTP://LOCALHOST:80/v1/",
            policy: .openAICompatible
        )

        #expect(cloud.absoluteString == "https://api.example.com/v1")
        #expect(cloud.origin == .init(scheme: "https", host: "api.example.com", port: 443))
        #expect(!cloud.isLocal)
        #expect(local.absoluteString == "http://localhost/v1")
        #expect(local.isLocal)
    }

    @Test
    func rejectsAmbiguousOrCredentialBearingEndpointInputWithoutRetainingIt() {
        let canary = "ENDPOINT_PRIVACY_CANARY"
        let rejected = [
            "https://user:\(canary)@api.example.test/v1",
            "https://api.example.test/v1?token=\(canary)",
            "https://api.example.test/v1#\(canary)",
            "https://api.example.test/v1\\\(canary)",
            "https://api.example.test/v1\n\(canary)",
            "https://api.example.test/v1/../\(canary)",
            "https://api.example.test/%2F\(canary)",
            "https://api.example.test/%5c\(canary)",
            "https://api.example.test/%2e%2e/\(canary)",
            "http://api.example.test/\(canary)",
            "https:///\(canary)"
        ]

        for input in rejected {
            do {
                _ = try ProviderEndpoint(input, policy: .openAICompatible)
                Issue.record("Expected endpoint input to be rejected.")
            } catch let error as ProviderEndpoint.ValidationError {
                #expect(!error.localizedDescription.contains(canary))
                #expect(!String(describing: error).contains(canary))
                #expect(!String(reflecting: error).contains(canary))
                #expect(!String(reflecting: error).contains(input))
            } catch {
                Issue.record("Expected a closed ProviderEndpoint.ValidationError.")
            }
        }
    }

    @Test
    func deepSeekEndpointIsPinnedToOfficialHTTPSOriginAndSupportedBasePath() throws {
        let root = try ProviderEndpoint("https://api.deepseek.com", policy: .deepSeek)
        let versioned = try ProviderEndpoint("HTTPS://API.DEEPSEEK.COM:443/v1/", policy: .deepSeek)

        #expect(root.absoluteString == "https://api.deepseek.com")
        #expect(versioned.absoluteString == "https://api.deepseek.com/v1")
        expectRejected("https://api.deepseek.com.evil.invalid/v1", policy: .deepSeek)
        expectRejected("https://api.deepseek.com:8443/v1", policy: .deepSeek)
        expectRejected("https://api.deepseek.com/v2", policy: .deepSeek)
        expectRejected("http://127.0.0.1:11434", policy: .deepSeek)
    }

    @Test
    func ollamaPolicyAcceptsOnlyCanonicalLoopbackOnFixedPort() throws {
        let numeric = try ProviderEndpoint("http://127.0.0.1:11434/", policy: .ollamaLocal)
        let named = try ProviderEndpoint("http://localhost:11434", policy: .ollamaLocal)

        #expect(numeric.absoluteString == "http://127.0.0.1:11434")
        #expect(named.isLocal)
        expectRejected("http://127.0.0.1:11435", policy: .ollamaLocal)
        expectRejected("http://localhost:11434/v1", policy: .ollamaLocal)
        expectRejected("http://ollama.example.test:11434", policy: .ollamaLocal)
    }

    @Test
    func providerCredentialAccountRotatesAcrossKindAndOrigin() throws {
        var provider = LLMProviderConfiguration.deepSeekDefault()
        provider.id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        provider.apiKeyAccount = KeychainConstants.deepSeekAccount
        let deepSeek = try provider.validatedForLiveUse()

        provider.kind = .openAICompatible
        provider.baseURL = "https://custom-one.example.test/v1"
        provider.apiKeyAccount = KeychainConstants.deepSeekAccount
        let firstCustom = try provider.validatedForLiveUse()

        provider.baseURL = "https://custom-two.example.test/v1"
        let secondCustom = try provider.validatedForLiveUse()

        #expect(ProviderCredentialAccount.isReservedForDeepSeek(deepSeek.apiKeyAccount))
        #expect(!ProviderCredentialAccount.isReservedForDeepSeek(firstCustom.apiKeyAccount))
        #expect(firstCustom.apiKeyAccount != deepSeek.apiKeyAccount)
        #expect(secondCustom.apiKeyAccount != firstCustom.apiKeyAccount)
    }

    @Test
    func customProviderRequestCannotReuseReservedDeepSeekCredential() throws {
        let keyStore = InMemoryAPIKeyStore()
        try keyStore.saveAPIKey(
            "sk-deepseek-credential-canary",
            account: KeychainConstants.deepSeekAccount
        )
        var provider = LLMProviderConfiguration.deepSeekDefault()
        provider.id = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        provider.kind = .openAICompatible
        provider.baseURL = "https://custom-provider.example.test/v1"
        provider.apiKeyAccount = KeychainConstants.deepSeekAccount
        let validated = try provider.validatedForLiveUse()
        let client = OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: mockSession())

        #expect(throws: LLMProviderError.missingAPIKey(providerName: provider.name)) {
            _ = try client.makeURLRequest(
                configuration: provider,
                messages: [.user("synthetic")],
                responseFormat: nil,
                options: .default
            )
        }

        let customAccount = try #require(validated.apiKeyAccount)
        try keyStore.saveAPIKey("sk-custom-credential", account: customAccount)
        let request = try client.makeURLRequest(
            configuration: provider,
            messages: [.user("synthetic")],
            responseFormat: nil,
            options: .default
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-custom-credential")
    }

    @Test
    func embeddingCredentialAccountRotatesWithKindAndOrigin() throws {
        let first = try ProviderEndpoint("https://embeddings-one.example.test/v1", policy: .cloudEmbedding)
        let second = try ProviderEndpoint("https://embeddings-two.example.test/v1", policy: .cloudEmbedding)
        let openAIFirst = ProviderCredentialAccount.embeddingAccount(kind: .openAICompatibleCloud, endpoint: first)
        let customFirst = ProviderCredentialAccount.embeddingAccount(kind: .customCloud, endpoint: first)
        let openAISecond = ProviderCredentialAccount.embeddingAccount(kind: .openAICompatibleCloud, endpoint: second)

        #expect(openAIFirst != customFirst)
        #expect(openAIFirst != openAISecond)
        #expect(!ProviderCredentialAccount.isReservedForDeepSeek(openAIFirst))
        #expect(!ProviderCredentialAccount.isReservedForDeepSeek(customFirst))
    }

    @Test
    func releaseChoicesExcludePlaceholderClientsAndHistoricalRowsStillValidate() throws {
        #expect(LLMProviderKind.allCases == [.deepSeek, .openAICompatible])

        for kind in [LLMProviderKind.openAI, .anthropic, .gemini] {
            var historical = LLMProviderConfiguration.openAICompatibleDefault()
            historical.id = UUID()
            historical.kind = kind
            historical.baseURL = "HTTPS://API.EXAMPLE.TEST:443/v1/"
            historical.apiKeyAccount = KeychainConstants.deepSeekAccount

            let validated = try historical.validatedForLiveUse()
            #expect(validated.baseURL == "https://api.example.test/v1")
            #expect(validated.apiKeyAccount?.hasPrefix("provider.\(kind.rawValue).") == true)

            historical.baseURL = "https://user:PLACEHOLDER_ENDPOINT_CANARY@api.example.test/v1"
            #expect(throws: ProviderEndpoint.ValidationError.self) {
                _ = try historical.validatedForLiveUse()
            }
        }
    }

    @Test
    @MainActor
    func rejectedLiveSettingsDoNotEnterAppStateOrPersistence() throws {
        let database = try temporaryDatabase()
        let repository = SettingsRepository(database: database)
        let appState = AppState(
            database: database,
            llmRouter: LLMRouter(settingsRepository: repository, apiKeyStore: InMemoryAPIKeyStore()),
            keychainService: KeychainService(store: InMemoryMockKeychainStore())
        )
        let originalProvider = try #require(appState.providerConfigurations.first { $0.kind == .openAICompatible })
        var rejectedProvider = originalProvider
        rejectedProvider.baseURL = "https://user:ENDPOINT_STATE_CANARY@api.example.test/v1?token=ENDPOINT_STATE_CANARY"

        appState.saveProviderConfiguration(rejectedProvider)

        #expect(appState.providerConfigurations.first { $0.id == originalProvider.id }?.baseURL == originalProvider.baseURL)
        #expect(try repository.providerConfiguration(id: originalProvider.id)?.baseURL == originalProvider.baseURL)
        #expect(appState.errorMessage?.contains("ENDPOINT_STATE_CANARY") != true)

        let originalSettings = appState.settings
        var rejectedSettings = originalSettings
        rejectedSettings.embeddingProviderKind = .customCloud
        rejectedSettings.embeddingBaseURL = "http://remote-ENDPOINT_STATE_CANARY.example.test/v1"

        appState.saveSettings(rejectedSettings)

        #expect(appState.settings == originalSettings)
        #expect((try repository.loadSettings()) == originalSettings)
        #expect(appState.errorMessage?.contains("ENDPOINT_STATE_CANARY") != true)
    }

    @Test
    func redirectPolicyAllowsOnlySameOriginIncludingDefaultPortEquivalence() throws {
        let source = try #require(URL(string: "https://api.example.test/v1/chat/completions"))
        let sameOrigin = try #require(URL(string: "https://API.EXAMPLE.TEST:443/v1/redirected"))
        let crossHost = try #require(URL(string: "https://collector.example.test/v1"))
        let crossPort = try #require(URL(string: "https://api.example.test:8443/v1"))
        let downgrade = try #require(URL(string: "http://api.example.test/v1"))

        #expect(ProviderEndpoint.sameOrigin(source, sameOrigin))
        #expect(!ProviderEndpoint.sameOrigin(source, crossHost))
        #expect(!ProviderEndpoint.sameOrigin(source, crossPort))
        #expect(!ProviderEndpoint.sameOrigin(source, downgrade))

        let protectedSession = ProviderNetworkSession.sameOriginProtected(copying: mockSession())
        let redirectDelegate = try #require(protectedSession.delegate as? SameOriginRedirectDelegate)
        let task = protectedSession.dataTask(with: source)
        let response = try #require(
            HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": sameOrigin.absoluteString]
            )
        )

        func redirectedRequest(to destination: URL) -> URLRequest? {
            var result: URLRequest?
            redirectDelegate.urlSession(
                protectedSession,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                result = request
            }
            return result
        }

        #expect(redirectedRequest(to: sameOrigin)?.url == sameOrigin)
        #expect(redirectedRequest(to: crossHost) == nil)
        #expect(redirectedRequest(to: crossPort) == nil)
        #expect(redirectedRequest(to: downgrade) == nil)
    }

    private func expectRejected(_ input: String, policy: ProviderEndpoint.Policy) {
        do {
            _ = try ProviderEndpoint(input, policy: policy)
            Issue.record("Expected endpoint input to be rejected.")
        } catch is ProviderEndpoint.ValidationError {
            // Expected closed error.
        } catch {
            Issue.record("Expected ProviderEndpoint.ValidationError.")
        }
    }

    private func temporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaProviderEndpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
