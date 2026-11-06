import Foundation
import Testing
import os
@testable import Hireva

struct KeychainIdentityAndRequestContractTests {
    @Test
    func mockKeepsServiceAndAccountAsSeparateIdentityComponents() throws {
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(data: Data("synthetic-a".utf8), service: "synthetic:namespace", account: "user")
        try store.saveGenericPassword(data: Data("synthetic-b".utf8), service: "synthetic", account: "namespace:user")

        #expect(try store.loadGenericPassword(service: "synthetic:namespace", account: "user") == "synthetic-a")
        #expect(try store.loadGenericPassword(service: "synthetic", account: "namespace:user") == "synthetic-b")
        try store.deleteGenericPassword(service: "synthetic:namespace", account: "user")
        #expect(try store.loadGenericPassword(service: "synthetic:namespace", account: "user") == nil)
        #expect(try store.loadGenericPassword(service: "synthetic", account: "namespace:user") == "synthetic-b")
    }

    @Test
    func actualClientsReadEachRequestFromTheSameAccountWithTheirExistingPolicies() throws {
        let store = RequestPolicyStore()
        let keys = KeychainService(store: store)
        let account = "synthetic.shared-provider"
        var configuration = LLMProviderConfiguration.openAICompatibleDefault()
        configuration.apiKeyAccount = account
        configuration.baseURL = "https://synthetic-contract.invalid/v1"
        let llm = OpenAICompatibleLLMClient(apiKeyStore: keys)
        let embedding = CloudEmbeddingProvider(baseURL: configuration.baseURL, apiKeyAccount: account,
            modelName: "synthetic-embedding", dimensions: 3, apiKeyStore: keys)

        try keys.saveAPIKey("synthetic-first", account: account)
        let first = try llm.makeURLRequest(configuration: configuration, messages: [.user("synthetic question")],
            responseFormat: nil, options: .default)
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-first")
        try keys.saveAPIKey("synthetic-second", account: account)
        let second = try embedding.makeRequest(texts: ["synthetic document"])
        #expect(second.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-second")
        try keys.deleteAPIKey(account: account)
        #expect(throws: EmbeddingProviderError.missingAPIKey(providerName: "Cloud Embeddings")) {
            _ = try embedding.makeRequest(texts: ["synthetic document"])
        }
        #expect(store.reads == [
            .init(service: KeychainConstants.service, account: account, policy: .allow),
            .init(service: KeychainConstants.service, account: account, policy: .skip),
            .init(service: KeychainConstants.service, account: account, policy: .skip)
        ])
        #expect(keys.lastWriteStatus == "Deleted")
        #expect(keys.lastReadStatus == "Success")
    }
}

private final class RequestPolicyStore: KeychainStore, Sendable {
    struct Read: Equatable, Sendable {
        let service: String
        let account: String
        let policy: KeychainAuthenticationPolicy
    }
    private struct Key: Hashable, Sendable {
        let service: String
        let account: String
    }
    private struct State: Sendable {
        var values: [Key: Data] = [:]
        var reads: [Read] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var reads: [Read] { state.withLock { $0.reads } }

    func saveGenericPassword(data: Data, service: String, account: String) throws {
        state.withLock { $0.values[Key(service: service, account: account)] = data }
    }
    func loadGenericPassword(service: String, account: String,
                             authenticationPolicy: KeychainAuthenticationPolicy) throws -> String? {
        let data = state.withLock { state in
            state.reads.append(Read(service: service, account: account, policy: authenticationPolicy))
            return state.values[Key(service: service, account: account)]
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
    func deleteGenericPassword(service: String, account: String) throws {
        _ = state.withLock { $0.values.removeValue(forKey: Key(service: service, account: account)) }
    }
}
