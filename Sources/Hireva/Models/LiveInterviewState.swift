import Foundation

enum LiveInterviewState: Identifiable, Hashable {
    case idle
    case requestingPermission
    case ready
    case listening
    case transcribing
    case detectingQuestion
    case generatingSuggestion
    case paused
    case stopped
    case permissionDenied
    case error(String)

    var id: String {
        switch self {
        case .idle: return "idle"
        case .requestingPermission: return "requestingPermission"
        case .ready: return "ready"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .detectingQuestion: return "detectingQuestion"
        case .generatingSuggestion: return "generatingSuggestion"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .permissionDenied: return "permissionDenied"
        case .error: return "error"
        }
    }

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .requestingPermission:
            return "Requesting Permission"
        case .ready:
            return "Ready"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .detectingQuestion:
            return "Detecting Question"
        case .generatingSuggestion:
            return "Generating Suggestion"
        case .paused:
            return "Paused"
        case .stopped:
            return "Stopped"
        case .permissionDenied:
            return "Permission Denied"
        case .error:
            return "Error"
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self {
            return message
        }
        return nil
    }

    var canStartListening: Bool {
        switch self {
        case .idle, .ready, .stopped, .paused, .permissionDenied, .error:
            return true
        case .requestingPermission, .listening, .transcribing, .detectingQuestion, .generatingSuggestion:
            return false
        }
    }

    var canStop: Bool {
        switch self {
        case .listening, .transcribing, .detectingQuestion, .generatingSuggestion, .requestingPermission, .paused:
            return true
        case .idle, .ready, .stopped, .permissionDenied, .error:
            return false
        }
    }

    var canAnswerNow: Bool {
        switch self {
        case .ready, .listening, .transcribing, .paused, .stopped, .idle, .permissionDenied, .error:
            return true
        case .requestingPermission, .detectingQuestion, .generatingSuggestion:
            return false
        }
    }
}
