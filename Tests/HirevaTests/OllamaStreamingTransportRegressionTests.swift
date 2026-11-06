import Combine
import Foundation
import os
import Testing
@testable import Hireva

@Suite(.serialized)
struct OllamaStreamingTransportRegressionTests {
    private let baseURL = URL(string: "https://ollama-streaming-regression.test")!

    @Test(arguments: ["load", "false", "missing", "stop", "unload", "content", "error", "malformed", "http"])
    func loadOnlyPreparationDoesNotAdmitAnAnswer(_ scenario: String) async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider { request in
            #expect(request.url?.path == "/api/generate" && request.httpMethod == "POST")
            let body = probe.requestBody(request).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            #expect(body == ["model": "synthetic-qwen"])
            #expect(request.timeoutInterval == 8)
            if scenario == "http" { return .httpError(503) }
            if scenario == "malformed" { return .json("{") }
            let done = scenario == "missing" ? "" : "\"done\":\(scenario == "false" ? "false" : "true"),"
            let reason = ["stop", "unload"].contains(scenario) ? scenario : "load"
            let error = scenario == "error" ? ",\"error\":\"Synthetic preparation failure\"" : ""
            return .json("{\(done)\"done_reason\":\"\(reason)\",\"response\":\"\(scenario == "content" ? "Unexpected answer" : "")\"\(error)}")
        }
        let before = provider.lastGenerationDiagnostics
        do {
            try await provider.prepareModel(modelName: "synthetic-qwen")
            #expect(scenario == "load")
        } catch { #expect(scenario != "load") }
        #expect(provider.lastGenerationDiagnostics == before)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func preparationCancellationAndDeadlineReleaseOnlyTheirHTTPTask(timeout: Bool) async throws {
        let started = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let clock = ControlledGenerationWatchdogClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/generate")
            if probe.incrementChatCount() > 1 { return .json(#"{"done":true,"done_reason":"load","response":""}"#) }
            return OllamaStreamingPlan(chunks: [], finishes: false,
                onStop: { stopped.continuation.yield(()) }, beforeChunks: release.stream,
                onTaskCreated: { workers.register($0); started.continuation.yield(()) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        let pending = Task {
            try await GenerationCoordinator.withTimeout(seconds: 8, delayProvider: clock) {
                try await provider.prepareModel(modelName: "synthetic-qwen")
            }
        }
        func cleanup() async {
            pending.cancel(); clock.cancelAll(); release.continuation.finish()
            started.continuation.finish(); stopped.continuation.finish()
            _ = await pending.result
            session.invalidateAndCancel(); await workers.cancelAndJoin()
        }
        do {
            _ = try await TestEventWaitTrace(label: "prepare-native").nextEvent(in: started.stream, event: "started")
            if timeout { try await clock.waitUntilScheduled(); clock.advance(by: 8_000_000_000) }
            else { pending.cancel() }
            _ = try await TestEventWaitTrace(label: "prepare-native").nextEvent(in: stopped.stream, event: "stopped")
            switch await pending.result {
            case .success: Issue.record("Cancelled or expired preparation must fail")
            case .failure(let error):
                if timeout { #expect((error as NSError).domain == "TimeoutDomain") }
                else { #expect(OllamaFailureCategory.classify(error) == .requestCancelled) }
            }
            #expect((await session.allTasks).isEmpty)
            try await provider.prepareModel(modelName: "synthetic-qwen")
            #expect(probe.chatCount == 2)
            await cleanup()
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["ready", "failure", "stop", "model", "mode", "restart"])
    @MainActor
    func actualLiveStartupWaitsForPreparationAndRejectsRevokedIdentity(_ scenario: String) async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let replacementRelease = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/generate")
            let ordinal = probe.incrementChatCount()
            return OllamaStreamingPlan(statusCode: scenario == "failure" ? 503 : 200,
                chunks: [.init(delayNanoseconds: 0, data: Data(#"{"done":true,"done_reason":"load","response":""}"#.utf8))],
                beforeChunks: ordinal == 1 ? release.stream : replacementRelease.stream,
                onTaskCreated: { workers.register($0); started.continuation.yield(()) })
        }
        let environment = try await HirevaTestEnvironment(prefix: "LiveModelPreparation")
        let app = environment.appState
        app.localLLMProviderOverride = OllamaQwenProvider(baseURL: baseURL, session: session)
        app.setSelectedAnswerProviderMode(.localQwenPrimary)
        app.setSelectedQwenModelName("synthetic-qwen")
        app.setSelectedASRProvider(.appleSpeech)
        var settings = app.settings
        settings.audioCaptureMode = .microphoneOnly
        app.saveSettings(settings)
        var admissions = 0
        app.liveASRWillStart = { _, _ in
            admissions += 1
            throw TranscriptionError.unavailable("Synthetic boundary stops before native capture.")
        }
        var startup: Task<Void, Never>?
        var retiredStartup: Task<Void, Never>?
        func cleanup() async {
            release.continuation.finish(); replacementRelease.continuation.finish(); started.continuation.finish()
            startup?.cancel(); await startup?.value
            retiredStartup?.cancel(); await retiredStartup?.value
            session.invalidateAndCancel(); await workers.cancelAndJoin()
            try? await environment.shutdown()
        }
        do {
            app.startListening(mode: .microphone)
            let scheduled = try #require(app.captureStartupTask)
            startup = scheduled
            _ = try await TestEventWaitTrace(label: "prepare-live").nextEvent(in: started.stream, event: "prepared-request")
            #expect(admissions == 0 && app.currentSession == nil)
            if scenario == "stop" { app.stopListening() }
            if scenario == "model" { app.setSelectedQwenModelName("synthetic-new") }
            if scenario == "mode" { app.setSelectedAnswerProviderMode(.deepSeekPrimary) }
            if scenario == "restart" {
                let oldID = try #require(app.captureStartupID)
                retiredStartup = scheduled
                app.stopListening()
                app.startListening(mode: .microphone)
                let requiredRestartStartup: Task<Void, Never> = try #require(app.captureStartupTask)
                startup = requiredRestartStartup
                let newID = try #require(app.captureStartupID)
                #expect(newID != oldID)
                _ = try await TestEventWaitTrace(label: "prepare-live").nextEvent(in: started.stream, event: "replacement-request")
                await scheduled.value
                release.continuation.finish()
                #expect(admissions == 0 && app.currentSession == nil)
                #expect(app.captureStartupID == newID && startup?.isCancelled == false)
                #expect(probe.chatCount == 2)
                #expect((await session.allTasks).count == 1)
                replacementRelease.continuation.finish()
            }
            release.continuation.finish()
            await startup?.value
            #expect(admissions == (["ready", "failure", "restart"].contains(scenario) ? 1 : 0))
            #expect(probe.chatCount == (scenario == "restart" ? 2 : 1))
            await cleanup()
            #expect((await session.allTasks).isEmpty)
            #expect(app.captureLifecycle.pendingTaskCount == 0 && app.captureLifecycle.retiringTaskCount == 0)
            #expect(!app.captureLifecycle.hasFailedTeardown)
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["chat-held", "generate-held", "chat-tail", "generate-tail"])
    func completedAnswerStopsAtDoneWithoutWaitingForHTTPBody(_ scenario: String) async throws {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let path = scenario.hasPrefix("generate") ? "/api/generate" : "/api/chat"
        let content = path == "/api/generate" ? #""response":"Final answer.""# : #""message":{"content":"Final answer."}"#
        OllamaStreamingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data("{\"models\":[{\"name\":\"synthetic-qwen\"}]}\n".utf8))],
                    onTaskCreated: { workers.register($0) })
            }
            #expect(request.url?.path == path)
            let ordinal = probe.incrementChatCount()
            var wire = "{\(content),\"done\":true,\"done_reason\":\"stop\",\"eval_count\":7}\n"
            if ordinal == 1 && scenario.hasSuffix("tail") {
                wire += "{\(content),\"done\":true,\"done_reason\":\"length\",\"eval_count\":999}\n"
                wire += "{\"error\":\"late error after completion\"}\n"
            }
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(wire.utf8))],
                finishes: ordinal != 1 || scenario.hasSuffix("tail"),
                onStop: { if ordinal == 1 { stopped.withLock { $0 = true } } },
                onTaskCreated: { workers.register($0) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        var owned: OllamaQwenProvider.OwnedAnswerStream?
        var consumer: Task<[LLMToken], Error>?
        func cleanup() async {
            consumer?.cancel()
            owned?.producerTask.cancel()
            session.invalidateAndCancel()
            _ = await consumer?.result
            await owned?.producerTask.value
            await workers.cancelAndJoin()
        }
        do {
            let request = LocalLLMRequest(prompt: "Synthetic question", systemPrompt: nil,
                modelName: "synthetic-qwen", temperature: 0,
                responseSchema: path == "/api/generate" ? .object(["type": .string("string")]) : nil)
            let value = try await provider.generateOwnedAnswer(request: request)
            owned = value
            let collecting = Task {
                defer { completed.withLock { $0 = true } }
                var tokens: [LLMToken] = []
                for try await token in value.stream { tokens.append(token) }
                return tokens
            }
            consumer = collecting
            try await probe.waitUntil({ _ in completed.withLock { $0 } }, attempts: 400)
            #expect(try await collecting.value.map(\.text).joined() == "Final answer.")
            await value.producerTask.value
            #expect(provider.lastGenerationDiagnostics.streamCompleted)
            #expect(provider.lastGenerationDiagnostics.doneReason == "stop")
            #expect(provider.lastGenerationDiagnostics.evalCount == 7)
            #expect(provider.lastGenerationDiagnostics.finalErrorCategory == nil)
            if scenario.hasSuffix("held") {
                try await probe.waitUntil { _ in stopped.withLock { $0 } }
            }
            #expect(!(await session.allTasks).contains { $0.originalRequest?.url?.path == path })
            #expect(try await collect(provider: provider, request: request).map(\.text).joined() == "Final answer.")
            #expect(probe.chatCount == 2, "Cleanup must cancel only the completed request, preserving the shared session.")
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["chat-http", "generate-http", "chat-event", "generate-event"])
    func failedAnswerStopsUnfinishedHTTPBody(_ scenario: String) async throws {
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let path = scenario.hasPrefix("generate") ? "/api/generate" : "/api/chat"
        OllamaStreamingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            }
            #expect(request.url?.path == path)
            return OllamaStreamingPlan(statusCode: scenario.hasSuffix("http") ? 503 : 200,
                chunks: scenario.hasSuffix("http") ? [] : [
                    .init(delayNanoseconds: 0, data: Data("{\"error\":\"synthetic failure\"}\n".utf8))
                ], finishes: false, onStop: { stopped.withLock { $0 = true } },
                onTaskCreated: { workers.register($0) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        var owned: OllamaQwenProvider.OwnedAnswerStream?
        func cleanup() async {
            owned?.producerTask.cancel()
            session.invalidateAndCancel()
            await owned?.producerTask.value
            await workers.cancelAndJoin()
        }
        do {
            let value = try await provider.generateOwnedAnswer(request: .init(
                prompt: "Synthetic question", systemPrompt: nil, modelName: "synthetic-qwen", temperature: 0,
                responseSchema: path == "/api/generate" ? .object(["type": .string("string")]) : nil))
            owned = value
            await expectFailure(.providerHTTPError) {
                for try await _ in value.stream { Issue.record("Error response must not emit an answer") }
            }
            await value.producerTask.value
            #expect(provider.lastGenerationDiagnostics.transportRequestCount == 1)
            // Observe transport exit before fixture invalidation, rather than
            // inferring it from the completed Swift producer.
            try await probe.waitUntil { _ in stopped.withLock { $0 } }
            var tasks = await session.allTasks
            for _ in 0..<200 where tasks.contains(where: { $0.originalRequest?.url?.path == path }) {
                try await Task.sleep(for: .milliseconds(5))
                tasks = await session.allTasks
            }
            #expect(!tasks.contains { $0.originalRequest?.url?.path == path })
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test
    func nonThinkingSchemaUsesGenerateAndPreservesServerTemplate() async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider { request in
            if request.url?.path == "/api/tags" {
                return .json(#"{"models":[{"name":"synthetic-qwen"}]}"#)
            }
            #expect(request.url?.path == "/api/generate")
            let body = probe.requestBody(request)
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            #expect(json?["prompt"] as? String == "Untrusted input")
            #expect(json?["system"] as? String == "Return the allowed enum")
            #expect(json?["think"] as? Bool == false)
            #expect(json?["raw"] == nil && json?["template"] == nil && json?["suffix"] == nil)
            #expect((json?["format"] as? [String: Any])?["enum"] as? [String] == ["ready"])
            return .lines([#"{"response":"\"ready\"","done":true}"#])
        }
        let tokens = try await collect(provider: provider, request: .init(prompt: "Untrusted input",
            systemPrompt: "Return the allowed enum", modelName: "synthetic-qwen", temperature: 0,
            responseSchema: .object(["type": .string("string"), "enum": .array([.string("ready")])])) )
        #expect(tokens.map(\.text).joined() == "\"ready\"")
        #expect(provider.lastGenerationDiagnostics.responseSchema == .generateResponse)
        #expect(provider.lastGenerationDiagnostics.endpoint.hasSuffix("/api/generate"))
        #expect(provider.lastGenerationDiagnostics.transportRequestCount == 1)
    }

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
        do {
            try await probe.waitUntil { $0.tagsStarted }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Expected readiness cancellation")
            } catch {
                #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
                #expect((error as? OllamaQwenProviderError) != .ollamaNotRunning)
                #expect(provider.lastGenerationDiagnostics.transportRequestCount == 0)
            }
        } catch {
            task.cancel()
            _ = await task.result
            throw error
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
        #expect(provider.lastGenerationDiagnostics.transportRequestCount == 2)
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
                        #"{"done":true,"prompt_eval_count":111,"eval_count":11}"#
                    ], initialDelayNanoseconds: 400_000_000, onStart: { probe.markFirstChatStarted() })
                }
                return .lines([
                    #"{"message":{"role":"assistant","content":"Second answer."},"done":false}"#,
                    #"{"done":true,"prompt_eval_count":222,"eval_count":22}"#
                ])
            default:
                return .httpError(404)
            }
        }

        let firstTask = Task {
            try await collect(provider: provider, request: request(model: "synthetic-first"))
        }
        do {
            try await probe.waitUntil { $0.firstChatStarted }
            let second = try await collect(provider: provider, request: request(model: "synthetic-second"))
            let first = try await firstTask.value
            #expect(first.map(\.text) == ["First answer."])
            #expect(second.map(\.text) == ["Second answer."])
            #expect(provider.lastGenerationDiagnostics.model == "synthetic-second")
            #expect(provider.lastGenerationDiagnostics.promptEvalCount == 222)
            #expect(provider.lastGenerationDiagnostics.evalCount == 22)
        } catch {
            firstTask.cancel()
            _ = await firstTask.result
            throw error
        }
    }

    // Five deliberately ordered real transport interleavings, repeated four times.
    // This protects the existing generation fence while its shared storage changes.
    @Test(.timeLimit(.minutes(1)))
    func checkedSharedStatePreservesTwentyControlledTransportInterleavings() async throws {
        for order in 0..<20 {
            try await exerciseControlledTransportInterleaving(order: order)
        }
    }

    private func exerciseControlledTransportInterleaving(order: Int) async throws {
        let kind = order % 5
        let trace = TestEventWaitTrace(label: "ollama-shared-state-\(order)")
        let firstGate = AsyncStream<Void>.makeStream()
        let secondGate = AsyncStream<Void>.makeStream()
        let pullGate = AsyncStream<Void>.makeStream()
        let firstStarted = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let pullStarted = AsyncStream<Void>.makeStream()
        let readSignals = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        func controlledPlan(
            lines: [String], gate: AsyncStream<Void>,
            started: AsyncStream<Void>.Continuation, status: Int = 200
        ) -> OllamaStreamingPlan {
            OllamaStreamingPlan(statusCode: status,
                chunks: lines.map { .init(delayNanoseconds: 0, data: Data(($0 + "\n").utf8)) },
                beforeChunks: gate,
                onTaskCreated: { task in
                    workers.register(task)
                    started.yield(())
                })
        }
        OllamaStreamingURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags":
                probe.incrementTagsCount()
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data(#"{"models":[{"name":"synthetic-first"},{"name":"synthetic-second"}]}"#.utf8))],
                    onTaskCreated: { workers.register($0) })
            case "/api/chat":
                if probe.modelName(from: request) == "synthetic-first" {
                    return controlledPlan(lines: [
                        #"{"message":{"role":"assistant","content":"First answer."},"done":false}"#,
                        #"{"done":true}"#], gate: firstGate.stream, started: firstStarted.continuation)
                }
                return controlledPlan(lines: [
                    #"{"message":{"role":"assistant","content":"Second answer."},"done":false}"#,
                    #"{"done":true}"#], gate: secondGate.stream,
                    started: secondStarted.continuation, status: kind == 4 ? 503 : 200)
            case "/api/pull":
                return controlledPlan(lines: [
                    #"{"status":"downloading 合成 🦉","completed":1,"total":2}"#,
                    #"{"status":"success","completed":2,"total":2}"#,
                    #"{"status":"success"}"#,
                    #"{"error":"must remain unread after success"}"#],
                    gate: pullGate.stream, started: pullStarted.continuation)
            default:
                return .httpError(404)
            }
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        var firstTask: Task<[LLMToken], Error>?
        var secondTask: Task<[LLMToken], Error>?
        var pullTask: Task<[ModelDownloadProgress], Error>?
        var readerTask: Task<[OllamaProviderDiagnostics], Never>?
        func cleanup() async {
            firstGate.continuation.finish(); secondGate.continuation.finish()
            pullGate.continuation.finish(); readSignals.continuation.finish()
            firstStarted.continuation.finish(); secondStarted.continuation.finish()
            pullStarted.continuation.finish()
            firstTask?.cancel(); secondTask?.cancel(); pullTask?.cancel(); readerTask?.cancel()
            if let firstTask { _ = await firstTask.result }
            if let secondTask { _ = await secondTask.result }
            if let pullTask { _ = await pullTask.result }
            if let readerTask { _ = await readerTask.value }
            session.invalidateAndCancel()
            await workers.cancelAndJoin()
        }
        do {
            let health = await provider.healthCheck(modelName: "synthetic-first")
            #expect(health.isReady)
            firstTask = Task { try await collect(provider: provider, request: request(model: "synthetic-first")) }
            _ = try await trace.nextEvent(in: firstStarted.stream, event: "first.worker.registered")
            secondTask = Task { try await collect(provider: provider, request: request(model: "synthetic-second")) }
            _ = try await trace.nextEvent(in: secondStarted.stream, event: "second.worker.registered")
            let first = try #require(firstTask)
            let second = try #require(secondTask)
            readerTask = Task {
                var snapshots: [OllamaProviderDiagnostics] = []
                for await _ in readSignals.stream {
                    snapshots.append(provider.lastGenerationDiagnostics)
                }
                return snapshots
            }
            readSignals.continuation.yield(())
            if kind == 1 {
                firstGate.continuation.yield(())
                let firstTokens = try await first.value
                #expect(firstTokens.map(\.text) == ["First answer."])
                #expect(provider.lastGenerationDiagnostics.model == "synthetic-second")
            } else if kind == 2 {
                first.cancel()
                firstGate.continuation.finish()
                switch await first.result {
                case .success(let tokens): #expect(tokens.isEmpty)
                case .failure(let error): #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
                }
            } else if kind == 3 {
                pullTask = Task { try await collectPull(provider) }
                _ = try await trace.nextEvent(in: pullStarted.stream, event: "pull.worker.registered")
                #expect(provider.lastGenerationDiagnostics.model == "synthetic-second")
                pullGate.continuation.yield(())
                let pull = try #require(pullTask)
                let events = try await pull.value
                #expect(events.first?.statusMessage == "downloading 合成 🦉")
                #expect(events.filter { $0.statusMessage == "Ready" }.count == 1)
                let tagsBeforeHealth = probe.tagsCount
                let afterPull = await provider.healthCheck(modelName: "synthetic-second")
                #expect(afterPull.isReady)
                #expect(probe.tagsCount == tagsBeforeHealth + 1)
            }
            readSignals.continuation.yield(())
            secondGate.continuation.yield(())
            if kind == 4 {
                switch await second.result {
                case .success: Issue.record("Expected synthetic HTTP503 failure")
                case .failure(let error): #expect(OllamaFailureCategory.classify(error) == .providerHTTPError)
                }
                let tagsBeforeHealth = probe.tagsCount
                let afterFailure = await provider.healthCheck(modelName: "synthetic-second")
                #expect(afterFailure.isReady)
                #expect(probe.tagsCount == tagsBeforeHealth + 1)
            } else {
                let secondTokens = try await second.value
                #expect(secondTokens.map(\.text) == ["Second answer."])
            }
            readSignals.continuation.yield(())
            if kind != 1 && kind != 2 {
                firstGate.continuation.yield(())
                let firstTokens = try await first.value
                #expect(firstTokens.map(\.text) == ["First answer."])
            }
            readSignals.continuation.yield(())
            readSignals.continuation.finish()
            let reader = try #require(readerTask)
            let snapshots = await reader.value
            #expect(!snapshots.isEmpty)
            #expect(snapshots.allSatisfy { $0.model == "synthetic-second" })
            let final = provider.lastGenerationDiagnostics
            #expect(final.model == "synthetic-second")
            if kind == 4 {
                #expect(final.finalErrorCategory == .providerHTTPError)
            } else {
                #expect(final.finalErrorCategory == nil)
                #expect(final.parsedContentCharacters == "Second answer.".count)
            }
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test
    func pullPreservesUTF8AcrossEveryByteBoundary() async throws {
        let status = "Downloading 中文 model 🦉"
        let body = "{\"status\":\"\(status)\",\"completed\":50,\"total\":100}\n{\"status\":\"success\"}\n"
        let provider = makeProvider { _ in
            OllamaStreamingPlan(chunks: body.utf8.map {
                .init(delayNanoseconds: 0, data: Data([$0]))
            })
        }

        let events = try await collectPull(provider)

        #expect(events.first?.statusMessage == status)
        #expect(events.first?.progress == 0.5)
        #expect(events.filter { $0.statusMessage == "Ready" }.count == 1)
    }

    @Test
    func pullParsesMultipleLinesBlankLinesAndUnterminatedSuccess() async throws {
        let provider = makeProvider { _ in
            OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(
                "\n \r\n{\"status\":\"pulling manifest\"}\r\n{\"status\":\"downloading\",\"completed\":3,\"total\":4}\n{\"status\":\"success\"}".utf8
            ))])
        }

        let events = try await collectPull(provider)

        #expect(events.map(\.statusMessage) == ["pulling manifest", "downloading", "Ready"])
        #expect(events[1].progress == 0.75)
    }

    @Test
    func pullRejectsProgressOnlyEOFWithoutReportingReady() async {
        let provider = makeProvider { _ in
            .lines([#"{"status":"downloading","completed":100,"total":100}"#])
        }
        var events: [ModelDownloadProgress] = []

        do {
            for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
            Issue.record("EOF without status=success must fail")
        } catch {
            #expect(OllamaFailureCategory.classify(error) == .responseSchemaMismatch)
        }

        #expect(events.map(\.statusMessage) == ["downloading"])
    }

    @Test
    func pullSuccessIsTerminalAndCompletedOnlyOnce() async throws {
        let provider = makeProvider { _ in
            .lines([
                #"{"status":"success","completed":4,"total":4}"#,
                #"{"status":"success"}"#,
                #"{"status":"downloading","completed":1,"total":4}"#,
                #"{"error":"late transport event"}"#
            ])
        }

        let events = try await collectPull(provider)

        #expect(events.map(\.statusMessage) == ["Ready"])
        #expect(events.first?.totalBytes == 4)
        #expect(events.first?.downloadedBytes == 4)
    }

    @Test
    func pullRejectsMalformedJSONAndInvalidUTF8() async {
        var invalidUTF8 = Data(#"{"status":""#.utf8)
        invalidUTF8.append(contentsOf: [0xC3, 0x28])
        invalidUTF8.append(Data("\"}\n".utf8))
        for data in [Data("{malformed\n".utf8), invalidUTF8] {
            let provider = makeProvider { _ in
                OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: data)])
            }
            var events: [ModelDownloadProgress] = []
            do {
                for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
                Issue.record("Malformed pull data must fail")
            } catch {
                #expect(OllamaFailureCategory.classify(error) == .responseSchemaMismatch)
            }
            #expect(events.isEmpty)
        }
    }

    @Test
    func pullPreservesServerErrorWithoutReportingReady() async {
        let message = "下载失败 🦉"
        let provider = makeProvider { _ in .lines(["{\"error\":\"\(message)\"}"]) }
        var events: [ModelDownloadProgress] = []

        do {
            for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
            Issue.record("Server error must fail")
        } catch {
            #expect(error.localizedDescription == message)
        }

        #expect(events.isEmpty)
    }

    @Test
    func pullRejectsHTTPFailureWithoutReportingReady() async {
        let provider = makeProvider { _ in .httpError(503) }
        await expectFailure(.providerHTTPError) { _ = try await collectPull(provider) }
    }

    @Test
    func pullRejectsNetworkFailureWithoutReportingReady() async {
        let provider = makeProvider { _ in
            OllamaStreamingPlan(
                chunks: [.init(delayNanoseconds: 0, data: Data("{\"status\":\"pulling manifest\"}\n".utf8))],
                terminalError: .networkConnectionLost
            )
        }
        var events: [ModelDownloadProgress] = []
        do {
            for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
            Issue.record("Network failure must fail")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(!events.contains { $0.statusMessage == "Ready" })
    }

    @Test(arguments: ["normal", "timeout", "cancelled"])
    func pullConsumerCancellationStopsOwnedTransport(observation: String) async throws {
        let probe = OllamaStreamingProbe()
        let provider = makeProvider { _ in
            OllamaStreamingPlan(chunks: [], finishes: false,
                onStart: { probe.markPullStarted() }, onStop: { probe.markPullStopped() })
        }
        let consumer = Task { () -> [ModelDownloadProgress] in
            var events: [ModelDownloadProgress] = []
            do {
                for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
            } catch {
                #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
            }
            return events
        }
        func observeAndStop() async throws -> [ModelDownloadProgress] {
            do {
                try await probe.waitUntil { $0.pullStarted }
                if observation == "timeout" {
                    try await probe.waitUntil({ _ in false }, attempts: 1)
                } else if observation == "cancelled" {
                    let observer = Task { try await probe.waitUntil { _ in false } }
                    observer.cancel()
                    try await observer.value
                }
                consumer.cancel()
                let events = await consumer.value
                try await probe.waitUntil { $0.pullStopped }
                return events
            } catch {
                consumer.cancel()
                _ = await consumer.value
                // This receipt waiter remains awaitable when the original
                // observation itself was cancelled; retain the original error.
                let stopped = Task { try await probe.waitUntil { $0.pullStopped } }
                if case .failure(let cleanupError) = await stopped.result {
                    Issue.record(cleanupError)
                }
                throw error
            }
        }
        do {
            let events = try await observeAndStop()
            #expect(observation == "normal")
            #expect(events.isEmpty)
        } catch {
            #expect(observation != "normal")
            #expect(observation == "timeout" ? error is OllamaStreamingProbeError : error is CancellationError)
            #expect(consumer.isCancelled)
            #expect(probe.pullStopped)
            // The regression itself also owns recovery after a failed assertion.
            consumer.cancel()
            let events = await consumer.value
            try await probe.waitUntil { $0.pullStopped }
            #expect(events.isEmpty)
        }
    }

    @Test
    @MainActor
    func pullSetupClearsOldCompletionAndShowsCurrentFailure() async {
        let provider = makeProvider { request in
            if request.url?.path == "/api/tags" {
                return .json(#"{"models":[{"name":"old-model"}]}"#)
            }
            let body = OllamaStreamingProbe().requestBody(request)
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if json?["model"] as? String == "old-model" {
                return .lines([#"{"status":"success","completed":4,"total":4}"#])
            }
            return .lines([#"{"error":"synthetic pull failure"}"#])
        }
        let viewModel = LocalModelsSetupViewModel(
            modelManager: FileLocalModelManager(rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("hireva-pull-ui-\(UUID().uuidString)")),
            qwenProvider: provider,
            parakeetRuntimeClient: ParakeetSidecarRuntimeClient(executableURLProvider: { nil })
        )
        viewModel.pullQwen(modelName: "old-model")
        await viewModel.waitForPendingOperations()
        #expect(viewModel.qwenProgress == .completed(modelID: "old-model", totalBytes: 4))
        viewModel.pullQwen(modelName: "synthetic-qwen")
        #expect(viewModel.qwenProgress == nil)
        #expect(viewModel.qwenHealth.selectedModel == "synthetic-qwen")
        await viewModel.waitForPendingOperations()

        #expect(viewModel.lastError == "synthetic pull failure")
        #expect(!viewModel.qwenHealth.isReady)
        #expect(viewModel.qwenHealth.selectedModel == "synthetic-qwen")
        #expect(viewModel.qwenProgress == nil)
        await viewModel.shutdown()
    }


    /// A cache response from before pull admission cannot replace post-pull
    /// readiness. Transport chunks and wall-cache time are both controlled;
    /// no change to the actual three-second default TTL or HTTP protocol.
    @Test(.timeLimit(.minutes(1)))
    func tagsFromBeforePullCannotReplacePostPullReadinessCache() async throws {
        let oldTagsRelease = AsyncStream<Void>.makeStream()
        let oldTagsStarted = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        OllamaStreamingURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/tags":
                probe.incrementTagsCount()
                if probe.tagsCount == 1 {
                    return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                        data: Data(#"{"models":[]}"#.utf8))],
                        beforeChunks: oldTagsRelease.stream,
                        onTaskCreated: { task in
                            workers.register(task)
                            oldTagsStarted.continuation.yield(())
                        })
                }
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data(#"{"models":[{"name":"synthetic-qwen"}]}"#.utf8))],
                    onTaskCreated: { workers.register($0) })
            case "/api/pull":
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data("{\"status\":\"success\"}\n".utf8))],
                    onTaskCreated: { workers.register($0) })
            default: return .httpError(404)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
            cacheNow: { Date(timeIntervalSince1970: 1_700_000_000) })
        var oldRead: Task<LocalLLMHealth, Never>?
        func cleanup() async {
            oldTagsRelease.continuation.finish()
            oldTagsStarted.continuation.finish()
            oldRead?.cancel()
            _ = await oldRead?.value
            session.invalidateAndCancel()
            await workers.cancelAndJoin()
        }
        do {
            oldRead = Task { await provider.healthCheck(modelName: "synthetic-qwen") }
            _ = try await TestEventWaitTrace(label: "OllamaCacheBeforePull")
                .nextEvent(in: oldTagsStarted.stream, event: "old.tags.worker_registered")
            let completion = try await collectPull(provider)
            #expect(completion.filter { $0.statusMessage == "Ready" }.count == 1)
            let afterPull = await provider.healthCheck(modelName: "synthetic-qwen")
            #expect(afterPull.isReady)
            #expect(probe.tagsCount == 2)
            oldTagsRelease.continuation.yield(())
            let oldSnapshot = await oldRead?.value
            #expect(oldSnapshot?.modelInstalled == false) // Its own frozen HTTP result is still legitimate.
            let final = await provider.healthCheck(modelName: "synthetic-qwen")
            #expect(final.isReady)
            #expect(probe.tagsCount == 2) // Verify the valid post-pull cache was retained.
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    /// Real Ollama provider + injected URLSession. The producer checkpoint holds
    /// its actual Task after stream completion, exposing consumer/producer exit
    /// as separate facts without delaying a validated raw answer unnecessarily.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func coordinatorRetainsNormalAndFailedOllamaProducersUntilActualExit() async throws {
        for fails in [false, true] {
            let exit = ControlledOllamaProducerExit()
            let workers = OllamaControlledTransportWorkers()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
            let session = URLSession(configuration: configuration)
            OllamaStreamingURLProtocol.handler = { request in
                if request.url?.path == "/api/tags" {
                    return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                        data: Data(#"{"models":[{"name":"synthetic-qwen"}]}"#.utf8))],
                        onTaskCreated: { workers.register($0) })
                }
                return OllamaStreamingPlan(statusCode: fails ? 503 : 200,
                    chunks: [
                        .init(delayNanoseconds: 0, data: Data("{\"message\":{\"role\":\"assistant\",\"content\":\"Synthetic answer.\"},\"done\":false}\n".utf8)),
                        .init(delayNanoseconds: 0, data: Data("{\"done\":true}\n".utf8))
                    ], onTaskCreated: { workers.register($0) })
            }
            let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
                producerExitCheckpoint: { await exit.hold($0) })
            let owner = GenerationCoordinator()
            let input = ownedOllamaInput(provider: provider, generation: "owned-exit-\(fails)", model: "synthetic-qwen")
            var request: Task<String, Error>?
            var stopping: Task<Bool, Never>?
            let deadline = ControlledGenerationWatchdogClock()
            func cleanup() async {
                request?.cancel(); stopping?.cancel(); deadline.cancelAll()
                await exit.releaseAll()
                _ = await request?.result; _ = await stopping?.value
                owner.closeAdmission()
                await owner.drainRetiredTasks()
                session.invalidateAndCancel()
                await workers.cancelAndJoin()
            }
            do {
                owner.activate(identity: input.context.identity, persistenceTicket: 0,
                    triggerPath: input.context.triggerPath, startedAt: input.context.startedAt)
                let pending = Task {
                    try await owner.generateLocalAnswer(context: input.context, request: input.request,
                        provider: provider) { _, _ in true }
                }
                request = pending
                #expect(try await exit.nextEntered() == 1)
                switch await pending.result {
                case .success(let answer):
                    #expect(!fails)
                    #expect(answer == "Synthetic answer.")
                case .failure(let error):
                    #expect(fails)
                    #expect(OllamaFailureCategory.classify(error) == .providerHTTPError)
                }
                #expect(owner.stageATask == nil)
                #expect(await exit.pendingCount() == 1)
                #expect(owner.retiringLocalProducerTaskCount == 1)
                #expect(owner.pendingCleanupTaskCount >= 1)
                let boundedStop = Task { await owner.shutdownAndDrain(timeout: 2, delayProvider: deadline) }
                stopping = boundedStop
                try await deadline.waitUntilScheduled()
                deadline.advance(by: 2_000_000_000)
                #expect(await boundedStop.value == false)
                #expect(owner.retiringLocalProducerTaskCount == 1)
                await exit.release(1)
                await owner.drainRetiredTasks()
                #expect(owner.retiringLocalProducerTaskCount == 0)
                #expect(owner.pendingCleanupTaskCount == 0)
                #expect(await exit.pendingCount() == 0)
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func ownedOllamaStartupCancellationReachesItsActualURLSessionRequest() async throws {
        let tagRelease = AsyncStream<Void>.makeStream()
        let tagsStarted = AsyncStream<Void>.makeStream()
        let tagsStopped = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/tags")
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                data: Data(#"{"models":[{"name":"synthetic-qwen"}]}"#.utf8))],
                onStop: { tagsStopped.continuation.yield(()) }, beforeChunks: tagRelease.stream,
                onTaskCreated: { task in workers.register(task); tagsStarted.continuation.yield(()) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        let owner = GenerationCoordinator()
        let input = ownedOllamaInput(provider: provider, generation: "startup-native-cancel", model: "synthetic-qwen")
        var request: Task<String, Error>?
        func cleanup() async {
            request?.cancel(); tagRelease.continuation.finish()
            tagsStarted.continuation.finish(); tagsStopped.continuation.finish()
            _ = await request?.result
            owner.closeAdmission(); await owner.drainRetiredTasks()
            session.invalidateAndCancel(); await workers.cancelAndJoin()
        }
        do {
            owner.activate(identity: input.context.identity, persistenceTicket: 0,
                triggerPath: input.context.triggerPath, startedAt: input.context.startedAt)
            let pending = Task {
                try await owner.generateLocalAnswer(context: input.context, request: input.request,
                    provider: provider) { _, _ in Issue.record("Cancelled startup must not emit"); return false }
            }
            request = pending
            _ = try await TestEventWaitTrace(label: "ollama-owned-startup")
                .nextEvent(in: tagsStarted.stream, event: "tags-request-started")
            let child = try #require(owner.stageATask)
            pending.cancel()
            #expect(child.isCancelled)
            // Observe URLProtocol.stopLoading before joining the consumer, rather
            // than inferring transport cancellation from the Swift Task handle.
            _ = try await TestEventWaitTrace(label: "ollama-owned-startup")
                .nextEvent(in: tagsStopped.stream, event: "tags-request-stopped")
            switch await pending.result {
            case .success: Issue.record("Expected actual URLSession startup cancellation")
            case .failure(let error):
                #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
                #expect((error as? OllamaQwenProviderError) != .ollamaNotRunning)
            }
            await owner.drainRetiredTasks()
            #expect(owner.retiringLocalProducerTaskCount == 0)
            #expect(owner.pendingCleanupTaskCount == 0)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancelledOllamaProducerCleanupCannotStopTheNextRequestInTheSameSession() async throws {
        let exit = ControlledOllamaProducerExit()
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstStopped = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data(#"{"models":[{"name":"synthetic-first"},{"name":"synthetic-second"}]}"#.utf8))],
                    onTaskCreated: { workers.register($0) })
            }
            if probe.modelName(from: request) == "synthetic-first" {
                return OllamaStreamingPlan(chunks: [], finishes: false,
                    onStop: { firstStopped.continuation.yield(()) },
                    onTaskCreated: { task in workers.register(task); firstStarted.continuation.yield(()) })
            }
            return OllamaStreamingPlan(chunks: [
                .init(delayNanoseconds: 0, data: Data("{\"message\":{\"role\":\"assistant\",\"content\":\"Second frozen answer.\"},\"done\":false}\n".utf8)),
                .init(delayNanoseconds: 0, data: Data("{\"done\":true}\n".utf8))
            ], beforeChunks: secondRelease.stream,
                onTaskCreated: { task in workers.register(task); secondStarted.continuation.yield(()) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
            producerExitCheckpoint: { await exit.hold($0) })
        let owner = GenerationCoordinator()
        let input = ownedOllamaInput(provider: provider, generation: "old-native-request", model: "synthetic-first")
        let next = ownedOllamaInput(provider: provider, generation: "new-native-request", model: "synthetic-second")
        var first: Task<String, Error>?
        var second: Task<String, Error>?
        var emitted: [String] = []
        func cleanup() async {
            first?.cancel(); second?.cancel()
            secondRelease.continuation.finish()
            firstStarted.continuation.finish(); firstStopped.continuation.finish(); secondStarted.continuation.finish()
            await exit.releaseAll()
            _ = await first?.result; _ = await second?.result
            owner.closeAdmission(); await owner.drainRetiredTasks()
            session.invalidateAndCancel(); await workers.cancelAndJoin()
        }
        do {
            owner.activate(identity: input.context.identity, persistenceTicket: 0,
                triggerPath: input.context.triggerPath, startedAt: input.context.startedAt)
            let old = Task {
                try await owner.generateLocalAnswer(context: input.context, request: input.request, provider: provider) {
                    _, token in emitted.append("old:" + token.text); return true
                }
            }
            first = old
            _ = try await TestEventWaitTrace(label: "ollama-first-native")
                .nextEvent(in: firstStarted.stream, event: "chat-started")
            let oldChild = try #require(owner.stageATask)
            old.cancel()
            _ = try await TestEventWaitTrace(label: "ollama-first-native")
                .nextEvent(in: firstStopped.stream, event: "chat-stopped")
            #expect(try await exit.nextEntered() == 1)
            switch await old.result {
            case .success: Issue.record("Expected cancelled old native request")
            case .failure(let error): #expect(OllamaFailureCategory.classify(error) == .requestCancelled)
            }
            #expect(oldChild.isCancelled)
            #expect(owner.retiringLocalProducerTaskCount == 1)
            owner.activate(identity: next.context.identity, persistenceTicket: 0,
                triggerPath: next.context.triggerPath, startedAt: next.context.startedAt)
            let replacement = Task {
                try await owner.generateLocalAnswer(context: next.context, request: next.request, provider: provider) {
                    identity, token in
                    #expect(identity == next.context.identity)
                    emitted.append("new:" + token.text)
                    return true
                }
            }
            second = replacement
            _ = try await TestEventWaitTrace(label: "ollama-second-native")
                .nextEvent(in: secondStarted.stream, event: "chat-started")
            let newChild = try #require(owner.stageATask)
            await exit.release(1)
            await owner.drainRetiredTasks()
            #expect(owner.retiringLocalProducerTaskCount == 0)
            #expect(owner.stageATask != nil)
            #expect(!newChild.isCancelled)
            #expect(emitted.isEmpty)
            secondRelease.continuation.yield(())
            #expect(try await exit.nextEntered() == 2)
            #expect(try await replacement.value == "Second frozen answer.")
            #expect(emitted == ["new:Second frozen answer."])
            #expect(provider.lastGenerationDiagnostics.model == "synthetic-second")
            #expect(provider.lastGenerationDiagnostics.finalErrorCategory == nil)
            #expect(owner.retiringLocalProducerTaskCount == 1)
            await exit.release(2)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(await exit.pendingCount() == 0)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    /// Actual Ollama + URLSession/URLProtocol + Generate Recap + HistoryState.
    /// The held producer tail is independent of stream/consumer completion.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func historyRecapRetainsItsActualRoutingAndRecapProducersUntilExit() async throws {
        let fixture = try await RecapEntryFixture(localOnly: true)
        let exit = ControlledOllamaProducerExit()
        let workers = OllamaControlledTransportWorkers()
        let clock = ControlledGenerationWatchdogClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = fixture.originalModel
        let tags = String(decoding: try JSONEncoder().encode(["models": [["name": model]]]), as: UTF8.self)
        let route = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
        let routeEncoded = String(decoding: try JSONEncoder().encode(route), as: UTF8.self)
        let feedback = RecapUnitFeedback(observations: [.init(segmentID: fixture.answer.id,
            quote: fixture.answer.text, feedback: "Explain rollback as well.")])
        let feedbackJSON = String(decoding: try JSONEncoder().encode(feedback), as: UTF8.self)
        let feedbackEncoded = String(decoding: try JSONEncoder().encode(feedbackJSON), as: UTF8.self)
        OllamaStreamingURLProtocol.handler = { request in
            let payload: String
            switch request.url?.path {
            case "/api/tags": payload = tags
            case "/api/generate": payload = "{\"response\":\(routeEncoded),\"done\":true}\n"
            case "/api/chat": payload = "{\"message\":{\"role\":\"assistant\",\"content\":\(feedbackEncoded)},\"done\":true}\n"
            default: return .httpError(404)
            }
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(payload.utf8))],
                onTaskCreated: { workers.register($0) })
        }
        fixture.app.localLLMProviderOverride = OllamaQwenProvider(baseURL: baseURL, session: session,
            producerExitCheckpoint: { await exit.hold($0) })
        var roots: [Task<Void, Never>] = []
        enum ShutdownEvent: Sendable { case deadlineRegistered, completed(Bool) }
        let lifecycle = AsyncStream<ShutdownEvent>.makeStream(bufferingPolicy: .bufferingOldest(2))
        var registration: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        func cleanup() async {
            fixture.routingGate.releaseAll()
            clock.cancelAll()
            registration?.cancel()
            await exit.releaseAll()
            if let registration { await registration.value }
            _ = await shutdown?.value
            lifecycle.continuation.finish()
            try? await fixture.close(roots)
            session.invalidateAndCancel()
            await workers.cancelAndJoin()
        }
        do {
            fixture.app.generateRecap(for: fixture.session)
            let root = try #require(fixture.app.recapTask)
            roots.append(root)
            #expect(try await exit.nextEntered() == 1)
            #expect(fixture.app.historyState.pendingRecapTaskCount == 1)
            #expect(fixture.app.isGeneratingRecap)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            await exit.release(1)
            #expect(try await exit.nextEntered() == 2)
            #expect(fixture.app.historyState.pendingRecapTaskCount == 1)
            #expect(fixture.app.isGeneratingRecap)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)

            let history = fixture.app.historyState
            registration = Task {
                do {
                    try await clock.waitUntilPending(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    lifecycle.continuation.yield(.deadlineRegistered)
                } catch { /* Cancellation ends only this retained fixture observer. */ }
            }
            let stopping = Task {
                let result = await history.shutdownAndDrain(timeout: 2, delayProvider: clock)
                lifecycle.continuation.yield(.completed(result))
                return result
            }
            shutdown = stopping
            let event = try await TestEventWaitTrace(label: "recap-native-shutdown-lifecycle")
                .nextEvent(in: lifecycle.stream, event: "deadline-or-actual-completion")
            #expect(root.isCancelled)
            switch event {
            case .deadlineRegistered:
                clock.advance(by: 2_000_000_000)
            case .completed(let result):
                #expect(!result,
                    "Shutdown returned while the exact recap producer remained held; consumer exit is not resource exit.")
            }
            #expect(await stopping.value == false)
            #expect(history.pendingRecapTaskCount == 1)
            #expect(await exit.pendingCount() == 1)
            await exit.release(2)
            try await fixture.join(root)
            await history.drainRetiredRecaps()
            #expect(history.pendingRecapTaskCount == 0)
            #expect(await exit.pendingCount() == 0)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    /// Startup cancellation observes actual URLSession stopLoading. It never
    /// invalidates the shared provider/session to stop an earlier recap request.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func historyRecapCancellationStopsItsOwnedURLSessionStartup() async throws {
        let fixture = try await RecapEntryFixture(localOnly: true)
        let tagsStarted = AsyncStream<Void>.makeStream()
        let tagsStopped = AsyncStream<Void>.makeStream()
        let tagsRelease = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = fixture.originalModel
        let tags = String(decoding: try JSONEncoder().encode(["models": [["name": model]]]), as: UTF8.self)
        OllamaStreamingURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/tags")
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(tags.utf8))],
                onStop: { tagsStopped.continuation.yield(()) }, beforeChunks: tagsRelease.stream,
                onTaskCreated: { task in workers.register(task); tagsStarted.continuation.yield(()) })
        }
        fixture.app.localLLMProviderOverride = OllamaQwenProvider(baseURL: baseURL, session: session)
        var roots: [Task<Void, Never>] = []
        func cleanup() async {
            tagsRelease.continuation.finish()
            tagsStarted.continuation.finish()
            tagsStopped.continuation.finish()
            try? await fixture.close(roots)
            session.invalidateAndCancel()
            await workers.cancelAndJoin()
        }
        do {
            fixture.app.generateRecap(for: fixture.session)
            let root = try #require(fixture.app.recapTask)
            roots.append(root)
            _ = try await TestEventWaitTrace(label: "recap-owned-native-startup")
                .nextEvent(in: tagsStarted.stream, event: "tags-started")
            fixture.app.saveTranscriptCorrection(fixture.answer, text: fixture.answer.text,
                speaker: .candidate, startsQuestion: false, question: "")
            #expect(root.isCancelled)
            #expect(fixture.app.historyState.retiringRecapTaskCount == 1)
            _ = try await TestEventWaitTrace(label: "recap-owned-native-startup")
                .nextEvent(in: tagsStopped.stream, event: "tags-stopped")
            try await fixture.join(root)
            await fixture.app.historyState.drainRetiredRecaps()
            #expect(fixture.app.historyState.pendingRecapTaskCount == 0)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @MainActor
    private func ownedOllamaInput(provider: OllamaQwenProvider, generation: String, model: String)
        -> (context: GenerationExecutionContext, request: LocalLLMRequest) {
        let date = Date(timeIntervalSince1970: 1)
        let session = InterviewSession(id: "synthetic-owned-native-session", title: "Synthetic native transport ownership",
            company: nil, role: nil, startedAt: date, endedAt: nil, mode: .mock, createdAt: date)
        let question = DetectedQuestion(id: "question-" + generation, sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic owned native transport", shouldTrigger: true, questionComplete: true,
            modelName: model, promptVersion: "synthetic", createdAt: date)
        let prompt = PromptContextBuilder.promptSnapshot(question: question,
            context: .init(cvChunks: [], jobDescriptionChunks: []), transcriptContext: "",
            cvSummary: "", jdSummary: "", stage: .firstAnswer)
        let context = GenerationExecutionContext(session: session, question: question, generationID: generation,
            triggerPath: .manualGenerate, providerID: provider.id, providerModel: model,
            retrievedContext: prompt.ragContextSnapshot, promptSnapshot: prompt, transcriptSnapshot: "",
            startedAt: date, source: .mock, speaker: .unknown)
        return (context, LocalLLMRequest(prompt: prompt.prompt, systemPrompt: "Synthetic system prompt",
            modelName: model, temperature: 0, numPredict: 32))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func contextBuildRetainsItsActualOllamaProducerAcrossCancelAndRestart() async throws {
        let exit = ControlledOllamaProducerExit()
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstRelease = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        let secondRelease = AsyncStream<Void>.makeStream()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let content = "Synthetic candidate: isolated test material.\nProjects\n- I implemented database transactions."
        let extraction = #"{"facts":[{"statement":"I implemented database transactions.","source_span":"I implemented database transactions.","evidence_type":"project","confidence":1.0}]}"#
        let encodedContent = String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self)
        let response = "{\"message\":{\"role\":\"assistant\",\"content\":\(encodedContent)},\"done\":false}\n{\"done\":true}\n"
        OllamaStreamingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data(#"{"models":[{"name":"synthetic-extraction"}]}"#.utf8))],
                    onTaskCreated: { workers.register($0) })
            }
            #expect(request.url?.path == "/api/chat")
            let ordinal = probe.incrementChatCount()
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(response.utf8))],
                beforeChunks: ordinal == 1 ? firstRelease.stream : secondRelease.stream,
                onTaskCreated: { task in
                    workers.register(task)
                    if ordinal == 1 { firstStarted.continuation.yield(()) }
                    else { secondStarted.continuation.yield(()) }
                })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
            producerExitCheckpoint: { await exit.hold($0) })
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let documents = DocumentRepository(database: database)
        let contexts = InterviewContextRepository(database: database)
        let document = try documents.saveDocument(type: .cv, title: "Synthetic extraction ownership CV", content: content)
        let namespace = "actual-producer-context-" + UUID().uuidString
        let owner = InterviewContextState(repository: contexts, documents: documents,
            documentRecords: { [document] },
            makeBuilder: { _ in AutomaticInterviewContextBuilder(
                evidenceExtractor: LocalQwenDocumentEvidenceExtractor(provider: provider, modelName: "synthetic-extraction"),
                chunkProvider: { try documents.chunks(documentID: $0) }, cacheNamespace: namespace) },
            selectionWillChange: {}, domainDidChange: { _ in }, contextDidChange: {},
            refreshApplication: {}, feedback: { _ in }, clearFeedback: { _ in }, showError: { _ in })
        func cleanup() async {
            owner.closeAdmission()
            firstRelease.continuation.finish(); secondRelease.continuation.finish()
            firstStarted.continuation.finish(); secondStarted.continuation.finish()
            await exit.releaseAll()
            await owner.shutdown()
            session.invalidateAndCancel()
            await workers.cancelAndJoin()
            try? database.close()
        }
        do {
            let first = try #require(owner.requestRebuild())
            _ = try await TestEventWaitTrace(label: "context-first-actual-producer")
                .nextEvent(in: firstStarted.stream, event: "chat-started")
            #expect(owner.worker != nil)
            firstRelease.continuation.yield(())
            #expect(try await exit.nextEntered() == 1)
            #expect(owner.pendingTaskCount == 1,
                "A finished stream's held actual producer must remain under the context worker.")
            owner.invalidateBuild()
            #expect(first.isCancelled)
            #expect(owner.pendingTaskCount == 1)
            let second = try #require(owner.requestRebuild())
            _ = try await TestEventWaitTrace(label: "context-second-actual-producer")
                .nextEvent(in: secondStarted.stream, event: "chat-started")
            #expect(owner.pendingTaskCount == 2)
            // Releasing only the old cleanup must not cancel or clear the new
            // build, and the cancelled old build must not publish candidate facts.
            await exit.release(1)
            await first.value
            #expect(owner.pendingTaskCount == 1)
            #expect(owner.worker != nil)
            #expect(!second.isCancelled)
            #expect(try contexts.candidateProfiles().isEmpty)
            secondRelease.continuation.yield(())
            #expect(try await exit.nextEntered() == 2)
            #expect(owner.pendingTaskCount == 1)
            await exit.release(2)
            await second.value
            #expect(owner.pendingTaskCount == 0)
            #expect(owner.automaticContextBuildResult?.metrics.usedLocalQwen == true)
            let profiles = try contexts.candidateProfiles()
            let profile = try #require(profiles.first)
            #expect(profile.allEvidence.contains { $0.sourceSpan?.contains("database transactions") == true })
            #expect(owner.activeCandidateProfileID == profile.id)
            #expect(profiles.count == 1)
            #expect(await exit.pendingCount() == 0)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    /// These use the real concrete provider and its injected URLSession. The
    /// response bodies are synthetic protocol packets, never model-quality evidence.
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func practiceWaitsForNormalAndFailedActualOllamaProducerExit() async throws {
        for fails in [false, true] {
            let exit = ControlledOllamaProducerExit()
            let workers = OllamaControlledTransportWorkers()
            let probe = OllamaStreamingProbe()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let output = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(1))
            OllamaStreamingURLProtocol.handler = { request in
                if request.url?.path == "/api/tags" {
                    return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                        data: Data(#"{"models":[{"name":"synthetic-practice-owned"}]}"#.utf8))],
                        onTaskCreated: { workers.register($0) })
                }
                #expect(request.url?.path == "/api/generate")
                let ordinal = probe.incrementChatCount()
                if ordinal == 2 && fails {
                    return OllamaStreamingPlan(statusCode: 503, chunks: [],
                        onTaskCreated: { workers.register($0) })
                }
                return practiceOwnedPacket(ordinal: ordinal, workers: workers)
            }
            let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
                producerExitCheckpoint: { await exit.hold($0) })
            let database = try AppDatabase(inMemory: true)
            let controller = actualOllamaPracticeController(database: database, provider: provider)
            let observation = controller.runUpdates.sink { run in
                if let phase = run?.phase, [.completed, .failed].contains(phase) {
                    output.continuation.yield(phase.rawValue)
                }
            }
            func cleanup() async {
                controller.cancel()
                await exit.releaseAll()
                await controller.shutdown()
                observation.cancel(); output.continuation.finish()
                session.invalidateAndCancel(); await workers.cancelAndJoin()
                try? database.close()
            }
            do {
                controller.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                    language: "en", criteria: ["State the retry policy"], maxFollowUps: 0)
                controller.beginAnswer()
                controller.run?.draft = "Bound the number of retries."
                controller.submit()
                try #require(try await exit.nextEntered() == 1)
                try #require(controller.run?.phase == .evaluating)
                await exit.release(1)
                try #require(try await exit.nextEntered() == 2)
                #expect(await exit.pendingCount() == 1)
                try #require(controller.run?.phase == .evaluating)
                #expect(controller.run?.attempts.first?.feedback == nil)
                try #require(probe.chatCount == 2,
                    "An admitted draft cannot start semantic review before its exact producer exits.")
                await exit.release(2)
                if !fails {
                    try #require(try await exit.nextEntered() == 3)
                    try #require(controller.run?.phase == .evaluating)
                    #expect(controller.run?.attempts.first?.feedback == nil)
                    await exit.release(3)
                }
                let phase = try await TestEventWaitTrace(label: "practice-native-exit-\(fails)")
                    .nextEvent(in: output.stream, event: "terminal-phase-published")
                #expect(phase == (fails ? "failed" : "completed"))
                #expect(probe.chatCount == (fails ? 2 : 3))
                if fails {
                    #expect(controller.run?.attempts.first?.feedback == nil)
                    #expect(controller.error?.contains("HTTP 503") == true)
                } else {
                    let feedback = try #require(controller.run?.attempts.first?.feedback)
                    #expect(feedback.covered.map(\.quote) == ["Bound the number of retries."])
                    #expect(feedback.missing.isEmpty && feedback.followUp == nil)
                    #expect(feedback.reference == "Bound the retry count.")
                }
                #expect(await exit.pendingCount() == 0)
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancelledPracticeAndEveryShutdownWaiterRetainItsHeldActualProducer() async throws {
        let exit = ControlledOllamaProducerExit()
        let workers = OllamaControlledTransportWorkers()
        let probe = OllamaStreamingProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            if request.url?.path == "/api/tags" {
                return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                    data: Data(#"{"models":[{"name":"synthetic-practice-owned"}]}"#.utf8))],
                    onTaskCreated: { workers.register($0) })
            }
            #expect(request.url?.path == "/api/generate")
            return practiceOwnedPacket(ordinal: probe.incrementChatCount(), workers: workers)
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session,
            producerExitCheckpoint: { await exit.hold($0) })
        let database = try AppDatabase(inMemory: true)
        let controller = actualOllamaPracticeController(database: database, provider: provider)
        let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let secondStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var firstReturned = false
        var secondReturned = false
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        func cleanup() async {
            controller.cancel()
            await exit.releaseAll()
            await first?.value; await second?.value
            await controller.shutdown()
            firstStarted.continuation.finish(); secondStarted.continuation.finish()
            session.invalidateAndCancel(); await workers.cancelAndJoin()
            try? database.close()
        }
        do {
            controller.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                language: "en", criteria: ["State the retry policy"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = "Bound the number of retries."
            controller.submit()
            try #require(try await exit.nextEntered() == 1)
            await exit.release(1)
            try #require(try await exit.nextEntered() == 2)
            try #require(controller.run?.phase == .evaluating)
            controller.cancel()
            #expect(controller.run?.phase == .cancelled)
            first = Task { @MainActor in
                firstStarted.continuation.yield(())
                await controller.shutdown()
                firstReturned = true
            }
            _ = try await TestEventWaitTrace(label: "practice-native-first-shutdown")
                .nextEvent(in: firstStarted.stream, event: "waiter-started")
            second = Task { @MainActor in
                secondStarted.continuation.yield(())
                await controller.shutdown()
                secondReturned = true
            }
            _ = try await TestEventWaitTrace(label: "practice-native-second-shutdown")
                .nextEvent(in: secondStarted.stream, event: "waiter-started")
            // Each MainActor waiter executes through its first suspension before
            // this same-actor observer can inspect its completion flag.
            #expect(!firstReturned && !secondReturned)
            #expect(await exit.pendingCount() == 1)
            #expect(probe.chatCount == 2)
            #expect(controller.run?.attempts.first?.feedback == nil)
            await exit.release(2)
            await first?.value; await second?.value
            #expect(firstReturned && secondReturned)
            #expect(await exit.pendingCount() == 0)
            #expect(controller.run?.phase == .cancelled)
            #expect(controller.run?.attempts.first?.feedback == nil)
            #expect(probe.chatCount == 2, "Cancelled feedback cannot start another review call.")
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func practiceStartupCancellationReachesItsActualReadinessRequest() async throws {
        let tagsRelease = AsyncStream<Void>.makeStream()
        let tagsStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let tagsStopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let workers = OllamaControlledTransportWorkers()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OllamaStreamingURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/tags")
            return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0,
                data: Data(#"{"models":[{"name":"synthetic-practice-owned"}]}"#.utf8))],
                onStop: { tagsStopped.continuation.yield(()) }, beforeChunks: tagsRelease.stream,
                onTaskCreated: { task in workers.register(task); tagsStarted.continuation.yield(()) })
        }
        let provider = OllamaQwenProvider(baseURL: baseURL, session: session)
        let database = try AppDatabase(inMemory: true)
        let controller = actualOllamaPracticeController(database: database, provider: provider)
        var shutdown: Task<Void, Never>?
        func cleanup() async {
            controller.cancel(); tagsRelease.continuation.finish()
            await shutdown?.value; await controller.shutdown()
            tagsStarted.continuation.finish(); tagsStopped.continuation.finish()
            session.invalidateAndCancel(); await workers.cancelAndJoin()
            try? database.close()
        }
        do {
            controller.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                language: "en", criteria: ["State the retry policy"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = "Bound the number of retries."
            controller.submit()
            _ = try await TestEventWaitTrace(label: "practice-native-startup")
                .nextEvent(in: tagsStarted.stream, event: "tags-started")
            shutdown = Task { await controller.shutdown() }
            _ = try await TestEventWaitTrace(label: "practice-native-startup")
                .nextEvent(in: tagsStopped.stream, event: "URLProtocol.stopLoading")
            await shutdown?.value
            #expect(controller.run?.phase == .cancelled)
            #expect(controller.run?.attempts.first?.feedback == nil)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @MainActor
    private func actualOllamaPracticeController(database: AppDatabase, provider: OllamaQwenProvider) -> PracticeController {
        PracticeController(dependencies: .init(
            repository: PracticeRepository(database: database),
            sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database),
            contexts: InterviewContextRepository(database: database),
            persistenceConsent: PersistenceConsent(),
            context: { .init(historyEnabled: false,
                selection: .init(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general),
                temporarySnapshotID: nil) },
            evaluationConfiguration: { (provider, "synthetic-practice-owned") },
            selectedASRProvider: { .localParakeet }, isLiveCaptureActive: { false }, prepareForPractice: {},
            requestAudioPermissions: { _ in
                Issue.record("These native transport cases must never request microphone permission.")
                throw CancellationError()
            },
            makeAudioProvider: { _ in
                Issue.record("These native transport cases must never create a capture provider.")
                throw CancellationError()
            },
            historyDidChange: { _ in }, delayProvider: RealDelayProvider()))
    }

    private func collectPull(_ provider: OllamaQwenProvider) async throws -> [ModelDownloadProgress] {
        var events: [ModelDownloadProgress] = []
        for try await event in provider.pullModel("synthetic-qwen") { events.append(event) }
        return events
    }

    private func makeProvider(
        probe: OllamaStreamingProbe = OllamaStreamingProbe(),
        handler: @escaping (URLRequest) -> OllamaStreamingPlan
    ) -> OllamaQwenProvider {
        OllamaStreamingURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStreamingURLProtocol.self]
        return OllamaQwenProvider(baseURL: baseURL, session: URLSession(configuration: configuration))
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

private func practiceOwnedPacket(ordinal: Int, workers: OllamaControlledTransportWorkers) -> OllamaStreamingPlan {
    let text: String
    switch ordinal {
    case 1:
        text = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
    case 2:
        text = #"{"r0":"Bound the number of retries.","assessments":{"r0":{"presence":"present","accuracy":"unverified","accuracyBasis":"Synthetic transport fixture; technical facts are not independently certified.","fulfillment":"met","basis":"The submitted answer states a bounded retry policy."}},"suggestion":"State an explicit retry budget.","followUp":"","reason":"The supplied retry policy is covered.","reference":"Bound the retry count."}"#
    case 3:
        text = #"{"r0":"Bound the number of retries.","assessments":{"r0":{"presence":"present","accuracy":"unverified","accuracyBasis":"Synthetic transport fixture; technical facts are not independently certified.","fulfillment":"met","basis":"The submitted answer states a bounded retry policy."}},"suggestion":"State an explicit retry budget.","followUp":"","reason":"The supplied retry policy is covered.","reference":"Bound the retry count.","reviewOutcome":"accepted"}"#
    default:
        Issue.record("Unexpected additional actual Practice model request.")
        return OllamaStreamingPlan(statusCode: 500, chunks: [], onTaskCreated: { workers.register($0) })
    }
    guard let data = try? JSONEncoder().encode(text) else {
        Issue.record("Synthetic Practice wire text cannot encode.")
        return OllamaStreamingPlan(statusCode: 500, chunks: [], onTaskCreated: { workers.register($0) })
    }
    let wire = "{\"response\":\(String(decoding: data, as: UTF8.self)),\"done\":false}\n{\"done\":true}\n"
    return OllamaStreamingPlan(chunks: [.init(delayNanoseconds: 0, data: Data(wire.utf8))],
        onTaskCreated: { workers.register($0) })
}

private struct OllamaStreamingPlan: Sendable {
    struct Chunk: Sendable {
        let delayNanoseconds: UInt64
        let data: Data
    }

    let statusCode: Int
    let chunks: [Chunk]
    let finishes: Bool
    let onStart: (@Sendable () -> Void)?
    let onFinish: (@Sendable () -> Void)?
    let onStop: (@Sendable () -> Void)?
    let terminalError: URLError.Code?
    let beforeChunks: AsyncStream<Void>?
    let onTaskCreated: (@Sendable (Task<Void, Never>) -> Void)?

    init(
        statusCode: Int = 200,
        chunks: [Chunk],
        finishes: Bool = true,
        onStart: (@Sendable () -> Void)? = nil,
        onFinish: (@Sendable () -> Void)? = nil,
        onStop: (@Sendable () -> Void)? = nil,
        terminalError: URLError.Code? = nil,
        beforeChunks: AsyncStream<Void>? = nil,
        onTaskCreated: (@Sendable (Task<Void, Never>) -> Void)? = nil
    ) {
        self.statusCode = statusCode
        self.chunks = chunks
        self.finishes = finishes
        self.onStart = onStart
        self.onFinish = onFinish
        self.onStop = onStop
        self.terminalError = terminalError
        self.beforeChunks = beforeChunks
        self.onTaskCreated = onTaskCreated
    }

    static func json(_ json: String) -> OllamaStreamingPlan {
        lines([json])
    }

    static func lines(
        _ lines: [String],
        initialDelayNanoseconds: UInt64 = 0,
        onStart: (@Sendable () -> Void)? = nil
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
    private var onStop: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        plan.onStart?()
        onStop = plan.onStop
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
                if let gate = plan.beforeChunks {
                    var iterator = gate.makeAsyncIterator()
                    _ = await iterator.next()
                    try Task.checkCancellation()
                }
                for chunk in plan.chunks {
                    if chunk.delayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: chunk.delayNanoseconds)
                    }
                    try Task.checkCancellation()
                    self.client?.urlProtocol(self, didLoad: chunk.data)
                }
                guard plan.finishes else { return }
                if let code = plan.terminalError {
                    self.client?.urlProtocol(self, didFailWithError: URLError(code))
                    return
                }
                plan.onFinish?()
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
        if let loadingTask { plan.onTaskCreated?(loadingTask) }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        onStop?()
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
    private var storagePullStarted = false
    private var storagePullStopped = false

    var tagsCount: Int { withLock { storageTagsCount } }
    var chatCount: Int { withLock { storageChatCount } }
    var tagsStarted: Bool { withLock { storageTagsStarted } }
    var firstChatStarted: Bool { withLock { storageFirstChatStarted } }
    var chatFinished: Bool { withLock { storageChatFinished } }
    var chatRequestStreamValue: Bool? { withLock { storageChatRequestStreamValue } }
    var chatRequestThinkValue: Bool? { withLock { storageChatRequestThinkValue } }
    var pullStarted: Bool { withLock { storagePullStarted } }
    var pullStopped: Bool { withLock { storagePullStopped } }

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
    func markPullStarted() { withLock { storagePullStarted = true } }
    func markPullStopped() { withLock { storagePullStopped = true } }

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

    func requestBody(_ request: URLRequest) -> Data? {
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

// Registry retains the actual URLProtocol worker handles until the owning case joins.
// It adds no task, timer, unsafe state or reference across an await under a lock.
private final class OllamaControlledTransportWorkers: Sendable {
    private let handles = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    func register(_ task: Task<Void, Never>) { handles.withLock { $0.append(task) } }
    func cancelAndJoin() async {
        let tasks = handles.withLock { $0 }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
}

// A releasable test-only producer tail. It deliberately ignores cancellation
// so an actual provider Task cannot disappear merely because its stream ended.
private actor ControlledOllamaProducerExit {
    nonisolated let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(8))
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<Int>()
    private var closed = false
    func hold(_ id: Int) async {
        entered.continuation.yield(id)
        if !closed && !released.contains(id) {
            await withCheckedContinuation { waiting[id] = $0 }
        }
    }
    func pendingCount() -> Int { waiting.count }
    func nextEntered() async throws -> Int {
        try await TestEventWaitTrace(label: "ollama-actual-producer-exit")
            .nextEvent(in: entered.stream, event: "producer-held")
    }
    func release(_ id: Int) { released.insert(id); waiting.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        closed = true
        let held = Array(waiting.values)
        waiting.removeAll()
        held.forEach { $0.resume() }
        entered.continuation.finish()
    }
}
