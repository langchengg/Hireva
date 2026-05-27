import Foundation
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

        #expect(providers.contains { $0.kind == .ollamaLocal && $0.baseURL == "http://localhost:11434" })
        #expect(providers.contains { $0.kind == .deepSeek && $0.apiKeyAccount == "deepseek.default" })
        #expect(realtime.kind == .ollamaLocal)
        #expect(recap.kind == .deepSeek)
    }

    @Test
    func ollamaListsInstalledModelsFromTagsEndpoint() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.absoluteString == "http://localhost:11434/api/tags")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"models":[{"name":"llama3.2:latest"},{"name":"gemma4:26b"}]}"#.utf8)
            return (response, data)
        }

        let client = OllamaLLMClient(session: makeMockSession())
        let models = try await client.listModels(configuration: .localOllamaDefault())

        #expect(models.map(\.name) == ["llama3.2:latest", "gemma4:26b"])
    }

    @Test
    func ollamaChatUsesNativeChatEndpointAndJSONFormat() async throws {
        let client = OllamaLLMClient(session: makeMockSession())
        let constructed = try client.makeChatRequest(
            configuration: .localOllamaDefault(model: "gemma4:26b"),
            messages: [.system("System"), .user("Return {\"ok\":true}")],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0.2)
        )
        let body = String(data: try #require(constructed.httpBody), encoding: .utf8) ?? ""
        #expect(constructed.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(body.contains(#""format":"json""#))
        #expect(body.contains("Return valid JSON only. No markdown. No explanation."))

        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/tags" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"models":[{"name":"gemma4:26b"}]}"#.utf8))
            }

            #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
            #expect(request.httpMethod == "POST")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"message":{"role":"assistant","content":"{\"ok\":true}"},"done":true}"#.utf8))
        }

        let result = try await client.chatCompletion(
            configuration: .localOllamaDefault(model: "gemma4:26b"),
            messages: [.system("System"), .user("Return {\"ok\":true}")],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0.2)
        )

        #expect(result.content == #"{"ok":true}"#)
        #expect(result.providerKind == .ollamaLocal)
        #expect(result.isLocal)
    }

    @Test
    func ollamaNotRunningReturnsFriendlyError() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let client = OllamaLLMClient(session: makeMockSession())

        await #expect(throws: LLMProviderError.ollamaNotRunning) {
            _ = try await client.listModels(configuration: .localOllamaDefault())
        }
    }

    @Test
    func ollamaMissingModelReturnsPullInstruction() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"models":[{"name":"llama3.2:latest"}]}"#.utf8))
        }

        let client = OllamaLLMClient(session: makeMockSession())

        await #expect(throws: LLMProviderError.modelNotFound("gemma4:26b")) {
            _ = try await client.chatCompletion(
                configuration: .localOllamaDefault(model: "gemma4:26b"),
                messages: [.user("Hi")],
                responseFormat: .jsonObject,
                options: .default
            )
        }
    }

    @Test
    func openAICompatibleMissingAPIKeyReturnsProviderError() async {
        let keyStore = InMemoryAPIKeyStore()
        let client = OpenAICompatibleLLMClient(apiKeyStore: keyStore, session: makeMockSession())
        var configuration = LLMProviderConfiguration.deepSeekDefault()
        configuration.kind = .openAICompatible
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
    func routerUsesActiveRealtimeProviderConfiguration() async throws {
        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let providers = try repository.ensureDefaultProviderConfigurations()
        let ollama = try #require(providers.first { $0.kind == .ollamaLocal })
        try repository.setActiveRealtimeProvider(id: ollama.id)

        let fake = FakeLLMClient(kind: .ollamaLocal)
        let router = LLMRouter(settingsRepository: repository, clients: [.ollamaLocal: fake])

        let result = try await router.chatForRealtime(
            messages: [.user("Hello")],
            responseFormat: .jsonObject,
            options: .default
        )

        #expect(result.providerKind == .ollamaLocal)
        #expect(result.modelName == ollama.model)
        #expect(fake.lastConfiguration?.id == ollama.id)
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

    @Test
    func ollamaTimedOutMapsToFriendlyError() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let client = OllamaLLMClient(session: makeMockSession())

        do {
            _ = try await client.listModels(configuration: .localOllamaDefault())
            #expect(false, "Expected to throw timeout network failure")
        } catch let LLMProviderError.networkFailure(_, message) {
            #expect(message.contains("Ollama timed out. Try a smaller model or increase timeout."))
        } catch {
            #expect(false, "Expected networkFailure error, got \(error)")
        }
    }

    @Test
    func questionDetectionServiceUtilizesOllamaSuccessfully() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/tags" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"models":[{"name":"gemma4:26b"}]}"#.utf8))
            }
            
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = """
            {
                "message": {
                    "role": "assistant",
                    "content": "{\\"should_trigger\\": true, \\"confidence\\": 0.95, \\"intent\\": \\"project_deep_dive\\", \\"question_complete\\": true, \\"answer_strategy\\": \\"project_walkthrough\\", \\"question_text\\": \\"Can you explain your system?\\", \\"reason\\": \\"test\\"}"
                }
            }
            """
            return (response, Data(payload.utf8))
        }

        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let client = OllamaLLMClient(session: makeMockSession())
        let router = LLMRouter(settingsRepository: repository, clients: [.ollamaLocal: client])
        let service = QuestionDetectionService(llmRouter: router)

        let result = try await service.detect(
            transcriptContext: "Interviewer: Can you explain your system?",
            sessionID: UUID().uuidString,
            transcriptSegmentID: nil,
            model: "gemma4:26b"
        )

        #expect(result.question.shouldTrigger)
        #expect(result.question.questionText == "Can you explain your system?")
        #expect(result.question.confidence == 0.95)
    }

    @Test
    func suggestionGenerationServiceUtilizesOllamaSuccessfully() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/tags" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"models":[{"name":"gemma4:26b"}]}"#.utf8))
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload = """
            {
                "message": {
                    "role": "assistant",
                    "content": "{\\"strategy\\": \\"Technical Deep Dive\\", \\"say_first\\": \\"I would describe our architecture...\\", \\"key_points\\": [\\"Decoupled components\\", \\"Event driven\\"], \\"follow_up_ready\\": [\\"How does it scale?\\"], \\"confidence\\": 0.9}"
                }
            }
            """
            return (response, Data(payload.utf8))
        }

        let database = try makeTemporaryDatabase()
        let repository = SettingsRepository(database: database)
        let client = OllamaLLMClient(session: makeMockSession())
        let router = LLMRouter(settingsRepository: repository, clients: [.ollamaLocal: client])
        let service = SuggestionGenerationService(llmRouter: router)

        let result = try await service.generate(
            question: DetectedQuestion(
                id: UUID().uuidString,
                sessionID: UUID().uuidString,
                transcriptSegmentID: nil,
                questionText: "How does your architecture work?",
                intent: .projectDeepDive,
                answerStrategy: .projectWalkthrough,
                confidence: 0.9,
                reason: nil,
                shouldTrigger: true,
                questionComplete: true,
                modelName: "gemma4:26b",
                promptVersion: "1.0",
                createdAt: Date()
            ),
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            transcriptContext: "How does your architecture work?",
            sessionID: UUID().uuidString,
            model: "gemma4:26b"
        )

        #expect(result.card.strategy == "Technical Deep Dive")
        #expect(result.card.sayFirst == "I would describe our architecture...")
        #expect(result.card.keyPoints == ["Decoupled components", "Event driven"])
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
            isLocal: configuration.kind == .ollamaLocal,
            rawResponse: nil
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        lastConfiguration = configuration
        return []
    }
}
