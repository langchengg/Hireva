import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
struct SettingsFinalWriteAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [SettingsFinalMutation.providerSave,
        .providerDelete, .realtimeWithModel])
    func cancellingTheRegisteredTestCanCloseBeforeTheSQLWrite(operation: SettingsFinalMutation) async throws {
        try await SettingsFinalFixture.run { fixture in
            // No await occurs between registration and mutation. The exact
            // retained worker is cancelled before its transport entry can run.
            fixture.owner.testProviderConnection(fixture.provider)
            let worker = try #require(fixture.owner.providerTestTask)
            #expect(fixture.owner.isTestingConnection)
            let before = try fixture.snapshot()
            let observation = fixture.owner.objectWillChange.sink {
                fixture.closeOnce()
            }
            defer { observation.cancel() }
            fixture.submit(operation)
            #expect(fixture.didClose)
            #expect(worker.isCancelled)
            #expect(!fixture.owner.isTestingConnection)
            #expect(try fixture.snapshot() == before,
                "The committed test cancellation notification precedes this actual SQL write.")
            #expect(!fixture.feedbacks.contains { $0.kind == .success })
            await fixture.owner.shutdown()
            await worker.value
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func removingTheProviderResultCanCloseBeforeDeletingTheStoredProvider() async throws {
        try await SettingsFinalFixture.run { fixture in
            let before = try fixture.snapshot()
            let observation = fixture.owner.$providerConnectionResults.dropFirst().sink { _ in
                fixture.closeOnce()
            }
            defer { observation.cancel() }
            fixture.submit(.providerDelete)
            #expect(fixture.didClose)
            #expect(try fixture.snapshot() == before,
                "Removing the UI result publishes synchronously before repository deletion.")
            #expect(!fixture.feedbacks.contains { $0.kind == .success })
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [SettingsFinalMutation.defaultKeyDelete, .answerMode])
    func theInjectedFinalNotificationCanRevokeTheCredentialOrPreferenceWrite(operation: SettingsFinalMutation) async throws {
        try await SettingsFinalFixture.run { fixture in
            let before = try fixture.snapshot()
            fixture.closeFromChange = operation
            fixture.submit(operation)
            #expect(fixture.didClose)
            #expect(try fixture.snapshot() == before)
            #expect(!fixture.feedbacks.contains { $0.kind == .success })
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: SettingsFinalMutation.allCases)
    func anOpenFinalBoundaryPreservesTheOriginalMutation(operation: SettingsFinalMutation) async throws {
        try await SettingsFinalFixture.run { fixture in
            let before = try fixture.snapshot()
            fixture.submit(operation)
            #expect(!fixture.didClose)
            let after = try fixture.snapshot()
            switch operation {
            case .providerSave:
                let stored = try #require(after.providers.first { $0.id == fixture.provider.id })
                #expect(stored.name == fixture.changedProvider.name)
                #expect(stored.model == fixture.changedProvider.model)
                #expect(after.realtime == before.realtime)
            case .providerDelete:
                #expect(after.providers.allSatisfy { $0.id != fixture.provider.id })
            case .realtimeWithModel:
                #expect(after.realtime?.id == fixture.provider.id)
                #expect(after.realtime?.model == fixture.changedProvider.model)
            case .defaultKeyDelete:
                #expect(before.defaultKey != nil)
                #expect(after.defaultKey == nil)
                #expect(after.providers == before.providers)
            case .answerMode:
                #expect(before.answerMode == AnswerProviderMode.deepSeekPrimary.rawValue)
                #expect(after.answerMode == AnswerProviderMode.localQwenPrimary.rawValue)
                #expect(after.providers == before.providers)
            }
            if [.providerSave, .providerDelete, .realtimeWithModel].contains(operation) {
                #expect(fixture.feedbacks.contains { $0.kind == .success })
            }
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }
}

enum SettingsFinalMutation: CaseIterable, Equatable, Sendable {
    case providerSave, providerDelete, realtimeWithModel, defaultKeyDelete, answerMode
}

@MainActor
private final class SettingsFinalFixture {
    struct Snapshot: Equatable {
        let providers: [LLMProviderConfiguration]
        let realtime: LLMProviderConfiguration?
        let recap: LLMProviderConfiguration?
        let defaultKey: String?
        let providerKey: String?
        let answerMode: String?
    }
    let database: AppDatabase
    let repository: SettingsRepository
    let keychain: KeychainService
    let defaults: UserDefaults
    let suite: String
    let provider: LLMProviderConfiguration
    let changedProvider: LLMProviderConfiguration
    private(set) var owner: SettingsState!
    private(set) var didClose = false
    private(set) var feedbacks: [ActionFeedback] = []
    var closeFromChange: SettingsFinalMutation?

    init() async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        repository = SettingsRepository(database: database)
        keychain = KeychainService(store: InMemoryMockKeychainStore())
        suite = "com.langcheng.Hireva.tests.settings-last-admission.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(AnswerProviderMode.deepSeekPrimary.rawValue,
            forKey: HirevaPreferenceKeys.answerProviderMode)
        _ = try repository.ensureDefaultProviderConfigurations()
        var target = LLMProviderConfiguration.openAICompatibleDefault()
        target.id = UUID()
        target.name = "Synthetic final-boundary provider"
        target.model = "synthetic-original-model"
        target.baseURL = "https://synthetic-final-boundary.test/v1"
        target.apiKeyAccount = "synthetic.settings-final.provider.\(target.id.uuidString)"
        provider = target
        target.name = "Synthetic revised final-boundary provider"
        target.model = "synthetic-revised-model"
        changedProvider = target
        try repository.saveProviderConfiguration(provider)
        try keychain.saveAPIKey("sk-synthetic-default-final-only")
        try keychain.saveAPIKey("sk-synthetic-provider-final-only",
            account: try #require(provider.apiKeyAccount))
        let router = LLMRouter(settingsRepository: repository, clients: [:])
        owner = SettingsState(repository: repository, keychain: keychain, router: router,
            defaults: defaults,
            feedback: { [weak self] value in self?.feedbacks.append(value) },
            onChange: { [weak self] change in
                guard let self else { return }
                switch change {
                case .apiKeyWillChange:
                    if self.closeFromChange == .defaultKeyDelete { self.closeOnce() }
                case .answerModeWillChange:
                    if self.closeFromChange == .answerMode { self.closeOnce() }
                default: break
                }
            })
        try owner.reload()
        feedbacks.removeAll()
    }

    func closeOnce() {
        guard !didClose else { return }
        didClose = true
        owner.closeAdmission()
    }
    func submit(_ operation: SettingsFinalMutation) {
        switch operation {
        case .providerSave: owner.saveProviderConfiguration(changedProvider)
        case .providerDelete: owner.deleteProviderConfiguration(provider)
        case .realtimeWithModel:
            owner.updateActiveRealtimeProvider(provider: provider, model: changedProvider.model)
        case .defaultKeyDelete: owner.deleteAPIKey()
        case .answerMode: owner.setSelectedAnswerProviderMode(.localQwenPrimary)
        }
    }
    func snapshot() throws -> Snapshot {
        Snapshot(providers: try repository.providerConfigurations(),
            realtime: try repository.activeRealtimeProvider(),
            recap: try repository.activeRecapProvider(),
            defaultKey: try keychain.loadAPIKey(),
            providerKey: try keychain.loadAPIKey(account: try #require(provider.apiKeyAccount)),
            answerMode: defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode))
    }
    static func run(_ body: (SettingsFinalFixture) async throws -> Void) async throws {
        let fixture = try await SettingsFinalFixture()
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
