import Foundation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case ollamaLocal
    case deepSeek
    case openAICompatible
    case openAI
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollamaLocal: return "Local Ollama"
        case .deepSeek: return "DeepSeek"
        case .openAICompatible: return "OpenAI-compatible"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    var isLocal: Bool {
        self == .ollamaLocal
    }
}

struct LLMProviderConfiguration: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: LLMProviderKind
    var baseURL: String
    var model: String
    var apiKeyAccount: String?
    var isDefaultForRealtime: Bool
    var isDefaultForRecap: Bool
    var supportsJSONMode: Bool
    var supportsStreaming: Bool
    var supportsThinking: Bool
    var createdAt: Date
    var updatedAt: Date

    static func localOllamaDefault(model: String = "gemma4:26b") -> LLMProviderConfiguration {
        let now = Date()
        return LLMProviderConfiguration(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Local Ollama",
            kind: .ollamaLocal,
            baseURL: "http://localhost:11434",
            model: model,
            apiKeyAccount: nil,
            isDefaultForRealtime: true,
            isDefaultForRecap: false,
            supportsJSONMode: true,
            supportsStreaming: true,
            supportsThinking: false,
            createdAt: now,
            updatedAt: now
        )
    }

    static func deepSeekDefault(model: String = "deepseek-v4-flash") -> LLMProviderConfiguration {
        let now = Date()
        return LLMProviderConfiguration(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com",
            model: model,
            apiKeyAccount: "deepseek.default",
            isDefaultForRealtime: false,
            isDefaultForRecap: true,
            supportsJSONMode: true,
            supportsStreaming: true,
            supportsThinking: true,
            createdAt: now,
            updatedAt: now
        )
    }

    static func openAICompatibleDefault() -> LLMProviderConfiguration {
        let now = Date()
        return LLMProviderConfiguration(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Custom OpenAI-compatible",
            kind: .openAICompatible,
            baseURL: "https://api.example.com",
            model: "model-name",
            apiKeyAccount: "custom.openaiCompatible.default",
            isDefaultForRealtime: false,
            isDefaultForRecap: false,
            supportsJSONMode: true,
            supportsStreaming: true,
            supportsThinking: false,
            createdAt: now,
            updatedAt: now
        )
    }
}

struct LLMChatMessage: Codable, Hashable {
    var role: String
    var content: String

    static func system(_ content: String) -> LLMChatMessage {
        LLMChatMessage(role: "system", content: content)
    }

    static func user(_ content: String) -> LLMChatMessage {
        LLMChatMessage(role: "user", content: content)
    }

    static func assistant(_ content: String) -> LLMChatMessage {
        LLMChatMessage(role: "assistant", content: content)
    }
}

struct LLMChatResult: Hashable {
    var content: String
    var modelName: String
    var providerKind: LLMProviderKind
    var providerName: String
    var baseURL: String
    var latencyMS: Int
    var isLocal: Bool
    var rawResponse: String?
}

struct LLMModelInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var modifiedAt: Date?
    var size: Int64?
}

struct LLMConnectionTestResult: Hashable {
    var success: Bool
    var message: String
    var latencyMS: Int?
    var models: [LLMModelInfo]
}

enum LLMResponseFormat: Codable, Hashable {
    case jsonObject
    case text
}

struct LLMRequestOptions: Codable, Hashable {
    var temperature: Double?
    var stream: Bool
    var includeRawResponse: Bool

    static let `default` = LLMRequestOptions()

    init(temperature: Double? = nil, stream: Bool = false, includeRawResponse: Bool = false) {
        self.temperature = temperature
        self.stream = stream
        self.includeRawResponse = includeRawResponse
    }
}

enum LLMProviderError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidBaseURL(String)
    case missingAPIKey(providerName: String)
    case ollamaNotRunning
    case modelNotFound(String)
    case invalidResponse(String)
    case emptyResponse(providerName: String)
    case rateLimited(providerName: String)
    case invalidAPIKey(providerName: String)
    case serverError(providerName: String, statusCode: Int, body: String)
    case networkFailure(providerName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider):
            return "\(provider) is not configured yet."
        case .invalidBaseURL(let baseURL):
            return "Invalid provider base URL: \(baseURL)"
        case .missingAPIKey(let providerName):
            return "\(providerName) requires an API key. Add one in Settings."
        case .ollamaNotRunning:
            return "Ollama is not running. Start it with the Ollama app or run `ollama serve`."
        case .modelNotFound(let model):
            return "Model not found locally. Run: ollama pull \(model) or choose another installed model."
        case .invalidResponse(let message):
            return "Provider returned an invalid response: \(message)"
        case .emptyResponse(let providerName):
            return "\(providerName) returned an empty response."
        case .rateLimited(let providerName):
            return "\(providerName) rate limit reached. Wait a moment and try again."
        case .invalidAPIKey(let providerName):
            return "\(providerName) rejected the API key."
        case .serverError(let providerName, let statusCode, let body):
            return "\(providerName) returned server error \(statusCode): \(body.prefix(220))"
        case .networkFailure(let providerName, let message):
            return "\(providerName) network request failed: \(message)"
        }
    }
}

protocol LLMClientProtocol: AnyObject {
    var providerKind: LLMProviderKind { get }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo]
}
