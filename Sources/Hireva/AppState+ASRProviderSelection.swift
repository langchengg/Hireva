import Foundation

extension AppState {
    private static var selectedASRProviderKey: String { HirevaPreferenceKeys.selectedASRProvider }
    private static var activeASRProviderKey: String { HirevaPreferenceKeys.activeASRProvider }
    private static var selectedQwenModelKey: String { HirevaPreferenceKeys.selectedQwenModel }
    private static var answerProviderModeKey: String { HirevaPreferenceKeys.answerProviderMode }
    private static var appleSpeechASRDefaultMigrationKey: String { HirevaPreferenceKeys.appleSpeechASRDefaultMigration }
    private var preferenceDefaults: UserDefaults { dialogueDefaults ?? .standard }

    var selectedASRProviderID: ASRProviderID {
        ASRProviderID(rawValue: preferenceDefaults.string(forKey: Self.selectedASRProviderKey) ?? "") ?? .appleSpeech
    }

    var selectedTranscriptionProviderMode: TranscriptionProviderMode {
        TranscriptionProviderMode(providerID: selectedASRProviderID)
    }

    var selectedQwenModelName: String {
        let stored = preferenceDefaults.string(forKey: Self.selectedQwenModelKey)
        return (stored?.isEmpty == false) ? stored! : LocalModelDescriptor.defaultQwenLocalLLM.id
    }

    var selectedAnswerProviderMode: AnswerProviderMode {
        if let answerProviderModeOverride {
            return answerProviderModeOverride
        }
        return AnswerProviderMode(storedValue: preferenceDefaults.string(forKey: Self.answerProviderModeKey))
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

    func setSelectedASRProvider(_ provider: ASRProviderID) {
        preferenceDefaults.set(provider.rawValue, forKey: Self.selectedASRProviderKey)
        objectWillChange.send()
    }

    func setSelectedAnswerProviderMode(_ mode: AnswerProviderMode) {
        preferenceDefaults.set(mode.rawValue, forKey: Self.answerProviderModeKey)
        objectWillChange.send()
    }

    func setSelectedQwenModelName(_ modelName: String) {
        preferenceDefaults.set(modelName, forKey: Self.selectedQwenModelKey)
        objectWillChange.send()
    }

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
        guard qwenReady else { return }
        let rawValue = preferenceDefaults.string(forKey: Self.answerProviderModeKey)
        let isUnset = rawValue == nil || rawValue == ""
        let isLegacyDeepSeek = rawValue == "deepSeek" || rawValue == AnswerProviderMode.deepSeekPrimary.rawValue
        guard isUnset || isLegacyDeepSeek else { return }
        setSelectedAnswerProviderMode(.localQwenPrimary)
    }

    func runLaunchLocalQwenDefaultMigrationIfNeeded() {
        guard !isRunningUnderTestOrAutomation() else { return }
        let rawValue = preferenceDefaults.string(forKey: Self.answerProviderModeKey)
        let shouldProbe = rawValue == nil ||
            rawValue == "" ||
            rawValue == "deepSeek" ||
            rawValue == AnswerProviderMode.deepSeekPrimary.rawValue
        guard shouldProbe else { return }
        let modelName = selectedQwenModelName
        Task { [weak self] in
            let health = await OllamaQwenProvider().healthCheck(modelName: modelName)
            await MainActor.run {
                self?.migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: health.isReady)
            }
        }
    }
}
