import Foundation
import Testing
@testable import Hireva

/// These tests exercise the actual public mutation entries. No provider transport,
/// production preferences, native Keychain or permission service is created.
@MainActor
struct SettingsSynchronousAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: SettingsSynchronousMutation.allCases)
    func loadingCallbackClosureRejectsTheAlreadySubmittedMutation(operation: SettingsSynchronousMutation) async throws {
        try await SettingsSynchronousFixture.run { fixture in
            let before = try fixture.snapshot()
            fixture.closeAt = .loading
            fixture.submit(operation)
            #expect(fixture.didClose)
            #expect(fixture.callbackCount == 1)
            #expect(try fixture.snapshot() == before,
                "The real loading feedback synchronously closed admission before SQL or mock Keychain write.")
            #expect(fixture.owner.settings == before.settings,
                "Closing from loading must also prevent committing this outer applied-settings value.")
            #expect(fixture.feedbacks.filter { $0.kind == .success }.isEmpty)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: SettingsSynchronousMutation.allCases)
    func anOpenEntryStillPerformsItsOriginalStoredMutation(operation: SettingsSynchronousMutation) async throws {
        try await SettingsSynchronousFixture.run { fixture in
            let before = try fixture.snapshot()
            fixture.submit(operation)
            #expect(!fixture.didClose)
            let after = try fixture.snapshot()
            switch operation {
            case .settings:
                #expect(after.settings != before.settings)
                #expect(after.settings.floatingWindowOpacity == fixture.nextSettings.floatingWindowOpacity)
                #expect(fixture.owner.settings == after.settings)
            case .defaultKey: #expect(after.defaultKey == fixture.nextKey)
            case .providerKey: #expect(after.providerKey == fixture.nextKey)
            case .embeddingKey: #expect(after.embeddingKey == fixture.nextKey)
            case .providerSave:
                #expect(after.providers.first { $0.id == fixture.target.id }?.name == fixture.updatedTarget.name)
                #expect(after.providers.first { $0.id == fixture.target.id }?.model == fixture.updatedTarget.model)
            case .providerDelete: #expect(after.providers.allSatisfy { $0.id != fixture.target.id })
            case .realtime:
                #expect(after.realtime?.id == fixture.target.id)
                #expect(after.realtime?.model == fixture.target.model)
            case .realtimeWithModel:
                #expect(after.realtime?.id == fixture.target.id)
                #expect(after.realtime?.model == fixture.updatedTarget.model)
            case .recap: #expect(after.recap?.id == fixture.target.id)
            }
            #expect(fixture.feedbacks.contains { $0.kind == .success })
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [SettingsSynchronousMutation.settings,
        .defaultKey, .providerKey, .embeddingKey])
    func theLastInjectedPrewriteCallbackCanCloseWithoutWriting(operation: SettingsSynchronousMutation) async throws {
        try await SettingsSynchronousFixture.run { fixture in
            let before = try fixture.snapshot()
            fixture.closeAt = operation == .settings ? .settingsChange : .credentialChange
            fixture.submit(operation)
            #expect(fixture.didClose)
            #expect(fixture.callbackCount == 1)
            #expect(try fixture.snapshot() == before,
                "The callback immediately before the actual write has revoked admission; no await or copied mutation logic is used.")
            #expect(fixture.feedbacks.filter { $0.kind == .success }.isEmpty)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }
}

enum SettingsSynchronousMutation: CaseIterable, Sendable {
    case settings, defaultKey, providerKey, embeddingKey
    case providerSave, providerDelete, realtime, realtimeWithModel, recap
}

@MainActor
private final class SettingsSynchronousFixture {
    enum ClosurePoint: Equatable { case loading, settingsChange, credentialChange }
    struct Snapshot: Equatable {
        let settings: AppSettings
        let providers: [LLMProviderConfiguration]
        let realtime: LLMProviderConfiguration?
        let recap: LLMProviderConfiguration?
        let defaultKey: String?
        let providerKey: String?
        let embeddingKey: String?
    }
    let database: AppDatabase
    let repository: SettingsRepository
    let keychain: KeychainService
    let defaults: UserDefaults
    let suite: String
    let target: LLMProviderConfiguration
    let updatedTarget: LLMProviderConfiguration
    let nextSettings: AppSettings
    let embeddingAccount = "synthetic.settings-admission.embedding"
    let nextKey = "sk-synthetic-next-admission-only"
    var closeAt: ClosurePoint?
    private(set) var didClose = false
    private(set) var callbackCount = 0
    private(set) var feedbacks: [ActionFeedback] = []
    private(set) var owner: SettingsState!

    init() async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        repository = SettingsRepository(database: database)
        keychain = KeychainService(store: InMemoryMockKeychainStore())
        suite = "com.langcheng.Hireva.tests.sync-settings-admission.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        _ = try repository.ensureDefaultProviderConfigurations()
        var target = LLMProviderConfiguration.openAICompatibleDefault()
        target.id = UUID()
        target.name = "Synthetic independent provider"
        target.baseURL = "https://synthetic-settings-admission.test/v1"
        target.model = "synthetic-original-model"
        target.apiKeyAccount = "synthetic.settings-admission.provider.\(target.id.uuidString)"
        target.isDefaultForRealtime = false
        target.isDefaultForRecap = false
        self.target = target
        var next = target
        next.name = "Synthetic revised provider"
        next.model = "synthetic-revised-model"
        updatedTarget = next
        try repository.saveProviderConfiguration(target)
        var settings = AppSettings.default
        settings.floatingWindowOpacity = 0.73
        try repository.saveSettings(settings)
        settings.floatingWindowOpacity = 0.91
        nextSettings = settings
        for account in [KeychainConstants.deepSeekAccount,
            try #require(target.apiKeyAccount), embeddingAccount] {
            try keychain.saveAPIKey("sk-synthetic-before-admission-only", account: account)
        }
        let router = LLMRouter(settingsRepository: repository, clients: [:])
        owner = SettingsState(repository: repository, keychain: keychain, router: router,
            defaults: defaults,
            feedback: { [weak self] value in
                guard let self else { return }
                self.feedbacks.append(value)
                if value.kind == .loading { self.closeIfNeeded(.loading) }
            },
            onChange: { [weak self] change in
                switch change {
                case .settingsChanged: self?.closeIfNeeded(.settingsChange)
                case .apiKeyWillChange: self?.closeIfNeeded(.credentialChange)
                default: break
                }
            })
        try owner.reload()
        feedbacks.removeAll()
    }

    private func closeIfNeeded(_ point: ClosurePoint) {
        guard !didClose, closeAt == point else { return }
        didClose = true
        callbackCount += 1
        owner.closeAdmission()
    }

    func submit(_ operation: SettingsSynchronousMutation) {
        switch operation {
        case .settings: owner.saveSettings(nextSettings)
        case .defaultKey: owner.saveAPIKey(nextKey)
        case .providerKey: owner.saveAPIKey(nextKey, for: target)
        case .embeddingKey: owner.saveEmbeddingAPIKey(nextKey, account: embeddingAccount)
        case .providerSave: owner.saveProviderConfiguration(updatedTarget)
        case .providerDelete: owner.deleteProviderConfiguration(target)
        case .realtime: owner.setActiveRealtimeProvider(target)
        case .realtimeWithModel: owner.updateActiveRealtimeProvider(provider: target, model: updatedTarget.model)
        case .recap: owner.setActiveRecapProvider(target)
        }
    }

    func snapshot() throws -> Snapshot {
        Snapshot(settings: try repository.loadSettings(),
            providers: try repository.providerConfigurations(),
            realtime: try repository.activeRealtimeProvider(),
            recap: try repository.activeRecapProvider(),
            defaultKey: try keychain.loadAPIKey(),
            providerKey: try keychain.loadAPIKey(account: try #require(target.apiKeyAccount)),
            embeddingKey: try keychain.loadAPIKey(account: embeddingAccount))
    }

    static func run(_ body: (SettingsSynchronousFixture) async throws -> Void) async throws {
        let fixture = try await SettingsSynchronousFixture()
        do {
            try await body(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    private func close() async throws {
        owner.closeAdmission()
        await owner.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }
}
