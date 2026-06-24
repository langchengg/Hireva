import Foundation

final class OpenAICompatibleLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind

    private let apiKeyStore: APIKeyStore
    private let session: URLSession
    private let encoder = JSONEncoder()

    init(
        providerKind: LLMProviderKind = .openAICompatible,
        apiKeyStore: APIKeyStore,
        session: URLSession = .shared
    ) {
        self.providerKind = providerKind
        self.apiKeyStore = apiKeyStore
        self.session = session
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        let started = ContinuousClock.now
        let result = try await chatCompletion(
            configuration: configuration,
            messages: [.system("Return valid JSON only."), .user(#"Return {"ok": true}"#)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0)
        )
        _ = try JSONParsing.decodeObject(ConnectionOKPayload.self, from: result.content)
        return LLMConnectionTestResult(
            success: true,
            message: "Connected to \(configuration.name) in \(latencyMS(since: started)) ms.",
            latencyMS: result.latencyMS,
            models: try await listModels(configuration: configuration)
        )
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let request = try makeURLRequest(
            configuration: configuration,
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )

        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMProviderError.networkFailure(providerName: configuration.name, message: error.localizedDescription)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        try validateHTTPResponse(response, body: body, providerName: configuration.name)

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw LLMProviderError.invalidResponse("Could not decode OpenAI-compatible chat response.")
        }

        guard let content = decoded.choices.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.emptyResponse(providerName: configuration.name)
        }

        return LLMChatResult(
            content: content,
            modelName: decoded.model ?? configuration.model,
            providerKind: configuration.kind,
            providerName: configuration.name,
            baseURL: configuration.baseURL,
            latencyMS: latencyMS(since: started),
            isLocal: configuration.kind.isLocal,
            rawResponse: options.includeRawResponse ? body : nil
        )
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var streamingOptions = options
                    streamingOptions.stream = true
                    let request = try makeURLRequest(
                        configuration: configuration,
                        messages: messages,
                        responseFormat: responseFormat,
                        options: streamingOptions
                    )
                    
                    let (bytes, response) = try await session.bytes(for: request)
                    try validateHTTPResponse(response, body: "", providerName: configuration.name)
                    
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        let events = parser.append(line + "\n")
                        for event in events {
                            switch event {
                            case .token(let token):
                                continuation.yield(token)
                            case .usage(let prompt, _, _, let cached):
                                print("[DeepSeekUsage] Stream total: \(prompt) | Cached: \(cached) | Missed: \(prompt - cached)")
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        if configuration.kind == .deepSeek {
            return [
                LLMModelInfo(name: "deepseek-v4-flash", modifiedAt: nil, size: nil),
                LLMModelInfo(name: "deepseek-v4-pro", modifiedAt: nil, size: nil)
            ]
        }
        return []
    }

    func makeURLRequest(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) throws -> URLRequest {
        guard let baseURL = URL(string: configuration.baseURL) else {
            throw LLMProviderError.invalidBaseURL(configuration.baseURL)
        }
        guard let account = configuration.apiKeyAccount,
              let apiKey = try apiKeyStore.loadAPIKey(account: account),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey(providerName: configuration.name)
        }

        let requestBody = ChatCompletionRequest(
            model: configuration.model,
            messages: messages.map { ChatMessage(role: $0.role, content: $0.content) },
            responseFormat: responseFormat == .jsonObject ? .jsonObject : nil,
            stream: options.stream,
            temperature: options.temperature
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        if let timeoutInterval = options.timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(requestBody)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, body: String, providerName: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Missing HTTP response.")
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LLMProviderError.invalidAPIKey(providerName: providerName)
        case 429:
            throw LLMProviderError.rateLimited(providerName: providerName)
        default:
            throw LLMProviderError.serverError(providerName: providerName, statusCode: http.statusCode, body: body)
        }
    }

    private func latencyMS(since started: ContinuousClock.Instant) -> Int {
        let elapsed = started.duration(to: ContinuousClock.now)
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

final class DeepSeekLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let compatibleClient: OpenAICompatibleLLMClient

    init(apiKeyStore: APIKeyStore, session: URLSession = .shared) {
        compatibleClient = OpenAICompatibleLLMClient(providerKind: .deepSeek, apiKeyStore: apiKeyStore, session: session)
    }

    convenience init(keychain: KeychainService, settingsRepository: SettingsRepository? = nil) {
        self.init(apiKeyStore: keychain)
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        try await compatibleClient.testConnection(configuration: normalized(configuration))
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        try await compatibleClient.chatCompletion(
            configuration: normalized(configuration),
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        compatibleClient.chatCompletionStream(
            configuration: normalized(configuration),
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        try await compatibleClient.listModels(configuration: normalized(configuration))
    }

    private func normalized(_ configuration: LLMProviderConfiguration) -> LLMProviderConfiguration {
        var normalized = configuration
        normalized.kind = .deepSeek
        if normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.baseURL = "https://api.deepseek.com"
        }
        if normalized.apiKeyAccount == nil {
            normalized.apiKeyAccount = "deepseek.default"
        }
        return normalized
    }
}

private struct ConnectionOKPayload: Decodable {
    var ok: Bool
}
