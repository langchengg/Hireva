import Foundation

struct ChatMessage: Codable, Hashable {
    var role: String
    var content: String

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }
}

struct ChatResponseFormat: Codable, Hashable {
    var type: String

    static let jsonObject = ChatResponseFormat(type: "json_object")
}

struct ChatCompletionRequest: Codable, Hashable {
    var model: String
    var messages: [ChatMessage]
    var responseFormat: ChatResponseFormat?
    var stream: Bool
    var temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case stream
        case temperature
    }
}

struct ChatCompletionResponse: Codable, Hashable {
    struct Choice: Codable, Hashable {
        struct Message: Codable, Hashable {
            var role: String?
            var content: String?
        }

        var index: Int?
        var message: Message?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    var id: String?
    var model: String?
    var choices: [Choice]
}

enum DeepSeekError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case invalidAPIKey
    case rateLimited
    case serverError(Int, String)
    case networkFailure(Error)
    case invalidJSON
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a DeepSeek API key in Settings before using AI features."
        case .invalidURL:
            return "DeepSeek API URL is invalid."
        case .invalidAPIKey:
            return "DeepSeek rejected the API key."
        case .rateLimited:
            return "DeepSeek rate limit reached. Wait a moment and try again."
        case .serverError(let code, let body):
            return "DeepSeek returned server error \(code): \(body.prefix(220))"
        case .networkFailure(let error):
            return "Network request failed: \(error.localizedDescription)"
        case .invalidJSON:
            return "DeepSeek response could not be decoded."
        case .emptyResponse:
            return "DeepSeek returned an empty response."
        }
    }
}

final class DeepSeekClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "https://api.deepseek.com")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
    }

    func makeURLRequest(apiKey: String, request: ChatCompletionRequest) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekError.missingAPIKey
        }
        let url = baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try encoder.encode(request)
        return urlRequest
    }

    func complete(apiKey: String, request: ChatCompletionRequest) async throws -> (response: ChatCompletionResponse, rawJSON: String) {
        let urlRequest = try makeURLRequest(apiKey: apiKey, request: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw DeepSeekError.networkFailure(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidJSON
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw DeepSeekError.invalidAPIKey
        case 429:
            throw DeepSeekError.rateLimited
        default:
            throw DeepSeekError.serverError(http.statusCode, body)
        }

        do {
            return (try JSONDecoder().decode(ChatCompletionResponse.self, from: data), body)
        } catch {
            throw DeepSeekError.invalidJSON
        }
    }
}
