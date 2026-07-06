import Foundation

extension AppState {
    private static var selectedASRProviderKey: String { "InterviewCopilot.selectedASRProvider" }
    private static var activeASRProviderKey: String { "InterviewCopilot.activeASRProvider" }
    private static var selectedQwenModelKey: String { "InterviewCopilot.selectedQwenModel" }
    private static var answerProviderModeKey: String { "InterviewCopilot.answerProviderMode" }

    var selectedASRProviderID: ASRProviderID {
        ASRProviderID(rawValue: UserDefaults.standard.string(forKey: Self.selectedASRProviderKey) ?? "") ?? .localParakeet
    }

    var selectedTranscriptionProviderMode: TranscriptionProviderMode {
        TranscriptionProviderMode(providerID: selectedASRProviderID)
    }

    var selectedQwenModelName: String {
        let stored = UserDefaults.standard.string(forKey: Self.selectedQwenModelKey)
        return (stored?.isEmpty == false) ? stored! : LocalModelDescriptor.defaultQwenLocalLLM.id
    }

    var selectedAnswerProviderMode: AnswerProviderMode {
        if let answerProviderModeOverride {
            return answerProviderModeOverride
        }
        return AnswerProviderMode(storedValue: UserDefaults.standard.string(forKey: Self.answerProviderModeKey))
    }

    var activeASRProviderID: ASRProviderID? {
        ASRProviderID(rawValue: UserDefaults.standard.string(forKey: Self.activeASRProviderKey) ?? "")
    }

    var activeASRProviderDisplayName: String {
        activeASRProviderID?.displayName ?? "None"
    }

    var latestTranscriptASRSource: String {
        transcriptSegments.reversed().first { $0.speaker != .system }?.asrSource?.rawValue ?? "None"
    }

    func setSelectedASRProvider(_ provider: ASRProviderID) {
        UserDefaults.standard.set(provider.rawValue, forKey: Self.selectedASRProviderKey)
        objectWillChange.send()
    }

    func setSelectedAnswerProviderMode(_ mode: AnswerProviderMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.answerProviderModeKey)
        objectWillChange.send()
    }

    func setSelectedQwenModelName(_ modelName: String) {
        UserDefaults.standard.set(modelName, forKey: Self.selectedQwenModelKey)
        objectWillChange.send()
    }

    func markActiveASRProvider(_ provider: ASRProviderID?) {
        if let provider {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.activeASRProviderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeASRProviderKey)
        }
        objectWillChange.send()
    }

    func clearStaleActiveASRProviderOnLaunch() {
        UserDefaults.standard.removeObject(forKey: Self.activeASRProviderKey)
        objectWillChange.send()
    }

    func migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: Bool) {
        guard qwenReady else { return }
        let rawValue = UserDefaults.standard.string(forKey: Self.answerProviderModeKey)
        let isUnset = rawValue == nil || rawValue == ""
        let isLegacyDeepSeek = rawValue == "deepSeek" || rawValue == AnswerProviderMode.deepSeekPrimary.rawValue
        guard isUnset || isLegacyDeepSeek else { return }
        setSelectedAnswerProviderMode(.localQwenPrimary)
    }

    func runLaunchLocalQwenDefaultMigrationIfNeeded() {
        guard !isRunningUnderTestOrAutomation() else { return }
        let rawValue = UserDefaults.standard.string(forKey: Self.answerProviderModeKey)
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
