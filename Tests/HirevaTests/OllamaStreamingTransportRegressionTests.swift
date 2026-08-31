import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
struct OllamaStreamingTransportRegressionTests {
    @Test
    func streamsFinalAnswerChunksBeforeDoneAcrossArbitraryNetworkBoundaries() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/chat":
                probe.recordChatRequest(request)
                return OllamaStreamingPlan(
                    chunks: [
                        .init(delayNanoseconds: 0, data: Data(#"{"message":{"role":"assistant","content":"First"#.utf8)),
                        .init(delayNanoseconds: 10_000_000, data: Data(#" chunk"},"done":false}"#.utf8)),
                        .init(delayNanoseconds: 0, data: Data("\n".utf8)),
                        .init(delayNanoseconds: 0, data: Data(#"{"message":{"role":"assistant","content":" then second."},"done":false}"#.utf8)),
                        .init(delayNanoseconds: 0, data: Data("\n".utf8)),
                        .init(delayNanoseconds: 500_000_000, data: Data(#"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#.utf8)),
                        .init(delayNanoseconds: 0, data: Data("\n".utf8))
                    ],
                    onFinish: { probe.markChatFinished() }
                )
            default:
                return .httpError(404)
            }
        }

        let stream = try await provider.generateAnswer(request: request())
        var iterator = stream.makeAsyncIterator()
        let first = try #require(try await iterator.next())

        #expect(first.text == "First chunk")
        #expect(!probe.chatFinished)
        let second = try #require(try await iterator.next())
        #expect(second.text == " then second.")
        #expect(try await iterator.next() == nil)
        #expect(probe.chatRequestStreamValue == true)
        #expect(probe.chatRequestThinkValue == false)
    }

    @Test
    func ignoresThinkingAndRejectsThinkingOnlyCompletion() async throws {
        let provider = makeProvider { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/chat":
                return .lines([
                    #"{"message":{"role":"assistant","content":"","thinking":"internal-only"},"done":false}"#,
                    #"{"message":{"role":"assistant","content":""},"done":true}"#
                ])
            default:
                return .httpError(404)
            }
        }

        await expectFailure(.reasoningReceivedWithoutFinalAnswer) {
            _ = try await collect(provider: provider, request: request())
        }
    }

    @Test
    func toleratesOneMalformedEventButRejectsAnAllMalformedStream() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/chat":
                let chatNumber = probe.incrementChatCount()
                if chatNumber == 1 {
                    return .lines([
                        "{malformed",
                        #"{"message":{"role":"assistant","content":"Recovered answer."},"done":false}"#,
                        #"{"done":true}"#
                    ])
                }
                return .lines(["{malformed", "still-not-json"])
            default:
                return .httpError(404)
            }
        }

        let recovered = try await collect(provider: provider, request: request())
        #expect(recovered.map(\.text) == ["Recovered answer."])
        await expectFailure(.malformedStreamEvent) {
            _ = try await collect(provider: provider, request: request())
        }
    }

    @Test
    func rejectsContentStreamThatEndsWithoutDoneEvent() async throws {
        let provider = makeProvider { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/chat":
                return .lines([
                    #"{"message":{"role":"assistant","content":"Incomplete answer."},"done":false}"#
                ])
            default:
                return .httpError(404)
            }
        }

        await expectFailure(.streamParserDroppedContent) {
            _ = try await collect(provider: provider, request: request())
        }
    }

    @Test
    func cancellationDuringReadinessIsNotReportedAsOllamaUnavailable() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            if request.url?.path == "/api/tags" {
                return OllamaStreamingPlan(
                    chunks: [.init(delayNanoseconds: 2_000_000_000, data: Data(#"{"models":[{"name":"synthetic-qwen"}]}"#.utf8))],
                    onStart: { probe.markTagsStarted() }
                )
            }
            return .httpError(404)
        }

        let task = Task {
            _ = try await provider.generateAnswer(request: request())
        }
        try await probe.waitUntil { $0.tagsStarted }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected readiness cancellation")
        } catch {
            #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
            #expect((error as? OllamaQwenProviderError) != .ollamaNotRunning)
        }
    }

    @Test
    func twoSuccessfulGenerationsUseOneShortLivedTagsCheck() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            switch request.url?.path {
            case "/api/tags":
                probe.incrementTagsCount()
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/chat":
                return .lines([
                    #"{"message":{"role":"assistant","content":"Synthetic answer."},"done":false}"#,
                    #"{"done":true}"#
                ])
            default:
                return .httpError(404)
            }
        }

        _ = try await collect(provider: provider, request: request())
        _ = try await collect(provider: provider, request: request())

        #expect(probe.tagsCount == 1)
    }

    @Test
    func pullAndGenerationErrorInvalidateReadinessCache() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            switch request.url?.path {
            case "/api/tags":
                probe.incrementTagsCount()
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            case "/api/pull":
                return .lines([#"{"status":"success","completed":1,"total":1}"#])
            case "/api/chat":
                let chatNumber = probe.incrementChatCount()
                if chatNumber == 2 {
                    return .httpError(503)
                }
                return .lines([
                    #"{"message":{"role":"assistant","content":"Synthetic answer."},"done":false}"#,
                    #"{"done":true}"#
                ])
            default:
                return .httpError(404)
            }
        }

        _ = try await collect(provider: provider, request: request())
        for try await _ in provider.pullModel("synthetic-qwen") {}
        await expectFailure(.providerHTTPError) {
            _ = try await collect(provider: provider, request: request())
        }
        _ = try await collect(provider: provider, request: request())

        #expect(probe.tagsCount == 3)
    }

    @Test
    func lateGenerationCannotOverwriteNewerDiagnostics() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider(probe: probe) { request in
            switch request.url?.path {
            case "/api/tags":
                return .json(#"{"models":[{"name":"synthetic-first"},{"name":"synthetic-second"}]}"#)
            case "/api/chat":
                let model = probe.modelName(from: request)
                if model == "synthetic-first" {
                    return OllamaStreamingPlan.lines([
                        #"{"message":{"role":"assistant","content":"First answer."},"done":false}"#,
                        #"{"done":true}"#
                    ], initialDelayNanoseconds: 400_000_000, onStart: { probe.markFirstChatStarted() })
                }
                return .lines([
                    #"{"message":{"role":"assistant","content":"Second answer."},"done":false}"#,
                    #"{"done":true}"#
                ])
            default:
                return .httpError(404)
            }
        }

        let firstTask = Task {
            try await collect(provider: provider, request: request(model: "synthetic-first"))
        }
        try await probe.waitUntil { $0.firstChatStarted }
        let second = try await collect(provider: provider, request: request(model: "synthetic-second"))
        let first = try await firstTask.value

        #expect(first.map(\.text) == ["First answer."])
        #expect(second.map(\.text) == ["Second answer."])
        #expect(provider.lastGenerationDiagnostics.model == "synthetic-second")
    }

    private func makeProvider(
        probe: OllamaStreamingProbe = OllamaStreamingProbe(),
        handler: @escaping (URLRequest) -> OllamaStreamingPlan
    ) -> OllamaQwenProvider {
        OllamaStreamingURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        return OllamaQwenProvider(session: URLSession(configuration: configuration))
    }

    private func request(model: String = "synthetic-qwen") -> LocalLLMRequest {
        LocalLLMRequest(
            prompt: "Synthetic interview question",
            systemPrompt: "Synthetic system prompt",
            modelName: model,
            temperature: 0,
            numPredict: 32
        )
    }

    private func collect(
        provider: OllamaQwenProvider,
        request: LocalLLMRequest
    ) async throws -> [LLMToken] {
        let stream = try await provider.generateAnswer(request: request)
        var tokens: [LLMToken] = []
        for try await token in stream {
            tokens.append(token)
        }
        return tokens
    }

    private func expectFailure(
        _ expected: OllamaFailureCategory,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected failure category \(expected.rawValue)")
        } catch {
            #expect(OllamaFailureCategory.classify(error) == expected)
        }
    }
}

private struct OllamaStreamingPlan {
    struct Chunk {
        let delayNanoseconds: UInt64
        let data: Data
    }

    let statusCode: Int
    let chunks: [Chunk]
    let finishes: Bool
    let onStart: (() -> Void)?
    let onFinish: (() -> Void)?

    init(
        statusCode: Int = 200,
        chunks: [Chunk],
        finishes: Bool = true,
        onStart: (() -> Void)? = nil,
        onFinish: (() -> Void)? = nil
    ) {
        self.statusCode = statusCode
        self.chunks = chunks
        self.finishes = finishes
        self.onStart = onStart
        self.onFinish = onFinish
    }

    static func json(_ json: String) -> OllamaStreamingPlan {
        lines([json])
    }

    static func lines(
        _ lines: [String],
        initialDelayNanoseconds: UInt64 = 0,
        onStart: (() -> Void)? = nil
    ) -> OllamaStreamingPlan {
        OllamaStreamingPlan(
            chunks: lines.enumerated().map { index, line in
                Chunk(
                    delayNanoseconds: index == 0 ? initialDelayNanoseconds : 0,
                    data: Data((line + "\n").utf8)
                )
            },
            onStart: onStart
        )
    }

    static func httpError(_ statusCode: Int) -> OllamaStreamingPlan {
        OllamaStreamingPlan(statusCode: statusCode, chunks: [])
    }
}

private final class OllamaStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> OllamaStreamingPlan)?
    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        plan.onStart?()
        let response = HTTPURLResponse(
            url: url,
            statusCode: plan.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for chunk in plan.chunks {
                    if chunk.delayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunk.delayNanoseconds)
                    }
                    try Task.checkCancellation()
                    self.client?.urlProtocol(self, didLoad: chunk.data)
                }
                guard plan.finishes else { return }
                plan.onFinish?()
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}

private final class OllamaStreamingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storageTagsCount = 0
    private var storageChatCount = 0
    private var storageTagsStarted = false
    private var storageFirstChatStarted = false
    private var storageChatFinished = false
    private var storageChatRequestStreamValue: Bool?
    private var storageChatRequestThinkValue: Bool?

    var tagsCount: Int { withLock { storageTagsCount } }
    var tagsStarted: Bool { withLock { storageTagsStarted } }
    var firstChatStarted: Bool { withLock { storageFirstChatStarted } }
    var chatFinished: Bool { withLock { storageChatFinished } }
    var chatRequestStreamValue: Bool? { withLock { storageChatRequestStreamValue } }
    var chatRequestThinkValue: Bool? { withLock { storageChatRequestThinkValue } }

    func incrementTagsCount() {
        withLock { storageTagsCount += 1 }
    }

    func incrementChatCount() -> Int {
        withLock {
            storageChatCount += 1
            return storageChatCount
        }
    }

    func markTagsStarted() { withLock { storageTagsStarted = true } }
    func markFirstChatStarted() { withLock { storageFirstChatStarted = true } }
    func markChatFinished() { withLock { storageChatFinished = true } }

    func recordChatRequest(_ request: URLRequest) {
        guard let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return
        }
        withLock {
            storageChatRequestStreamValue = json["stream"] as? Bool
            storageChatRequestThinkValue = json["think"] as? Bool
        }
    }

    func modelName(from request: URLRequest) -> String? {
        guard let body = requestBody(request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func waitUntil(
        _ predicate: (OllamaStreamingProbe) -> Bool,
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if predicate(self) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw OllamaStreamingProbeError.timeout
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private enum OllamaStreamingProbeError: Error {
    case timeout
}
