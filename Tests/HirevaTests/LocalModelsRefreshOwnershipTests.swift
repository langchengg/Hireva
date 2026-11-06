import AVFoundation
import Foundation
import Testing
@testable import Hireva

@MainActor
struct LocalModelsRefreshOwnershipTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func laterRefreshOwnsPublicationWhenFirstFinishesFirst(iteration: Int) async throws {
        try await exerciseRefreshOrder(firstFinishesLast: false, iteration: iteration)
    }
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func laterRefreshOwnsPublicationWhenFirstFinishesLast(iteration: Int) async throws {
        try await exerciseRefreshOrder(firstFinishesLast: true, iteration: iteration)
    }

    private func exerciseRefreshOrder(firstFinishesLast: Bool, iteration: Int) async throws {
        do {
            try await LocalModelsRefreshFixture.run(context: "refresh_order_\(firstFinishesLast)_iteration_\(iteration)") { fixture in
                let original = fixture.viewModel.qwenHealth
                let first = fixture.refresh("synthetic-qwen-a")
                try await fixture.first.waitUntilStarted()
                let second = fixture.refresh("synthetic-qwen-b")
                try await fixture.second.waitUntilStarted()

                if firstFinishesLast {
                    await fixture.second.release()
                    await second.value
                    #expect(fixture.viewModel.qwenHealth.selectedModel == "synthetic-qwen-b")
                    #expect(fixture.viewModel.qwenHealth.isReady)
                    await fixture.first.release()
                    await first.value
                } else {
                    await fixture.first.release()
                    await first.value
                    #expect(fixture.viewModel.qwenHealth == original, "Old request published in iteration \(iteration).")
                    #expect(fixture.viewModel.isRefreshing, "Old cleanup cleared the newer refresh in iteration \(iteration).")
                    await fixture.second.release()
                    await second.value
                }

                #expect(fixture.viewModel.qwenHealth.selectedModel == "synthetic-qwen-b")
                #expect(fixture.viewModel.qwenHealth.isReady)
                #expect(!fixture.viewModel.isRefreshing)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func cancellingViewRefreshRejectsNoncooperativeLateHealthAndRuntimePublication(iteration: Int) async throws {
        try await LocalModelsRefreshFixture.run(context: "refresh_cancel_iteration_\(iteration)") { fixture in
            let original = fixture.viewModel.qwenHealth
            let task = fixture.refresh("synthetic-qwen-a")
            try await fixture.first.waitUntilStarted()
            task.cancel()
            try await fixture.first.waitUntilCancelled()
            await fixture.first.release()
            await task.value

            #expect(fixture.viewModel.qwenHealth == original)
            #expect(!fixture.viewModel.parakeetRuntimeAvailable)
            #expect(!fixture.viewModel.isRefreshing)
        }
    }
}

private actor SetupHealthGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<Void>.Continuation
    private let ready: Bool
    private var continuation: CheckedContinuation<LocalLLMHealth, Never>?
    private var modelName: String?
    private var released = false

    init(ready: Bool, label: String) {
        trace = TestEventWaitTrace(label: label)
        self.ready = ready
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancelled = cancel.stream
        cancelContinuation = cancel.continuation
    }

    func result(modelName: String) async -> LocalLLMHealth {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.modelName = modelName
                self.continuation = continuation
                trace.mark("producer.start.yield.before")
                let yielded = startContinuation.yield(())
                trace.mark("producer.start.yield.\(yielded)")
                startContinuation.finish()
                if released { complete() }
            }
        } onCancel: {
            // The transport intentionally ignores cancellation until explicitly released.
            trace.mark("producer.cancel.yield.before")
            let yielded = cancelContinuation.yield(())
            trace.mark("producer.cancel.yield.\(yielded)")
            cancelContinuation.finish()
        }
    }

    func release() {
        released = true
        complete()
    }

    private func complete() {
        guard let continuation, let modelName else { return }
        self.continuation = nil
        continuation.resume(returning: LocalLLMHealth(
            ollamaRunning: true, selectedModel: modelName, modelInstalled: ready,
            providerSource: .ollamaQwen, lastError: nil))
    }

    nonisolated func waitUntilStarted() async throws { try await Self.waitFor(started, trace: trace, event: "start") }
    nonisolated func waitUntilCancelled() async throws { try await Self.waitFor(cancelled, trace: trace, event: "cancel") }

    private nonisolated static func waitFor(_ events: AsyncStream<Void>, trace: TestEventWaitTrace, event: String) async throws {
        _ = try await trace.nextEvent(in: events, event: event)
    }
}

private final class SetupControlledQwenProvider: LocalLLMProvider {
    let id = "synthetic-setup-qwen"
    let displayName = "Synthetic setup Qwen"
    private let first: SetupHealthGate
    private let second: SetupHealthGate

    init(first: SetupHealthGate, second: SetupHealthGate) {
        self.first = first
        self.second = second
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        let gate = modelName == "synthetic-qwen-a" ? first : second
        return await gate.result(modelName: modelName)
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }

    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        throw CancellationError()
    }
}

private struct SetupStaticModelManager: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .notInstalled }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { false }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        URL(fileURLWithPath: "/synthetic-never-opened-models").appendingPathComponent(model.storageRelativePath)
    }
}

private final class SetupStaticRuntime: ParakeetRuntimeClient {
    func isRuntimeAvailable() async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        throw CancellationError()
    }
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func stop() async {}
}

@MainActor
private final class LocalModelsRefreshFixture {
    let first: SetupHealthGate
    let second: SetupHealthGate
    let viewModel: LocalModelsSetupViewModel
    private var tasks: [Task<Void, Never>] = []
    private let trace: TestEventWaitTrace

    init(context: String) {
        trace = TestEventWaitTrace(label: context)
        let first = SetupHealthGate(ready: false, label: "\(context):health_a")
        let second = SetupHealthGate(ready: true, label: "\(context):health_b")
        self.first = first
        self.second = second
        viewModel = LocalModelsSetupViewModel(modelManager: SetupStaticModelManager(),
            qwenProvider: SetupControlledQwenProvider(first: first, second: second),
            parakeetRuntimeClient: SetupStaticRuntime())
    }

    func refresh(_ model: String) -> Task<Void, Never> {
        let task = Task { await viewModel.refresh(qwenModel: model) }
        tasks.append(task)
        return task
    }

    private func cleanup() async {
        trace.mark("cleanup.begin.pending_\(viewModel.pendingOperationTaskCount)")
        viewModel.closeAdmission()
        for task in tasks { task.cancel() }
        await first.release()
        await second.release()
        for task in tasks { await task.value }
        await viewModel.waitForPendingOperations()
        trace.mark("cleanup.end.pending_\(viewModel.pendingOperationTaskCount)")
    }

    static func run(context: String, _ body: (LocalModelsRefreshFixture) async throws -> Void) async throws {
        let fixture = LocalModelsRefreshFixture(context: context)
        fixture.trace.mark("case.begin")
        do {
            try await body(fixture)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }
}
