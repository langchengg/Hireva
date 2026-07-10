import Foundation

enum InterviewContextMode: String, Codable, CaseIterable {
    case general
    case phdRobotics = "phd_robotics"

    var displayName: String {
        switch self {
        case .general: return "General"
        case .phdRobotics: return "PhD Robotics"
        }
    }
}

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
}

enum InterviewTriggerDecision: String, Codable {
    case evaluateInterviewerQuestion = "evaluate_interviewer_question"
    case triggerAnswer = "trigger_answer"
    case suppressCandidatePresentation = "suppress_candidate_presentation"
    case suppressCandidateSpeech = "suppress_candidate_speech"
    case candidateQuestionToPanel = "candidate_question_to_panel"
    case suppressLogistics = "suppress_logistics"
    case suppressClosing = "suppress_closing"
    case suppressSystemEvent = "suppress_system_event"
}

struct InterviewDialogueTriggerEvaluation: Equatable {
    let shouldEvaluateQuestion: Bool
    let decision: InterviewTriggerDecision
    let triggerReason: String
    let suppressionReason: String
    let blockedReasonCode: String
}

/// Pure speaker/phase gate applied before question extraction and generation.
enum InterviewDialogueTriggerPolicy {
    static func evaluate(
        segment: TranscriptSegment,
        phase: InterviewPhase,
        listeningMode: InterviewListeningMode,
        candidatePresentationMode: CandidateSpeechMode,
        candidateAsksPanelMode: CandidateSpeechMode,
        allowCandidateQuestionDetection: Bool
    ) -> InterviewDialogueTriggerEvaluation {
        if segment.speaker == .system {
            return suppressed(.suppressSystemEvent, reason: "system event is not interview speech", code: "systemEvent")
        }

        if segment.speaker == .candidate {
            if phase == .candidatePresentation, candidatePresentationMode == .suppressAnswers {
                return suppressed(
                    .suppressCandidatePresentation,
                    reason: "candidate presentation is not an interviewer question",
                    code: "candidatePresentation"
                )
            }
            if phase == .candidateQuestionsToPanel, candidateAsksPanelMode == .suppressAnswers {
                return suppressed(
                    .candidateQuestionToPanel,
                    reason: "candidate question is directed to the panel",
                    code: "candidateQuestionToPanel"
                )
            }
            if (segment.source == .microphone || segment.source == .mixed),
               !allowCandidateQuestionDetection {
                return suppressed(
                    .suppressCandidateSpeech,
                    reason: "question detection from microphone is disabled (allowQuestionDetectionFromMicrophoneOnly = false)",
                    code: "captureModeDisabled"
                )
            }
            if allowCandidateQuestionDetection,
               (segment.source == .microphone || segment.source == .mixed) {
                return allowed("microphone question detection is explicitly enabled")
            }
            return suppressed(
                .suppressCandidateSpeech,
                reason: "candidate speech does not request a candidate-facing answer",
                code: "candidateSpeech"
            )
        }

        let normalized = normalize(segment.text)
        if phase == .closing || isClosing(normalized) {
            return suppressed(.suppressClosing, reason: "closing or recruitment logistics", code: "closing")
        }
        if phase == .logistics || isLogistics(normalized) {
            return suppressed(.suppressLogistics, reason: "interview logistics is not a substantive question", code: "logistics")
        }

        if segment.speaker == .interviewer {
            return allowed("explicit interviewer role may contain a substantive question")
        }

        let systemLike = segment.source == .systemAudio || segment.source == .processAudio || segment.source == .mock
        if listeningMode == .panelQuestionsOnly, systemLike {
            return allowed("system audio in panel-questions-only mode may contain panel speech")
        }
        if listeningMode == .standard {
            return allowed("standard mode defers unknown speaker content to question classification")
        }
        if allowCandidateQuestionDetection,
           (segment.source == .microphone || segment.source == .mixed) {
            return allowed("microphone question detection is explicitly enabled")
        }

        return suppressed(
            .suppressCandidateSpeech,
            reason: "speaker is not attributable to the panel",
            code: "speakerNotPanel"
        )
    }

    private static func allowed(_ reason: String) -> InterviewDialogueTriggerEvaluation {
        InterviewDialogueTriggerEvaluation(
            shouldEvaluateQuestion: true,
            decision: .evaluateInterviewerQuestion,
            triggerReason: reason,
            suppressionReason: "",
            blockedReasonCode: ""
        )
    }

    private static func suppressed(
        _ decision: InterviewTriggerDecision,
        reason: String,
        code: String
    ) -> InterviewDialogueTriggerEvaluation {
        InterviewDialogueTriggerEvaluation(
            shouldEvaluateQuestion: false,
            decision: decision,
            triggerReason: "",
            suppressionReason: reason,
            blockedReasonCode: code
        )
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isLogistics(_ text: String) -> Bool {
        guard text.split(separator: " ").count <= 12 else { return false }
        let phrases = [
            "you can start when you are ready",
            "you can start when ready",
            "start when you are ready",
            "shall i ask a question first",
            "do you have any questions for us",
            "can you see my slide",
            "can you see the slide",
            "can you see my screen",
        ]
        if phrases.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) { return true }
        return ["okay", "ok", "thank you", "thanks"].contains(text)
    }

    private static func isClosing(_ text: String) -> Bool {
        guard text.split(separator: " ").count <= 12 else { return false }
        return [
            "that is all from us",
            "that covers our questions",
            "we will let you know",
            "we will be in touch",
            "thanks for your time",
        ].contains(where: { text == $0 || text.hasPrefix($0 + " ") })
    }
}
