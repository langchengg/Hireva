import Foundation

public enum ManualCaptureState: Equatable, Hashable {
    case idle
    case waitingForPermission
    case recording
    case stopping
    case transcribing
    case transcriptReady
    case generatingSuggestion
    case suggestionReady
    case cancelled
    case error(String)
    
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForPermission: return "Requesting Permission"
        case .recording: return "Recording..."
        case .stopping: return "Stopping..."
        case .transcribing: return "Transcribing..."
        case .transcriptReady: return "Transcript Ready"
        case .generatingSuggestion: return "Generating Answer..."
        case .suggestionReady: return "Suggestion Ready"
        case .cancelled: return "Cancelled"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
