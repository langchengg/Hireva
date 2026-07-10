import Foundation

enum InterviewContextMode: String, Codable, CaseIterable {
    case general
    case phdRobotics = "phd_robotics"

    var displayName: String {
        switch self {
        case .general: return "General"
        case .phdRobotics: return "Academic / Robotics"
        }
    }
}

/// The only dialogue phase-like choice exposed in normal product UI.
enum InterviewSessionMode: String, Codable, CaseIterable {
    case auto
    case presentation
    case panelQuestions = "panel_questions"
    case candidateQuestions = "candidate_questions"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .presentation: return "Presentation"
        case .panelQuestions: return "Panel Questions"
        case .candidateQuestions: return "Candidate Questions"
        }
    }
}

/// Runtime flow state. Closing is internal and is intentionally not selectable
/// as a normal session mode.
enum DialogueSessionPhase: String, Codable, Equatable {
    case auto
    case presentation
    case panelQuestions = "panel_questions"
    case candidateQuestions = "candidate_questions"
    case closing

    static func initial(for mode: InterviewSessionMode) -> DialogueSessionPhase {
        switch mode {
        case .auto: return .auto
        case .presentation: return .presentation
        case .panelQuestions: return .panelQuestions
        case .candidateQuestions: return .candidateQuestions
        }
    }
}

enum DialogueTurnRole: String, Codable, Equatable {
    case interviewer
    case candidate
    case ambiguous
}

enum DialogueTurnType: String, Codable, Equatable {
    case substantiveQuestion = "substantive_question"
    case clarificationQuestion = "clarification_question"
    case candidateAnswer = "candidate_answer"
    case candidatePresentation = "candidate_presentation"
    case candidateQuestionToPanel = "candidate_question_to_panel"
    case logistics
    case backchannel
    case closing
    case statement
    case unknown
}

struct DialogueRuntimeState: Equatable {
    var selectedSessionMode: InterviewSessionMode
    var resolvedSessionPhase: DialogueSessionPhase
    var detectedSpeakerRole: DialogueTurnRole = .ambiguous
    var detectedTurnType: DialogueTurnType = .unknown

    static func initial(for mode: InterviewSessionMode) -> DialogueRuntimeState {
        DialogueRuntimeState(
            selectedSessionMode: mode,
            resolvedSessionPhase: .initial(for: mode)
        )
    }

    func applying(_ decision: DialogueTriggerDecision) -> DialogueRuntimeState {
        var next = self
        next.resolvedSessionPhase = decision.nextResolvedSessionPhase ?? resolvedSessionPhase
        next.detectedSpeakerRole = decision.speakerRole
        next.detectedTurnType = decision.turnType
        return next
    }
}

// Legacy stored values are retained only for launch migration and test-fixture
// compatibility. They are not exposed by Settings and do not drive production
// turn classification.
enum InterviewListeningMode: String, Codable, CaseIterable {
    case standard
    case panelQuestionsOnly = "panel_questions_only"

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .panelQuestionsOnly: return "Panel Questions"
        }
    }
}

enum CandidateSpeechMode: String, Codable, CaseIterable {
    case normal
    case suppressAnswers = "suppress_answers"

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .suppressAnswers: return "Suppress"
        }
    }
}

enum InterviewPhase: String, Codable, CaseIterable {
    case unknown
    case logistics
    case candidatePresentation = "candidate_presentation"
    case interviewerQuestions = "interviewer_questions"
    case candidateAnswer = "candidate_answer"
    case candidateQuestionsToPanel = "candidate_questions_to_panel"
    case closing

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .logistics: return "Logistics"
        case .candidatePresentation: return "Candidate Presentation"
        case .interviewerQuestions: return "Panel Questions"
        case .candidateAnswer: return "Candidate Answer"
        case .candidateQuestionsToPanel: return "Candidate Questions"
        case .closing: return "Closing"
        }
    }

    var legacyTurnType: DialogueTurnType? {
        switch self {
        case .logistics: return .logistics
        case .candidatePresentation: return .candidatePresentation
        case .candidateAnswer: return .candidateAnswer
        case .candidateQuestionsToPanel: return .candidateQuestionToPanel
        case .closing: return .closing
        case .unknown, .interviewerQuestions: return nil
        }
    }
}

enum InterviewTriggerDecision: String, Codable {
    case evaluateInterviewerQuestion = "evaluate_interviewer_question"
    case triggerAnswer = "trigger_answer"
    case suppressCandidatePresentation = "suppress_candidate_presentation"
    case suppressCandidateSpeech = "suppress_candidate_speech"
    case candidateQuestionToPanel = "candidate_question_to_panel"
    case transitionToCandidateQuestions = "transition_to_candidate_questions"
    case suppressLogistics = "suppress_logistics"
    case suppressBackchannel = "suppress_backchannel"
    case suppressClosing = "suppress_closing"
    case suppressStatement = "suppress_statement"
    case suppressSystemEvent = "suppress_system_event"
}

struct DialogueTriggerDecision: Equatable {
    let shouldEvaluateQuestion: Bool
    let decision: InterviewTriggerDecision
    let speakerRole: DialogueTurnRole
    let turnType: DialogueTurnType
    let triggerReason: String
    let suppressionReason: String
    let blockedReasonCode: String
    let nextResolvedSessionPhase: DialogueSessionPhase?
    let modeTransitionReason: String
}

typealias InterviewDialogueTriggerEvaluation = DialogueTriggerDecision

/// Central speaker/source/semantics gate applied before provider-backed question
/// classification. It owns coarse dialogue transitions, but never owns question
/// IDs, generation IDs, provider calls, persistence, or answer UI.
enum InterviewDialogueTriggerPolicy {
    static func decideDialogueTrigger(
        segment: TranscriptSegment,
        sessionMode: InterviewSessionMode,
        currentState: DialogueRuntimeState,
        answerPanelQuestions: Bool,
        suppressPresentation: Bool,
        suppressCandidateQuestions: Bool
    ) -> DialogueTriggerDecision {
        let role = inferredRole(for: segment)
        let normalized = normalize(segment.text)

        if segment.speaker == .system {
            return suppressed(
                .suppressSystemEvent,
                role: .ambiguous,
                type: .statement,
                reason: "system event is not interview speech",
                code: "systemEvent"
            )
        }

        if isClosing(normalized) {
            return suppressed(
                .suppressClosing,
                role: role,
                type: .closing,
                reason: "closing speech is not a candidate-facing question",
                code: "closing",
                nextPhase: .closing,
                transitionReason: "closing language detected"
            )
        }

        if role == .candidate {
            switch currentState.resolvedSessionPhase {
            case .auto:
                if suppressPresentation {
                    return suppressed(
                        .suppressCandidatePresentation,
                        role: role,
                        type: .candidatePresentation,
                        reason: "candidate presentation is not an interviewer question",
                        code: "candidatePresentation",
                        nextPhase: .presentation,
                        transitionReason: "candidate speech detected before panel questions"
                    )
                }
            case .presentation:
                if suppressPresentation {
                    return suppressed(
                        .suppressCandidatePresentation,
                        role: role,
                        type: .candidatePresentation,
                        reason: "candidate presentation is not an interviewer question",
                        code: "candidatePresentation"
                    )
                }
            case .candidateQuestions:
                if suppressCandidateQuestions {
                    return suppressed(
                        .candidateQuestionToPanel,
                        role: role,
                        type: .candidateQuestionToPanel,
                        reason: "candidate question is directed to the panel",
                        code: "candidateQuestionToPanel"
                    )
                }
            case .panelQuestions, .closing:
                break
            }

            return suppressed(
                .suppressCandidateSpeech,
                role: role,
                type: currentState.resolvedSessionPhase == .presentation ? .candidatePresentation : .candidateAnswer,
                reason: "candidate speech does not request a candidate-facing answer",
                code: "candidateSpeech"
            )
        }

        if isBackchannel(normalized) {
            return suppressed(
                .suppressBackchannel,
                role: role,
                type: .backchannel,
                reason: "backchannel is not a substantive question",
                code: "backchannel"
            )
        }

        if isLogistics(normalized) {
            return suppressed(
                .suppressLogistics,
                role: role,
                type: .logistics,
                reason: "interview logistics is not a substantive question",
                code: "logistics"
            )
        }

        let candidates = QuestionCandidatePipeline.extract(from: segment.text)
        let substantiveCandidates = candidates.filter { !isPanelInvitation(normalize($0.text)) }
        if substantiveCandidates.isEmpty, isPanelInvitation(normalized) {
            return suppressed(
                .transitionToCandidateQuestions,
                role: role,
                type: .statement,
                reason: "panel invited the candidate to ask questions",
                code: "candidateQuestionsTransition",
                nextPhase: .candidateQuestions,
                transitionReason: "panel invitation detected"
            )
        }

        guard !substantiveCandidates.isEmpty else {
            return suppressed(
                .suppressStatement,
                role: role,
                type: .statement,
                reason: "utterance is not a complete substantive interviewer question",
                code: "notSubstantiveQuestion"
            )
        }

        guard answerPanelQuestions else {
            return suppressed(
                .suppressStatement,
                role: role,
                type: .substantiveQuestion,
                reason: "answering panel questions is disabled",
                code: "panelAnswersDisabled"
            )
        }

        if sessionMode == .candidateQuestions {
            return suppressed(
                .candidateQuestionToPanel,
                role: role,
                type: .candidateQuestionToPanel,
                reason: "candidate-question session mode suppresses normal answer generation",
                code: "candidateQuestionToPanel"
            )
        }

        if currentState.resolvedSessionPhase == .candidateQuestions {
            if sessionMode != .candidateQuestions,
               role == .interviewer,
               isPanelQuestionResumption(normalized) {
                let turnType: DialogueTurnType = isClarification(normalized) ? .clarificationQuestion : .substantiveQuestion
                return allowed(
                    role: role,
                    type: turnType,
                    reason: "interviewer resumed panel questions after candidate questions",
                    nextPhase: .panelQuestions,
                    transitionReason: "substantive interviewer follow-up detected"
                )
            }
            return suppressed(
                .candidateQuestionToPanel,
                role: role,
                type: .candidateQuestionToPanel,
                reason: "candidate-question session mode suppresses normal answer generation",
                code: "candidateQuestionToPanel"
            )
        }

        let turnType: DialogueTurnType = isClarification(normalized) ? .clarificationQuestion : .substantiveQuestion
        let shouldEnterPanelQuestions = currentState.resolvedSessionPhase == .auto ||
            currentState.resolvedSessionPhase == .presentation
        return allowed(
            role: role,
            type: turnType,
            reason: "complete interviewer question accepted from \(segment.source.rawValue)",
            nextPhase: shouldEnterPanelQuestions ? .panelQuestions : nil,
            transitionReason: shouldEnterPanelQuestions ? "first substantive panel question accepted" : ""
        )
    }

    /// Compatibility entry point for older deterministic fixtures. Production
    /// routing uses `decideDialogueTrigger` and never treats Candidate Answer as
    /// a user-controlled global phase.
    static func evaluate(
        segment: TranscriptSegment,
        phase: InterviewPhase,
        listeningMode: InterviewListeningMode,
        candidatePresentationMode: CandidateSpeechMode,
        candidateAsksPanelMode: CandidateSpeechMode,
        allowCandidateQuestionDetection: Bool
    ) -> InterviewDialogueTriggerEvaluation {
        let selectedMode: InterviewSessionMode = listeningMode == .panelQuestionsOnly ? .panelQuestions : .auto
        let resolvedPhase: DialogueSessionPhase
        switch phase {
        case .candidatePresentation: resolvedPhase = .presentation
        case .interviewerQuestions, .candidateAnswer: resolvedPhase = .panelQuestions
        case .candidateQuestionsToPanel: resolvedPhase = .candidateQuestions
        case .closing: resolvedPhase = .closing
        case .unknown, .logistics: resolvedPhase = .initial(for: selectedMode)
        }
        return decideDialogueTrigger(
            segment: segment,
            sessionMode: selectedMode,
            currentState: DialogueRuntimeState(
                selectedSessionMode: selectedMode,
                resolvedSessionPhase: resolvedPhase,
                detectedTurnType: phase.legacyTurnType ?? .unknown
            ),
            answerPanelQuestions: true,
            suppressPresentation: candidatePresentationMode == .suppressAnswers,
            suppressCandidateQuestions: candidateAsksPanelMode == .suppressAnswers
        )
    }

    private static func inferredRole(for segment: TranscriptSegment) -> DialogueTurnRole {
        switch segment.speaker {
        case .interviewer: return .interviewer
        case .candidate: return .candidate
        case .speakerA, .speakerB, .system: return .ambiguous
        case .unknown:
            switch segment.source {
            case .systemAudio, .processAudio: return .interviewer
            case .microphone: return .candidate
            case .mixed, .mock: return .ambiguous
            }
        }
    }

    private static func allowed(
        role: DialogueTurnRole,
        type: DialogueTurnType,
        reason: String,
        nextPhase: DialogueSessionPhase? = nil,
        transitionReason: String = ""
    ) -> DialogueTriggerDecision {
        DialogueTriggerDecision(
            shouldEvaluateQuestion: true,
            decision: .evaluateInterviewerQuestion,
            speakerRole: role,
            turnType: type,
            triggerReason: reason,
            suppressionReason: "",
            blockedReasonCode: "",
            nextResolvedSessionPhase: nextPhase,
            modeTransitionReason: transitionReason
        )
    }

    private static func suppressed(
        _ decision: InterviewTriggerDecision,
        role: DialogueTurnRole,
        type: DialogueTurnType,
        reason: String,
        code: String,
        nextPhase: DialogueSessionPhase? = nil,
        transitionReason: String = ""
    ) -> DialogueTriggerDecision {
        DialogueTriggerDecision(
            shouldEvaluateQuestion: false,
            decision: decision,
            speakerRole: role,
            turnType: type,
            triggerReason: "",
            suppressionReason: reason,
            blockedReasonCode: code,
            nextResolvedSessionPhase: nextPhase,
            modeTransitionReason: transitionReason
        )
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isClarification(_ text: String) -> Bool {
        text.hasPrefix("to clarify ") ||
            text.hasPrefix("just to clarify ") ||
            text.hasPrefix("sorry perhaps i was unclear ") ||
            text.hasPrefix("as a follow up ")
    }

    private static func isPanelInvitation(_ text: String) -> Bool {
        let phrases = [
            "do you have any questions for us",
            "is there anything you would like to ask",
            "would you like to ask the panel anything",
            "anything you would like to ask the panel",
            "that completes our formal questions",
            "that completes our questions"
        ]
        return phrases.contains { text == $0 || text.contains($0) }
    }

    private static func isPanelQuestionResumption(_ text: String) -> Bool {
        let phrases = [
            "before we finish",
            "one final question",
            "one more question",
            "we have another question",
            "the panel has another question",
            "can i ask one more"
        ]
        return phrases.contains { text == $0 || text.contains($0) }
    }

    private static func isLogistics(_ text: String) -> Bool {
        let phrases = [
            "you can start when you are ready",
            "you can start when ready",
            "start when you are ready",
            "begin your presentation when you are comfortable",
            "take a moment to get ready",
            "can you see my slide",
            "can you see the slide",
            "can you see my screen"
        ]
        return phrases.contains { text == $0 || text.contains($0) }
    }

    private static func isBackchannel(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count <= 5 else { return false }
        return ["okay", "ok", "yeah", "yes", "right", "thank you", "thanks", "great thanks"].contains(text)
    }

    private static func isClosing(_ text: String) -> Bool {
        let phrases = [
            "that is all from us",
            "that covers our questions",
            "we will let you know",
            "we will be in touch",
            "thanks for your time",
            "thank you for your time today",
            "contact you once the panel has reviewed"
        ]
        return phrases.contains { text == $0 || text.contains($0) }
    }
}

struct DialogueSettingsMigrationResult: Equatable {
    let contextMode: InterviewContextMode
    let selectedMode: InterviewSessionMode
    let resolvedPhase: DialogueSessionPhase
    let legacyTurnType: DialogueTurnType?
    let answerPanelQuestions: Bool
    let suppressPresentation: Bool
    let suppressCandidateQuestions: Bool
}

enum DialogueSettingsStore {
    static let contextModeKey = "InterviewCopilot.interviewContextMode"
    static let sessionModeKey = "InterviewCopilot.interviewSessionMode"
    static let answerPanelQuestionsKey = "InterviewCopilot.answerPanelQuestions"
    static let suppressPresentationKey = "InterviewCopilot.suppressPresentation"
    static let suppressCandidateQuestionsKey = "InterviewCopilot.suppressCandidateQuestions"
    static let legacyListeningModeKey = "InterviewCopilot.interviewListeningMode"
    static let legacyPhaseKey = "InterviewCopilot.interviewPhase"

    static func loadAndMigrate(defaults: UserDefaults?) -> DialogueSettingsMigrationResult {
        guard let defaults else {
            return DialogueSettingsMigrationResult(
                contextMode: .general,
                selectedMode: .auto,
                resolvedPhase: .auto,
                legacyTurnType: nil,
                answerPanelQuestions: true,
                suppressPresentation: true,
                suppressCandidateQuestions: true
            )
        }

        let contextMode = InterviewContextMode(
            rawValue: defaults.string(forKey: contextModeKey) ?? ""
        ) ?? .general
        let legacyPhase = InterviewPhase(rawValue: defaults.string(forKey: legacyPhaseKey) ?? "")
        let selected: InterviewSessionMode
        if let stored = InterviewSessionMode(rawValue: defaults.string(forKey: sessionModeKey) ?? "") {
            selected = stored
        } else if let legacyPhase {
            switch legacyPhase {
            case .candidatePresentation: selected = .presentation
            case .candidateQuestionsToPanel: selected = .candidateQuestions
            case .interviewerQuestions, .candidateAnswer: selected = .panelQuestions
            case .unknown, .logistics, .closing: selected = .auto
            }
        } else if defaults.string(forKey: legacyListeningModeKey) == InterviewListeningMode.panelQuestionsOnly.rawValue {
            selected = .panelQuestions
        } else {
            selected = .auto
        }

        let answerPanelQuestions = storedBool(defaults, key: answerPanelQuestionsKey, defaultValue: true)
        let suppressPresentation = storedBool(defaults, key: suppressPresentationKey, defaultValue: true)
        let suppressCandidateQuestions = storedBool(defaults, key: suppressCandidateQuestionsKey, defaultValue: true)

        defaults.set(contextMode.rawValue, forKey: contextModeKey)
        defaults.set(selected.rawValue, forKey: sessionModeKey)
        defaults.set(answerPanelQuestions, forKey: answerPanelQuestionsKey)
        defaults.set(suppressPresentation, forKey: suppressPresentationKey)
        defaults.set(suppressCandidateQuestions, forKey: suppressCandidateQuestionsKey)
        defaults.removeObject(forKey: legacyListeningModeKey)
        defaults.removeObject(forKey: legacyPhaseKey)
        return DialogueSettingsMigrationResult(
            contextMode: contextMode,
            selectedMode: selected,
            resolvedPhase: .initial(for: selected),
            legacyTurnType: legacyPhase?.legacyTurnType,
            answerPanelQuestions: answerPanelQuestions,
            suppressPresentation: suppressPresentation,
            suppressCandidateQuestions: suppressCandidateQuestions
        )
    }

    private static func storedBool(
        _ defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
