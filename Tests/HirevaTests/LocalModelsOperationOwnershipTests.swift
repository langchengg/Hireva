import AVFoundation
import Foundation
import Testing
@testable import Hireva

// Cancellation and shutdown contracts use independently owned synthetic jobs.
// Each independent repetition has the same 60-second owning-test deadline.
// Existing install and deletion regressions remain in their original suites.
@MainActor
struct LocalModelsOperationOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], 0..<20)
    func cancellingRecommendedJoinsItsChildrenWithoutClosingFutureRefresh(asrFinishesFirst: Bool, iteration: Int) async throws {
        try await SetupOperationFixture.run(context: "cancel_owned_\(asrFinishesFirst)_iteration_\(iteration)", holdPostPullHealth: true) { fixture in
            fixture.viewModel.installRecommended(qwenModel: "synthetic-setup-model")
            let parent = try fixture.capture(.installRecommended)
            try await fixture.asr.waitUntilStarted()
            try await fixture.qwen.waitUntilStarted()
            let download = try fixture.capture(.downloadTranscription)
            let pull = try fixture.capture(.pullQwen)
            if asrFinishesFirst {
                await fixture.asr.release()
                await download.value
            }
            await fixture.qwen.release()
            try await fixture.postPull.waitUntilStarted()
            let originalHealth = fixture.viewModel.qwenHealth
            fixture.viewModel.cancelRecommended()
            try await fixture.postPull.waitUntilCancelled()
            await fixture.postPull.release()
            await fixture.asr.release()
            await parent.value
            await download.value
            await pull.value
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(fixture.viewModel.qwenHealth == originalHealth,
                "Cancelled child published old health in iteration \(iteration).")
            #expect(!fixture.viewModel.isInstallingRecommended)
            #expect(!fixture.viewModel.isDownloadingTranscription)
            #expect(!fixture.viewModel.isPullingQwen)
            #expect(fixture.viewModel.lastError == nil)

            await fixture.viewModel.refresh(qwenModel: "synthetic-current-model")
            #expect(fixture.viewModel.qwenHealth.selectedModel == "synthetic-current-model")
            #expect(fixture.viewModel.qwenHealth.isReady)
            #expect(!fixture.viewModel.isRefreshing)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], 0..<20)
    func parentCancellationPreservesAnAlreadyRunningIndependentChild(borrowTranscription: Bool, iteration: Int) async throws {
        try await SetupOperationFixture.run(context: "cancel_borrowed_\(borrowTranscription)_iteration_\(iteration)", holdPostPullHealth: true) { fixture in
            if borrowTranscription {
                fixture.viewModel.downloadTranscriptionModel()
                try await fixture.asr.waitUntilStarted()
            } else {
                fixture.viewModel.pullQwen(modelName: "synthetic-setup-model")
                try await fixture.qwen.waitUntilStarted()
            }
            let independent = try fixture.capture(borrowTranscription ? .downloadTranscription : .pullQwen)
            fixture.viewModel.installRecommended(qwenModel: "synthetic-setup-model")
            let parent = try fixture.capture(.installRecommended)
            if borrowTranscription { try await fixture.qwen.waitUntilStarted() }
            else { try await fixture.asr.waitUntilStarted() }
            let created = try fixture.capture(borrowTranscription ? .pullQwen : .downloadTranscription)
            #expect(fixture.viewModel.operationTasks(for: .downloadTranscription).count == 1)
            #expect(fixture.viewModel.operationTasks(for: .pullQwen).count == 1)
            let originalHealth = fixture.viewModel.qwenHealth
            await fixture.qwen.release()
            try await fixture.postPull.waitUntilStarted()

            fixture.viewModel.cancelRecommended()
            #expect(parent.isCancelled)
            #expect(created.isCancelled, "Parent did not cancel its own child in iteration \(iteration).")
            #expect(!independent.isCancelled, "Parent cancelled borrowed user work in iteration \(iteration).")
            #expect(fixture.viewModel.pendingOperationTaskCount > 0)
            if borrowTranscription { try await fixture.postPull.waitUntilCancelled() }
            await fixture.postPull.release()
            await fixture.asr.release()
            await parent.value
            await created.value
            await independent.value
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(!fixture.viewModel.isInstallingRecommended)
            #expect(fixture.viewModel.lastError == nil)
            if borrowTranscription {
                #expect(fixture.viewModel.transcriptionStatus.isReady)
                #expect(fixture.viewModel.qwenHealth == originalHealth)
            } else {
                #expect(fixture.viewModel.qwenHealth.isReady)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], 0..<20)
    func shutdownCancelsChildrenJoinsLateHealthAndPermanentlyClosesAdmission(asrFinishesFirst: Bool, iteration: Int) async throws {
        try await SetupOperationFixture.run(context: "shutdown_\(asrFinishesFirst)_iteration_\(iteration)", holdPostPullHealth: true) { fixture in
            fixture.viewModel.installRecommended(qwenModel: "synthetic-setup-model")
            let parent = try fixture.capture(.installRecommended)
            try await fixture.asr.waitUntilStarted()
            try await fixture.qwen.waitUntilStarted()
            let download = try fixture.capture(.downloadTranscription)
            let pull = try fixture.capture(.pullQwen)
            if asrFinishesFirst {
                await fixture.asr.release()
                await download.value
            }
            await fixture.qwen.release()
            try await fixture.postPull.waitUntilStarted()
            let originalHealth = fixture.viewModel.qwenHealth
            let shutdown = fixture.beginShutdown()
            try await fixture.postPull.waitUntilCancelled()
            #expect(fixture.viewModel.pendingOperationTaskCount > 0,
                "Noncooperative health still owns its Task in iteration \(iteration).")

            await fixture.postPull.release()
            await fixture.asr.release()
            await shutdown.value
            await parent.value
            await download.value
            await pull.value
            #expect(fixture.viewModel.qwenHealth == originalHealth)
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(!fixture.viewModel.isInstallingRecommended)
            #expect(!fixture.viewModel.isDownloadingTranscription)
            #expect(!fixture.viewModel.isPullingQwen)

            fixture.viewModel.installRecommended(qwenModel: "synthetic-after-shutdown")
            fixture.viewModel.downloadTranscriptionModel()
            fixture.viewModel.pullQwen(modelName: "synthetic-after-shutdown")
            fixture.viewModel.deleteTranscriptionModel()
            await fixture.viewModel.refresh(qwenModel: "synthetic-after-shutdown")
            #expect(fixture.viewModel.pendingOperationTaskCount == 0)
            #expect(fixture.viewModel.qwenHealth == originalHealth)
            #expect(!fixture.viewModel.isInstallingRecommended)
            #expect(!fixture.viewModel.isDownloadingTranscription)
            #expect(!fixture.viewModel.isPullingQwen)
            #expect(fixture.viewModel.lastError == nil)
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

private actor SetupStreamingManager: LocalModelManager {
    nonisolated private let gate: SetupProgressGate
    private let postDownload: SetupPostPullHealthGate?
    private let deleteCompletion: SetupPostPullHealthGate?
    private var heldStatusOnce = false
    private var deleted = false
    init(gate: SetupProgressGate, postDownload: SetupPostPullHealthGate?, deleteCompletion: SetupPostPullHealthGate?) {
        self.gate = gate; self.postDownload = postDownload; self.deleteCompletion = deleteCompletion
    }
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus {
        let ready = await gate.isComplete()
        let snapshot: LocalModelStatus = ready && !deleted ? .installed : .notInstalled
        if ready, !heldStatusOnce, let postDownload {
            heldStatusOnce = true
            await postDownload.hold()
        }
        return snapshot
    }
    nonisolated func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { gate.begin() }
    func deleteModel(_ model: LocalModelDescriptor) async throws {
        deleted = true
        if let deleteCompletion { await deleteCompletion.hold() }
    }
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { await gate.isComplete() && !deleted }
    nonisolated func fileURL(for model: LocalModelDescriptor) -> URL {
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
    let postDownload: SetupPostPullHealthGate
    let deleteCompletion: SetupPostPullHealthGate
    let viewModel: LocalModelsSetupViewModel
    private var tasks: [Task<Void, Never>] = []
    private let trace: TestEventWaitTrace

    init(context: String, holdPostPullHealth: Bool, holdPostDownloadStatus: Bool, holdDeleteCompletion: Bool) {
        trace = TestEventWaitTrace(label: context)
        let asr = SetupProgressGate(modelID: LocalModelDescriptor.defaultParakeetASR.id, label: "\(context):asr")
        let qwen = SetupProgressGate(modelID: "synthetic-setup-model", label: "\(context):qwen")
        let postPull = SetupPostPullHealthGate(label: "\(context):post_pull")
        let postDownload = SetupPostPullHealthGate(label: "\(context):post_download")
        let deleteCompletion = SetupPostPullHealthGate(label: "\(context):delete_completion")
        self.postDownload = postDownload
        self.deleteCompletion = deleteCompletion
        self.asr = asr
        self.qwen = qwen
        self.postPull = postPull
        viewModel = LocalModelsSetupViewModel(modelManager: SetupStreamingManager(gate: asr,
                postDownload: holdPostDownloadStatus ? postDownload : nil,
                deleteCompletion: holdDeleteCompletion ? deleteCompletion : nil),
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

    func beginShutdown() -> Task<Void, Never> {
        let task = Task {
            await viewModel.shutdown()
            #expect(await postPull.isReleased(), "Shutdown returned before noncooperative health exited.")
        }
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
        await postDownload.release()
        await deleteCompletion.release()
        for task in tasks { await task.value }
        await viewModel.waitForPendingOperations()
        trace.mark("cleanup.end.pending_\(viewModel.pendingOperationTaskCount)")
    }

    static func run(context: String, holdPostPullHealth: Bool = false, holdPostDownloadStatus: Bool = false, holdDeleteCompletion: Bool = false,
        _ body: (SetupOperationFixture) async throws -> Void) async throws {
        let fixture = SetupOperationFixture(context: context, holdPostPullHealth: holdPostPullHealth,
            holdPostDownloadStatus: holdPostDownloadStatus, holdDeleteCompletion: holdDeleteCompletion)
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
