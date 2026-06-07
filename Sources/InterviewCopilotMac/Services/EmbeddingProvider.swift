import Foundation

protocol EmbeddingProvider {
    var providerID: String { get }
    var modelName: String { get }
    var dimension: Int { get async throws }

    func embed(text: String) async throws -> [Float]
    func embedBatch(texts: [String]) async throws -> [[Float]]
}

enum EmbeddingProviderError: LocalizedError, Equatable {
    case missingAPIKey(providerName: String)
    case disabled(String)
    case embeddingModelMissing(String)
    case invalidEmbeddingResponse(String)
    case dimensionMismatch(expected: Int, actual: Int)
    case networkError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let providerName):
            return "\(providerName) requires an embedding API key. Add one in Settings."
        case .disabled(let message):
            return message
        case .embeddingModelMissing(let model):
            return "Embedding model '\(model)' is unavailable. Choose a configured cloud embedding model."
        case .invalidEmbeddingResponse(let msg):
            return "Invalid embedding response: \(msg)"
        case .dimensionMismatch(let expected, let actual):
            return "Dimension mismatch: expected \(expected) but got \(actual)."
        case .networkError(let msg):
            return "Embedding network error: \(msg)"
        case .timeout:
            return "Embedding request timed out."
        }
    }
}

enum EmbeddingRequestFormatType: String, Codable, Hashable {
    case openAICompatible
    case custom
}

class ControlledMockEmbeddingProvider: EmbeddingProvider {
    var providerID: String = "controlled-mock"
    var modelName: String = "controlled-mock-model"
    var dimension: Int { get async throws { 384 } }
    
    func embed(text: String) async throws -> [Float] {
        let lower = text.lowercased()
        var centroid = [Float](repeating: 0.0, count: 384)
        
        let hasRobotics = lower.contains("embodied") || lower.contains("vla") || lower.contains("manipulation") || lower.contains("robotics") || lower.contains("robotic")
        let hasROS = lower.contains("ros2") || lower.contains("rover") || lower.contains("navigation") || lower.contains("ros") || lower.contains("c++") || lower.contains("cpp")
        let hasEmbedding = lower.contains("embedding") || lower.contains("vector") || lower.contains("hybrid")
        
        if hasRobotics {
            // Fill 0..<128 with deterministic pattern
            for i in 0..<128 {
                centroid[i] = Float(sin(Double(i)))
            }
        }
        if hasROS {
            // Fill 128..<256 with deterministic pattern
            for i in 128..<256 {
                centroid[i] = Float(sin(Double(i)))
            }
        }
        if hasEmbedding {
            // Fill 256..<384 with deterministic pattern
            for i in 256..<384 {
                centroid[i] = Float(sin(Double(i)))
            }
        }
        
        // If no categories match, add a default fallback pattern so it's not pure zero
        if !hasRobotics && !hasROS && !hasEmbedding {
            for i in 0..<384 {
                centroid[i] = Float(cos(Double(i &* text.hashValue)))
            }
        }
        
        // Normalize centroid to unit length
        let length = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        if length > 0 {
            for i in 0..<384 {
                centroid[i] /= length
            }
        }
        return centroid
    }
    
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            results.append(try await embed(text: text))
        }
        return results
    }
}

final class CloudEmbeddingProvider: EmbeddingProvider {
    let providerID: String
    let displayName: String
    let baseURL: String
    let apiKeyAccount: String
    let modelName: String
    let dimensions: Int?
    let requestFormat: EmbeddingRequestFormatType

    private let apiKeyStore: APIKeyStore
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    init(
        providerID: String = "cloudOpenAICompatible",
        displayName: String = "Cloud Embeddings",
        baseURL: String,
        apiKeyAccount: String,
        modelName: String,
        dimensions: Int?,
        requestFormat: EmbeddingRequestFormatType = .openAICompatible,
        apiKeyStore: APIKeyStore,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 60
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKeyAccount = apiKeyAccount
        self.modelName = modelName
        self.dimensions = dimensions
        self.requestFormat = requestFormat
        self.apiKeyStore = apiKeyStore
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    var dimension: Int {
        get async throws {
            if let dimensions, dimensions > 0 {
                return dimensions
            }
            return try await embed(text: "dimension_query_test").count
        }
    }

    func embed(text: String) async throws -> [Float] {
        let embeddings = try await embedBatch(texts: [text])
        guard let first = embeddings.first else {
            throw EmbeddingProviderError.invalidEmbeddingResponse("No embedding returned.")
        }
        return first
    }

    func embedBatch(texts: [String]) async throws -> [[Float]] {
        if texts.isEmpty { return [] }

        let request = try makeRequest(texts: texts)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapNetworkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.invalidEmbeddingResponse("Missing HTTP response.")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw EmbeddingProviderError.missingAPIKey(providerName: displayName)
        case 404:
            throw EmbeddingProviderError.embeddingModelMissing(modelName)
        default:
            throw EmbeddingProviderError.networkError("\(displayName) returned HTTP \(http.statusCode).")
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
            let sorted = decoded.data.sorted { $0.index < $1.index }
            let embeddings = sorted.map(\.embedding)
            guard embeddings.count == texts.count else {
                throw EmbeddingProviderError.invalidEmbeddingResponse("Expected \(texts.count) embeddings, got \(embeddings.count).")
            }
            if let dimensions, dimensions > 0, let first = embeddings.first, first.count != dimensions {
                throw EmbeddingProviderError.dimensionMismatch(expected: dimensions, actual: first.count)
            }
            return embeddings
        } catch let error as EmbeddingProviderError {
            throw error
        } catch {
            throw EmbeddingProviderError.invalidEmbeddingResponse("Failed to parse JSON: \(error.localizedDescription)")
        }
    }

    func makeRequest(texts: [String]) throws -> URLRequest {
        guard requestFormat == .openAICompatible else {
            throw EmbeddingProviderError.disabled("Custom embedding request format is not implemented yet.")
        }
        guard let url = URL(string: baseURL)?.appendingPathComponent("embeddings") else {
            throw EmbeddingProviderError.networkError("Invalid embedding base URL.")
        }
        guard let apiKey = try apiKeyStore.loadAPIKey(account: apiKeyAccount),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmbeddingProviderError.missingAPIKey(providerName: displayName)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutInterval

        let body = OpenAIEmbeddingRequest(model: modelName, input: texts)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func mapNetworkError(_ error: Error) -> EmbeddingProviderError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timeout
        }
        return .networkError(error.localizedDescription)
    }
}

private struct OpenAIEmbeddingRequest: Encodable {
    let model: String
    let input: [String]
}

private struct OpenAIEmbeddingResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }

    let data: [Item]
    let model: String?
}
