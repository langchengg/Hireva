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
    let numPredict: Int?

    init(
        prompt: String,
        systemPrompt: String?,
        modelName: String,
        temperature: Double?,
        numPredict: Int? = nil
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.modelName = modelName
        self.temperature = temperature
        self.numPredict = numPredict
    }
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
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
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
                    request.timeoutInterval = 3_600
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

        let payload = OllamaGenerateRequest(
            model: localRequest.modelName,
            prompt: localRequest.prompt,
            system: localRequest.systemPrompt,
            stream: true,
            think: false,
            options: OllamaGenerateOptions(
                temperature: localRequest.temperature,
                numPredict: localRequest.numPredict
            )
        )
        let request = try makeGenerateRequest(payload)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)

                    var bufferedLine = ""
                    var yieldedTokenCount = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let scalar = UnicodeScalar(Int(byte))
                        guard let scalar else { continue }
                        let char = Character(scalar)
                        if char == "\n" {
                            if try emitGenerateLine(bufferedLine, modelName: localRequest.modelName, continuation: continuation) {
                                yieldedTokenCount += 1
                            }
                            bufferedLine.removeAll(keepingCapacity: true)
                        } else {
                            bufferedLine.append(char)
                        }
                    }
                    if !bufferedLine.isEmpty {
                        if try emitGenerateLine(bufferedLine, modelName: localRequest.modelName, continuation: continuation) {
                            yieldedTokenCount += 1
                        }
                    }

                    if yieldedTokenCount == 0,
                       let fallbackText = try await generateNonStreamingAnswer(
                        payload: payload.withStream(false)
                       ) {
                        continuation.yield(LLMToken(
                            text: fallbackText,
                            source: .ollamaQwen,
                            modelName: localRequest.modelName
                        ))
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

    private func makeGenerateRequest(_ payload: OllamaGenerateRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func generateNonStreamingAnswer(
        payload: OllamaGenerateRequest
    ) async throws -> String? {
        let request = try makeGenerateRequest(payload)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let event = try decoder.decode(OllamaGenerateResponse.self, from: data)
        if let error = event.error, !error.isEmpty {
            throw OllamaQwenProviderError.invalidResponse(error)
        }
        let text = (event.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text
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
    ) throws -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let event = try decoder.decode(OllamaGenerateResponse.self, from: Data(trimmed.utf8))
        if let error = event.error, !error.isEmpty {
            throw OllamaQwenProviderError.invalidResponse(error)
        }
        let text = event.response ?? ""
        if !text.isEmpty {
            continuation.yield(LLMToken(text: text, source: .ollamaQwen, modelName: modelName))
            return true
        }
        return false
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
    let think: Bool?
    let options: OllamaGenerateOptions?

    func withStream(_ stream: Bool) -> OllamaGenerateRequest {
        OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            system: system,
            stream: stream,
            think: think,
            options: options
        )
    }
}

private struct OllamaGenerateOptions: Encodable {
    let temperature: Double?
    let numPredict: Int?

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
    }
}

private struct OllamaGenerateResponse: Decodable {
    let response: String?
    let done: Bool?
    let doneReason: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case response
        case done
        case doneReason = "done_reason"
        case error
    }
}
