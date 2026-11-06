import Foundation

extension AppState {
    private static var selectedASRProviderKey: String { HirevaPreferenceKeys.selectedASRProvider }
    private static var activeASRProviderKey: String { HirevaPreferenceKeys.activeASRProvider }
    private static var selectedQwenModelKey: String { HirevaPreferenceKeys.selectedQwenModel }
    private static var answerProviderModeKey: String { HirevaPreferenceKeys.answerProviderMode }
    private static var appleSpeechASRDefaultMigrationKey: String { HirevaPreferenceKeys.appleSpeechASRDefaultMigration }
    private var preferenceDefaults: UserDefaults { dialogueDefaults ?? .standard }

    var selectedASRProviderID: ASRProviderID { settingsState.selectedASRProviderID }

    var selectedTranscriptionProviderMode: TranscriptionProviderMode {
        TranscriptionProviderMode(providerID: selectedASRProviderID)
    }

    var selectedQwenModelName: String { settingsState.selectedQwenModelName }
    var selectedAnswerProviderMode: AnswerProviderMode {
        answerProviderModeOverride ?? settingsState.selectedAnswerProviderMode
    }

    var activeASRProviderID: ASRProviderID? {
        ASRProviderID(rawValue: preferenceDefaults.string(forKey: Self.activeASRProviderKey) ?? "")
    }

    var activeASRProviderDisplayName: String {
        activeASRProviderID?.displayName ?? "None"
    }

    var latestTranscriptASRSource: String {
        transcriptSegments.reversed().first { $0.speaker != .system }?.asrSource?.rawValue ?? "None"
    }

    func setSelectedASRProvider(_ provider: ASRProviderID) { settingsState.setSelectedASRProvider(provider) }
    func setSelectedAnswerProviderMode(_ mode: AnswerProviderMode) {
        settingsState.setSelectedAnswerProviderMode(mode, currentMode: selectedAnswerProviderMode)
    }
    func setSelectedQwenModelName(_ modelName: String) { settingsState.setSelectedQwenModelName(modelName) }

    func markActiveASRProvider(_ provider: ASRProviderID?) {
        if let provider {
            preferenceDefaults.set(provider.rawValue, forKey: Self.activeASRProviderKey)
        } else {
            preferenceDefaults.removeObject(forKey: Self.activeASRProviderKey)
        }
        objectWillChange.send()
    }

    func clearStaleActiveASRProviderOnLaunch() {
        preferenceDefaults.removeObject(forKey: Self.activeASRProviderKey)
        objectWillChange.send()
    }

    func migrateStoredASRProviderToAppleSpeechDefaultIfNeeded() {
        guard !preferenceDefaults.bool(forKey: Self.appleSpeechASRDefaultMigrationKey) else { return }
        defer {
            preferenceDefaults.set(true, forKey: Self.appleSpeechASRDefaultMigrationKey)
        }
        let rawValue = preferenceDefaults.string(forKey: Self.selectedASRProviderKey)
        guard rawValue == ASRProviderID.localParakeet.rawValue else { return }
        setSelectedASRProvider(.appleSpeech)
    }

    func runLaunchASRProviderDefaultMigrationIfNeeded() {
        guard !isRunningUnderTestOrAutomation() else { return }
        migrateStoredASRProviderToAppleSpeechDefaultIfNeeded()
    }

    func migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: Bool) {
        settingsState.migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: qwenReady)
    }

    @discardableResult
    func runLaunchLocalQwenDefaultMigrationIfNeeded(
        healthCheck: (@MainActor (String) async -> LocalLLMHealth)? = nil
    ) -> Task<Void, Never>? {
        guard healthCheck != nil || !isRunningUnderTestOrAutomation() else { return nil }
        return settingsState.runLaunchLocalQwenDefaultMigrationIfNeeded(healthCheck: healthCheck)
    }
}
