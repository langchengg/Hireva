import Foundation

extension AppState {
    var dialogueRuntimeState: DialogueRuntimeState {
        DialogueRuntimeState(
            selectedSessionMode: interviewSessionMode,
            resolvedSessionPhase: resolvedInterviewSessionPhase,
            detectedSpeakerRole: detectedDialogueSpeakerRole,
            detectedTurnType: detectedDialogueTurnType
        )
    }

    func interviewSessionModeSelectionDidChange(from oldValue: InterviewSessionMode) {
        persistDialogueSetting(interviewSessionMode.rawValue, key: DialogueSettingsStore.sessionModeKey)
        let nextPhase = DialogueSessionPhase.initial(for: interviewSessionMode)
        guard oldValue != interviewSessionMode || resolvedInterviewSessionPhase != nextPhase else { return }
        let previous = resolvedInterviewSessionPhase
        resolvedInterviewSessionPhase = nextPhase
        lastModeTransition = "\(previous.rawValue) -> \(nextPhase.rawValue)"
        lastModeTransitionReason = "user selected \(interviewSessionMode.rawValue)"
    }

    func persistDialogueSetting(_ value: Any, key: String) {
        dialogueDefaults?.set(value, forKey: key)
    }

    func applyDialogueDecision(
        _ decision: DialogueTriggerDecision,
        source: AudioSourceType,
        allowModeTransition: Bool = true
    ) {
        detectedDialogueSpeakerRole = decision.speakerRole
        detectedDialogueTurnType = decision.turnType
        lastDialogueSourceChannel = source.rawValue
        if allowModeTransition,
           let nextPhase = decision.nextResolvedSessionPhase,
           nextPhase != resolvedInterviewSessionPhase {
            let previous = resolvedInterviewSessionPhase
            resolvedInterviewSessionPhase = nextPhase
            lastModeTransition = "\(previous.rawValue) -> \(nextPhase.rawValue)"
            lastModeTransitionReason = decision.modeTransitionReason
        }
    }

    func applyLegacyInterviewPhaseBridge(_ phase: InterviewPhase) {
        switch phase {
        case .unknown:
            return
        case .logistics:
            detectedDialogueTurnType = .logistics
        case .candidatePresentation:
            resolvedInterviewSessionPhase = .presentation
            detectedDialogueTurnType = .candidatePresentation
        case .interviewerQuestions:
            resolvedInterviewSessionPhase = .panelQuestions
        case .candidateAnswer:
            // Candidate answer is a turn classification, never a global mode.
            detectedDialogueTurnType = .candidateAnswer
        case .candidateQuestionsToPanel:
            resolvedInterviewSessionPhase = .candidateQuestions
            detectedDialogueTurnType = .candidateQuestionToPanel
        case .closing:
            resolvedInterviewSessionPhase = .closing
            detectedDialogueTurnType = .closing
        }
    }
}
