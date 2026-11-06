import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct LocalModelsApplicationOwnershipTests {
    enum LateReadiness: CaseIterable, Sendable { case refresh, pull }

    @Test(.timeLimit(.minutes(1)))
    func setupAndDiagnosticsObserveOneApplicationOwnerAndModelChangesRevokeOldReadiness() async throws {
        try await ApplicationModelFixture.run(context: "shared_windows") { fixture in
            #expect(fixture.factory.count == 0)
            let setup = LocalModelsSetupView(appState: fixture.app)
            let diagnostics = DiagnosticsView(appState: fixture.app)
            #expect(setup.viewModel === fixture.owner)
            #expect(diagnostics.localModels === fixture.owner)
            #expect(fixture.app.localModelsSetupState === fixture.owner)
            #expect(fixture.factory.count == 1)
            #expect(fixture.owner.qwenHealth.selectedModel == "synthetic-qwen-a")
            #expect(!fixture.owner.qwenHealth.isReady)
            await fixture.health.release()
            await fixture.owner.refresh(qwenModel: "synthetic-qwen-a")
            #expect(fixture.owner.qwenHealth.isReady)
            var firstUpdates = 0
            var secondUpdates = 0
            let first = setup.viewModel.objectWillChange.sink { firstUpdates += 1 }
            let second = diagnostics.localModels.objectWillChange.sink { secondUpdates += 1 }
            defer { first.cancel(); second.cancel() }

            setup.qwenModelSelection.wrappedValue = "synthetic-qwen-b"
            #expect(fixture.app.settingsState.selectedQwenModelName == "synthetic-qwen-b")
            #expect(fixture.owner.qwenHealth.selectedModel == "synthetic-qwen-b")
            #expect(!fixture.owner.qwenHealth.isReady)
            #expect(firstUpdates > 0)
            #expect(secondUpdates > 0)
            #expect(fixture.factory.count == 1)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func applicationShutdownCancelsAndJoinsItsNoncooperativeReadinessTask(iteration: Int) async throws {
        do {
            try await ApplicationModelFixture.run(context: "app_shutdown_iteration_\(iteration)") { fixture in
                #expect(fixture.app.localModelsSetupState === fixture.owner)
                let refresh = Task { await fixture.owner.refresh(qwenModel: "synthetic-qwen-a") }
                fixture.tasks.append(refresh)
                try await fixture.health.waitUntilStarted()
                let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let cancelled = fixture.health.cancelled
                let shutdown = Task {
                    await fixture.app.shutdownForTesting()
                    finished.continuation.yield(())
                    finished.continuation.finish()
                }
                fixture.tasks.append(shutdown)
                let cancellationWon = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        var iterator = cancelled.makeAsyncIterator()
                        return await iterator.next() != nil
                    }
                    group.addTask {
                        var iterator = finished.stream.makeAsyncIterator()
                        _ = await iterator.next()
                        return false
                    }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                try Task.checkCancellation()
                #expect(cancellationWon)
                // The exact suspended Task remains retained through its real exit.
                #expect(fixture.owner.pendingOperationTaskCount == 1)
                await fixture.health.release()
                await refresh.value
                await shutdown.value
                #expect(fixture.owner.pendingOperationTaskCount == 0)
                #expect(!fixture.owner.qwenHealth.isReady)
                #expect(!fixture.owner.parakeetRuntimeAvailable)
                fixture.owner.requestRefresh(qwenModel: "synthetic-qwen-b")
                #expect(fixture.owner.pendingOperationTaskCount == 0)
                #expect(await fixture.health.requestCount() == 1)
                #expect(fixture.factory.count == 1)
            }
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func actualSetupReadinessActionUsesItsFrozenOutcome(iteration: Int) async throws {
        try await exerciseSetupReadiness(cancel: false, iteration: iteration)
    }
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func actualSetupReadinessActionHonorsViewCancellation(iteration: Int) async throws {
        try await exerciseSetupReadiness(cancel: true, iteration: iteration)
    }

    private func exerciseSetupReadiness(cancel: Bool, iteration: Int) async throws {
        do {
            try await ApplicationModelFixture.run(context: "setup_cancel_\(cancel)_iteration_\(iteration)") { fixture in
                let setup = LocalModelsSetupView(appState: fixture.app)
                let action = Task { await setup.refreshReadinessForSetup() }
                fixture.tasks.append(action)
                try await fixture.health.waitUntilStarted()
                if cancel {
                    action.cancel()
                    try await fixture.health.waitUntilCancelled()
                }
                await fixture.health.release()
                await action.value
                #expect(fixture.app.selectedAnswerProviderMode == (cancel ? .deepSeekPrimary : .localQwenPrimary))
                #expect(fixture.owner.qwenHealth.isReady == !cancel)
                #expect(fixture.owner.pendingOperationTaskCount == 0)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: LateReadiness.allCases, 0..<20)
    func settingsSelectionRejectsOldReadyHealthFromRefreshOrPull(operation: LateReadiness, iteration: Int) async throws {
        try await ApplicationModelFixture.run(context: "selection_\(operation)_iteration_\(iteration)", immediateFirstHealth: true) { fixture in
            let setup = LocalModelsSetupView(appState: fixture.app)
            await fixture.owner.refresh(qwenModel: "synthetic-qwen-a")
            #expect(fixture.owner.qwenHealth.isReady)
            let old: Task<Void, Never>
            switch operation {
            case .refresh:
                old = Task { await fixture.owner.refresh(qwenModel: "synthetic-qwen-a") }
            case .pull:
                fixture.owner.pullQwen(modelName: "synthetic-qwen-a")
                let matches = fixture.owner.operationTasks(for: .pullQwen)
                #expect(matches.count == 1)
                old = try #require(matches.first)
                try await fixture.pull.waitUntilStarted()
                await fixture.pull.release()
            }
            fixture.tasks.append(old)
            try await fixture.health.waitUntilStarted()

            setup.qwenModelSelection.wrappedValue = "synthetic-qwen-b"
            try await fixture.health.waitUntilCancelled()
            #expect(fixture.owner.qwenHealth.selectedModel == "synthetic-qwen-b")
            #expect(!fixture.owner.qwenHealth.isReady)
            #expect(!fixture.owner.isPullingQwen)
            #expect(fixture.app.settingsState.selectedQwenModelName == "synthetic-qwen-b")
            await fixture.health.release()
            await old.value
            #expect(fixture.owner.qwenHealth.selectedModel == "synthetic-qwen-b")
            #expect(!fixture.owner.qwenHealth.isReady)
            #expect(fixture.owner.pendingOperationTaskCount == 0)
            #expect(fixture.app.selectedAnswerProviderMode == .deepSeekPrimary)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownDoesNotConstructAnUnusedModelOwnerAndLateAccessIsClosed() async throws {
        try await ApplicationModelFixture.run(context: "unused_shutdown") { fixture in
            #expect(fixture.factory.count == 0)
            await fixture.app.shutdownForTesting()
            #expect(fixture.factory.count == 0)
            let late = fixture.app.localModelsSetupState
            #expect(late === fixture.owner)
            #expect(fixture.factory.count == 1)
            #expect(fixture.app.localModelsSetupState === late)
            late.requestRefresh(qwenModel: "synthetic-qwen-a")
            late.pullQwen(modelName: "synthetic-qwen-a")
            late.downloadTranscriptionModel()
            late.deleteTranscriptionModel()
            late.installRecommended(qwenModel: "synthetic-qwen-a")
            #expect(late.pendingOperationTaskCount == 0)
            #expect(await fixture.health.requestCount() == 0)
            #expect(fixture.factory.count == 1)
        }
    }
}

private actor ApplicationModelHealthGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<Void>.Continuation
    private let immediateFirst: Bool
    private var held: CheckedContinuation<LocalLLMHealth, Never>?
    private var requestedModel: String?
    private var count = 0
    private var released = false
    init(label: String, immediateFirst: Bool) {
        trace = TestEventWaitTrace(label: label)
        self.immediateFirst = immediateFirst
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancelled = cancel.stream
        cancelContinuation = cancel.continuation
    }
    func result(modelName: String) async -> LocalLLMHealth {
        count += 1
        if immediateFirst, count == 1 { return ready(modelName: modelName) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                held = continuation
                requestedModel = modelName
                trace.mark("producer.start.yield.before")
                let yielded = startContinuation.yield(())
                trace.mark("producer.start.yield.\(yielded)")
                startContinuation.finish()
                completeIfReleased()
            }
        } onCancel: {
            trace.mark("producer.cancel.yield.before")
            let yielded = cancelContinuation.yield(())
            trace.mark("producer.cancel.yield.\(yielded)")
            cancelContinuation.finish()
        }
    }
    func requestCount() -> Int { count }
    func release() { released = true; completeIfReleased() }
    private func ready(modelName: String) -> LocalLLMHealth {
        LocalLLMHealth(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    private func completeIfReleased() {
        guard released, let held, let requestedModel else { return }
        self.held = nil
        held.resume(returning: ready(modelName: requestedModel))
    }
    nonisolated func waitUntilStarted() async throws { _ = try await trace.nextEvent(in: started, event: "start") }
    nonisolated func waitUntilCancelled() async throws { _ = try await trace.nextEvent(in: cancelled, event: "cancel") }
}

private actor ApplicationModelPullGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let progress: AsyncThrowingStream<ModelDownloadProgress, Error>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let progressContinuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    private var released = false
    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
        let progress = AsyncThrowingStream<ModelDownloadProgress, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.progress = progress.stream
        progressContinuation = progress.continuation
    }
    nonisolated func begin() -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        trace.mark("producer.start.yield.before")
        let yielded = startContinuation.yield(())
        trace.mark("producer.start.yield.\(yielded)")
        startContinuation.finish()
        return progress
    }
    func release() {
        guard !released else { return }
        released = true
        progressContinuation.yield(.completed(modelID: "synthetic-qwen-a", totalBytes: 1))
        progressContinuation.finish()
    }
    nonisolated func waitUntilStarted() async throws { _ = try await trace.nextEvent(in: started, event: "start") }
}

private struct ApplicationModelManager: LocalModelManager, Sendable {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        URL(fileURLWithPath: "/synthetic-unopened-application-model").appendingPathComponent(model.storageRelativePath)
    }
}
private final class ApplicationModelProvider: LocalLLMProvider, Sendable {
    let id = "synthetic-application-model"
    let displayName = "Synthetic application model"
    let health: ApplicationModelHealthGate
    let pull: ApplicationModelPullGate
    init(health: ApplicationModelHealthGate, pull: ApplicationModelPullGate) { self.health = health; self.pull = pull }
    func healthCheck(modelName: String) async -> LocalLLMHealth { await health.result(modelName: modelName) }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { pull.begin() }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> { throw CancellationError() }
}
private final class ApplicationModelRuntime: ParakeetRuntimeClient, Sendable {
    func isRuntimeAvailable() async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> { throw CancellationError() }
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func stop() async {}
}

@MainActor
private final class ApplicationModelFactory {
    let owner: LocalModelsSetupViewModel
    private(set) var count = 0
    init(owner: LocalModelsSetupViewModel) { self.owner = owner }
    func make() -> LocalModelsSetupViewModel { count += 1; return owner }
}

@MainActor
private final class ApplicationModelFixture {
    let database: AppDatabase
    let defaults: UserDefaults
    let suite: String
    let health: ApplicationModelHealthGate
    let pull: ApplicationModelPullGate
    let owner: LocalModelsSetupViewModel
    let factory: ApplicationModelFactory
    let app: AppState
    var tasks: [Task<Void, Never>] = []
    init(context: String, immediateFirstHealth: Bool) async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        suite = "com.langcheng.Hireva.tests.application-model-owner.\(UUID().uuidString)"
        do {
            defaults = try #require(UserDefaults(suiteName: suite))
        } catch {
            try? database.close()
            throw error
        }
        defaults.set("synthetic-qwen-a", forKey: HirevaPreferenceKeys.selectedQwenModel)
        defaults.set(AnswerProviderMode.deepSeekPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        let health = ApplicationModelHealthGate(label: "\(context):health", immediateFirst: immediateFirstHealth)
        let pull = ApplicationModelPullGate(label: "\(context):pull")
        self.health = health; self.pull = pull
        let owner = LocalModelsSetupViewModel(modelManager: ApplicationModelManager(),
            qwenProvider: ApplicationModelProvider(health: health, pull: pull), parakeetRuntimeClient: ApplicationModelRuntime())
        self.owner = owner
        let factory = ApplicationModelFactory(owner: owner)
        self.factory = factory
        app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults, localModelsSetupFactory: { factory.make() })
    }
    private func cleanup() async throws {
        owner.closeAdmission()
        for task in tasks { task.cancel() }
        await health.release()
        await pull.release()
        for task in tasks { await task.value }
        await app.shutdownForTesting()
        await owner.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }
    static func run(context: String, immediateFirstHealth: Bool = false,
        _ body: (ApplicationModelFixture) async throws -> Void) async throws {
        let fixture = try await ApplicationModelFixture(context: context, immediateFirstHealth: immediateFirstHealth)
        do { try await body(fixture); try await fixture.cleanup() }
        catch { try await fixture.cleanup(); throw error }
    }
}
