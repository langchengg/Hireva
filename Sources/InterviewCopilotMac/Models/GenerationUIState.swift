import Foundation

/// User or system path that initiated a generation attempt.
enum GenerationTriggerPath: String, CaseIterable, Codable, Hashable {
    case autoDetect = "auto_detect"
    case manualGenerate = "manual_generate"
    case manualCapture = "manual_capture"
    case regenerate = "regenerate"
}

/// Product-facing generation state for the current answer card.
///
/// The spinner should only be shown for loading states before any visible
/// answer exists. Once fallback or first provider text is visible, the UI should
/// show expansion status instead of blocking the answer behind a spinner.
enum GenerationUIState: Equatable {
    case idle
    case preparing(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case generatingFirstAnswer(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case showingFallback(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case streamingAnswer(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case expandingFullAnswer(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case answerReady(questionID: String?, generationID: String, triggerPath: GenerationTriggerPath)
    case failed(questionID: String?, generationID: String?, triggerPath: GenerationTriggerPath?, reason: String)
    case timeout(questionID: String?, generationID: String?, triggerPath: GenerationTriggerPath?, reason: String)
    case cancelled(questionID: String?, generationID: String?, triggerPath: GenerationTriggerPath?, reason: String)

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .generatingFirstAnswer:
            return "Generating first answer"
        case .showingFallback:
            return "Showing fallback"
        case .streamingAnswer:
            return "Streaming answer"
        case .expandingFullAnswer:
            return "Expanding full answer"
        case .answerReady:
            return "Answer ready"
        case .failed:
            return "Failed"
        case .timeout:
            return "Timeout"
        case .cancelled:
            return "Cancelled"
        }
    }

    var generationID: String? {
        switch self {
        case .idle:
            return nil
        case let .preparing(_, generationID, _),
             let .generatingFirstAnswer(_, generationID, _),
             let .showingFallback(_, generationID, _),
             let .streamingAnswer(_, generationID, _),
             let .expandingFullAnswer(_, generationID, _),
             let .answerReady(_, generationID, _):
            return generationID
        case let .failed(_, generationID, _, _),
             let .timeout(_, generationID, _, _),
             let .cancelled(_, generationID, _, _):
            return generationID
        }
    }

    var questionID: String? {
        switch self {
        case .idle:
            return nil
        case let .preparing(questionID, _, _),
             let .generatingFirstAnswer(questionID, _, _),
             let .showingFallback(questionID, _, _),
             let .streamingAnswer(questionID, _, _),
             let .expandingFullAnswer(questionID, _, _),
             let .answerReady(questionID, _, _):
            return questionID
        case let .failed(questionID, _, _, _),
             let .timeout(questionID, _, _, _),
             let .cancelled(questionID, _, _, _):
            return questionID
        }
    }

    var triggerPath: GenerationTriggerPath? {
        switch self {
        case .idle:
            return nil
        case let .preparing(_, _, triggerPath),
             let .generatingFirstAnswer(_, _, triggerPath),
             let .showingFallback(_, _, triggerPath),
             let .streamingAnswer(_, _, triggerPath),
             let .expandingFullAnswer(_, _, triggerPath),
             let .answerReady(_, _, triggerPath):
            return triggerPath
        case let .failed(_, _, triggerPath, _),
             let .timeout(_, _, triggerPath, _),
             let .cancelled(_, _, triggerPath, _):
            return triggerPath
        }
    }

    var isLoadingWithoutVisibleAnswer: Bool {
        switch self {
        case .preparing, .generatingFirstAnswer:
            return true
        case .idle, .showingFallback, .streamingAnswer, .expandingFullAnswer, .answerReady, .failed, .timeout, .cancelled:
            return false
        }
    }

    var isExpandingAfterVisibleAnswer: Bool {
        if case .expandingFullAnswer = self {
            return true
        }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .idle, .answerReady, .failed, .timeout, .cancelled:
            return true
        case .preparing, .generatingFirstAnswer, .showingFallback, .streamingAnswer, .expandingFullAnswer:
            return false
        }
    }

    var failureReason: String? {
        switch self {
        case let .failed(_, _, _, reason),
             let .timeout(_, _, _, reason),
             let .cancelled(_, _, _, reason):
            return reason
        case .idle, .preparing, .generatingFirstAnswer, .showingFallback, .streamingAnswer, .expandingFullAnswer, .answerReady:
            return nil
        }
    }
}

struct GenerationTelemetry: Equatable {
    var questionID: String?
    var generationID: String?
    var source: String?
    var speaker: String?
    var triggerPath: GenerationTriggerPath?
    var generationState: String
    var startedAt: Date?
    var firstVisibleAt: Date?
    var fallbackShownAt: Date?
    var firstDeepSeekTokenAt: Date?
    var firstKeyPointAt: Date?
    var fullCardAt: Date?
    var dbPersistedAt: Date?
    var failureReason: String?
    var wasStaleDiscarded: Bool
    var duplicateSuppressionCount: Int
    var staleDiscardCount: Int
    var providerError: String?
    var jsonParseError: String?
    var dbError: String?

    static var idle: GenerationTelemetry {
        GenerationTelemetry(
            questionID: nil,
            generationID: nil,
            source: nil,
            speaker: nil,
            triggerPath: nil,
            generationState: GenerationUIState.idle.displayName,
            startedAt: nil,
            firstVisibleAt: nil,
            fallbackShownAt: nil,
            firstDeepSeekTokenAt: nil,
            firstKeyPointAt: nil,
            fullCardAt: nil,
            dbPersistedAt: nil,
            failureReason: nil,
            wasStaleDiscarded: false,
            duplicateSuppressionCount: 0,
            staleDiscardCount: 0,
            providerError: nil,
            jsonParseError: nil,
            dbError: nil
        )
    }

    var elapsedMs: Int? {
        guard let startedAt else { return nil }
        return Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}
