import Foundation

extension AppState {
    var dialogueRuntimeState: DialogueRuntimeState {
        liveInterview.dialogueRuntimeState(selectedSessionMode: interviewSessionMode)
    }

    func interviewSessionModeSelectionDidChange(from oldValue: InterviewSessionMode) {
        liveInterview.interviewSessionModeSelectionDidChange(from: oldValue, to: interviewSessionMode)
    }

    func persistDialogueSetting(_ value: Any, key: String) {
        dialogueDefaults?.set(value, forKey: key)
    }

    func applyDialogueDecision(
        _ decision: DialogueTriggerDecision,
        source: AudioSourceType,
        allowModeTransition: Bool = true
    ) {
        liveInterview.applyDialogueDecision(decision, source: source, allowModeTransition: allowModeTransition)
    }

    func applyLegacyInterviewPhaseBridge(_ phase: InterviewPhase) {
        liveInterview.applyLegacyInterviewPhaseBridge(phase)
    }
}
