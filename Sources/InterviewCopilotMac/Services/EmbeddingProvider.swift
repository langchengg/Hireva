import Foundation

protocol EmbeddingProvider {
    var providerID: String { get }
    var modelName: String { get }
    var dimension: Int { get async throws }

    func embed(text: String) async throws -> [Float]
    func embedBatch(texts: [String]) async throws -> [[Float]]
}

enum EmbeddingProviderError: LocalizedError, Equatable {
    case ollamaNotRunning
    case embeddingModelMissing(String)
    case invalidEmbeddingResponse(String)
    case dimensionMismatch(expected: Int, actual: Int)
    case networkError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .ollamaNotRunning:
            return "Ollama is not running. Start it with the Ollama app or run `ollama serve`."
        case .embeddingModelMissing(let model):
            return "Embedding model '\(model)' is missing. Run: ollama pull \(model)."
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

class ControlledMockEmbeddingProvider: EmbeddingProvider {
    var providerID: String = "controlled-mock"
    var modelName: String = "controlled-mock-model"
    var dimension: Int { get async throws { 384 } }
    
    func embed(text: String) async throws -> [Float] {
        let lower = text.lowercased()
        var centroid = [Float](repeating: 0.0, count: 384)
        
        let hasRobotics = lower.contains("embodied") || lower.contains("vla") || lower.contains("manipulation") || lower.contains("robotics") || lower.contains("robotic")
        let hasROS = lower.contains("ros2") || lower.contains("rover") || lower.contains("navigation") || lower.contains("ros") || lower.contains("c++") || lower.contains("cpp")
        let hasEmbedding = lower.contains("local") || lower.contains("ollama") || lower.contains("embedding") || lower.contains("vector") || lower.contains("hybrid")
        
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

class OllamaEmbeddingProvider: EmbeddingProvider {
    let providerID: String = "localOllama"
    let modelName: String
    private let baseURL: String
    private let timeoutInterval: TimeInterval
    private let session: URLSession

    private var cachedDimension: Int?
    private var probedEndpoint: String?

    init(
        modelName: String = "nomic-embed-text",
        baseURL: String = "http://localhost:11434",
        timeoutInterval: TimeInterval = 60.0,
        session: URLSession = .shared
    ) {
        self.modelName = modelName
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.timeoutInterval = timeoutInterval
        self.session = session
    }

    var dimension: Int {
        get async throws {
            if let cached = cachedDimension {
                return cached
            }
            let dummy = try await embed(text: "dimension_query_test")
            let dim = dummy.count
            cachedDimension = dim
            return dim
        }
    }

    func embed(text: String) async throws -> [Float] {
        let endpoint = try await resolveEndpoint()
        let url = URL(string: "\(baseURL)\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutInterval

        let requestBody: [String: Any]
        if endpoint == "/api/embed" {
            requestBody = [
                "model": modelName,
                "input": [text]
            ]
        } else {
            requestBody = [
                "model": modelName,
                "prompt": text
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw resolveNetworkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.invalidEmbeddingResponse("No HTTP response")
        }

        if httpResponse.statusCode == 404 {
            throw EmbeddingProviderError.embeddingModelMissing(modelName)
        }

        guard httpResponse.statusCode == 200 else {
            throw EmbeddingProviderError.invalidEmbeddingResponse("Ollama returned HTTP \(httpResponse.statusCode)")
        }

        do {
            if endpoint == "/api/embed" {
                struct EmbedResponse: Codable {
                    let embeddings: [[Float]]
                }
                let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
                guard let first = decoded.embeddings.first else {
                    throw EmbeddingProviderError.invalidEmbeddingResponse("Empty embedding array returned from /api/embed")
                }
                return first
            } else {
                struct EmbeddingsResponse: Codable {
                    let embedding: [Float]
                }
                let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
                return decoded.embedding
            }
        } catch {
            throw EmbeddingProviderError.invalidEmbeddingResponse("Failed to parse JSON: \(error.localizedDescription)")
        }
    }

    func embedBatch(texts: [String]) async throws -> [[Float]] {
        if texts.isEmpty { return [] }
        let endpoint = try await resolveEndpoint()

        // Batch /api/embed takes list natively
        if endpoint == "/api/embed" {
            let url = URL(string: "\(baseURL)/api/embed")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeoutInterval

            let requestBody: [String: Any] = [
                "model": modelName,
                "input": texts
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw resolveNetworkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmbeddingProviderError.invalidEmbeddingResponse("No HTTP response")
            }

            if httpResponse.statusCode == 404 {
                throw EmbeddingProviderError.embeddingModelMissing(modelName)
            }

            guard httpResponse.statusCode == 200 else {
                throw EmbeddingProviderError.invalidEmbeddingResponse("Ollama returned HTTP \(httpResponse.statusCode)")
            }

            struct EmbedResponse: Codable {
                let embeddings: [[Float]]
            }
            let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
            return decoded.embeddings
        } else {
            // Fall back to sequential calls for /api/embeddings
            var results: [[Float]] = []
            for text in texts {
                let emb = try await embed(text: text)
                results.append(emb)
            }
            return results
        }
    }

    private func resolveEndpoint() async throws -> String {
        if let probed = probedEndpoint {
            return probed
        }

        // Probe /api/embed first
        do {
            let dummyVector = try await probeEndpoint(path: "/api/embed")
            if !dummyVector.isEmpty {
                probedEndpoint = "/api/embed"
                await updateProbedEndpointDiagnostics(path: "/api/embed")
                return "/api/embed"
            }
        } catch {
            print("[OllamaEmbeddingProvider] Probe of /api/embed failed: \(error.localizedDescription)")
        }

        // Probe /api/embeddings next
        do {
            let dummyVector = try await probeEndpoint(path: "/api/embeddings")
            if !dummyVector.isEmpty {
                probedEndpoint = "/api/embeddings"
                await updateProbedEndpointDiagnostics(path: "/api/embeddings")
                return "/api/embeddings"
            }
        } catch {
            print("[OllamaEmbeddingProvider] Probe of /api/embeddings failed: \(error.localizedDescription)")
            throw error
        }

        throw EmbeddingProviderError.ollamaNotRunning
    }

    private func probeEndpoint(path: String) async throws -> [Float] {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3.0 // Short timeout for probing

        let requestBody: [String: Any]
        if path == "/api/embed" {
            requestBody = ["model": modelName, "input": ["probe"]]
        } else {
            requestBody = ["model": modelName, "prompt": "probe"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingProviderError.ollamaNotRunning
        }

        if httpResponse.statusCode == 404 {
            throw EmbeddingProviderError.embeddingModelMissing(modelName)
        }

        guard httpResponse.statusCode == 200 else {
            throw EmbeddingProviderError.ollamaNotRunning
        }

        if path == "/api/embed" {
            struct EmbedResponse: Codable {
                let embeddings: [[Float]]
            }
            let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
            return decoded.embeddings.first ?? []
        } else {
            struct EmbeddingsResponse: Codable {
                let embedding: [Float]
            }
            let decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
            return decoded.embedding
        }
    }

    private func resolveNetworkError(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return EmbeddingProviderError.timeout
            } else if [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(urlError.code) {
                return EmbeddingProviderError.ollamaNotRunning
            }
        }
        return EmbeddingProviderError.networkError(error.localizedDescription)
    }

    private func updateProbedEndpointDiagnostics(path: String) async {
        await MainActor.run {
            OllamaDiagnostics.shared.probedEmbeddingEndpoint = path
        }
    }
}
