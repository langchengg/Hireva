import Foundation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case ollamaLocal
    case deepSeek
    case openAICompatible
    case openAI
    case anthropic
    case gemini

    static var allCases: [LLMProviderKind] {
        [.deepSeek, .openAICompatible, .openAI, .anthropic, .gemini]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollamaLocal: return "Legacy Local Provider (Disabled)"
        case .deepSeek: return "DeepSeek"
        case .openAICompatible: return "OpenAI-compatible"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    var isLocal: Bool {
        false
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

    static func deepSeekDefault(model: String = "deepseek-v4-flash") -> LLMProviderConfiguration {
        let now = Date()
        return LLMProviderConfiguration(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com",
            model: model,
            apiKeyAccount: "deepseek.default",
            isDefaultForRealtime: true,
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

enum LLMProviderErrorCategory: String, Codable, Equatable, Hashable {
    case configuration
    case authentication
    case model
    case response
    case rateLimit
    case server
    case network
}

enum LLMProviderErrorCode: String, Codable, Equatable, Hashable {
    case notConfigured = "provider_not_configured"
    case invalidBaseURL = "invalid_base_url"
    case missingAPIKey = "missing_api_key"
    case modelNotFound = "model_not_found"
    case invalidResponse = "invalid_response"
    case emptyResponse = "empty_response"
    case rateLimited = "rate_limited"
    case invalidAPIKey = "invalid_api_key"
    case serverError = "server_error"
    case networkFailure = "network_failure"
}

struct LLMRequestOptions: Codable, Hashable {
    var temperature: Double?
    var stream: Bool
    var includeRawResponse: Bool
    var timeoutInterval: TimeInterval?

    static let `default` = LLMRequestOptions()

    init(
        temperature: Double? = nil,
        stream: Bool = false,
        includeRawResponse: Bool = false,
        timeoutInterval: TimeInterval? = nil
    ) {
        self.temperature = temperature
        self.stream = stream
        self.includeRawResponse = includeRawResponse
        self.timeoutInterval = timeoutInterval
    }
}

enum LLMProviderError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidBaseURL(String)
    case missingAPIKey(providerName: String)
    case modelNotFound(String)
    case invalidResponse(String)
    case emptyResponse(providerName: String)
    case rateLimited(providerName: String)
    case invalidAPIKey(providerName: String)
    case serverError(providerName: String, statusCode: Int, body: String)
    case networkFailure(providerName: String, message: String)

    var category: LLMProviderErrorCategory {
        switch self {
        case .notConfigured, .invalidBaseURL:
            return .configuration
        case .missingAPIKey, .invalidAPIKey:
            return .authentication
        case .modelNotFound:
            return .model
        case .invalidResponse, .emptyResponse:
            return .response
        case .rateLimited:
            return .rateLimit
        case .serverError:
            return .server
        case .networkFailure:
            return .network
        }
    }

    var code: LLMProviderErrorCode {
        switch self {
        case .notConfigured:
            return .notConfigured
        case .invalidBaseURL:
            return .invalidBaseURL
        case .missingAPIKey:
            return .missingAPIKey
        case .modelNotFound:
            return .modelNotFound
        case .invalidResponse:
            return .invalidResponse
        case .emptyResponse:
            return .emptyResponse
        case .rateLimited:
            return .rateLimited
        case .invalidAPIKey:
            return .invalidAPIKey
        case .serverError:
            return .serverError
        case .networkFailure:
            return .networkFailure
        }
    }

    var httpStatusCode: Int? {
        switch self {
        case .invalidAPIKey:
            return nil
        case .rateLimited:
            return 429
        case .serverError(_, let statusCode, _):
            return statusCode
        default:
            return nil
        }
    }

    var providerKind: LLMProviderKind? {
        guard let descriptor = providerDescriptor else { return nil }

        switch descriptor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "deepseek", "streaming for deepseek":
            return .deepSeek
        case "openai", "streaming for openai":
            return .openAI
        case "anthropic", "streaming for anthropic":
            return .anthropic
        case "gemini", "streaming for gemini":
            return .gemini
        case "openai-compatible", "custom openai-compatible", "streaming for openai-compatible":
            return .openAICompatible
        case "legacy local provider (disabled)", "streaming for legacy local provider (disabled)":
            return .ollamaLocal
        default:
            return nil
        }
    }

    var errorDescription: String? {
        let errorCode = code.rawValue
        let provider = safeProviderDisplayName

        switch self {
        case .notConfigured:
            return "\(provider) is not configured yet (\(errorCode))."
        case .invalidBaseURL:
            return "\(provider) has an invalid base URL (\(errorCode))."
        case .missingAPIKey:
            return "\(provider) requires an API key (\(errorCode)). Add one in Settings."
        case .modelNotFound:
            return "The configured provider model was not found (\(errorCode)). Check the model setting."
        case .invalidResponse:
            return "\(provider) returned an invalid response (\(errorCode))."
        case .emptyResponse:
            return "\(provider) returned an empty response (\(errorCode))."
        case .rateLimited:
            return "\(provider) rate limit reached (\(errorCode)). Wait a moment and try again."
        case .invalidAPIKey:
            return "\(provider) rejected the API key (\(errorCode))."
        case .serverError(_, let statusCode, _):
            return "\(provider) returned HTTP \(statusCode) (\(errorCode))."
        case .networkFailure:
            return "\(provider) network request failed (\(errorCode))."
        }
    }

    private var providerDescriptor: String? {
        switch self {
        case .notConfigured(let provider),
             .missingAPIKey(let provider),
             .emptyResponse(let provider),
             .rateLimited(let provider),
             .invalidAPIKey(let provider),
             .serverError(let provider, _, _),
             .networkFailure(let provider, _):
            return provider
        case .invalidBaseURL, .modelNotFound, .invalidResponse:
            return nil
        }
    }

    private var safeProviderDisplayName: String {
        switch providerKind {
        case .deepSeek:
            return "DeepSeek"
        case .openAICompatible:
            return "OpenAI-compatible provider"
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .gemini:
            return "Gemini"
        case .ollamaLocal:
            return "Local provider"
        case nil:
            return "Selected provider"
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

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error>
}

extension LLMClientProtocol {
    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMProviderError.notConfigured("Streaming for \(providerKind.displayName)"))
        }
    }
}
