import Foundation

final class OllamaLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .ollamaLocal

    private let session: URLSession
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        let started = ContinuousClock.now
        let models = try await listModels(configuration: configuration)
        guard models.contains(where: { $0.name == configuration.model }) else {
            throw LLMProviderError.modelNotFound(configuration.model)
        }

        let result = try await chatCompletion(
            configuration: configuration,
            messages: [.system("Return valid JSON only."), .user(#"Return {"ok": true}"#)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0)
        )
        _ = try JSONParsing.decodeObject(ConnectionOKPayload.self, from: result.content)
        return LLMConnectionTestResult(
            success: true,
            message: "Connected to local Ollama in \(latencyMS(since: started)) ms.",
            latencyMS: result.latencyMS,
            models: models
        )
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let models = try await listModels(configuration: configuration)
        guard models.contains(where: { $0.name == configuration.model }) else {
            throw LLMProviderError.modelNotFound(configuration.model)
        }

        let request = try makeChatRequest(
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
            if let urlError = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
                throw LLMProviderError.ollamaNotRunning
            }
            throw LLMProviderError.networkFailure(providerName: configuration.name, message: error.localizedDescription)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        try validateHTTPResponse(response, body: body, providerName: configuration.name)

        let decoded: OllamaChatResponse
        do {
            decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        } catch {
            throw LLMProviderError.invalidResponse("Could not decode Ollama /api/chat response.")
        }

        let content = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw LLMProviderError.emptyResponse(providerName: configuration.name)
        }

        return LLMChatResult(
            content: content,
            modelName: configuration.model,
            providerKind: .ollamaLocal,
            providerName: configuration.name,
            baseURL: configuration.baseURL,
            latencyMS: latencyMS(since: started),
            isLocal: true,
            rawResponse: options.includeRawResponse ? body : nil
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        guard let baseURL = URL(string: configuration.baseURL) else {
            throw LLMProviderError.invalidBaseURL(configuration.baseURL)
        }
        let request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let urlError = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
                throw LLMProviderError.ollamaNotRunning
            }
            throw LLMProviderError.networkFailure(providerName: configuration.name, message: error.localizedDescription)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        try validateHTTPResponse(response, body: body, providerName: configuration.name)
        let decoded: OllamaTagsResponse
        do {
            decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        } catch {
            throw LLMProviderError.invalidResponse("Could not decode Ollama /api/tags response.")
        }
        return decoded.models.map {
            LLMModelInfo(name: $0.name, modifiedAt: $0.modifiedAt.flatMap(DateCoding.date), size: $0.size)
        }
    }

    func makeChatRequest(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) throws -> URLRequest {
        guard let baseURL = URL(string: configuration.baseURL) else {
            throw LLMProviderError.invalidBaseURL(configuration.baseURL)
        }

        var preparedMessages = messages
        if responseFormat == .jsonObject {
            let instruction = "Return valid JSON only. No markdown. No explanation."
            if let firstSystemIndex = preparedMessages.firstIndex(where: { $0.role == "system" }) {
                preparedMessages[firstSystemIndex].content += "\n\(instruction)"
            } else {
                preparedMessages.insert(.system(instruction), at: 0)
            }
        }

        let body = OllamaChatRequest(
            model: configuration.model,
            messages: preparedMessages,
            stream: options.stream,
            format: responseFormat == .jsonObject ? "json" : nil,
            options: OllamaOptions(temperature: options.temperature)
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, body: String, providerName: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Missing HTTP response.")
        }

        switch http.statusCode {
        case 200..<300:
            return
        default:
            throw LLMProviderError.serverError(providerName: providerName, statusCode: http.statusCode, body: body)
        }
    }

    private func latencyMS(since started: ContinuousClock.Instant) -> Int {
        let elapsed = started.duration(to: ContinuousClock.now)
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        var name: String
        var modifiedAt: String?
        var size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case modifiedAt = "modified_at"
            case size
        }
    }

    var models: [Model]
}

private struct OllamaChatRequest: Encodable {
    var model: String
    var messages: [LLMChatMessage]
    var stream: Bool
    var format: String?
    var options: OllamaOptions?
}

private struct OllamaOptions: Encodable {
    var temperature: Double?
}

private struct OllamaChatResponse: Decodable {
    struct Message: Decodable {
        var role: String
        var content: String
    }

    var message: Message
    var done: Bool?
}

private struct ConnectionOKPayload: Decodable {
    var ok: Bool
}
