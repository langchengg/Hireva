import Foundation

enum AudioStreamDiagnosticState: Equatable {
    case notSelected
    case permissionRequired(String)
    case starting
    case waitingForData
    case dataReceived
    case recognizing
    case transcribing
    case failed(String)
    case stopped
}

/// Immutable projection of one source's existing capture and recognition state.
/// Capture delivery does not prove ASR delivery: a nil ASR buffer count means
/// the current provider does not expose that measurement.
struct AudioStreamDiagnosticSnapshot: Equatable {
    let source: AudioSourceType
    let state: AudioStreamDiagnosticState

    init(
        source: AudioSourceType,
        selected: Bool,
        permissionFailure: String?,
        runtimeState: CaptureRuntimeState,
        captureRunning: Bool,
        lastCapturedBufferAt: Date?,
        asrBufferCount: Int?,
        recognitionActive: Bool?,
        hasTranscript: Bool,
        sourceError: String?
    ) {
        self.source = source
        if !selected {
            state = .notSelected
        } else if let permissionFailure {
            state = .permissionRequired(permissionFailure)
        } else if let sourceError, !sourceError.isEmpty {
            state = .failed(sourceError)
        } else if !captureRunning {
            switch runtimeState {
            case .starting:
                state = .starting
            case .error(let reason):
                state = .failed(reason)
            default:
                state = .stopped
            }
        } else if lastCapturedBufferAt == nil && (asrBufferCount ?? 0) == 0 {
            state = .waitingForData
        } else if hasTranscript {
            state = .transcribing
        } else if let asrBufferCount, asrBufferCount > 0, recognitionActive == true {
            state = .recognizing
        } else {
            state = .dataReceived
        }
    }

    var detail: String {
        switch state {
        case .notSelected: return "Not selected in the capture mode"
        case .permissionRequired(let reason): return reason
        case .starting: return "Starting capture"
        case .waitingForData: return "Waiting for audio buffer"
        case .dataReceived: return "Capture buffers received; ASR delivery is not verified"
        case .recognizing: return "ASR processing audio; waiting for transcript"
        case .transcribing: return "Transcript received"
        case .failed(let reason): return reason
        case .stopped: return "Capture stopped"
        }
    }

    private var sourceName: String {
        source == .microphone ? "Microphone" : "System audio"
    }

    private var priority: Int {
        switch state {
        case .failed, .permissionRequired: return 0
        case .stopped: return 1
        case .starting, .waitingForData: return 2
        case .dataReceived, .recognizing: return 3
        case .notSelected, .transcribing: return 4
        }
    }

    private var reason: String? {
        switch state {
        case .notSelected, .transcribing:
            return nil
        case .failed, .permissionRequired:
            return "\(sourceName) not running: \(detail)"
        default:
            return "\(sourceName): \(detail)"
        }
    }

    static func streamNotRunningReason(_ snapshots: [Self]) -> String? {
        let reasons = snapshots.enumerated()
            .sorted {
                $0.element.priority == $1.element.priority
                    ? $0.offset < $1.offset
                    : $0.element.priority < $1.element.priority
            }
            .compactMap { $0.element.reason }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}
