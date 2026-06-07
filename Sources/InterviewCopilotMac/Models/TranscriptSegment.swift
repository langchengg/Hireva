import Foundation

enum AudioSourceType: String, Codable, CaseIterable {
    case microphone
    case systemAudio
    case processAudio
    case mock
    case mixed
}

enum SpeakerRole: String, Codable, CaseIterable {
    case candidate
    case interviewer
    case unknown
    case speakerA
    case speakerB
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .candidate:
            return "Candidate"
        case .interviewer:
            return "Interviewer"
        case .unknown:
            return "Unknown"
        case .speakerA:
            return "Speaker A"
        case .speakerB:
            return "Speaker B"
        case .system:
            return "System"
        }
    }
}

public struct AudioDeviceInfo: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let transportType: String?
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let isInput: Bool
    public let isOutput: Bool

    public init(
        id: String,
        name: String,
        transportType: String?,
        isDefaultInput: Bool,
        isDefaultOutput: Bool,
        isInput: Bool,
        isOutput: Bool
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
        self.isInput = isInput
        self.isOutput = isOutput
    }
}

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var source: AudioSourceType
    var speaker: SpeakerRole
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var createdAt: Date
    var inputDeviceName: String?
    var outputDeviceName: String?
    var deviceID: String?
    var confidence: Double?

    // ASR Latency (utterance-level, not session-level)
    var asrFirstPartialMS: Int?
    var asrFinalMS: Int?
    var asrBestSelectedMS: Int?
    var asrFinalizationReason: String?

    init(
        id: String,
        sessionID: String,
        source: AudioSourceType = .microphone,
        speaker: SpeakerRole,
        text: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        createdAt: Date = Date(),
        inputDeviceName: String? = nil,
        outputDeviceName: String? = nil,
        deviceID: String? = nil,
        confidence: Double? = nil,
        asrFirstPartialMS: Int? = nil,
        asrFinalMS: Int? = nil,
        asrBestSelectedMS: Int? = nil,
        asrFinalizationReason: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.deviceID = deviceID
        self.confidence = confidence
        self.asrFirstPartialMS = asrFirstPartialMS
        self.asrFinalMS = asrFinalMS
        self.asrBestSelectedMS = asrBestSelectedMS
        self.asrFinalizationReason = asrFinalizationReason
    }

    static func system(_ text: String, sessionID: String = "ephemeral") -> TranscriptSegment {
        TranscriptSegment(
            id: UUID().uuidString,
            sessionID: sessionID,
            source: .mixed,
            speaker: .system,
            text: text,
            startTime: nil,
            endTime: nil,
            createdAt: Date(),
            inputDeviceName: nil,
            outputDeviceName: nil,
            deviceID: nil,
            confidence: nil
        )
    }
}
