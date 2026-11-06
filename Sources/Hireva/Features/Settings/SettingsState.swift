import Foundation
import Combine

/// Owns applied settings, provider configuration projections and connection
/// tests. Runtime/privacy coordination and global feedback stay at assembly.
@MainActor
final class SettingsState: ObservableObject {
    enum Change {
        case settingsChanged(previous: AppSettings, current: AppSettings)
        case apiKeyWillChange(account: String)
        case answerModeWillChange(previous: AnswerProviderMode, current: AnswerProviderMode)
        case selectedQwenModelChanged(previous: String, current: String)
        case sessionModeChanged(previous: InterviewSessionMode, current: InterviewSessionMode)
        case realtimeProviderRequestChanged
        case providerConnected(LLMProviderConfiguration, LLMConnectionTestResult)
        case providerFailed(String)
        case refreshApplication
        case showError(String)
        case clearError
    }

    @Published var settings: AppSettings = .default {
        didSet { onChange(.settingsChanged(previous: oldValue, current: settings)) }
    }
    @Published var providerConfigurations: [LLMProviderConfiguration] = []
    @Published var activeRealtimeProvider: LLMProviderConfiguration? {
        didSet {
            if !LLMProviderConfiguration.sameQuestionDetectionRequest(oldValue, activeRealtimeProvider) {
                onChange(.realtimeProviderRequestChanged)
            }
        }
    }
    @Published var activeRecapProvider: LLMProviderConfiguration?
    @Published private(set) var providerConnectionResults: [UUID: String] = [:]
    private enum ProviderTestOutput: Hashable {
        case provider(UUID), connection, embeddingStatus, embeddingError
    }
    private var publishingProviderOutput = false
    private var pendingProviderOutputWrites: [ProviderTestOutput: String?] = [:]
    @Published private(set) var connectionResult: String?
    @Published private(set) var lastProviderSwitchTimestamp: Date?
    @Published private(set) var lastProviderSwitchError: String?
    // Context rebuilding still reports through these compatibility properties.
    // The stored status is here once, shared with embedding connection tests.
    @Published private(set) var lastEmbeddingTestStatus = "Not tested"
    @Published private(set) var lastEmbeddingError: String?
    @Published var interviewContextMode: InterviewContextMode {
        didSet { defaults.set(interviewContextMode.rawValue, forKey: DialogueSettingsStore.contextModeKey) }
    }
    @Published var interviewSessionMode: InterviewSessionMode {
        didSet {
            defaults.set(interviewSessionMode.rawValue, forKey: DialogueSettingsStore.sessionModeKey)
            onChange(.sessionModeChanged(previous: oldValue, current: interviewSessionMode))
        }
    }
    @Published var answerPanelQuestionsEnabled: Bool {
        didSet { defaults.set(answerPanelQuestionsEnabled, forKey: DialogueSettingsStore.answerPanelQuestionsKey) }
    }
    @Published var candidatePresentationMode: CandidateSpeechMode {
        didSet { defaults.set(candidatePresentationMode == .suppressAnswers, forKey: DialogueSettingsStore.suppressPresentationKey) }
    }
    @Published var candidateAsksPanelMode: CandidateSpeechMode {
        didSet { defaults.set(candidateAsksPanelMode == .suppressAnswers, forKey: DialogueSettingsStore.suppressCandidateQuestionsKey) }
    }

    struct KeychainStatusSnapshot: Sendable {
        var hasAnyAPIKey = false
        var deepSeekKeyExists = false
        var deepSeekKeyLengthCategory = "unknown"
        var maskedKey = "None"
        var lastReadStatus = "Not Checked"
        var lastWriteStatus = "Not Checked"
        var migrationPerformed = false
        var legacyItemFound = false
        var legacyItemCount = 0
        var authorizationWarning: String?
        var mismatchStatus = "No key found"
    }
    @Published private(set) var keychainStatus = KeychainStatusSnapshot()

    private struct ProviderTest {
        let id: UUID
        let actionID: String
        let providerID: UUID?
        let storedConfiguration: LLMProviderConfiguration?
        let task: Task<Void, Never>
    }
    private var currentTest: ProviderTest? {
        // Observers query the already committed owner, including reentrant
        // replacement/cancellation before the submitting entry returns.
        didSet { objectWillChange.send() }
    }
    private var retiringTests: [UUID: Task<Void, Never>] = [:]
    private var statusTask: Task<Void, Never>?
    private var statusID = UUID()
    private var retiringStatusTasks: [UUID: Task<Void, Never>] = [:]
    struct LocalQwenMigrationTicket: Equatable, Sendable {
        fileprivate let epoch: UUID
        let modelName: String
        fileprivate let originalMode: String?
    }
    private struct LocalQwenMigration {
        let ticket: LocalQwenMigrationTicket
        let task: Task<Void, Never>
    }
    private var localQwenMigrationEpoch = UUID()
    private var currentQwenMigration: LocalQwenMigration?
    private var retiringQwenMigrationTasks: [UUID: Task<Void, Never>] = [:]
    private let localQwenHealthCheck: (@MainActor (String) async -> LocalLLMHealth)?
    private var admissionClosed = false
    private let repository: SettingsRepository
    private let keychain: KeychainService
    private let router: LLMRouter
    private let defaults: UserDefaults
    private let isActionLoading: (String) -> Bool
    private let feedback: (ActionFeedback) -> Void
    private let clearFeedback: (String) -> Void
    private let onChange: (Change) -> Void

    init(repository: SettingsRepository, keychain: KeychainService, router: LLMRouter,
         defaults: UserDefaults,
         localQwenHealthCheck: (@MainActor (String) async -> LocalLLMHealth)? = nil,
         isActionLoading: @escaping (String) -> Bool = { _ in false },
         feedback: @escaping (ActionFeedback) -> Void = { _ in },
         clearFeedback: @escaping (String) -> Void = { _ in },
         onChange: @escaping (Change) -> Void = { _ in }) {
        self.repository = repository
        self.keychain = keychain
        self.router = router
        self.defaults = defaults
        self.localQwenHealthCheck = localQwenHealthCheck
        self.isActionLoading = isActionLoading
        self.feedback = feedback
        self.clearFeedback = clearFeedback
        self.onChange = onChange
        let dialogue = DialogueSettingsStore.loadAndMigrate(defaults: defaults)
        interviewContextMode = dialogue.contextMode
        interviewSessionMode = dialogue.selectedMode
        answerPanelQuestionsEnabled = dialogue.answerPanelQuestions
        candidatePresentationMode = dialogue.suppressPresentation ? .suppressAnswers : .normal
        candidateAsksPanelMode = dialogue.suppressCandidateQuestions ? .suppressAnswers : .normal
    }

    deinit {
        currentTest?.task.cancel()
        retiringTests.values.forEach { $0.cancel() }
        statusTask?.cancel()
        retiringStatusTasks.values.forEach { $0.cancel() }
        currentQwenMigration?.task.cancel()
        retiringQwenMigrationTasks.values.forEach { $0.cancel() }
    }

    var localQwenMigrationTask: Task<Void, Never>? { currentQwenMigration?.task }
    var isTestingConnection: Bool { currentTest != nil }
    var providerTestTask: Task<Void, Never>? { currentTest?.task }
    var pendingTaskCount: Int {
        retiringTests.count + (currentTest == nil ? 0 : 1) +
            retiringStatusTasks.count + (statusTask == nil ? 0 : 1) +
            retiringQwenMigrationTasks.count + (currentQwenMigration == nil ? 0 : 1)
    }
    var hasAPIKey: Bool { keychainStatus.hasAnyAPIKey }
    var keychainServiceName: String { KeychainConstants.service }
    var keychainDeepSeekAccount: String { KeychainConstants.deepSeekAccount }
    var keychainDeepSeekKeyExists: Bool {
        get { keychainStatus.deepSeekKeyExists }
        set { keychainStatus.deepSeekKeyExists = newValue }
    }
    var keychainDeepSeekKeyLengthCategory: String { keychainStatus.deepSeekKeyLengthCategory }
    var keychainMaskedKey: String { keychainStatus.maskedKey }
    var keychainLastReadStatus: String { keychainStatus.lastReadStatus }
    var keychainLastWriteStatus: String { keychainStatus.lastWriteStatus }
    var keychainMigrationPerformed: Bool { keychainStatus.migrationPerformed }
    var keychainLegacyItemFound: Bool { keychainStatus.legacyItemFound }
    var keychainLegacyItemCount: Int { keychainStatus.legacyItemCount }
    var keychainMismatchStatus: String { keychainStatus.mismatchStatus }
    var keychainAuthorizationWarning: String? { keychainStatus.authorizationWarning }
    var activeRealtimeProviderBadge: String {
        guard let provider = activeRealtimeProvider else { return "No realtime provider" }
        return "\(provider.name): \(provider.model)"
    }
    var activeRealtimeProviderPrivacyNote: String {
        guard let provider = activeRealtimeProvider else { return "No AI provider is selected." }
        return "Cloud mode: selected transcript and CV/JD snippets are sent to \(provider.name)."
    }

    var selectedASRProviderID: ASRProviderID {
        ASRProviderID(rawValue: defaults.string(forKey: HirevaPreferenceKeys.selectedASRProvider) ?? "") ?? .appleSpeech
    }
    var parakeetContextBiasEnabled: Bool { defaults.bool(forKey: HirevaPreferenceKeys.parakeetContextBias) }
    func setParakeetContextBiasEnabled(_ enabled: Bool) {
        guard !admissionClosed else { return }
        defaults.set(enabled, forKey: HirevaPreferenceKeys.parakeetContextBias)
        objectWillChange.send()
    }
    var selectedQwenModelName: String {
        let stored = defaults.string(forKey: HirevaPreferenceKeys.selectedQwenModel)
        return (stored?.isEmpty == false) ? stored! : LocalModelDescriptor.defaultQwenLocalLLM.id
    }
    var selectedAnswerProviderMode: AnswerProviderMode {
        AnswerProviderMode(storedValue: defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode))
    }
    func setSelectedASRProvider(_ provider: ASRProviderID) {
        guard !admissionClosed else { return }
        defaults.set(provider.rawValue, forKey: HirevaPreferenceKeys.selectedASRProvider)
        objectWillChange.send()
    }
    func setSelectedQwenModelName(_ modelName: String) {
        guard !admissionClosed else { return }
        let previous = selectedQwenModelName
        invalidateLocalQwenMigration()
        defaults.set(modelName, forKey: HirevaPreferenceKeys.selectedQwenModel)
        if previous != selectedQwenModelName {
            onChange(.selectedQwenModelChanged(previous: previous, current: selectedQwenModelName))
        }
        objectWillChange.send()
    }
    func setSelectedAnswerProviderMode(_ mode: AnswerProviderMode, currentMode: AnswerProviderMode? = nil) {
        guard !admissionClosed else { return }
        // User intent revokes older readiness even when its stored value repeats.
        invalidateLocalQwenMigration()
        let previous = currentMode ?? selectedAnswerProviderMode
        if previous != mode { onChange(.answerModeWillChange(previous: previous, current: mode)) }
        guard !admissionClosed else { return }
        defaults.set(mode.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        objectWillChange.send()
    }

    /// These tickets bind automatic migration to the exact selected model and
    /// unmodified user-intent epoch. They add no preference key or model state.
    func makeLocalQwenMigrationTicket() -> LocalQwenMigrationTicket? {
        guard !admissionClosed else { return nil }
        let raw = defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode)
        guard raw == nil || raw == "" || raw == "deepSeek" || raw == AnswerProviderMode.deepSeekPrimary.rawValue else { return nil }
        invalidateLocalQwenMigration()
        return LocalQwenMigrationTicket(epoch: localQwenMigrationEpoch,
            modelName: selectedQwenModelName, originalMode: raw)
    }
    func applyLocalQwenMigrationReadiness(_ health: LocalLLMHealth, ticket: LocalQwenMigrationTicket) {
        applyLocalQwenMigration(qwenModel: health.selectedModel, ready: health.isReady, ticket: ticket)
    }
    private func applyLocalQwenMigration(qwenModel: String, ready: Bool, ticket: LocalQwenMigrationTicket) {
        guard !admissionClosed, !Task.isCancelled, ready, qwenModel == ticket.modelName,
              localQwenMigrationEpoch == ticket.epoch, selectedQwenModelName == ticket.modelName,
              defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode) == ticket.originalMode else { return }
        if let current = currentQwenMigration, current.ticket == ticket {
            // A successful probe remains retained through exit without cancelling
            // its own task when the accepted selection invalidates older tickets.
            currentQwenMigration = nil
            retiringQwenMigrationTasks[ticket.epoch] = current.task
        }
        setSelectedAnswerProviderMode(.localQwenPrimary)
    }
    // Synchronous legacy entry used by existing migration callers/tests. Async
    // production probes must use a ticket issued before their health await.
    func migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: Bool) {
        guard qwenReady, let ticket = makeLocalQwenMigrationTicket() else { return }
        applyLocalQwenMigration(qwenModel: ticket.modelName, ready: true, ticket: ticket)
    }
    @discardableResult
    func runLaunchLocalQwenDefaultMigrationIfNeeded(
        healthCheck: (@MainActor (String) async -> LocalLLMHealth)? = nil
    ) -> Task<Void, Never>? {
        guard let check = healthCheck ?? localQwenHealthCheck,
              let ticket = makeLocalQwenMigrationTicket() else { return nil }
        let task = Task { [weak self] in
            defer { self?.qwenMigrationDidExit(epoch: ticket.epoch) }
            let health = await check(ticket.modelName)
            guard !Task.isCancelled else { return }
            self?.applyLocalQwenMigrationReadiness(health, ticket: ticket)
        }
        currentQwenMigration = LocalQwenMigration(ticket: ticket, task: task)
        return task
    }
    private func invalidateLocalQwenMigration() {
        localQwenMigrationEpoch = UUID()
        if let old = currentQwenMigration {
            currentQwenMigration = nil
            retiringQwenMigrationTasks[old.ticket.epoch] = old.task
            old.task.cancel()
        }
    }
    private func qwenMigrationDidExit(epoch: UUID) {
        retiringQwenMigrationTasks[epoch] = nil
        if currentQwenMigration?.ticket.epoch == epoch { currentQwenMigration = nil }
    }

    /// Repository values are immutable UI projections, not alternate writable
    /// settings. The original storage keys/migrations remain in the repository.
    func reload() throws {
        let previousIDs = Set(providerConfigurations.map(\.id))
        settings = try repository.loadSettings()
        providerConfigurations = try repository.ensureDefaultProviderConfigurations()
        activeRealtimeProvider = try repository.activeRealtimeProvider()
        activeRecapProvider = try repository.activeRecapProvider()
        if let test = currentTest, !storedConfigurationIsCurrent(test) { cancelProviderTest() }
        let currentIDs = Set(providerConfigurations.map(\.id))
        for removed in previousIDs.subtracting(currentIDs) { setProviderResult(nil, for: removed) }
    }

    func saveSettings(_ newSettings: AppSettings) {
        let actionID = ActionID.saveSettings
        guard !admissionClosed, !isActionLoading(actionID) else { return }
        emit(actionID, .loading, "Saving settings", "Applying the latest preferences...")
        guard !admissionClosed else { return }
        var next = newSettings
        next.compactMode = next.floatingAssistantDisplayMode == .compact
        if next.highContrastFloatingPanel { next.floatingWindowOpacity = max(next.floatingWindowOpacity, 0.65) }
        do {
            settings = next
            guard !admissionClosed else { return }
            try repository.saveSettings(next)
            refreshApplication()
            emit(actionID, .success, "Settings saved", "Your settings were applied.")
        } catch { fail(actionID, "Save failed", "Could not save settings: \(error.localizedDescription)") }
    }

    func saveAPIKey(_ apiKey: String) {
        let id = ActionID.providerSaveKey
        guard !admissionClosed, !isActionLoading(id) else { return }
        emit(id, .loading, "Saving securely", "Saving the provider key without displaying it.")
        guard !admissionClosed else { return }
        do {
            cancelStatusRefresh()
            cancelProviderTest()
            onChange(.apiKeyWillChange(account: KeychainConstants.deepSeekAccount))
            guard !admissionClosed else { return }
            try keychain.saveAPIKey(apiKey)
            setConnectionResult("API key securely saved.")
            refreshApplication()
            emit(id, .success, "Saved securely", "Provider key saved. Raw key is hidden.")
        } catch { fail(id, "Key save failed", "Could not save API key: \(error.localizedDescription)") }
    }

    func saveAPIKey(_ apiKey: String, for provider: LLMProviderConfiguration) {
        let id = ActionID.provider(ActionID.providerSaveKey, provider.id)
        guard !admissionClosed, !isActionLoading(id) else { return }
        guard let account = provider.apiKeyAccount else {
            setConnectionResult("\(provider.name) does not require an API key.")
            emit(id, .info, "No key needed", "\(provider.name) does not require an API key.")
            return
        }
        emit(id, .loading, "Saving securely", "Saving \(provider.name) key without displaying it.")
        guard !admissionClosed else { return }
        do {
            cancelStatusRefresh()
            if currentTest?.providerID == provider.id { cancelProviderTest() }
            onChange(.apiKeyWillChange(account: account))
            guard !admissionClosed else { return }
            try keychain.saveAPIKey(apiKey, account: account)
            setProviderResult("API key securely saved.", for: provider.id)
            refreshApplication()
            emit(id, .success, "Saved securely", "\(provider.name) key saved. Raw key is hidden.")
        } catch { fail(id, "Key save failed", "Could not save API key: \(error.localizedDescription)") }
    }

    func saveEmbeddingAPIKey(_ apiKey: String, account: String) {
        let id = ActionID.saveEmbeddingKey
        guard !admissionClosed, !isActionLoading(id) else { return }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { fail(id, "Key save failed", "Embedding API key account is missing."); return }
        emit(id, .loading, "Saving securely", "Saving the embedding provider key without displaying it.")
        guard !admissionClosed else { return }
        do {
            cancelStatusRefresh()
            if currentTest?.providerID == nil { cancelProviderTest() }
            onChange(.apiKeyWillChange(account: account))
            guard !admissionClosed else { return }
            try keychain.saveAPIKey(apiKey, account: account)
            setEmbeddingError(nil)
            setEmbeddingTestStatus("Embedding API key securely saved.")
            refreshApplication()
            emit(id, .success, "Saved securely", "Embedding key saved. Raw key is hidden.")
        } catch { fail(id, "Key save failed", "Could not save embedding API key: \(error.localizedDescription)") }
    }

    func embeddingKeyStatus(account: String) -> String {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { return "No account configured" }
        switch keychain.apiKeyAccessState(account: account) {
        case .available(let masked, _): return masked
        case .missing: return "Missing"
        case .authorizationRequired: return "Needs re-authorization"
        case .unreadable: return "Configured, unreadable"
        }
    }

    func deleteAPIKey() {
        guard !admissionClosed else { return }
        do {
            cancelStatusRefresh()
            cancelProviderTest()
            onChange(.apiKeyWillChange(account: KeychainConstants.deepSeekAccount))
            guard !admissionClosed else { return }
            try keychain.deleteAPIKey()
            setConnectionResult("API key removed.")
            refreshApplication()
        } catch { onChange(.showError("Could not remove API key: \(error.localizedDescription)")) }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let id = ActionID.provider(ActionID.providerSave, provider.id)
        guard !admissionClosed, !isActionLoading(id) else { return }
        emit(id, .loading, "Saving provider", "Saving \(provider.name) configuration...")
        guard !admissionClosed else { return }
        do {
            if currentTest?.providerID == provider.id { cancelProviderTest() }
            cancelStatusRefresh()
            guard !admissionClosed else { return }
            try repository.saveProviderConfiguration(provider)
            refreshApplication()
            emit(id, .success, "Provider saved", "\(provider.name) configuration saved.")
        } catch { fail(id, "Provider save failed", "Could not save provider: \(error.localizedDescription)") }
    }

    func deleteProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let id = ActionID.provider(ActionID.providerDelete, provider.id)
        guard !admissionClosed, !isActionLoading(id) else { return }
        emit(id, .loading, "Deleting provider", "Removing \(provider.name)...")
        guard !admissionClosed else { return }
        do {
            if currentTest?.providerID == provider.id { cancelProviderTest() }
            setProviderResult(nil, for: provider.id)
            cancelStatusRefresh()
            guard !admissionClosed else { return }
            try repository.deleteProviderConfiguration(id: provider.id)
            refreshApplication()
            emit(id, .success, "Provider deleted", "\(provider.name) was removed.")
        } catch { fail(id, "Provider delete failed", "Could not delete provider: \(error.localizedDescription)") }
    }

    func setActiveRealtimeProvider(_ provider: LLMProviderConfiguration) {
        let id = ActionID.providerSwitch
        guard !admissionClosed, !isActionLoading(id) else { return }
        invalidateLocalQwenMigration()
        emit(id, .loading, "Switching provider", "Setting \(provider.name) for realtime answers...")
        guard !admissionClosed else { return }
        do {
            try repository.setActiveRealtimeProvider(id: provider.id)
            refreshApplication()
            emit(id, .success, "Provider switched", "\(provider.name) is now used for realtime answers.")
        } catch { fail(id, "Provider switch failed", "Could not set realtime provider: \(error.localizedDescription)") }
    }

    func updateActiveRealtimeProvider(provider: LLMProviderConfiguration, model: String?) {
        let id = ActionID.providerSwitch
        guard !admissionClosed, !isActionLoading(id) else { return }
        invalidateLocalQwenMigration()
        emit(id, .loading, "Switching provider", "Checking \(provider.name) configuration...")
        guard !admissionClosed else { return }
        onChange(.clearError)
        lastProviderSwitchError = nil
        lastProviderSwitchTimestamp = Date()
        var updated = provider
        if let model { updated.model = model }
        guard !admissionClosed else { return }
        do {
            if updated.kind == .ollamaLocal {
                switchFailure(id, "Local providers are disabled. Please choose DeepSeek or another API provider.")
                return
            }
            if updated.kind == .deepSeek || updated.kind == .openAICompatible {
                guard let account = updated.apiKeyAccount else {
                    switchFailure(id, "Missing API key account for \(updated.name).")
                    return
                }
                let status = keychain.apiKeyAccessState(account: account)
                guard status.hasReadableKey else {
                    if case .authorizationRequired(let message) = status { switchFailure(id, message) }
                    else { switchFailure(id, "Missing API Key for \(updated.name).") }
                    return
                }
            }
            if currentTest?.providerID == provider.id { cancelProviderTest() }
            cancelStatusRefresh()
            guard !admissionClosed else { return }
            try repository.saveProviderConfiguration(updated)
            try repository.setActiveRealtimeProvider(id: updated.id)
            refreshApplication()
            emit(id, .success, "Provider switched", "\(updated.name) \(updated.model) is active.")
        } catch { switchFailure(id, error.localizedDescription) }
    }

    func setActiveRecapProvider(_ provider: LLMProviderConfiguration) {
        let id = ActionID.provider(ActionID.providerSave, provider.id)
        guard !admissionClosed, !isActionLoading(id) else { return }
        emit(id, .loading, "Saving recap provider", "Setting \(provider.name) for full answers and recaps...")
        guard !admissionClosed else { return }
        do {
            try repository.setActiveRecapProvider(id: provider.id)
            refreshApplication()
            emit(id, .success, "Recap provider saved", "\(provider.name) is now used for recaps.")
        } catch { fail(id, "Provider save failed", "Could not set recap provider: \(error.localizedDescription)") }
    }

    func testProviderConnection(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerTest, provider.id)
        startProviderTest(provider, actionID: actionID, deepSeek: false)
    }

    func testDeepSeekConnection() {
        let id = ActionID.testDeepSeek
        guard !admissionClosed, !isActionLoading(id) else { return }
        guard let provider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            setConnectionResult("DeepSeek provider is not configured.")
            emit(id, .error, "DeepSeek not configured", "Add DeepSeek in Settings before testing.")
            return
        }
        guard let account = provider.apiKeyAccount else {
            setConnectionResult("DeepSeek key account is not configured.")
            emit(id, .error, "DeepSeek key missing", "Save a DeepSeek API key before testing.")
            return
        }
        let status = keychain.apiKeyAccessState(account: account)
        guard status.hasReadableKey else {
            if case .authorizationRequired(let message) = status {
                setConnectionResult(message)
                emit(id, .error, "Keychain needs re-authorization", message)
            } else {
                setConnectionResult("Add a DeepSeek API key before testing the connection.")
                emit(id, .error, "DeepSeek key missing", "Save a DeepSeek API key before testing.")
            }
            return
        }
        startProviderTest(provider, actionID: id, deepSeek: true)
    }

    private func startProviderTest(_ provider: LLMProviderConfiguration, actionID: String, deepSeek: Bool) {
        guard !admissionClosed, !isActionLoading(actionID) else { return }
        let stored: LLMProviderConfiguration?
        do {
            stored = try repository.providerConfiguration(id: provider.id)
        } catch {
            fail(actionID, "Provider test failed", "Could not read provider configuration: \(error.localizedDescription)")
            return
        }
        let id = UUID()
        let router = router
        let task = Task { [weak self] in
            defer { self?.testDidExit(id: id, actionID: actionID) }
            guard !Task.isCancelled, self?.canPublishTest(id) == true else { return }
            do {
                let result = try await router.testProvider(configuration: provider)
                guard let self, !Task.isCancelled, self.canPublishTest(id) else { return }
                if deepSeek { self.setConnectionResult(result.message) }
                else { self.setProviderResult(result.message, for: provider.id) }
                // Published subscribers run synchronously and can replace this
                // request before its remaining terminal effects are admitted.
                guard !Task.isCancelled, self.canPublishTest(id) else { return }
                if result.success {
                    self.emit(actionID, .success, deepSeek ? "DeepSeek connected" : "\(provider.name) connected", result.message)
                    guard !Task.isCancelled, self.canPublishTest(id) else { return }
                    self.onChange(.providerConnected(provider, result))
                } else {
                    self.emit(actionID, .error, deepSeek ? "DeepSeek test failed" : "\(provider.name) test failed", result.message)
                    guard !Task.isCancelled, self.canPublishTest(id) else { return }
                    self.onChange(.providerFailed(result.message))
                }
            } catch {
                guard let self, !Task.isCancelled, self.canPublishTest(id) else { return }
                let message = Self.userFacing(error)
                if deepSeek { self.setConnectionResult(message) }
                else { self.setProviderResult(message, for: provider.id) }
                guard !Task.isCancelled, self.canPublishTest(id) else { return }
                self.emit(actionID, .error, deepSeek ? "DeepSeek test failed" : "\(provider.name) test failed", message)
                guard !Task.isCancelled, self.canPublishTest(id) else { return }
                self.onChange(.providerFailed(message))
            }
        }
        guard admitProviderTest(ProviderTest(id: id, actionID: actionID,
            providerID: provider.id, storedConfiguration: stored, task: task)) else { return }
        emit(actionID, .loading, deepSeek ? "Testing DeepSeek" : "Testing \(provider.name)",
             deepSeek ? "Checking the saved key and model endpoint..." : "Testing provider connection...")
        guard canPublishTest(id) else { return }
        if deepSeek { setConnectionResult(nil) } else { setProviderResult(nil, for: provider.id) }
    }

    /// Register before notifications. Every superseded handle is retained before
    /// an observer can replace the new record; the returning entry cannot regain it.
    private func admitProviderTest(_ test: ProviderTest) -> Bool {
        guard !admissionClosed else {
            retiringTests[test.id] = test.task
            test.task.cancel()
            return false
        }
        let previous = currentTest
        if let previous { retiringTests[previous.id] = previous.task }
        currentTest = test
        previous?.task.cancel()
        if let previous, currentTest?.actionID != previous.actionID {
            clearFeedback(previous.actionID)
        }
        return canPublishTest(test.id)
    }

    /// These writes share the existing synchronous first-setter boundary. The
    /// pending map holds only reentrant intents, including an explicit nil; the
    /// Published properties remain the sole stored UI facts and typed publishers.
    func setConnectionResult(_ value: String?) { setProviderOutput(value, for: .connection) }
    func setEmbeddingTestStatus(_ value: String) { setProviderOutput(value, for: .embeddingStatus) }
    func setEmbeddingError(_ value: String?) { setProviderOutput(value, for: .embeddingError) }
    private func setProviderResult(_ value: String?, for providerID: UUID) {
        setProviderOutput(value, for: .provider(providerID))
    }
    private func setProviderOutput(_ value: String?, for output: ProviderTestOutput) {
        pendingProviderOutputWrites.updateValue(value, forKey: output)
        guard !publishingProviderOutput else { return }
        publishingProviderOutput = true
        defer { publishingProviderOutput = false }
        while let next = pendingProviderOutputWrites.first {
            pendingProviderOutputWrites.removeValue(forKey: next.key)
            switch next.key {
            case .provider(let id): providerConnectionResults[id] = next.value
            case .connection: connectionResult = next.value
            case .embeddingStatus:
                if let status = next.value { lastEmbeddingTestStatus = status }
            case .embeddingError: lastEmbeddingError = next.value
            }
        }
    }

    /// The caller resolves the concrete provider before this entry, freezing
    /// request configuration without handing the feature an application object.
    func testEmbeddingProvider(provider: (any EmbeddingProvider)?) {
        let actionID = ActionID.providerTest
        guard !admissionClosed, !isActionLoading(actionID) else { return }
        guard settings.embeddingProviderKind != .disabled else {
            setEmbeddingError(nil)
            setEmbeddingTestStatus("Keyword RAG ready; vector embeddings not configured.")
            emit(actionID, .info, "Keyword search ready", "Cloud embeddings are not configured.")
            return
        }
        guard let provider else {
            setEmbeddingTestStatus("Keyword RAG ready; vector embeddings not configured.")
            emit(actionID, .warning, "Embedding key missing", "Keyword search remains ready. Add a cloud embedding key to test embeddings.")
            return
        }
        let id = UUID()
        let frozenSettings = settings
        let task = Task { [weak self] in
            defer { self?.testDidExit(id: id, actionID: actionID) }
            guard !Task.isCancelled, self?.canPublishTest(id) == true else { return }
            let started = Date()
            do {
                let vector = try await provider.embed(text: "Embedding provider connection test.")
                guard let self, !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                self.setEmbeddingTestStatus("Connected. Dimension \(vector.count), latency \(latency) ms.")
                guard !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                self.setEmbeddingError(nil)
                guard !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                self.emit(actionID, .success, "Embedding provider connected", "Dimension \(vector.count), latency \(latency) ms.")
            } catch {
                guard let self, !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                self.setEmbeddingTestStatus("Embedding provider test failed.")
                guard !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                self.setEmbeddingError(Self.userFacing(error))
                guard !Task.isCancelled, self.canPublishTest(id), Self.embeddingConfigurationMatches(self.settings, frozenSettings) else { return }
                self.emit(actionID, .error, "Embedding test failed", Self.userFacing(error))
            }
        }
        guard admitProviderTest(ProviderTest(id: id, actionID: actionID,
            providerID: nil, storedConfiguration: nil, task: task)) else { return }
        emit(actionID, .loading, "Testing embeddings", "Sending a small provider test request...")
        guard canPublishTest(id), Self.embeddingConfigurationMatches(settings, frozenSettings) else { return }
        setEmbeddingError(nil)
    }

    /// Invalidate identity before requesting cancellation. Retiring handles are
    /// retained through actual exit; their cleanup cannot clear a newer action.
    func cancelProviderTest() {
        guard let current = currentTest else { return }
        retiringTests[current.id] = current.task
        currentTest = nil
        current.task.cancel()
        if currentTest?.actionID != current.actionID { clearFeedback(current.actionID) }
    }

    func closeAdmission() {
        admissionClosed = true
        cancelProviderTest()
        cancelStatusRefresh()
        invalidateLocalQwenMigration()
    }

    func shutdown() async {
        closeAdmission()
        let pending = Array(retiringTests.values) + Array(retiringStatusTasks.values) + Array(retiringQwenMigrationTasks.values)
        for task in pending { await task.value }
    }

    private static func embeddingConfigurationMatches(_ current: AppSettings, _ frozen: AppSettings) -> Bool {
        current.embeddingProviderKind == frozen.embeddingProviderKind &&
            current.embeddingBaseURL == frozen.embeddingBaseURL &&
            current.embeddingModelName == frozen.embeddingModelName &&
            current.embeddingApiKeyAccount == frozen.embeddingApiKeyAccount &&
            current.embeddingDimension == frozen.embeddingDimension &&
            current.embeddingTimeoutSeconds == frozen.embeddingTimeoutSeconds
    }

    private func canPublishTest(_ id: UUID) -> Bool {
        guard !admissionClosed, let current = currentTest, current.id == id else { return false }
        return storedConfigurationIsCurrent(current)
    }

    private func storedConfigurationIsCurrent(_ test: ProviderTest) -> Bool {
        guard let providerID = test.providerID else { return true }
        do { return try repository.providerConfiguration(id: providerID) == test.storedConfiguration }
        catch { return false }
    }

    private func testDidExit(id: UUID, actionID: String) {
        retiringTests.removeValue(forKey: id)
        guard currentTest?.id == id else { return }
        currentTest = nil
        // Completed success/error banners keep their normal lifetime. Cancelled
        // tests have no terminal result, so only their own loading action ends.
        if currentTest?.actionID != actionID, isActionLoading(actionID) { clearFeedback(actionID) }
    }

    func refreshKeychainStatus(loadImmediately: Bool, isTestProcess: Bool, answerMode: AnswerProviderMode) {
        guard !admissionClosed else { return }
        if loadImmediately {
            cancelStatusRefresh()
            keychainStatus = Self.loadKeychainStatusSnapshot(keychainService: keychain,
                accounts: Set(providerConfigurations.compactMap(\.apiKeyAccount)))
        } else if isTestProcess {
            var next = keychainStatus
            next.lastReadStatus = "Disabled for test process"
            next.mismatchStatus = "Keychain access disabled for test process"
            keychainStatus = next
        } else {
            var next = keychainStatus
            next.lastReadStatus = "Deferred"
            if next.mismatchStatus == "Not Checked" || next.mismatchStatus.isEmpty { next.mismatchStatus = "Keychain check deferred" }
            keychainStatus = next
            if answerMode != .localQwenPrimary { refreshKeychainStatusInBackground() }
        }
    }

    private func refreshKeychainStatusInBackground() {
        guard statusTask == nil, !admissionClosed else { return }
        let id = UUID()
        statusID = id
        let keychain = keychain
        let accounts = Set(providerConfigurations.compactMap(\.apiKeyAccount))
        statusTask = Task { [weak self] in
            defer { self?.statusDidExit(id: id) }
            // SecItem is synchronous: cancellation invalidates publication,
            // while shutdown awaits its actual return. It is not a hard abort.
            let snapshot = await Self.readStatusAwayFromMainActor(keychain: keychain, accounts: accounts)
            guard let self, !Task.isCancelled, !self.admissionClosed, self.statusID == id,
                  Set(self.providerConfigurations.compactMap(\.apiKeyAccount)) == accounts else { return }
            self.keychainStatus = snapshot
        }
    }

    nonisolated private static func readStatusAwayFromMainActor(keychain: KeychainService, accounts: Set<String>) async -> KeychainStatusSnapshot {
        keychain.performMigrationIfNeeded(accounts: accounts)
        return loadKeychainStatusSnapshot(keychainService: keychain, accounts: accounts)
    }

    private func cancelStatusRefresh() {
        let oldID = statusID
        statusID = UUID()
        if let task = statusTask {
            retiringStatusTasks[oldID] = task
            task.cancel()
        }
        statusTask = nil
    }

    private func statusDidExit(id: UUID) {
        retiringStatusTasks.removeValue(forKey: id)
        if statusID == id { statusTask = nil }
    }

    nonisolated private static func loadKeychainStatusSnapshot(keychainService: KeychainService, accounts: Set<String>) -> KeychainStatusSnapshot {
        var states: [String: KeychainAPIKeyAccessState] = [:]
        for account in accounts { states[account] = keychainService.apiKeyAccessState(account: account) }
        let deepSeek = states[KeychainConstants.deepSeekAccount] ?? keychainService.apiKeyAccessState(account: KeychainConstants.deepSeekAccount)
        states[KeychainConstants.deepSeekAccount] = deepSeek
        let diagnostics = keychainService.diagnosticSnapshot
        let warning: String?
        if case .authorizationRequired(let message) = deepSeek { warning = message } else { warning = nil }
        let mismatch: String
        if deepSeek.hasReadableKey { mismatch = "✅ DeepSeek API Key loaded successfully" }
        else if let warning { mismatch = "⚠️ \(warning)" }
        else if diagnostics.legacyItemFound || diagnostics.legacyItemCount > 0 {
            mismatch = diagnostics.legacyItemCount > 1 ? "⚠️ Legacy keys found (\(diagnostics.legacyItemCount) items), migration available" : "⚠️ Legacy key found, migration available"
        } else { mismatch = "❌ No DeepSeek API key found in Keychain" }
        return KeychainStatusSnapshot(hasAnyAPIKey: states.values.contains { $0.hasReadableKey },
            deepSeekKeyExists: deepSeek.hasReadableKey, deepSeekKeyLengthCategory: deepSeek.keyLengthCategory,
            maskedKey: deepSeek.maskedDisplay, lastReadStatus: diagnostics.lastReadStatus,
            lastWriteStatus: diagnostics.lastWriteStatus, migrationPerformed: diagnostics.migrationPerformed,
            legacyItemFound: diagnostics.legacyItemFound, legacyItemCount: diagnostics.legacyItemCount,
            authorizationWarning: warning, mismatchStatus: mismatch)
    }

    private func refreshApplication() {
        do {
            try reload()
            if !(keychain.store is RealKeychainStore) {
                refreshKeychainStatus(loadImmediately: true, isTestProcess: true,
                    answerMode: selectedAnswerProviderMode)
            }
            onChange(.refreshApplication)
        } catch { onChange(.showError(error.localizedDescription)) }
    }
    private func switchFailure(_ id: String, _ message: String) {
        lastProviderSwitchError = message
        onChange(.showError("Could not switch provider: \(message)"))
        emit(id, .error, "Provider switch failed", message)
    }
    private func fail(_ id: String, _ title: String, _ message: String) {
        emit(id, .error, title, message)
        onChange(.showError(message))
    }
    private func emit(_ id: String, _ kind: ActionFeedbackKind, _ title: String, _ message: String) {
        feedback(ActionFeedback(actionID: id, title: title, message: message, kind: kind,
            autoDismissAfter: kind == .loading || kind == .error ? nil : (kind == .warning ? 6 : 4)))
    }
    private static func userFacing(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
