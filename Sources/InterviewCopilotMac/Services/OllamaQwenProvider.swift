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
    let responseFormat: String?

    init(
        prompt: String,
        systemPrompt: String?,
        modelName: String,
        temperature: Double?,
        numPredict: Int? = nil,
        responseFormat: String? = nil
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.modelName = modelName
        self.temperature = temperature
        self.numPredict = numPredict
        self.responseFormat = responseFormat
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

protocol LocalLLMDiagnosticsProviding {
    var lastGenerationDiagnostics: OllamaProviderDiagnostics { get }
}

enum OllamaQwenProviderError: LocalizedError, Equatable {
    case ollamaNotRunning
    case modelNotReady(String)
    case invalidResponse(String)
    case categorized(OllamaFailureCategory, String)

    var category: OllamaFailureCategory {
        switch self {
        case .ollamaNotRunning, .modelNotReady:
            return .providerHTTPError
        case .invalidResponse:
            return .responseSchemaMismatch
        case .categorized(let category, _):
            return category
        }
    }

    var errorDescription: String? {
        switch self {
        case .ollamaNotRunning:
            return "Ollama is not running on localhost."
        case .modelNotReady(let model):
            return "Ollama model '\(model)' is not installed."
        case .invalidResponse(let message):
            return message
        case .categorized(_, let message):
            return message
        }
    }
}

final class OllamaQwenProvider: LocalLLMProvider, LocalLLMDiagnosticsProviding {
    let id = "ollama_qwen"
    let displayName = "Qwen via Ollama"

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let diagnosticsLock = NSLock()
    private var storedGenerationDiagnostics = OllamaProviderDiagnostics.empty()

    var lastGenerationDiagnostics: OllamaProviderDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedGenerationDiagnostics
    }

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

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let fallbackText = try await generateChatAnswer(request: localRequest) {
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

    private func makeChatRequest(_ payload: OllamaChatRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private func generateChatAnswer(request localRequest: LocalLLMRequest) async throws -> String? {
        var messages: [OllamaChatMessage] = []
        if let systemPrompt = localRequest.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            messages.append(OllamaChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(OllamaChatMessage(role: "user", content: localRequest.prompt))

        let payload = OllamaChatRequest(
            model: localRequest.modelName,
            messages: messages,
            stream: false,
            think: false,
            format: localRequest.responseFormat,
            options: OllamaGenerateOptions(
                temperature: localRequest.temperature,
                numPredict: localRequest.numPredict
            )
        )
        let request = try makeChatRequest(payload)
        var accumulator = OllamaResponseAccumulator(schema: .chatMessageContent)
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let line = String(data: data, encoding: .utf8) else {
                throw OllamaQwenProviderError.categorized(
                    .responseSchemaMismatch,
                    "Ollama returned a non-UTF-8 response."
                )
            }
            _ = try accumulator.ingest(line)
            let parsed = try accumulator.finish(requireDone: false)
            var diagnostics = parsed.diagnostics
            diagnostics.endpoint = baseURL.appendingPathComponent("api/chat").absoluteString
            diagnostics.model = localRequest.modelName
            diagnostics.streamMode = false
            diagnostics.requestMessageCount = messages.count
            diagnostics.systemPromptCharacters = localRequest.systemPrompt?.count ?? 0
            diagnostics.userPromptCharacters = localRequest.prompt.count
            storeDiagnostics(diagnostics)
            return parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            var diagnostics = accumulator.currentDiagnostics
            diagnostics.endpoint = baseURL.appendingPathComponent("api/chat").absoluteString
            diagnostics.model = localRequest.modelName
            diagnostics.streamMode = false
            diagnostics.responseSchema = .chatMessageContent
            diagnostics.requestMessageCount = messages.count
            diagnostics.systemPromptCharacters = localRequest.systemPrompt?.count ?? 0
            diagnostics.userPromptCharacters = localRequest.prompt.count
            diagnostics.finalErrorCategory = OllamaFailureCategory.classify(error)
            storeDiagnostics(diagnostics)
            throw error
        }
    }

    private func storeDiagnostics(_ diagnostics: OllamaProviderDiagnostics) {
        diagnosticsLock.lock()
        storedGenerationDiagnostics = diagnostics
        diagnosticsLock.unlock()
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
            throw OllamaQwenProviderError.categorized(
                .providerHTTPError,
                "Ollama returned HTTP \(http.statusCode)."
            )
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

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let think: Bool?
    let format: String?
    let options: OllamaGenerateOptions?
}

private struct OllamaChatMessage: Encodable, Decodable {
    let role: String
    let content: String
    let thinking: String?

    init(role: String, content: String, thinking: String? = nil) {
        self.role = role
        self.content = content
        self.thinking = thinking
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

private struct OllamaChatResponse: Decodable {
    let message: OllamaChatMessage?
    let done: Bool?
    let doneReason: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case doneReason = "done_reason"
        case error
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
