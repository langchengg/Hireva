import Foundation

public enum CaptureRuntimeState: Equatable, Hashable {
    case idle
    case starting
    case listening
    case generating
    case stopping
    case stopped(reason: StopReason?)
    case error(reason: String)
    
    public var id: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .listening: return "listening"
        case .generating: return "generating"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .error: return "error"
        }
    }
    
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .listening: return "Listening Active"
        case .generating: return "Generating Suggestion"
        case .stopping: return "Stopping"
        case .stopped(let reason):
            if let reason = reason {
                return "Stopped (\(reason.rawValue))"
            }
            return "Stopped"
        case .error(let reason): return "Error: \(reason)"
        }
    }
}

public enum StopReason: String, Codable, Equatable, Hashable {
    case userRequested
    case permissionDenied
    case screenCaptureStreamEnded
    case audioDeviceChanged
    case asrTaskFailed
    case llmGenerationCompletedIncorrectly
    case unknown
}
