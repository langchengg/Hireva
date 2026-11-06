import Foundation
import Combine
import os
import Testing
@testable import Hireva

@MainActor
struct SettingsProviderEntryReentryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func loadingObserverKeepsTheNewerSubmittedProviderWorker(withExistingWorker: Bool) async throws {
        try await SettingsEntryFixture.run { fixture in
            let previous = fixture.providers[0], outer = fixture.providers[1], newer = fixture.providers[2]
            var original: Task<Void, Never>?
            if withExistingWorker {
                fixture.owner.testProviderConnection(previous)
                let capturedOriginal = try #require(fixture.captureCurrentTask())
                original = capturedOriginal
                try await fixture.control.waitUntilEntered(previous.name)
            }
            var replaced = false
            var submitted: Task<Void, Never>?
            fixture.journal.onFeedback = { value in
                guard !replaced, value.actionID == fixture.actionID(outer), value.kind == .loading else { return }
                replaced = true
                fixture.captureCurrentTask()
                fixture.owner.testProviderConnection(newer)
                submitted = fixture.captureCurrentTask()
            }
            fixture.owner.testProviderConnection(outer)
            fixture.captureCurrentTask()
            let newest = try #require(submitted)
            #expect(replaced)
            #expect(fixture.owner.providerTestTask == newest,
                "A loading observer's newer submission must own the slot when the older entry returns.")
            #expect(!newest.isCancelled)
            if let original { #expect(original.isCancelled) }
            #expect(fixture.journal.isLoading(fixture.actionID(newer)))
            fixture.control.openAll()
            await fixture.joinOriginalTasks()
            let expectedCalls = withExistingWorker ? [previous.name, newer.name] : [newer.name]
            #expect(fixture.control.enteredNames == expectedCalls,
                "The superseded outer request must not start its provider after the synchronous observer returns.")
            #expect(fixture.owner.providerConnectionResults[outer.id] == nil)
            #expect(fixture.owner.providerConnectionResults[newer.id] == fixture.successMessage(newer))
            #expect(fixture.journal.connectedIDs == [newer.id])
            #expect(!fixture.journal.values.contains { $0.actionID == fixture.actionID(outer) && $0.kind.isTerminal })
            #expect(!fixture.owner.isTestingConnection)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func firstRegistrationObserverCanCancelOrCloseBeforeTheProviderStarts(closeAdmission: Bool) async throws {
        try await SettingsEntryFixture.run { fixture in
            let provider = fixture.providers[1]
            var observed = false
            var registered: Task<Void, Never>?
            let observation = fixture.owner.objectWillChange.sink {
                guard !observed else { return }
                observed = true
                registered = fixture.captureCurrentTask()
                if closeAdmission { fixture.owner.closeAdmission() }
                else { fixture.owner.cancelProviderTest() }
            }
            defer { observation.cancel() }
            fixture.owner.testProviderConnection(provider)
            fixture.captureCurrentTask()
            #expect(observed)
            #expect(registered != nil,
                "The first connection-test notification must expose an already registered exact worker.")
            #expect(registered?.isCancelled == true)
            #expect(!fixture.owner.isTestingConnection,
                "The older entry cannot register a worker after synchronous cancellation or shutdown.")
            fixture.control.openAll()
            await fixture.joinOriginalTasks()
            #expect(fixture.control.enteredNames.isEmpty)
            #expect(fixture.owner.providerConnectionResults[provider.id] == nil)
            #expect(fixture.journal.values.isEmpty)
            #expect(fixture.journal.connectedIDs.isEmpty)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationObserverCannotEraseTheNewerProviderWorker() async throws {
        try await SettingsEntryFixture.run { fixture in
            let previous = fixture.providers[0], newer = fixture.providers[2]
            fixture.owner.testProviderConnection(previous)
            let old = try #require(fixture.captureCurrentTask())
            try await fixture.control.waitUntilEntered(previous.name)
            var replaced = false
            var submitted: Task<Void, Never>?
            let observation = fixture.owner.objectWillChange.sink {
                guard !replaced else { return }
                replaced = true
                fixture.captureCurrentTask()
                fixture.owner.testProviderConnection(newer)
                submitted = fixture.captureCurrentTask()
            }
            defer { observation.cancel() }
            fixture.owner.cancelProviderTest()
            fixture.captureCurrentTask()
            let newest = try #require(submitted)
            #expect(replaced && old.isCancelled)
            #expect(fixture.owner.providerTestTask == newest,
                "The cancelled record's notification cannot wipe the observer's newer committed record.")
            #expect(!newest.isCancelled)
            #expect(fixture.journal.isLoading(fixture.actionID(newer)))
            fixture.control.openAll()
            await fixture.joinOriginalTasks()
            #expect(fixture.control.enteredNames == [previous.name, newer.name])
            #expect(fixture.owner.providerConnectionResults[previous.id] == nil)
            #expect(fixture.owner.providerConnectionResults[newer.id] == fixture.successMessage(newer))
            #expect(fixture.journal.connectedIDs == [newer.id])
            #expect(!fixture.owner.isTestingConnection)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }
}

@MainActor
private final class SettingsEntryJournal {
    var values: [ActionFeedback] = []
    var latest: [String: ActionFeedback] = [:]
    var connectedIDs: [UUID] = []
    var onFeedback: ((ActionFeedback) -> Void)?
    func append(_ value: ActionFeedback) {
        values.append(value)
        latest[value.actionID] = value
        onFeedback?(value)
    }
    func clear(_ actionID: String) { latest[actionID] = nil }
    func isLoading(_ actionID: String) -> Bool { latest[actionID]?.kind == .loading }
}

@MainActor
private final class SettingsEntryFixture {
    let database: AppDatabase
    let repository: SettingsRepository
    let defaults: UserDefaults
    let defaultsSuite: String
    let providers: [LLMProviderConfiguration]
    let control = SettingsEntryControl()
    let receipts = SettingsEntryReceipts()
    let journal = SettingsEntryJournal()
    let owner: SettingsState

    init() throws {
        database = try AppDatabase(inMemory: true)
        repository = SettingsRepository(database: database)
        defaultsSuite = "com.langcheng.Hireva.tests.settings-entry.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        var previous = LLMProviderConfiguration.deepSeekDefault()
        previous.id = UUID(); previous.name = "Synthetic previous"
        var outer = LLMProviderConfiguration.deepSeekDefault()
        outer.id = UUID(); outer.name = "Synthetic outer"
        var newer = LLMProviderConfiguration.openAICompatibleDefault()
        newer.id = UUID(); newer.name = "Synthetic newer"
        newer.baseURL = "https://settings-entry.test/v1"
        newer.model = "synthetic-local-fixture"
        newer.apiKeyAccount = "synthetic-entry-\(newer.id.uuidString)"
        providers = [previous, outer, newer]
        for provider in providers { try repository.saveProviderConfiguration(provider) }
        let router = LLMRouter(settingsRepository: repository, clients: [
            .deepSeek: SettingsEntryClient(kind: .deepSeek, control: control),
            .openAICompatible: SettingsEntryClient(kind: .openAICompatible, control: control)
        ])
        let feedbackJournal = journal
        owner = SettingsState(repository: repository,
            keychain: KeychainService(store: InMemoryMockKeychainStore()), router: router, defaults: defaults,
            isActionLoading: { feedbackJournal.isLoading($0) },
            feedback: { feedbackJournal.append($0) }, clearFeedback: { feedbackJournal.clear($0) },
            onChange: { change in
                if case .providerConnected(let configuration, _) = change { feedbackJournal.connectedIDs.append(configuration.id) }
            })
    }

    func actionID(_ provider: LLMProviderConfiguration) -> String { ActionID.provider(ActionID.providerTest, provider.id) }
    func successMessage(_ provider: LLMProviderConfiguration) -> String { "Synthetic connection success: \(provider.name)" }
    @discardableResult
    func captureCurrentTask() -> Task<Void, Never>? {
        let task = owner.providerTestTask
        if let task { receipts.append(task) }
        return task
    }
    func joinOriginalTasks() async { for task in receipts.tasks { await task.value } }

    static func run(_ body: (SettingsEntryFixture) async throws -> Void) async throws {
        let fixture = try SettingsEntryFixture()
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
        journal.onFeedback = nil
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

private final class SettingsEntryClient: LLMClientProtocol {
    let providerKind: LLMProviderKind
    let control: SettingsEntryControl
    init(kind: LLMProviderKind, control: SettingsEntryControl) { providerKind = kind; self.control = control }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        await control.wait(configuration.name)
        return LLMConnectionTestResult(success: true, message: "Synthetic connection success: \(configuration.name)", latencyMS: 1, models: [])
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Settings entry tests do not request model answers")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}

/// Checked, synthetic transport gates ignore cancellation only until the owning
/// fixture releases them. No provider call, socket, credential or native device is used.
private final class SettingsEntryControl: Sendable {
    private struct State: Sendable {
        var opened = false
        var enteredNames: [String] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entries = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private let trace = TestEventWaitTrace(label: "settings_provider_entry")
    var enteredNames: [String] { state.withLock { $0.enteredNames } }
    func wait(_ name: String) async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                value.enteredNames.append(name)
                if value.opened { return true }
                value.waiting.append(continuation)
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
    func openAll() {
        let waiting = state.withLock { value in
            value.opened = true
            let pending = value.waiting
            value.waiting.removeAll()
            return pending
        }
        waiting.forEach { $0.resume() }
        entries.continuation.finish()
    }
}

/// Public immutable Task receipts are fixture cleanup handles. They do not
/// supply a second production test registry or reproduce its admission logic.
private final class SettingsEntryReceipts: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    var tasks: [Task<Void, Never>] { values.withLock { $0 } }
    func append(_ task: Task<Void, Never>) {
        values.withLock { if !$0.contains(task) { $0.append(task) } }
    }
    func cancelAll() { tasks.forEach { $0.cancel() } }
}
