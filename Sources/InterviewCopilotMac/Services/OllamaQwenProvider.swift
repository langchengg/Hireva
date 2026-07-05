import Foundation

struct LocalLLMHealth: Equatable {
    let ollamaRunning: Bool
    let selectedModel: String
    let modelInstalled: Bool
    let providerSource: AnswerSource
    let lastError: String?

    var isReady: Bool {
        ollamaRunning && modelInstalled
    }

    var statusText: String {
        if !ollamaRunning { return "Ollama Not Running" }
        if !modelInstalled { return "Model Not Pulled" }
        return "Ready"
    }
}

struct LocalLLMRequest: Equatable {
    let prompt: String
    let systemPrompt: String?
    let modelName: String
    let temperature: Double?
}

struct LLMToken: Equatable {
    let text: String
    let source: AnswerSource
    let modelName: String
}

protocol LocalLLMProvider {
    var id: String { get }
    var displayName: String { get }
    func healthCheck(modelName: String) async -> LocalLLMHealth
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error>
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error>
}

enum OllamaQwenProviderError: LocalizedError, Equatable {
    case ollamaNotRunning
    case modelNotReady(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .ollamaNotRunning:
            return "Ollama is not running on localhost."
        case .modelNotReady(let model):
            return "Ollama model '\(model)' is not installed."
        case .invalidResponse(let message):
            return message
        }
    }
}

final class OllamaQwenProvider: LocalLLMProvider {
    let id = "ollama_qwen"
    let displayName = "Qwen via Ollama"

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = OllamaQwenProvider.defaultSession()
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    private static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        do {
            let models = try await listModels()
            return LocalLLMHealth(
                ollamaRunning: true,
                selectedModel: modelName,
                modelInstalled: models.contains(modelName),
                providerSource: .ollamaQwen,
                lastError: nil
            )
        } catch {
            return LocalLLMHealth(
                ollamaRunning: false,
                selectedModel: modelName,
                modelInstalled: false,
                providerSource: .ollamaQwen,
                lastError: error.localizedDescription
            )
        }
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: modelName, stream: true))

                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)

                    var bufferedLine = ""
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let scalar = UnicodeScalar(Int(byte))
                        guard let scalar else { continue }
                        let char = Character(scalar)
                        if char == "\n" {
                            try emitPullLine(bufferedLine, modelName: modelName, continuation: continuation)
                            bufferedLine.removeAll(keepingCapacity: true)
                        } else {
                            bufferedLine.append(char)
                        }
                    }
                    if !bufferedLine.isEmpty {
                        try emitPullLine(bufferedLine, modelName: modelName, continuation: continuation)
                    }
                    continuation.yield(.completed(modelID: modelName, totalBytes: nil))
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

    func generateAnswer(request localRequest: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let health = await healthCheck(modelName: localRequest.modelName)
        guard health.ollamaRunning else {
            throw OllamaQwenProviderError.ollamaNotRunning
        }
        guard health.modelInstalled else {
            throw OllamaQwenProviderError.modelNotReady(localRequest.modelName)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaGenerateRequest(
            model: localRequest.modelName,
            prompt: localRequest.prompt,
            system: localRequest.systemPrompt,
            stream: true,
            options: localRequest.temperature.map { ["temperature": $0] }
        ))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)

                    var bufferedLine = ""
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let scalar = UnicodeScalar(Int(byte))
                        guard let scalar else { continue }
                        let char = Character(scalar)
                        if char == "\n" {
                            try emitGenerateLine(bufferedLine, modelName: localRequest.modelName, continuation: continuation)
                            bufferedLine.removeAll(keepingCapacity: true)
                        } else {
                            bufferedLine.append(char)
                        }
                    }
                    if !bufferedLine.isEmpty {
                        try emitGenerateLine(bufferedLine, modelName: localRequest.modelName, continuation: continuation)
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

    private func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await session.data(from: url)
        try Self.validate(response)
        let tags = try decoder.decode(OllamaTagsResponse.self, from: data)
        return tags.models.map(\.name)
    }

    private func emitPullLine(
        _ line: String,
        modelName: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let event = try decoder.decode(OllamaPullResponse.self, from: Data(trimmed.utf8))
        let total = event.total.map(Int64.init)
        let completed = Int64(event.completed ?? 0)
        let progress = total.flatMap { $0 > 0 ? Double(completed) / Double($0) : nil } ?? 0
        continuation.yield(ModelDownloadProgress(
            modelID: modelName,
            progress: min(max(progress, 0), 1),
            downloadedBytes: completed,
            totalBytes: total,
            speedBytesPerSecond: nil,
            statusMessage: event.status
        ))
    }

    private func emitGenerateLine(
        _ line: String,
        modelName: String,
        continuation: AsyncThrowingStream<LLMToken, Error>.Continuation
    ) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let event = try decoder.decode(OllamaGenerateResponse.self, from: Data(trimmed.utf8))
        if !event.response.isEmpty {
            continuation.yield(LLMToken(text: event.response, source: .ollamaQwen, modelName: modelName))
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaQwenProviderError.invalidResponse("Ollama returned HTTP \(http.statusCode).")
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}

private struct OllamaPullRequest: Encodable {
    let model: String
    let stream: Bool
}

private struct OllamaPullResponse: Decodable {
    let status: String
    let completed: Int?
    let total: Int?
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let system: String?
    let stream: Bool
    let options: [String: Double]?
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
    let done: Bool?
}
