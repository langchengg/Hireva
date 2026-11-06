import Foundation
import os

struct LocalLLMHealth: Equatable, Sendable {
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

struct LocalLLMRequest: Equatable, Sendable {
    let prompt: String
    let systemPrompt: String?
    let modelName: String
    let temperature: Double?
    let numPredict: Int?
    let responseFormat: String?
    let responseSchema: LocalJSONValue?
    // Opt-in grammar property order; nil preserves the original transport wire.
    let responseSchemaPropertyOrder: [String]?
    let thinkingEnabled: Bool

    init(
        prompt: String,
        systemPrompt: String?,
        modelName: String,
        temperature: Double?,
        numPredict: Int? = nil,
        responseFormat: String? = nil,
        responseSchema: LocalJSONValue? = nil,
        responseSchemaPropertyOrder: [String]? = nil,
        thinkingEnabled: Bool = false
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.modelName = modelName
        self.temperature = temperature
        self.numPredict = numPredict
        self.responseFormat = responseFormat
        self.responseSchema = responseSchema
        self.responseSchemaPropertyOrder = responseSchemaPropertyOrder
        self.thinkingEnabled = thinkingEnabled
    }
}

struct LLMToken: Equatable, Sendable {
    let text: String
    let source: AnswerSource
    let modelName: String
}

protocol LocalLLMProvider: Sendable {
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

final class OllamaQwenProvider: LocalLLMProvider, LocalLLMDiagnosticsProviding, Sendable {
    let id = "ollama_qwen"
    let displayName = "Qwen via Ollama"

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    /// Network work and awaits stay outside this shared-state lock.
    private struct SharedState: Sendable {
        var generationDiagnostics = OllamaProviderDiagnostics.empty()
        var latestGeneration = 0
        var transportRequestCount = 0
        var cachedModelNames = Set<String>()
        var modelCacheExpiresAt: Date?
        var modelCacheRevision: UInt64 = 0
    }
    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())
    private let modelCacheTTL: TimeInterval = 3
    private let cacheNow: @Sendable () -> Date
    // Test-controlled cleanup readiness; no checkpoint is installed in production.
    private let producerExitCheckpoint: (@Sendable (Int) async -> Void)?

    var lastGenerationDiagnostics: OllamaProviderDiagnostics {
        sharedState.withLock { $0.generationDiagnostics }
    }

    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = OllamaQwenProvider.defaultSession(),
        cacheNow: @escaping @Sendable () -> Date = { Date() },
        producerExitCheckpoint: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cacheNow = cacheNow
        self.producerExitCheckpoint = producerExitCheckpoint
    }

    private static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration)
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        do {
            let models = try await modelNamesUsingCache()
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

    /// Load-only readiness; no candidate content, generation admission or residency override.
    func prepareModel(modelName: String) async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": modelName])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        let result = try decoder.decode(OllamaGenerateResponse.self, from: data)
        guard result.error == nil, result.done == true, result.doneReason == "load",
              result.response?.isEmpty != false else {
            throw OllamaQwenProviderError.invalidResponse("Ollama did not confirm model preparation.")
        }
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        invalidateModelCache()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 3_600
                    request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: modelName, stream: true))

                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)

                    // Frame NDJSON as bytes: a transport chunk may split a UTF-8 scalar.
                    // Pull has its own terminal status; EOF alone is not installation success.
                    var bufferedLine = Data()
                    var receivedSuccess = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 0x0A {
                            if try emitPullLine(bufferedLine, modelName: modelName, continuation: continuation) {
                                receivedSuccess = true
                                break
                            }
                            bufferedLine.removeAll(keepingCapacity: true)
                        } else {
                            bufferedLine.append(byte)
                        }
                    }
                    try Task.checkCancellation()
                    if !receivedSuccess, !bufferedLine.isEmpty {
                        receivedSuccess = try emitPullLine(bufferedLine, modelName: modelName, continuation: continuation)
                    }
                    guard receivedSuccess else {
                        throw OllamaQwenProviderError.invalidResponse(
                            "Ollama model pull ended before its success status."
                        )
                    }
                    self.invalidateModelCache()
                    continuation.finish()
                } catch {
                    self.invalidateModelCache()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// The stream and its exact producer share one request lifetime. The caller
    /// may retain/join this handle without stopping another provider request.
    struct OwnedAnswerStream: Sendable {
        let stream: AsyncThrowingStream<LLMToken, Error>
        let producerTask: Task<Void, Never>
    }

    /// Compatibility stream projection. Lifecycle owners use generateOwnedAnswer
    /// so consumer completion is not confused with producer/resource exit.
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        try await generateOwnedAnswer(request: request).stream
    }

    func generateOwnedAnswer(request localRequest: LocalLLMRequest) async throws -> OwnedAnswerStream {
        try Task.checkCancellation()
        let models = try await modelNamesUsingCache()
        try Task.checkCancellation()
        guard models.contains(localRequest.modelName) else {
            throw OllamaQwenProviderError.modelNotReady(localRequest.modelName)
        }
        let diagnosticsGeneration = beginDiagnosticsGeneration(modelName: localRequest.modelName)
        let (stream, continuation) = AsyncThrowingStream<LLMToken, Error>.makeStream()
        let task = Task {
            do {
                try await streamChatAnswer(
                    request: localRequest,
                    diagnosticsGeneration: diagnosticsGeneration,
                    continuation: continuation
                )
                continuation.finish()
            } catch {
                self.invalidateModelCache()
                continuation.finish(throwing: error)
            }
            if let producerExitCheckpoint {
                await producerExitCheckpoint(diagnosticsGeneration)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return OwnedAnswerStream(stream: stream, producerTask: task)
    }

    private func makeChatRequest(_ payload: OllamaChatRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        // Keep request serialization reproducible across process launches.
        // This does not imply deterministic model output or grammar behavior.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func streamChatAnswer(
        request localRequest: LocalLLMRequest,
        diagnosticsGeneration: Int,
        continuation: AsyncThrowingStream<LLMToken, Error>.Continuation
    ) async throws {
        var messages: [OllamaChatMessage] = []
        if let systemPrompt = localRequest.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            messages.append(OllamaChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(OllamaChatMessage(role: "user", content: localRequest.prompt))

        let payload = OllamaChatRequest(
            model: localRequest.modelName,
            messages: messages,
            stream: true,
            think: localRequest.thinkingEnabled,
            format: localRequest.responseSchema ?? localRequest.responseFormat.map(LocalJSONValue.string),
            options: OllamaGenerateOptions(
                temperature: localRequest.temperature,
                numPredict: localRequest.numPredict
            )
        )
        var request = try makeChatRequest(payload)
        // Ollama 0.24.0 /api/chat drops format for thinking-capable builtin
        // parsers (including Qwen 3.5) even when think=false. /api/generate
        // keeps format and applies the server's own model renderer. Use that
        // endpoint for constrained, non-thinking requests; never compose a
        // model-specific prompt template or relax the strict output decoder.
        let constrained = localRequest.responseSchema != nil && !localRequest.thinkingEnabled
        let responseSchema: OllamaResponseSchema = constrained ? .generateResponse : .chatMessageContent
        guard localRequest.responseSchemaPropertyOrder == nil || constrained else {
            throw OllamaQwenProviderError.invalidResponse("Explicit schema order requires a non-thinking structured request.")
        }
        if constrained {
            request.url = baseURL.appendingPathComponent("api/generate")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encode(OllamaStructuredGenerateRequest(
                model: localRequest.modelName, prompt: localRequest.prompt,
                system: localRequest.systemPrompt, stream: true, think: false,
                format: localRequest.responseSchema!, options: payload.options, truncate: false, shift: false
            ))
            if let order = localRequest.responseSchemaPropertyOrder {
                request.httpBody = try Self.orderedSchemaBody(body, schema: localRequest.responseSchema!, order: order)
            } else {
                request.httpBody = body
            }
        }
        var accumulator = OllamaResponseAccumulator(schema: responseSchema)
        do {
            sharedState.withLock { $0.transportRequestCount += 1 }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Self.validate(response)
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let content = try accumulator.ingest(line), !content.isEmpty {
                    continuation.yield(LLMToken(
                        text: content,
                        source: .ollamaQwen,
                        modelName: localRequest.modelName
                    ))
                }
                if accumulator.currentDiagnostics.streamCompleted { break }
            }
            let parsed = try accumulator.finish(requireDone: true)
            if constrained, parsed.diagnostics.doneReason == "length" {
                throw OllamaQwenProviderError.invalidResponse("Ollama reached the context or token limit before a normal structured completion.")
            }
            var diagnostics = parsed.diagnostics
            diagnostics.endpoint = request.url?.absoluteString ?? ""
            diagnostics.model = localRequest.modelName
            diagnostics.streamMode = true
            diagnostics.requestMessageCount = messages.count
            diagnostics.systemPromptCharacters = localRequest.systemPrompt?.count ?? 0
            diagnostics.userPromptCharacters = localRequest.prompt.count
            storeDiagnostics(diagnostics, generation: diagnosticsGeneration)
        } catch {
            var diagnostics = accumulator.currentDiagnostics
            diagnostics.endpoint = request.url?.absoluteString ?? ""
            diagnostics.model = localRequest.modelName
            diagnostics.streamMode = true
            diagnostics.responseSchema = responseSchema
            diagnostics.requestMessageCount = messages.count
            diagnostics.systemPromptCharacters = localRequest.systemPrompt?.count ?? 0
            diagnostics.userPromptCharacters = localRequest.prompt.count
            diagnostics.finalErrorCategory = OllamaFailureCategory.classify(error)
            storeDiagnostics(diagnostics, generation: diagnosticsGeneration)
            throw error
        }
    }

    /// Only the admitted object's properties are reordered. Transient JSONSerialization values
    /// preserve the encoded outer body's NSNumber integers and optional fields;
    /// they never escape this synchronous call. Scalar escaping remains Foundation's.
    private static func orderedSchemaBody(_ data: Data, schema: LocalJSONValue, order: [String]) throws -> Data {
        func completeRequiredObject(_ value: LocalJSONValue) -> Bool {
            guard case .object(let root) = value, root["type"] == .string("object"),
                  case .object(let fields)? = root["properties"], case .array(let required)? = root["required"],
                  root["anyOf"] == nil, root["oneOf"] == nil, root["allOf"] == nil,
                  Set(order) == Set(fields.keys), required.count == order.count,
                  Set(required.compactMap { if case .string(let id) = $0 { return id }; return nil }).count == order.count else { return false }
            return required.allSatisfy { if case .string(let id) = $0 { return fields[id] != nil }; return false }
        }
        let propertyPaths: [[String]]
        if case .object(let root) = schema, Set(root.keys) == Set(["anyOf"]),
           case .array(let branches)? = root["anyOf"], !branches.isEmpty,
           branches.allSatisfy({ branch in
               guard case .object(let object) = branch,
                     Set(object.keys) == Set(["type", "properties", "required", "additionalProperties"]),
                     object["additionalProperties"] == .boolean(false) else { return false }
               return completeRequiredObject(branch)
           }) {
            propertyPaths = branches.indices.map { ["anyOf", String($0), "properties"] }
        } else if completeRequiredObject(schema) { propertyPaths = [["properties"]] }
        else { propertyPaths = [] }
        guard !order.isEmpty, Set(order).count == order.count, !propertyPaths.isEmpty,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["format"] != nil else {
            throw OllamaQwenProviderError.invalidResponse("Explicit schema order requires complete unique fields for a required object or its strict anyOf branches.")
        }
        let scalarEncoder = JSONEncoder()
        func object(_ entries: [(String, Data)]) throws -> Data {
            var result = Data([0x7B])
            for (index, entry) in entries.enumerated() {
                if index > 0 { result.append(0x2C) }
                result.append(try scalarEncoder.encode(entry.0)); result.append(0x3A)
                result.append(entry.1)
            }
            result.append(0x7D); return result
        }
        func encodeSchema(_ value: LocalJSONValue, path: [String]) throws -> Data {
            switch value {
            case .object(let values):
                let keys = propertyPaths.contains(path) ? order : values.keys.sorted()
                return try object(keys.map { key in
                    guard let value = values[key] else { throw OllamaQwenProviderError.invalidResponse("Ordered schema field is absent.") }
                    return (key, try encodeSchema(value, path: path + [key]))
                })
            case .array(let values):
                var result = Data([0x5B])
                for (index, value) in values.enumerated() {
                    if index > 0 { result.append(0x2C) }
                    result.append(try encodeSchema(value, path: path + [String(index)]))
                }
                result.append(0x5D); return result
            default: return try scalarEncoder.encode(value)
            }
        }
        let schemaData = try encodeSchema(schema, path: [])
        return try object(body.keys.sorted().map { key in
            guard let value = body[key] else { throw OllamaQwenProviderError.invalidResponse("Structured body field is absent.") }
            let valueData: Data
            if key == "format" { valueData = schemaData }
            else { valueData = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
            return (key, valueData)
        })
    }

    private func beginDiagnosticsGeneration(modelName: String) -> Int {
        var diagnostics = OllamaProviderDiagnostics.empty()
        diagnostics.model = modelName
        diagnostics.endpoint = baseURL.appendingPathComponent("api/chat").absoluteString
        diagnostics.streamMode = true
        let snapshot = diagnostics
        return sharedState.withLock { state in
            state.latestGeneration += 1
            state.generationDiagnostics = snapshot
            return state.latestGeneration
        }
    }

    private func storeDiagnostics(_ diagnostics: OllamaProviderDiagnostics, generation: Int) {
        sharedState.withLock { state in
            if generation == state.latestGeneration {
                state.generationDiagnostics = diagnostics
                state.generationDiagnostics.transportRequestCount = state.transportRequestCount
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

    private func modelNamesUsingCache() async throws -> Set<String> {
        let snapshot = sharedState.withLock { state -> (revision: UInt64, names: Set<String>?) in
            guard let expiresAt = state.modelCacheExpiresAt, expiresAt > cacheNow() else {
                return (state.modelCacheRevision, nil)
            }
            return (state.modelCacheRevision, state.cachedModelNames)
        }
        if let cached = snapshot.names {
            return cached
        }

        let names = Set(try await listModels())
        sharedState.withLock { state in
            // An old HTTP result may serve its own caller, but cannot restore a
            // cache invalidated by a newer pull while the request was awaiting.
            guard state.modelCacheRevision == snapshot.revision else { return }
            state.cachedModelNames = names
            state.modelCacheExpiresAt = cacheNow().addingTimeInterval(modelCacheTTL)
        }
        return names
    }

    private func invalidateModelCache() {
        sharedState.withLock { state in
            state.modelCacheRevision &+= 1
            state.cachedModelNames = []
            state.modelCacheExpiresAt = nil
        }
    }

    private func emitPullLine(
        _ data: Data,
        modelName: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) throws -> Bool {
        guard let line = String(data: data, encoding: .utf8) else {
            throw OllamaQwenProviderError.invalidResponse("Ollama model pull returned invalid UTF-8.")
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let event: OllamaPullResponse
        do {
            event = try decoder.decode(OllamaPullResponse.self, from: Data(trimmed.utf8))
        } catch {
            throw OllamaQwenProviderError.invalidResponse("Ollama model pull returned malformed JSON.")
        }
        if let error = event.error, !error.isEmpty {
            throw OllamaQwenProviderError.invalidResponse(error)
        }
        guard let status = event.status, !status.isEmpty else {
            throw OllamaQwenProviderError.invalidResponse("Ollama model pull returned no status.")
        }
        let total = event.total
        if status == "success" {
            continuation.yield(.completed(modelID: modelName, totalBytes: total))
            return true
        }
        let completed = event.completed ?? 0
        let progress = total.flatMap { $0 > 0 ? Double(completed) / Double($0) : nil } ?? 0
        continuation.yield(ModelDownloadProgress(
            modelID: modelName,
            progress: min(max(progress, 0), 1),
            downloadedBytes: completed,
            totalBytes: total,
            speedBytesPerSecond: nil,
            statusMessage: status
        ))
        return false
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
    let status: String?
    let completed: Int64?
    let total: Int64?
    let error: String?
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let think: Bool?
    let format: LocalJSONValue?
    let options: OllamaGenerateOptions?
}

private struct OllamaStructuredGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let system: String?
    let stream: Bool
    let think: Bool
    let format: LocalJSONValue
    let options: OllamaGenerateOptions?
    // Reject input overflow and stop at context exhaustion instead of shifting frozen input.
    let truncate: Bool
    let shift: Bool
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
