import Foundation
import os
import Testing
@testable import Hireva

/// URLSession/URLProtocol packets and a releasable actual producer tail; no
/// local model, cloud request, Keychain, application database or audio device.
@Suite
@MainActor
struct SyntheticCaptureProducerOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [
        "Evaluate this practice answer",
        "Independently critique the complete original answer"
    ])
    func evaluatorInputIsCheckedBeforeEitherPhaseReachesTransport(phase: String) async throws {
        let fixture = CaptureTransportFixture()
        var capture = fixture.capture
        capture.expectedSourceEvidence = ""
        let request = LocalLLMRequest(prompt: "deliberately invalid evaluator JSON",
            systemPrompt: phase, modelName: fixture.request.modelName, temperature: 0)
        var rejectedMalformedInput = false
        do {
            _ = try await capture.generateAnswer(request: request)
        } catch is DecodingError {
            rejectedMalformedInput = true
        } catch {
            Issue.record("Expected evaluator JSON decoding failure: \(error)")
        }
        await fixture.exit.release()
        await capture.cancelAndJoinCaptures()
        fixture.close()
        #expect(rejectedMalformedInput)
        #expect(fixture.plan.generationRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func captureJoinRetainsActualProducerAfterNormalOrFailedBody(fails: Bool) async throws {
        let fixture = CaptureTransportFixture(statusCode: fails ? 503 : 200)
        let capture = fixture.capture
        var consumer: Task<Void, Never>?
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        var firstReturned = false
        var secondReturned = false
        let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let secondStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        func cleanup() async {
            consumer?.cancel()
            await fixture.exit.release()
            await first?.value; await second?.value
            await capture.cancelAndJoinCaptures()
            await consumer?.value
            firstStarted.continuation.finish(); secondStarted.continuation.finish()
            fixture.close()
        }
        do {
            let stream = try await capture.generateAnswer(request: fixture.request)
            consumer = Task { @MainActor in
                do { for try await _ in stream {} } catch {}
            }
            _ = try await fixture.exit.nextEntered()
            #expect(await fixture.exit.pendingCount() == 1)
            first = Task { @MainActor in
                firstStarted.continuation.yield(())
                await capture.cancelAndJoinCaptures()
                #expect(await fixture.exit.pendingCount() == 0,
                    "Capture join returned with its concrete Ollama producer still held.")
                firstReturned = true
            }
            _ = try await TestEventWaitTrace(label: "synthetic-capture-first-join")
                .nextEvent(in: firstStarted.stream, event: "waiter-started")
            second = Task { @MainActor in
                secondStarted.continuation.yield(())
                await capture.cancelAndJoinCaptures()
                #expect(await fixture.exit.pendingCount() == 0,
                    "Every capture teardown waiter must retain the same actual producer.")
                secondReturned = true
            }
            _ = try await TestEventWaitTrace(label: "synthetic-capture-second-join")
                .nextEvent(in: secondStarted.stream, event: "waiter-started")
            #expect(!firstReturned && !secondReturned)
            #expect(await fixture.exit.pendingCount() == 1)
            #expect(fixture.plan.generationRequests == 1)
            await fixture.exit.release()
            await first?.value; await second?.value
            #expect(firstReturned && secondReturned)
            #expect(await fixture.exit.pendingCount() == 0)
            #expect(fixture.plan.generationRequests == 1)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func captureConsumerCancellationStopsActualTransportAndJoinsHeldProducer() async throws {
        let fixture = CaptureTransportFixture(finishes: false)
        let capture = fixture.capture
        let tokenReceived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let joinStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var consumer: Task<Void, Never>?
        var join: Task<Void, Never>?
        var joinReturned = false
        func cleanup() async {
            consumer?.cancel()
            await fixture.exit.release()
            await join?.value; await capture.cancelAndJoinCaptures()
            await consumer?.value
            tokenReceived.continuation.finish(); joinStarted.continuation.finish()
            fixture.close()
        }
        do {
            let stream = try await capture.generateAnswer(request: fixture.request)
            consumer = Task { @MainActor in
                do {
                    for try await token in stream {
                        #expect(token.text == "captured synthetic packet")
                        tokenReceived.continuation.yield(())
                    }
                } catch {}
            }
            _ = try await TestEventWaitTrace(label: "synthetic-capture-token")
                .nextEvent(in: tokenReceived.stream, event: "token-received")
            consumer?.cancel()
            _ = try await TestEventWaitTrace(label: "synthetic-capture-transport")
                .nextEvent(in: fixture.plan.stopped.stream, event: "URLProtocol.stopLoading")
            _ = try await fixture.exit.nextEntered()
            join = Task { @MainActor in
                joinStarted.continuation.yield(())
                await capture.cancelAndJoinCaptures()
                #expect(await fixture.exit.pendingCount() == 0,
                    "Cancelled token consumer does not establish actual producer exit.")
                joinReturned = true
            }
            _ = try await TestEventWaitTrace(label: "synthetic-capture-cancel-join")
                .nextEvent(in: joinStarted.stream, event: "waiter-started")
            #expect(!joinReturned)
            #expect(await fixture.exit.pendingCount() == 1)
            await fixture.exit.release()
            await join?.value
            #expect(joinReturned)
            #expect(fixture.plan.generationRequests == 1)
            #expect(fixture.plan.generationStopCount >= 1)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func capturedUsageIsOptionalTerminalDataAfterActualProducerExit(constrained: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let frames = [
            #"{"done":true,"done_reason":"stop","prompt_eval_count":1379,"eval_count":43}"# + "\n",
            #"{"done":true,"done_reason":"stop"}"# + "\n",
            #"{"done":true,"done_reason":"stop","prompt_eval_count":0,"eval_count":0}"# + "\n"
        ]
        let fixture = CaptureTransportFixture(artifactDirectory: directory, constrained: constrained,
            terminalUsageFrames: frames)
        var consumer: Task<String, Error>?
        func resultFiles() throws -> Set<URL> {
            Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-result.json") })
        }
        func cleanup() async {
            consumer?.cancel()
            await fixture.exit.release()
            await fixture.capture.cancelAndJoinCaptures()
            _ = await consumer?.result
            fixture.close()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            var previousFiles = Set<URL>()
            for index in frames.indices {
                let stream = try await fixture.capture.generateAnswer(request: fixture.request)
                let task = Task {
                    var text = ""
                    for try await token in stream { text += token.text }
                    return text
                }
                consumer = task
                if index == 0 {
                    _ = try await fixture.exit.nextEntered()
                    #expect(await fixture.exit.pendingCount() == 1)
                    #expect(try resultFiles().isEmpty,
                        "The capture must not snapshot/publish a result while its exact producer is still held.")
                    await fixture.exit.release()
                }
                let text = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let value = try await task.value
                    try Task.checkCancellation()
                    return value
                } onCancel: { task.cancel() }
                #expect(text == "captured synthetic packet")
                let files = try resultFiles()
                let resultURL = try #require(files.subtracting(previousFiles).first)
                #expect(files.count == index + 1)
                #expect(files.subtracting(previousFiles).count == 1)
                previousFiles = files
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
                let captureID = try #require(object["captureID"] as? String)
                let requestURL = directory.appendingPathComponent("synthetic-local-\(fixture.capture.suffix)-\(captureID)-request.json")
                let requestObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any])
                #expect(requestObject["captureID"] as? String == captureID)
                #expect(object["streamFinished"] as? Bool == true)
                #expect(object["taskCancelled"] as? Bool == false)
                let diagnostics = try #require(object["providerDiagnostics"] as? [String: Any])
                #expect(diagnostics["model"] as? String == fixture.request.modelName)
                #expect(diagnostics["responseSchema"] as? String == (constrained ? "generate.response" : "chat.message.content"))
                #expect((diagnostics["endpoint"] as? String)?.hasSuffix(constrained ? "/api/generate" : "/api/chat") == true)
                #expect(diagnostics["streamCompleted"] as? Bool == true)
                if index == 0 {
                    #expect(diagnostics["prompt_eval_count"] as? Int == 1379)
                    #expect(diagnostics["eval_count"] as? Int == 43)
                } else if index == 1 {
                    #expect(diagnostics["prompt_eval_count"] == nil)
                    #expect(diagnostics["eval_count"] == nil)
                } else {
                    #expect(diagnostics["prompt_eval_count"] as? Int == 0)
                    #expect(diagnostics["eval_count"] as? Int == 0)
                }
                #expect(await fixture.exit.pendingCount() == 0)
            }
            #expect(fixture.plan.generationRequests == 3)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }
}

@MainActor
private final class CaptureTransportFixture {
    let exit: CaptureActualProducerExit
    let plan: CaptureURLPlan
    let session: URLSession
    let capture: SyntheticCaptureProvider
    let request: LocalLLMRequest
    private let host: String
    init(statusCode: Int = 200, finishes: Bool = true, artifactDirectory: URL? = nil,
         constrained: Bool = false, terminalUsageFrames: [String]? = nil) {
        let host = "capture-owned-" + UUID().uuidString.lowercased() + ".invalid"
        self.host = host
        let plan = CaptureURLPlan(statusCode: statusCode, finishes: finishes, terminalUsageFrames: terminalUsageFrames)
        self.plan = plan
        CaptureOwnedURLProtocol.install(plan, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureOwnedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        let exit = CaptureActualProducerExit()
        self.exit = exit
        let base = OllamaQwenProvider(baseURL: URL(string: "https://" + host)!, session: session,
            producerExitCheckpoint: { await exit.hold($0) })
        capture = SyntheticCaptureProvider(suffix: "transport-" + host, base: base, artifactDirectory: artifactDirectory)
        request = LocalLLMRequest(prompt: "Synthetic ownership packet", systemPrompt: nil,
            modelName: "capture-owned-synthetic", temperature: 0,
            responseSchema: constrained ? .object(["type": .string("string")]) : nil)
    }
    func close() {
        session.invalidateAndCancel()
        CaptureOwnedURLProtocol.remove(host: host)
        plan.stopped.continuation.finish()
    }
}

// The inherited Foundation protocol object is used only by its synchronous
// start/stop callbacks. No instance state or asynchronous callback Task is added;
// route plans and counters cross callback queues solely through allocated locks.
private final class CaptureOwnedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let routes = OSAllocatedUnfairLock(initialState: [String: CaptureURLPlan]())
    static func install(_ plan: CaptureURLPlan, host: String) { routes.withLock { $0[host] = plan } }
    static func remove(host: String) { routes.withLock { _ = $0.removeValue(forKey: host) } }
    private var plan: CaptureURLPlan? {
        guard let host = request.url?.host else { return nil }
        return Self.routes.withLock { $0[host] }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("capture-owned-") == true
            && request.url?.host?.hasSuffix(".invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let plan, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let tags = request.url?.path == "/api/tags"
        if !tags { plan.recordGeneration() }
        let status = tags ? 200 : plan.statusCode
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if tags {
            client?.urlProtocol(self, didLoad: Data(#"{"models":[{"name":"capture-owned-synthetic"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else if status != 200 {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let content = request.url?.path == "/api/generate"
                ? #"{"response":"captured synthetic packet","done":false}"#
                : #"{"message":{"content":"captured synthetic packet"},"done":false}"#
            client?.urlProtocol(self, didLoad: Data((content + "\n").utf8))
            if plan.finishes {
                client?.urlProtocol(self, didLoad: Data(plan.generationTerminalFrame.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        guard request.url?.path != "/api/tags", let plan else { return }
        plan.recordGenerationStop()
        plan.stopped.continuation.yield(())
    }
}

private final class CaptureURLPlan: Sendable {
    let statusCode: Int
    let finishes: Bool
    let terminalUsageFrames: [String]?
    let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private let counters = OSAllocatedUnfairLock(initialState: (requests: 0, stops: 0))
    init(statusCode: Int, finishes: Bool, terminalUsageFrames: [String]? = nil) {
        self.statusCode = statusCode; self.finishes = finishes; self.terminalUsageFrames = terminalUsageFrames
    }
    var generationTerminalFrame: String {
        guard let terminalUsageFrames else { return "{\"done\":true}\n" }
        let index = counters.withLock { $0.requests - 1 }
        return terminalUsageFrames.indices.contains(index) ? terminalUsageFrames[index] : "{\"done\":true}\n"
    }
    var generationRequests: Int { counters.withLock { $0.requests } }
    var generationStopCount: Int { counters.withLock { $0.stops } }
    func recordGeneration() { counters.withLock { $0.requests += 1 } }
    func recordGenerationStop() { counters.withLock { $0.stops += 1 } }
}

// Cancellation deliberately cannot destroy this resource-release latch. Every
// failure/cancellation cleanup releases it before awaiting the exact owner.
private actor CaptureActualProducerExit {
    nonisolated let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ id: Int) async {
        entered.continuation.yield(id)
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func nextEntered() async throws -> Int {
        try await TestEventWaitTrace(label: "synthetic-capture-actual-exit")
            .nextEvent(in: entered.stream, event: "producer-held")
    }
    func pendingCount() -> Int { waiter == nil ? 0 : 1 }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
        entered.continuation.finish()
    }
}
