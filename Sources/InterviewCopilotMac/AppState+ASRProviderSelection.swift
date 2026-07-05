import Foundation

extension AppState {
    private static var selectedASRProviderKey: String { "InterviewCopilot.selectedASRProvider" }
    private static var activeASRProviderKey: String { "InterviewCopilot.activeASRProvider" }
    private static var selectedQwenModelKey: String { "InterviewCopilot.selectedQwenModel" }
    private static var answerProviderModeKey: String { "InterviewCopilot.answerProviderMode" }

    var selectedASRProviderID: ASRProviderID {
        ASRProviderID(rawValue: UserDefaults.standard.string(forKey: Self.selectedASRProviderKey) ?? "") ?? .appleSpeech
    }

    var selectedTranscriptionProviderMode: TranscriptionProviderMode {
        TranscriptionProviderMode(providerID: selectedASRProviderID)
    }

    var selectedQwenModelName: String {
        let stored = UserDefaults.standard.string(forKey: Self.selectedQwenModelKey)
        return (stored?.isEmpty == false) ? stored! : LocalModelDescriptor.defaultQwenLocalLLM.id
    }

    var selectedAnswerProviderMode: AnswerProviderMode {
        AnswerProviderMode(storedValue: UserDefaults.standard.string(forKey: Self.answerProviderModeKey))
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
}
