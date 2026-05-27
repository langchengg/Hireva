import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct TestSuite7Tests {
    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test
    @MainActor
    func testSuite7_LLMProviders() async throws {
        print("=== Test Suite 7: LLM Providers ===")
        
        let database = try makeTemporaryDatabase()
        let settingsRepo = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        
        // 1. Initialize AppState with hermetic mock session for Ollama
        let mockSession = makeMockSession()
        let router = LLMRouter(settingsRepository: settingsRepo, clients: [
            .ollamaLocal: OllamaLLMClient(session: mockSession),
            .deepSeek: DeepSeekLLMClient(apiKeyStore: keychain),
            .openAICompatible: OpenAICompatibleLLMClient(apiKeyStore: keychain)
        ])
        let appState = AppState(database: database, llmRouter: router)
        
        let _ = try settingsRepo.ensureDefaultProviderConfigurations()
        appState.refreshAll()
        
        let ollama = appState.providerConfigurations.first(where: { $0.kind == .ollamaLocal })!
        let deepseek = appState.providerConfigurations.first(where: { $0.kind == .deepSeek })!
        
        print("[7.1] DeepSeek provider verification...")
        // Switch to DeepSeek should fail when key is missing
        try? appState.keychainService.deleteAPIKey(account: deepseek.apiKeyAccount!)
        appState.updateActiveRealtimeProvider(provider: deepseek, model: "deepseek-v4-flash")
        #expect(appState.activeRealtimeProvider?.kind == .ollamaLocal, "Should fail switch and keep Ollama when key is missing.")
        #expect(appState.lastProviderSwitchError != nil)
        print("  Missing API key handled successfully. Error: \(appState.lastProviderSwitchError!)")
        
        // Switch succeeds when key is present
        try appState.keychainService.saveAPIKey("fake-key", account: deepseek.apiKeyAccount!)
        appState.updateActiveRealtimeProvider(provider: deepseek, model: "deepseek-v4-flash")
        #expect(appState.activeRealtimeProvider?.kind == .deepSeek)
        #expect(appState.activeRealtimeProvider?.model == "deepseek-v4-flash")
        print("  Saves key and switches successfully. Model: \(appState.activeRealtimeProvider!.model)")
        
        print("[7.2] Ollama provider verification...")
        // Switch to Ollama
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/tags" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"models":[{"name":"gemma4:26b"}]}"#.utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"message":{"role":"assistant","content":"{\"ok\":true}"},"done":true}"#.utf8))
        }
        
        appState.updateActiveRealtimeProvider(provider: ollama, model: "gemma4:26b")
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        #expect(appState.activeRealtimeProvider?.kind == .ollamaLocal)
        #expect(appState.activeRealtimeProvider?.model == "gemma4:26b")
        print("  Switches to Ollama and selects model successfully.")
        
        print("[7.3] Ollama failure handling...")
        // Stop Ollama by returning error or network failure
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        // Try to switch to a different model (triggering listModels check)
        appState.updateActiveRealtimeProvider(provider: ollama, model: "llama3:latest")
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        
        // Switch should abort, displaying error, and previous provider/model remains active
        #expect(appState.activeRealtimeProvider?.model == "gemma4:26b", "Model should remain gemma4 since listModels failed.")
        #expect(appState.lastProviderSwitchError != nil)
        print("  Rejection of offline Ollama successful. Error: \(appState.lastProviderSwitchError!)")
        
        print("[7.4] Provider quick switcher state updates...")
        // Verify recap provider is completely isolated
        let recap = try #require(try settingsRepo.activeRecapProvider())
        #expect(recap.kind == .deepSeek, "Recap provider must stay DeepSeek.")
        
        // Clean up Keychain
        try? appState.keychainService.deleteAPIKey(account: deepseek.apiKeyAccount!)
        print("=== Test Suite 7: ALL TESTS PASSED ===")
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestSuite7Database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
