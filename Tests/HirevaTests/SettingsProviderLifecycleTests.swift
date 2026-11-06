import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
struct SettingsProviderLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func synchronousReplacementForTheSameProviderKeepsItsPendingResultEmpty() async throws {
        try await ProviderSettingsFixture.run(label: "same-provider-synchronous-replacement") { fixture in
            let first = fixture.providers[0]
            var second = fixture.providers[1]
            second.id = first.id
            let old = try fixture.startTest(first)
            try await fixture.gates[0].waitUntilStarted()
            var didReplace = false
            var replacement: Task<Void, Never>?
            let observation = fixture.app.settingsState.$providerConnectionResults.sink { incoming in
                guard !didReplace, incoming[first.id] == "synthetic connection success" else { return }
                didReplace = true
                fixture.app.settingsState.cancelProviderTest()
                do { try fixture.repository.saveProviderConfiguration(second) }
                catch { Issue.record(error); return }
                fixture.app.testProviderConnection(second)
                replacement = fixture.app.providerTestTask
                if let replacement { fixture.retain(replacement) }
            }
            defer { observation.cancel() }
            await fixture.gates[0].release()
            await old.value
            let current = try #require(replacement)
            try await fixture.gates[1].waitUntilStarted()
            #expect(old.isCancelled && fixture.app.providerTestTask == current)
            #expect(fixture.app.providerConnectionResults[first.id] == nil,
                "Published willSet cannot restore an old result after its observer clears it for a replacement.")
            #expect(fixture.app.isActionLoading(fixture.actionID(second)))
            await fixture.gates[1].release()
            await current.value
            #expect(fixture.app.diagnostics.lastProviderName == second.name)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func synchronousResultObserverCannotPublishOldTerminalEffectsAfterReplacement(repetition: Int) async throws {
        try await ProviderSettingsFixture.run(label: "synchronous-replacement-\(repetition)") { fixture in
            let first = fixture.providers[0], second = fixture.providers[1]
            let old = try fixture.startTest(first)
            try await fixture.gates[0].waitUntilStarted()
            var didReplace = false
            var replacement: Task<Void, Never>?
            let observation = fixture.app.settingsState.$providerConnectionResults.sink { incoming in
                guard !didReplace, incoming[first.id] == "synthetic connection success" else { return }
                didReplace = true
                fixture.app.testProviderConnection(second)
                replacement = fixture.app.providerTestTask
                if let replacement { fixture.retain(replacement) }
            }
            defer { observation.cancel() }
            await fixture.gates[0].release()
            await old.value
            let current = try #require(replacement)
            #expect(didReplace && old.isCancelled)
            #expect(fixture.app.providerTestTask == current)
            #expect(fixture.app.latestActionFeedback(for: fixture.actionID(first)) == nil,
                "The old result's synchronous observer revoked its terminal feedback admission.")
            #expect(fixture.app.diagnostics.lastProviderName != first.name,
                "The revoked old worker cannot publish diagnostic success after a replacement.")
            await fixture.gates[1].release()
            await current.value
            #expect(fixture.app.diagnostics.lastProviderName == second.name)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledProviderTestExitsLoadingWithoutPublishingItsLateResult() async throws {
        try await ProviderSettingsFixture.run(label: "cancelledProviderTestExitsLoadingWithoutPublishingItsLateResult") { fixture in
            let provider = fixture.providers[0]
            let gate = fixture.gates[0]
            let task = try fixture.startTest(provider)
            try await gate.waitUntilStarted()
            #expect(fixture.app.isTestingConnection)
            task.cancel()
            try await gate.waitUntilCancelled()
            await gate.release()
            await task.value
            #expect(!fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(provider)))
            #expect(fixture.app.providerConnectionResults[provider.id] == nil)
            #expect(fixture.app.diagnostics.lastProviderName != provider.name)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementKeepsTheNewTestActiveAndRetiresOnlyTheOldLoadingAction() async throws {
        try await ProviderSettingsFixture.run(label: "replacementKeepsTheNewTestActiveAndRetiresOnlyTheOldLoadingAction") { fixture in
            let first = fixture.providers[0]
            let second = fixture.providers[1]
            let old = try fixture.startTest(first)
            try await fixture.gates[0].waitUntilStarted()
            let current = try fixture.startTest(second)
            try await fixture.gates[1].waitUntilStarted()
            #expect(old.isCancelled)
            try await fixture.gates[0].waitUntilCancelled()
            await fixture.gates[0].release()
            await old.value
            #expect(fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(first)))
            #expect(fixture.app.isActionLoading(fixture.actionID(second)))
            #expect(fixture.app.providerConnectionResults[first.id] == nil)
            #expect(fixture.app.providerConnectionResults[second.id] == nil)
            await fixture.gates[1].release()
            await current.value
            #expect(!fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(second)))
            #expect(fixture.app.providerConnectionResults[second.id] == "synthetic connection success")
            #expect(fixture.app.diagnostics.lastProviderName == second.name)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func deletingAProviderInvalidatesItsInFlightConnectionResult() async throws {
        try await ProviderSettingsFixture.run(label: "deletingAProviderInvalidatesItsInFlightConnectionResult") { fixture in
            let provider = fixture.providers[1]
            let task = try fixture.startTest(provider)
            try await fixture.gates[1].waitUntilStarted()
            fixture.app.deleteProviderConfiguration(provider)
            #expect(try fixture.repository.providerConfiguration(id: provider.id) == nil)
            #expect(task.isCancelled)
            await fixture.gates[1].release()
            await task.value
            #expect(fixture.app.providerConnectionResults[provider.id] == nil)
            #expect(fixture.app.diagnostics.lastProviderName != provider.name)
            #expect(!fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(provider)))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownJoinsTheActualProviderOperationAndEndsLoading() async throws {
        try await ProviderSettingsFixture.run(label: "shutdownJoinsTheActualProviderOperationAndEndsLoading") { fixture in
            let provider = fixture.providers[0]
            let task = try fixture.startTest(provider)
            let gate = fixture.gates[0]
            try await gate.waitUntilStarted()
            let shutdown = fixture.beginShutdown(checking: gate)
            try await gate.waitUntilCancelled()
            #expect(task.isCancelled)
            await gate.release()
            await task.value
            await shutdown.value
            #expect(!fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(provider)))
            #expect(fixture.app.providerConnectionResults[provider.id] == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownPermanentlyRejectsNewProviderTestAdmission() async throws {
        try await ProviderSettingsFixture.run(label: "shutdownPermanentlyRejectsNewProviderTestAdmission") { fixture in
            await fixture.app.shutdownForTesting()
            for gate in fixture.gates { await gate.release() }
            let provider = fixture.providers[0]
            fixture.app.testProviderConnection(provider)
            let rejected = fixture.app.providerTestTask
            if let rejected {
                fixture.retain(rejected)
                await rejected.value
            }
            #expect(rejected == nil)
            #expect(await fixture.gates[0].calls() == 0)
            #expect(!fixture.app.isTestingConnection)
            #expect(!fixture.app.isActionLoading(fixture.actionID(provider)))
            #expect(fixture.app.providerConnectionResults[provider.id] == nil)
        }
    }
}

/// The real provider-test task's cancellation handler signals cancellation,
/// but the transport deliberately waits for its fixture-owned release.
private actor ProviderSettingsGate {
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let cancelContinuation: AsyncStream<Void>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var callCount = 0
    nonisolated let trace: TestEventWaitTrace

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream
        startContinuation = start.continuation
        cancelled = cancel.stream
        cancelContinuation = cancel.continuation
    }

    func connectionResult() async -> LLMConnectionTestResult {
        trace.mark("producer.connection.entered")
        defer { trace.mark("producer.connection.return") }
        callCount += 1
        let startResult = startContinuation.yield(())
        trace.mark("producer.started.yield.\(startResult)")
        let cancellation = cancelContinuation
        let cancellationTrace = trace
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { waiter = $0 }
            }
        } onCancel: {
            cancellationTrace.mark("producer.cancel.entered")
            let result = cancellation.yield(())
            cancellationTrace.mark("producer.cancelled.yield.\(result)")
        }
        return LLMConnectionTestResult(success: true, message: "synthetic connection success", latencyMS: 1, models: [])
    }

    func release() {
        trace.mark("producer.connection.release")
        released = true
        waiter?.resume()
        waiter = nil
        startContinuation.finish()
        cancelContinuation.finish()
    }

    func calls() -> Int { callCount }
    func isReleased() -> Bool { released }

    nonisolated func waitUntilStarted() async throws {
        try await waitForEvent(started, event: "started")
    }

    nonisolated func waitUntilCancelled() async throws {
        try await waitForEvent(cancelled, event: "cancelled")
    }

    private nonisolated func waitForEvent(_ stream: AsyncStream<Void>, event: String) async throws {
        _ = try await trace.nextEvent(in: stream, event: event)
    }
}


private final class ControlledProviderSettingsClient: LLMClientProtocol {
    let providerKind: LLMProviderKind
    private let gate: ProviderSettingsGate

    init(kind: LLMProviderKind, gate: ProviderSettingsGate) {
        providerKind = kind
        self.gate = gate
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        await gate.connectionResult()
    }

    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Provider lifecycle tests do not request answers")
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}

@MainActor
private final class ProviderSettingsFixture {
    let app: AppState
    let repository: SettingsRepository
    let providers: [LLMProviderConfiguration]
    let gates: [ProviderSettingsGate]
    private let database: AppDatabase
    private var tasks: [Task<Void, Never>] = []
    private var shutdowns: [Task<Void, Never>] = []

    init(label: String) throws {
        let gates = [ProviderSettingsGate(label: "settingsProvider.\(label).first"),
                     ProviderSettingsGate(label: "settingsProvider.\(label).second")]
        self.gates = gates
        let database = try AppDatabase(inMemory: true)
        self.database = database
        let repository = SettingsRepository(database: database)
        self.repository = repository
        var first = LLMProviderConfiguration.deepSeekDefault()
        first.name = "Synthetic first provider"
        var second = LLMProviderConfiguration.openAICompatibleDefault()
        second.id = UUID()
        second.name = "Synthetic second provider"
        second.baseURL = "https://provider-lifecycle.test/v1"
        second.model = "synthetic model"
        second.apiKeyAccount = "synthetic-provider-\(second.id.uuidString)"
        providers = [first, second]
        for provider in providers { try repository.saveProviderConfiguration(provider) }
        let router = LLMRouter(settingsRepository: repository, clients: [
            .deepSeek: ControlledProviderSettingsClient(kind: .deepSeek, gate: gates[0]),
            .openAICompatible: ControlledProviderSettingsClient(kind: .openAICompatible, gate: gates[1])
        ])
        app = AppState(database: database, llmRouter: router,
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false)
    }

    func actionID(_ provider: LLMProviderConfiguration) -> String {
        ActionID.provider(ActionID.providerTest, provider.id)
    }

    func startTest(_ provider: LLMProviderConfiguration) throws -> Task<Void, Never> {
        app.testProviderConnection(provider)
        let task = try #require(app.providerTestTask)
        retain(task)
        return task
    }

    func retain(_ task: Task<Void, Never>) { tasks.append(task) }

    func beginShutdown(checking gate: ProviderSettingsGate) -> Task<Void, Never> {
        let task = Task {
            await app.shutdownForTesting()
            #expect(await gate.isReleased(), "Shutdown returned before its owned provider task exited.")
        }
        shutdowns.append(task)
        return task
    }

    private func cleanup() async throws {
        // Close publication before releasing a deliberately non-cooperative
        // transport on normal exit, a failed assertion, or case cancellation.
        app.settingsState.closeAdmission()
        for task in tasks { task.cancel() }
        for gate in gates { await gate.release() }
        for task in tasks { await task.value }
        for task in shutdowns { await task.value }
        await app.shutdownForTesting()
        try database.close()
    }

    static func run(label: String, _ body: (ProviderSettingsFixture) async throws -> Void) async throws {
        let fixture = try ProviderSettingsFixture(label: label)
        do {
            try await body(fixture)
            try await fixture.cleanup()
        } catch {
            try await fixture.cleanup()
            throw error
        }
    }
}
