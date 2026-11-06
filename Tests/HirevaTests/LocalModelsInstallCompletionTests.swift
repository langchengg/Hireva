import AVFoundation
import Foundation
import Testing
@testable import Hireva

// External draft: actual existing install behavior plus retained-operation characterization.
// Requires retained-operations-characterization.patch; no shutdown stub or false bug red.
@MainActor
struct LocalModelsInstallCompletionTests {
    @Test(.timeLimit(.minutes(1)))
    func registeredOperationsRemainOwnedUntilTheirActualTasksExit() async throws {
        try await SetupOperationFixture.run(context: "retained_operation_characterization") { fixture in
            fixture.viewModel.downloadTranscriptionModel()
            fixture.viewModel.pullQwen(modelName: "synthetic-setup-model")
            let download = try fixture.capture(.downloadTranscription)
            let pull = try fixture.capture(.pullQwen)
            try await fixture.asr.waitUntilStarted()
            try await fixture.qwen.waitUntilStarted()
            #expect(fixture.viewModel.pendingOperationTaskCount == 2)

            await fixture.asr.release()
            await download.value
            #expect(fixture.viewModel.pendingOperationTaskCount == 1)
            await fixture.qwen.release()
            await pull.value
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(fixture.viewModel.transcriptionStatus.isReady)
            #expect(fixture.viewModel.qwenHealth.isReady)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], 0..<20)
    func recommendedInstallWaitsForBothStartedChildren(asrFinishesFirst: Bool, iteration: Int) async throws {
        try await SetupOperationFixture.run(context: "parent_await_\(asrFinishesFirst)_iteration_\(iteration)") { fixture in
            fixture.viewModel.installRecommended(qwenModel: "synthetic-setup-model")
            let parent = try fixture.capture(.installRecommended)
            try await fixture.asr.waitUntilStarted()
            try await fixture.qwen.waitUntilStarted()
            let download = try fixture.capture(.downloadTranscription)
            let pull = try fixture.capture(.pullQwen)
            #expect(fixture.viewModel.isInstallingRecommended,
                "Parent claimed completion with both children pending in iteration \(iteration).")

            if asrFinishesFirst {
                await fixture.asr.release()
                await download.value
            } else {
                await fixture.qwen.release()
                await pull.value
            }
            #expect(fixture.viewModel.isInstallingRecommended,
                "Parent claimed completion with one child pending in iteration \(iteration).")

            await fixture.asr.release()
            await fixture.qwen.release()
            await download.value
            await pull.value
            await parent.value
            #expect(!fixture.viewModel.isInstallingRecommended)
            #expect(!fixture.viewModel.isDownloadingTranscription)
            #expect(!fixture.viewModel.isPullingQwen)
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(fixture.viewModel.transcriptionStatus.isReady)
            #expect(fixture.viewModel.qwenHealth.isReady)
        }
    }


}

private actor SetupProgressGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let progress: AsyncThrowingStream<ModelDownloadProgress, Error>
    nonisolated let started: AsyncStream<Void>
    private let progressContinuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    private let startContinuation: AsyncStream<Void>.Continuation
    private let modelID: String
    private var completed = false

    init(modelID: String, label: String) {
        trace = TestEventWaitTrace(label: label)
        self.modelID = modelID
        let progress = AsyncThrowingStream<ModelDownloadProgress, Error>.makeStream(bufferingPolicy: .bufferingNewest(4))
        self.progress = progress.stream
        progressContinuation = progress.continuation
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
    }

    nonisolated func begin() -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        trace.mark("producer.start.yield.before")
        let yielded = startContinuation.yield(())
        trace.mark("producer.start.yield.\(yielded)")
        startContinuation.finish()
        return progress
    }

    func release() {
        guard !completed else { return }
        completed = true
        progressContinuation.yield(.completed(modelID: modelID, totalBytes: 1))
        progressContinuation.finish()
    }

    func isComplete() -> Bool { completed }

    nonisolated func waitUntilStarted() async throws {
        try await SetupOperationFixture.waitFor(started, trace: trace, event: "start")
    }
}

private actor SetupPostPullHealthGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancelled = cancel.stream
        cancelContinuation = cancel.continuation
    }

    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                trace.mark("producer.start.yield.before")
                let yielded = startContinuation.yield(())
                trace.mark("producer.start.yield.\(yielded)")
                startContinuation.finish()
                if released { complete() }
            }
        } onCancel: {
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
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }

    func isReleased() -> Bool { released }
    nonisolated func waitUntilStarted() async throws { try await SetupOperationFixture.waitFor(started, trace: trace, event: "start") }
    nonisolated func waitUntilCancelled() async throws { try await SetupOperationFixture.waitFor(cancelled, trace: trace, event: "cancel") }
}

private final class SetupStreamingManager: LocalModelManager {
    private let gate: SetupProgressGate
    init(gate: SetupProgressGate) { self.gate = gate }
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus {
        await gate.isComplete() ? .installed : .notInstalled
    }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { gate.begin() }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { await gate.isComplete() }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        URL(fileURLWithPath: "/synthetic-never-opened-models").appendingPathComponent(model.storageRelativePath)
    }
}

private final class SetupStreamingQwenProvider: LocalLLMProvider {
    let id = "synthetic-setup-pull"
    let displayName = "Synthetic setup pull"
    private let gate: SetupProgressGate
    private let postPull: SetupPostPullHealthGate
    private let holdPostPullHealth: Bool

    init(gate: SetupProgressGate, postPull: SetupPostPullHealthGate, holdPostPullHealth: Bool) {
        self.gate = gate
        self.postPull = postPull
        self.holdPostPullHealth = holdPostPullHealth
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        let ready = await gate.isComplete()
        if ready, holdPostPullHealth { await postPull.hold() }
        return LocalLLMHealth(ollamaRunning: true, selectedModel: modelName, modelInstalled: ready,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { gate.begin() }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> { throw CancellationError() }
}

private final class SetupOperationRuntime: ParakeetRuntimeClient {
    func isRuntimeAvailable() async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        throw CancellationError()
    }
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func stop() async {}
}

@MainActor
private final class SetupOperationFixture {
    let asr: SetupProgressGate
    let qwen: SetupProgressGate
    let postPull: SetupPostPullHealthGate
    let viewModel: LocalModelsSetupViewModel
    private var tasks: [Task<Void, Never>] = []
    private let trace: TestEventWaitTrace

    init(context: String, holdPostPullHealth: Bool) {
        trace = TestEventWaitTrace(label: context)
        let asr = SetupProgressGate(modelID: LocalModelDescriptor.defaultParakeetASR.id, label: "\(context):asr")
        let qwen = SetupProgressGate(modelID: "synthetic-setup-model", label: "\(context):qwen")
        let postPull = SetupPostPullHealthGate(label: "\(context):post_pull")
        self.asr = asr
        self.qwen = qwen
        self.postPull = postPull
        viewModel = LocalModelsSetupViewModel(modelManager: SetupStreamingManager(gate: asr),
            qwenProvider: SetupStreamingQwenProvider(gate: qwen, postPull: postPull, holdPostPullHealth: holdPostPullHealth),
            parakeetRuntimeClient: SetupOperationRuntime())
    }

    func capture(_ operation: LocalModelsSetupViewModel.Operation) throws -> Task<Void, Never> {
        let matching = viewModel.operationTasks(for: operation)
        #expect(matching.count == 1)
        let task = try #require(matching.first)
        tasks.append(task)
        return task
    }

    private func cleanup() async {
        trace.mark("cleanup.begin.pending_\(viewModel.pendingOperationTaskCount)")
        viewModel.closeAdmission()
        for task in tasks { task.cancel() }
        await asr.release()
        await qwen.release()
        await postPull.release()
        for task in tasks { await task.value }
        await viewModel.waitForPendingOperations()
        trace.mark("cleanup.end.pending_\(viewModel.pendingOperationTaskCount)")
    }

    static func run(context: String, holdPostPullHealth: Bool = false,
        _ body: (SetupOperationFixture) async throws -> Void) async throws {
        let fixture = SetupOperationFixture(context: context, holdPostPullHealth: holdPostPullHealth)
        fixture.trace.mark("case.begin")
        do {
            try await body(fixture)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    nonisolated static func waitFor(_ events: AsyncStream<Void>, trace: TestEventWaitTrace, event: String) async throws {
        _ = try await trace.nextEvent(in: events, event: event)
    }
}
