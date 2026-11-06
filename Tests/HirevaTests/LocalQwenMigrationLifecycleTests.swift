import Foundation
import Testing
@testable import Hireva

@MainActor
struct LocalQwenMigrationLifecycleTests {
    enum InterveningIntent: CaseIterable, Equatable, Sendable {
        case modelChange, repeatedSameMode, repeatedSameModel, modelABA, shutdown
    }

    @Test(.timeLimit(.minutes(1)))
    func launchReadinessForTheStillSelectedModelKeepsLegacySuccess() async throws {
        try await MigrationLifecycleFixture.run(context: "migration_unchanged_success") { fixture in
            let task = try #require(fixture.app.runLaunchLocalQwenDefaultMigrationIfNeeded(
                healthCheck: { await fixture.health.result(modelName: $0) }))
            fixture.tasks.append(task)
            try await fixture.health.waitUntilStarted()
            await fixture.health.release()
            await task.value
            #expect(fixture.app.selectedAnswerProviderMode == .localQwenPrimary)
            #expect(!task.isCancelled)
            #expect(fixture.app.settingsState.pendingTaskCount == 0)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func launchReadinessRejectsModelChange(iteration: Int) async throws {
        try await exerciseInterveningIntent(intent: .modelChange, iteration: iteration)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func launchReadinessRejectsRepeatedSameMode(iteration: Int) async throws {
        try await exerciseInterveningIntent(intent: .repeatedSameMode, iteration: iteration)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func launchReadinessRejectsRepeatedSameModel(iteration: Int) async throws {
        try await exerciseInterveningIntent(intent: .repeatedSameModel, iteration: iteration)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func launchReadinessRejectsModelABA(iteration: Int) async throws {
        try await exerciseInterveningIntent(intent: .modelABA, iteration: iteration)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func launchReadinessRejectsShutdown(iteration: Int) async throws {
        try await exerciseInterveningIntent(intent: .shutdown, iteration: iteration)
    }

    private func exerciseInterveningIntent(intent: InterveningIntent, iteration: Int) async throws {
        do {
            try await MigrationLifecycleFixture.run(context: "migration_\(intent)_iteration_\(iteration)") { fixture in
                let task = try #require(fixture.app.runLaunchLocalQwenDefaultMigrationIfNeeded(
                    healthCheck: { await fixture.health.result(modelName: $0) }))
                fixture.tasks.append(task)
                try await fixture.health.waitUntilStarted()

                switch intent {
                case .modelChange:
                    fixture.app.setSelectedQwenModelName("synthetic-qwen-b")
                case .repeatedSameMode:
                    // Repeating the stored value is still explicit user intent.
                    fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
                case .repeatedSameModel:
                    // The same selected model still represents a newer user action.
                    fixture.app.setSelectedQwenModelName("synthetic-qwen-a")
                case .modelABA:
                    fixture.app.setSelectedQwenModelName("synthetic-qwen-b")
                    fixture.app.setSelectedQwenModelName("synthetic-qwen-a")
                case .shutdown:
                    let finished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let cancelled = fixture.health.cancelled
                    let shutdown = Task {
                        await fixture.app.shutdownForTesting()
                        finished.continuation.yield(())
                        finished.continuation.finish()
                    }
                    fixture.tasks.append(shutdown)
                    // A noncooperative health call stays suspended until release.
                    // Correct shutdown sends cancellation before it can complete;
                    // the old unowned launch instead lets shutdown finish first.
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
                        let winner = await group.next() ?? false
                        group.cancelAll()
                        return winner
                    }
                    try Task.checkCancellation()
                    #expect(cancellationWon, "Shutdown returned without cancelling its launch health task, iteration \(iteration).")
                    #expect(task.isCancelled, "The captured actual launch task was not cancelled.")
                }

                await fixture.health.release()
                await task.value
                #expect(fixture.app.selectedAnswerProviderMode == .deepSeekPrimary,
                    "Late old-model readiness overwrote \(intent), iteration \(iteration).")
                #expect(fixture.defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode)
                    == AnswerProviderMode.deepSeekPrimary.rawValue)
                if intent == .modelChange {
                    #expect(fixture.app.selectedQwenModelName == "synthetic-qwen-b")
                } else {
                    #expect(fixture.app.selectedQwenModelName == "synthetic-qwen-a")
                }
            }
        }
    }
}

private actor MigrationLifecycleHealthGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<Void>.Continuation
    private var held: CheckedContinuation<LocalLLMHealth, Never>?
    private var requestedModel: String?
    private var released = false

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.started = started.stream
        startContinuation = started.continuation
        let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.cancelled = cancelled.stream
        cancelContinuation = cancelled.continuation
    }
    func result(modelName: String) async -> LocalLLMHealth {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requestedModel = modelName
                held = continuation
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
    func release() {
        released = true
        completeIfReleased()
    }
    private func completeIfReleased() {
        guard released, let held, let requestedModel else { return }
        self.held = nil
        held.resume(returning: LocalLLMHealth(ollamaRunning: true,
            selectedModel: requestedModel, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil))
    }
    nonisolated func waitUntilStarted() async throws {
        _ = try await trace.nextEvent(in: started, event: "start")
    }
}

@MainActor
private final class MigrationLifecycleFixture {
    let app: AppState
    let database: AppDatabase
    let defaults: UserDefaults
    let suite: String
    let health: MigrationLifecycleHealthGate
    var tasks: [Task<Void, Never>] = []

    init(context: String) throws {
        health = MigrationLifecycleHealthGate(label: context)
        suite = "com.langcheng.Hireva.tests.migration-lifecycle.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("synthetic-qwen-a", forKey: HirevaPreferenceKeys.selectedQwenModel)
        defaults.set(AnswerProviderMode.deepSeekPrimary.rawValue,
            forKey: HirevaPreferenceKeys.answerProviderMode)
        database = try AppDatabase(inMemory: true)
        app = AppState(database: database,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
    }
    private func cleanup() async throws {
        // Every noncooperative latch is released even after #require throws.
        for task in tasks { task.cancel() }
        await health.release()
        for task in tasks { await task.value }
        await app.shutdownForTesting()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }
    static func run(context: String, _ body: (MigrationLifecycleFixture) async throws -> Void) async throws {
        let fixture = try MigrationLifecycleFixture(context: context)
        do {
            try await body(fixture)
            try await fixture.cleanup()
        } catch {
            try await fixture.cleanup()
            throw error
        }
    }
}
