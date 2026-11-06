import Foundation
import Combine
import os
import Testing
@testable import Hireva

@MainActor
struct SettingsTestOutputFirstSetterTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func deepSeekTypedResultObserverCannotRestoreTheSupersededResult(oldSucceeded: Bool) async throws {
        try await SettingsOutputFixture.run(oldSucceeded: oldSucceeded) { fixture in
            let previous = fixture.provider
            fixture.owner.testDeepSeekConnection()
            let old = try #require(fixture.captureCurrentTask())
            try await fixture.control.waitUntilEntered(previous.name)
            var replaced = false
            var replacement: Task<Void, Never>?
            var frozenReplacement: LLMProviderConfiguration?
            var submitted = previous
            submitted.name = "Synthetic newer DeepSeek"
            submitted.model = "synthetic-newer-config"
            let observer = fixture.owner.$connectionResult.sink { incoming in
                guard !replaced, incoming == fixture.message(previous) else { return }
                replaced = true
                fixture.owner.cancelProviderTest()
                do {
                    try fixture.repository.saveProviderConfiguration(submitted)
                    try fixture.owner.reload()
                    frozenReplacement = try fixture.repository.providerConfiguration(id: submitted.id)
                } catch { Issue.record(error); return }
                fixture.owner.testDeepSeekConnection()
                replacement = fixture.captureCurrentTask()
            }
            defer { observer.cancel() }
            fixture.control.open(previous.name)
            await old.value
            let newest = try #require(replacement)
            #expect(replaced && old.isCancelled)
            #expect(fixture.owner.providerTestTask == newest && !newest.isCancelled)
            #expect(fixture.owner.connectionResult == nil,
                "The old Published setter cannot restore its result after the new exact DeepSeek test clears it.")
            #expect(fixture.journal.isLoading(ActionID.testDeepSeek))
            #expect(fixture.journal.connectedNames.isEmpty && fixture.journal.failureMessages.isEmpty)
            #expect(!fixture.journal.values.contains { $0.kind.isTerminal })
            fixture.control.open(submitted.name)
            await newest.value
            #expect(fixture.control.enteredNames == [previous.name, submitted.name])
            let expectedConfiguration = try #require(frozenReplacement)
            #expect(fixture.control.configurations.last == expectedConfiguration,
                "Compare every frozen configuration field with the exact saved/reloaded row, including repository-owned timestamps.")
            #expect(expectedConfiguration.model == submitted.model)
            #expect(fixture.owner.connectionResult == fixture.message(submitted))
            #expect(fixture.journal.connectedNames == [submitted.name])
            #expect(!fixture.owner.isTestingConnection)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func embeddingTypedStatusObserverKeepsTheExplicitKeywordModeStatus(oldSucceeded: Bool) async throws {
        try await SettingsOutputFixture.run(oldSucceeded: oldSucceeded) { fixture in
            let oldProvider = SettingsOutputEmbedding(name: "Synthetic old embedding", control: fixture.control, succeeds: oldSucceeded)
            fixture.owner.testEmbeddingProvider(provider: oldProvider)
            let old = try #require(fixture.captureCurrentTask())
            try await fixture.control.waitUntilEntered(oldProvider.providerID)
            var switched = false
            let keyword = "Keyword RAG ready; vector embeddings not configured."
            let observer = fixture.owner.$lastEmbeddingTestStatus.sink { incoming in
                let isOldOutput = oldSucceeded ? incoming.hasPrefix("Connected. Dimension 2,") : incoming == "Embedding provider test failed."
                guard !switched, isOldOutput else { return }
                switched = true
                fixture.owner.cancelProviderTest()
                fixture.owner.settings.embeddingProviderKind = .disabled
                fixture.owner.testEmbeddingProvider(provider: nil)
                fixture.captureCurrentTask()
            }
            defer { observer.cancel() }
            fixture.control.open(oldProvider.providerID)
            await old.value
            #expect(switched && old.isCancelled)
            #expect(fixture.owner.lastEmbeddingTestStatus == keyword,
                "The old Published setter cannot overwrite the newer keyword-only selection's synchronous status.")
            #expect(fixture.owner.lastEmbeddingError == nil)
            #expect(fixture.owner.settings.embeddingProviderKind == .disabled)
            #expect(fixture.control.enteredNames == [oldProvider.providerID])
            #expect(fixture.journal.latest[ActionID.providerTest]?.kind == .info)
            #expect(!fixture.journal.values.contains { $0.actionID == ActionID.providerTest && $0.kind.isTerminal })
            #expect(!fixture.owner.isTestingConnection)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func embeddingTypedErrorObserverKeepsTheHeldReplacementErrorCleared() async throws {
        try await SettingsOutputFixture.run(oldSucceeded: false) { fixture in
            let previous = SettingsOutputEmbedding(name: "Synthetic old embedding", control: fixture.control, succeeds: false)
            let newer = SettingsOutputEmbedding(name: "Synthetic newer embedding", control: fixture.control, succeeds: true)
            fixture.owner.testEmbeddingProvider(provider: previous)
            let old = try #require(fixture.captureCurrentTask())
            try await fixture.control.waitUntilEntered(previous.providerID)
            var replaced = false
            var replacement: Task<Void, Never>?
            let observer = fixture.owner.$lastEmbeddingError.sink { incoming in
                guard !replaced, incoming == SettingsOutputFailure().errorDescription else { return }
                replaced = true
                fixture.owner.cancelProviderTest()
                fixture.owner.testEmbeddingProvider(provider: newer)
                replacement = fixture.captureCurrentTask()
            }
            defer { observer.cancel() }
            fixture.control.open(previous.providerID)
            await old.value
            let newest = try #require(replacement)
            #expect(replaced && old.isCancelled)
            #expect(fixture.owner.providerTestTask == newest && !newest.isCancelled)
            #expect(fixture.owner.lastEmbeddingError == nil,
                "A replacement's explicit error clearing must win over the old failing Published setter.")
            #expect(fixture.journal.isLoading(ActionID.providerTest))
            #expect(!fixture.journal.values.contains { $0.actionID == ActionID.providerTest && $0.kind.isTerminal })
            fixture.control.open(newer.providerID)
            await newest.value
            #expect(fixture.control.enteredNames == [previous.providerID, newer.providerID])
            #expect(fixture.owner.lastEmbeddingError == nil)
            #expect(fixture.owner.lastEmbeddingTestStatus.hasPrefix("Connected. Dimension 2,"))
            #expect(fixture.journal.latest[ActionID.providerTest]?.kind == .success)
            #expect(!fixture.owner.isTestingConnection)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }
}

@MainActor
private final class SettingsOutputJournal {
    var values: [ActionFeedback] = []
    var latest: [String: ActionFeedback] = [:]
    var connectedNames: [String] = []
    var failureMessages: [String] = []
    func append(_ value: ActionFeedback) { values.append(value); latest[value.actionID] = value }
    func clear(_ actionID: String) { latest[actionID] = nil }
    func isLoading(_ actionID: String) -> Bool { latest[actionID]?.kind == .loading }
}

@MainActor
private final class SettingsOutputFixture {
    let database: AppDatabase
    let repository: SettingsRepository
    let defaults: UserDefaults
    let defaultsSuite: String
    let provider: LLMProviderConfiguration
    let control = SettingsOutputControl()
    let receipts = SettingsOutputReceipts()
    let journal = SettingsOutputJournal()
    let owner: SettingsState

    init(oldSucceeded: Bool) async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        repository = SettingsRepository(database: database)
        defaultsSuite = "com.langcheng.Hireva.tests.settings-output.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        var old = LLMProviderConfiguration.deepSeekDefault()
        old.id = UUID(); old.name = "Synthetic old DeepSeek"
        old.model = "synthetic-old-config"
        provider = old
        try repository.saveProviderConfiguration(old)
        var settings = AppSettings.default
        settings.embeddingProviderKind = .mock
        settings.embeddingDimension = 2
        try repository.saveSettings(settings)
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        let account = try #require(old.apiKeyAccount)
        try keychain.saveAPIKey("sk-synthetic-output-test-only", account: account)
        let router = LLMRouter(settingsRepository: repository, clients: [
            .deepSeek: SettingsOutputClient(control: control, oldSucceeded: oldSucceeded)
        ])
        let feedbackJournal = journal
        owner = SettingsState(repository: repository, keychain: keychain, router: router, defaults: defaults,
            isActionLoading: { feedbackJournal.isLoading($0) },
            feedback: { feedbackJournal.append($0) }, clearFeedback: { feedbackJournal.clear($0) },
            onChange: { change in
                switch change {
                case .providerConnected(let configuration, _): feedbackJournal.connectedNames.append(configuration.name)
                case .providerFailed(let message): feedbackJournal.failureMessages.append(message)
                default: break
                }
            })
        try owner.reload()
    }

    func message(_ configuration: LLMProviderConfiguration) -> String { "Synthetic connection result: \(configuration.name)" }
    @discardableResult
    func captureCurrentTask() -> Task<Void, Never>? {
        let task = owner.providerTestTask
        if let task { receipts.append(task) }
        return task
    }
    func joinOriginalTasks() async { for task in receipts.tasks { await task.value } }
    static func run(oldSucceeded: Bool, _ body: (SettingsOutputFixture) async throws -> Void) async throws {
        let fixture = try await SettingsOutputFixture(oldSucceeded: oldSucceeded)
        let control = fixture.control, receipts = fixture.receipts
        do {
            try await withTaskCancellationHandler {
                try await body(fixture)
            } onCancel: {
                control.openAll()
                receipts.cancelAll()
            }
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
    private func close() async throws {
        captureCurrentTask()
        owner.closeAdmission()
        control.openAll()
        receipts.cancelAll()
        await joinOriginalTasks()
        await owner.shutdown()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try database.close()
    }
}

private final class SettingsOutputClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    let control: SettingsOutputControl
    let oldSucceeded: Bool
    init(control: SettingsOutputControl, oldSucceeded: Bool) { self.control = control; self.oldSucceeded = oldSucceeded }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        await control.wait(configuration.name, configuration: configuration)
        let success = configuration.name == "Synthetic newer DeepSeek" || oldSucceeded
        return LLMConnectionTestResult(success: success,
            message: "Synthetic connection result: \(configuration.name)", latencyMS: 1, models: [])
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Settings output tests do not request answers")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}

private final class SettingsOutputEmbedding: EmbeddingProvider {
    let providerID: String
    let modelName = "synthetic-mock-embedding"
    let control: SettingsOutputControl
    let succeeds: Bool
    var dimension: Int { get async throws { 2 } }
    init(name: String, control: SettingsOutputControl, succeeds: Bool) {
        providerID = name; self.control = control; self.succeeds = succeeds
    }
    func embed(text: String) async throws -> [Float] {
        await control.wait(providerID)
        if !succeeds { throw SettingsOutputFailure() }
        return [1, 0]
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var output: [[Float]] = []
        for text in texts { output.append(try await embed(text: text)) }
        return output
    }
}

private struct SettingsOutputFailure: LocalizedError {
    var errorDescription: String? { "Synthetic controlled embedding failure." }
}

/// Gates are checked and synthetic. Only a previously submitted old operation's
/// actual entry is awaited; every name opens on owner cancellation or fixture exit.
private final class SettingsOutputControl: Sendable {
    private struct State: Sendable {
        var allOpen = false
        var openNames: Set<String> = []
        var enteredNames: [String] = []
        var configurations: [LLMProviderConfiguration] = []
        var waiting: [(String, CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entries = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private let trace = TestEventWaitTrace(label: "settings_output_first_setter")
    var enteredNames: [String] { state.withLock { $0.enteredNames } }
    var configurations: [LLMProviderConfiguration] { state.withLock { $0.configurations } }
    func wait(_ name: String, configuration: LLMProviderConfiguration? = nil) async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                value.enteredNames.append(name)
                if let configuration { value.configurations.append(configuration) }
                if value.allOpen || value.openNames.contains(name) { return true }
                value.waiting.append((name, continuation))
                return false
            }
            entries.continuation.yield(name)
            if resume { continuation.resume() }
        }
    }
    func waitUntilEntered(_ name: String) async throws {
        while !enteredNames.contains(name) {
            _ = try await trace.nextEvent(in: entries.stream, event: name)
        }
    }
    func open(_ name: String) {
        let waiting = state.withLock { value in
            value.openNames.insert(name)
            let selected = value.waiting.filter { $0.0 == name }.map { $0.1 }
            value.waiting.removeAll { $0.0 == name }
            return selected
        }
        waiting.forEach { $0.resume() }
    }
    func openAll() {
        let waiting = state.withLock { value in
            value.allOpen = true
            let selected = value.waiting.map { $0.1 }
            value.waiting.removeAll()
            return selected
        }
        waiting.forEach { $0.resume() }
        entries.continuation.finish()
    }
}

private final class SettingsOutputReceipts: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    var tasks: [Task<Void, Never>] { values.withLock { $0 } }
    func append(_ task: Task<Void, Never>) { values.withLock { if !$0.contains(task) { $0.append(task) } } }
    func cancelAll() { tasks.forEach { $0.cancel() } }
}
