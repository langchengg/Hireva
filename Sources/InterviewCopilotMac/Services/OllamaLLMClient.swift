import Foundation
import Combine

@MainActor
public final class OllamaDiagnostics: ObservableObject {
    public static let shared = OllamaDiagnostics()

    @Published public var reachable: Bool = false
    @Published public var modelInstalled: Bool = false
    @Published public var lastHTTPStatus: Int? = nil
    @Published public var lastRawError: String? = nil
    @Published public var lastRawResponsePreview: String? = nil
    
    // Detailed diagnostics
    @Published public var activeProviderName: String? = nil
    @Published public var activeModel: String? = nil
    @Published public var lastEndpoint: String? = nil
    @Published public var lastTimeout: Double? = nil
    @Published public var lastLatencyMS: Int? = nil
    @Published public var jsonParseSuccess: Bool = false
    @Published public var jsonParseFailureReason: String? = nil
    @Published public var fallbackCardUsed: Bool = false
    @Published public var probedEmbeddingEndpoint: String? = nil

    private init() {}

    public func reset() {
        reachable = false
        modelInstalled = false
        lastHTTPStatus = nil
        lastRawError = nil
        lastRawResponsePreview = nil
        activeProviderName = nil
        activeModel = nil
        lastEndpoint = nil
        lastTimeout = nil
        lastLatencyMS = nil
        jsonParseSuccess = false
        jsonParseFailureReason = nil
        fallbackCardUsed = false
        probedEmbeddingEndpoint = nil
    }
}

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
            await MainActor.run {
                OllamaDiagnostics.shared.modelInstalled = false
                OllamaDiagnostics.shared.lastRawError = "Model not found on connection test."
            }
            throw LLMProviderError.modelNotFound(configuration.model)
        }

        let result = try await chatCompletion(
            configuration: configuration,
            messages: [.system("Return valid JSON only."), .user(#"Return {"ok": true}"#)],
            responseFormat: .jsonObject,
            options: LLMRequestOptions(temperature: 0)
        )
        _ = try JSONParsing.decodeObject(ConnectionOKPayload.self, from: result.content)
        
        await MainActor.run {
            OllamaDiagnostics.shared.modelInstalled = true
        }

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
        let started = ContinuousClock.now
        let actualTimeout = options.timeoutInterval ?? 180.0

        // Safe logs violating no privacy rules
        print("[Ollama] baseURL = \(configuration.baseURL)")
        print("[Ollama] model = \(configuration.model)")
        print("[Ollama] endpoint = /api/chat")
        print("[Ollama] timeout = \(actualTimeout)s")

        await MainActor.run {
            OllamaDiagnostics.shared.activeProviderName = configuration.name
            OllamaDiagnostics.shared.activeModel = configuration.model
            OllamaDiagnostics.shared.lastEndpoint = "/api/chat"
            OllamaDiagnostics.shared.lastTimeout = actualTimeout
        }

        let models = try await listModels(configuration: configuration)
        let isInstalled = models.contains(where: { $0.name == configuration.model })
        await MainActor.run {
            OllamaDiagnostics.shared.modelInstalled = isInstalled
        }
        guard isInstalled else {
            await MainActor.run {
                OllamaDiagnostics.shared.lastRawError = "Model '\(configuration.model)' is not installed locally."
            }
            throw LLMProviderError.modelNotFound(configuration.model)
        }

        var request = try makeChatRequest(
            configuration: configuration,
            messages: messages,
            responseFormat: responseFormat,
            options: options
        )
        request.timeoutInterval = actualTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let errorMsg = error.localizedDescription
            let isNotRunning: Bool
            var timedOut = false
            if let urlError = error as? URLError {
                if urlError.code == .timedOut {
                    timedOut = true
                    isNotRunning = false
                    await MainActor.run {
                        OllamaDiagnostics.shared.lastRawError = "Request timed out."
                    }
                } else if [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
                    isNotRunning = true
                    await MainActor.run {
                        OllamaDiagnostics.shared.reachable = false
                        OllamaDiagnostics.shared.lastRawError = "Cannot connect to local Ollama. Is it running?"
                    }
                } else {
                    isNotRunning = false
                    await MainActor.run {
                        OllamaDiagnostics.shared.lastRawError = errorMsg
                    }
                }
            } else {
                isNotRunning = false
                await MainActor.run {
                    OllamaDiagnostics.shared.lastRawError = errorMsg
                }
            }

            if timedOut {
                throw LLMProviderError.networkFailure(providerName: configuration.name, message: "Ollama timed out. This can happen if the model is too large, not fully loaded, or the context is too long. Try a smaller model, increase timeout, or switch to DeepSeek.")
            }
            if isNotRunning {
                throw LLMProviderError.ollamaNotRunning
            }
            throw LLMProviderError.networkFailure(providerName: configuration.name, message: errorMsg)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        
        let latency = latencyMS(since: started)
        await MainActor.run {
            OllamaDiagnostics.shared.lastHTTPStatus = statusCode
            OllamaDiagnostics.shared.lastLatencyMS = latency
        }
        
        print("[Ollama] HTTP status = \(statusCode)")

        do {
            try validateHTTPResponse(response, body: body, providerName: configuration.name)
        } catch {
            await MainActor.run {
                OllamaDiagnostics.shared.lastRawError = "HTTP server error \(statusCode)"
                OllamaDiagnostics.shared.lastRawResponsePreview = String(body.prefix(300))
            }
            throw error
        }

        let decoded: OllamaChatResponse
        do {
            decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        } catch {
            await MainActor.run {
                OllamaDiagnostics.shared.lastRawError = "Failed to parse Ollama chat JSON: \(error.localizedDescription)"
                OllamaDiagnostics.shared.lastRawResponsePreview = String(body.prefix(300))
            }
            throw LLMProviderError.invalidResponse("Could not decode Ollama /api/chat response.")
        }

        let content = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("[Ollama] latency = \(latency) ms")
        print("[Ollama] response content length = \(content.count)")
        print("[Ollama] JSON parse success = \(!content.isEmpty)")

        await MainActor.run {
            OllamaDiagnostics.shared.lastRawResponsePreview = String(body.prefix(300))
            OllamaDiagnostics.shared.lastRawError = nil
        }

        guard !content.isEmpty else {
            throw LLMProviderError.emptyResponse(providerName: configuration.name)
        }

        return LLMChatResult(
            content: content,
            modelName: configuration.model,
            providerKind: .ollamaLocal,
            providerName: configuration.name,
            baseURL: configuration.baseURL,
            latencyMS: latency,
            isLocal: true,
            rawResponse: options.includeRawResponse ? body : nil
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        guard let baseURL = URL(string: configuration.baseURL) else {
            await MainActor.run {
                OllamaDiagnostics.shared.reachable = false
                OllamaDiagnostics.shared.lastRawError = "Invalid base URL: \(configuration.baseURL)"
            }
            throw LLMProviderError.invalidBaseURL(configuration.baseURL)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 10.0 // Fast timeout for listing models

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let errorMsg = error.localizedDescription
            let isNotRunning: Bool
            var timedOut = false
            if let urlError = error as? URLError {
                if urlError.code == .timedOut {
                    timedOut = true
                    isNotRunning = false
                    await MainActor.run {
                        OllamaDiagnostics.shared.reachable = false
                        OllamaDiagnostics.shared.lastRawError = "Ollama listing models timed out."
                    }
                } else if [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
                    isNotRunning = true
                    await MainActor.run {
                        OllamaDiagnostics.shared.reachable = false
                        OllamaDiagnostics.shared.lastRawError = "Cannot connect to local Ollama. Is it running?"
                    }
                } else {
                    isNotRunning = false
                    await MainActor.run {
                        OllamaDiagnostics.shared.reachable = false
                        OllamaDiagnostics.shared.lastRawError = errorMsg
                    }
                }
            } else {
                isNotRunning = false
                await MainActor.run {
                    OllamaDiagnostics.shared.reachable = false
                    OllamaDiagnostics.shared.lastRawError = errorMsg
                }
            }

            if timedOut {
                throw LLMProviderError.networkFailure(providerName: configuration.name, message: "Ollama timed out. Try a smaller model or increase timeout.")
            }
            if isNotRunning {
                throw LLMProviderError.ollamaNotRunning
            }
            throw LLMProviderError.networkFailure(providerName: configuration.name, message: errorMsg)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        do {
            try validateHTTPResponse(response, body: body, providerName: configuration.name)
        } catch {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            await MainActor.run {
                OllamaDiagnostics.shared.reachable = false
                OllamaDiagnostics.shared.lastHTTPStatus = statusCode
                OllamaDiagnostics.shared.lastRawError = "Tags server error: status \(statusCode ?? 0)"
            }
            throw error
        }

        let decoded: OllamaTagsResponse
        do {
            decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        } catch {
            await MainActor.run {
                OllamaDiagnostics.shared.reachable = true
                OllamaDiagnostics.shared.lastRawError = "Failed to parse tags JSON: \(error.localizedDescription)"
            }
            throw LLMProviderError.invalidResponse("Could not decode Ollama /api/tags response.")
        }

        await MainActor.run {
            OllamaDiagnostics.shared.reachable = true
            OllamaDiagnostics.shared.lastHTTPStatus = 200
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
