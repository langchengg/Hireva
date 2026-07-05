import Foundation

/// Origin of an ASR transcript segment.
///
/// Source attribution drives auto-detection safety: interviewer/system audio can
/// trigger answers, while candidate microphone speech is normally ignored.
enum AudioSourceType: String, Codable, CaseIterable {
    case microphone
    case systemAudio
    case processAudio
    case mock
    case mixed
}

/// Speaker attribution attached to a transcript segment.
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

/// Lightweight audio-device snapshot used by settings and diagnostics.
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

/// One ASR transcript segment with source, speaker, device, and latency
/// metadata.
///
/// Partial segments may update live UI, but final segments are preferred for
/// answer generation so truncated fragments do not become primary questions.
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
    var asrSource: ASRSource?

    // ASR Latency (utterance-level, not session-level)
    var asrFirstPartialMS: Int?
    var asrFinalMS: Int?
    var asrBestSelectedMS: Int?
    var asrFinalizationReason: String?

    // Immutable ingress provenance for one recognition callback. These fields
    // stay in memory/trace only; no database schema change is required.
    var recognitionTaskID: String?
    var recognitionEventSequence: Int?
    var sourceTextStartUTF16: Int?
    var sourceTextEndUTF16: Int?
    var recognitionIsFinal: Bool?

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
        asrSource: ASRSource? = nil,
        asrFirstPartialMS: Int? = nil,
        asrFinalMS: Int? = nil,
        asrBestSelectedMS: Int? = nil,
        asrFinalizationReason: String? = nil,
        recognitionTaskID: String? = nil,
        recognitionEventSequence: Int? = nil,
        sourceTextStartUTF16: Int? = nil,
        sourceTextEndUTF16: Int? = nil,
        recognitionIsFinal: Bool? = nil
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
        self.asrSource = asrSource
        self.asrFirstPartialMS = asrFirstPartialMS
        self.asrFinalMS = asrFinalMS
        self.asrBestSelectedMS = asrBestSelectedMS
        self.asrFinalizationReason = asrFinalizationReason
        self.recognitionTaskID = recognitionTaskID
        self.recognitionEventSequence = recognitionEventSequence
        self.sourceTextStartUTF16 = sourceTextStartUTF16
        self.sourceTextEndUTF16 = sourceTextEndUTF16
        self.recognitionIsFinal = recognitionIsFinal
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
