import Foundation

public enum DeepSeekModel: String, CaseIterable, Identifiable, Codable {
    case realtime = "deepseek-v4-flash"
    case analysis = "deepseek-v4-pro"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime:
            return "deepseek-v4-flash"
        case .analysis:
            return "deepseek-v4-pro"
        }
    }
}

public enum AudioCaptureMode: String, CaseIterable, Identifiable, Codable {
    case microphoneOnly = "microphoneOnly"
    case systemAudioOnly = "systemAudioOnly"
    case microphoneAndSystem = "microphoneAndSystem"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphoneOnly:
            return "Microphone Only (Candidate Only)"
        case .systemAudioOnly:
            return "System Audio Only (Interviewer Only)"
        case .microphoneAndSystem:
            return "Microphone + System Audio (Recommended)"
        }
    }
}

public struct AppSettings: Hashable, Codable {
    public var realtimeModel: DeepSeekModel
    public var recapModel: DeepSeekModel
    public var automaticQuestionDetectionEnabled: Bool
    public var manualOnlyMode: Bool
    public var saveTranscriptsLocally: Bool
    public var allowQuestionDetectionFromMicrophoneOnly: Bool
    public var audioCaptureMode: AudioCaptureMode
    public var floatingWindowOpacity: Double
    public var compactMode: Bool
    public var highContrastFloatingPanel: Bool

    public static let `default` = AppSettings(
        realtimeModel: .realtime,
        recapModel: .analysis,
        automaticQuestionDetectionEnabled: true,
        manualOnlyMode: false,
        saveTranscriptsLocally: true,
        allowQuestionDetectionFromMicrophoneOnly: false,
        audioCaptureMode: .microphoneAndSystem,
        floatingWindowOpacity: 0.82,
        compactMode: false,
        highContrastFloatingPanel: false
    )

    enum CodingKeys: String, CodingKey {
        case realtimeModel
        case recapModel
        case automaticQuestionDetectionEnabled
        case manualOnlyMode
        case saveTranscriptsLocally
        case allowQuestionDetectionFromMicrophoneOnly
        case audioCaptureMode
        case floatingWindowOpacity
        case compactMode
        case highContrastFloatingPanel
    }

    public init(
        realtimeModel: DeepSeekModel,
        recapModel: DeepSeekModel,
        automaticQuestionDetectionEnabled: Bool,
        manualOnlyMode: Bool,
        saveTranscriptsLocally: Bool,
        allowQuestionDetectionFromMicrophoneOnly: Bool,
        audioCaptureMode: AudioCaptureMode,
        floatingWindowOpacity: Double,
        compactMode: Bool,
        highContrastFloatingPanel: Bool
    ) {
        self.realtimeModel = realtimeModel
        self.recapModel = recapModel
        self.automaticQuestionDetectionEnabled = automaticQuestionDetectionEnabled
        self.manualOnlyMode = manualOnlyMode
        self.saveTranscriptsLocally = saveTranscriptsLocally
        self.allowQuestionDetectionFromMicrophoneOnly = allowQuestionDetectionFromMicrophoneOnly
        self.audioCaptureMode = audioCaptureMode
        self.floatingWindowOpacity = floatingWindowOpacity
        self.compactMode = compactMode
        self.highContrastFloatingPanel = highContrastFloatingPanel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.realtimeModel = try container.decodeIfPresent(DeepSeekModel.self, forKey: .realtimeModel) ?? .realtime
        self.recapModel = try container.decodeIfPresent(DeepSeekModel.self, forKey: .recapModel) ?? .analysis
        self.automaticQuestionDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticQuestionDetectionEnabled) ?? true
        self.manualOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .manualOnlyMode) ?? false
        self.saveTranscriptsLocally = try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptsLocally) ?? true
        self.allowQuestionDetectionFromMicrophoneOnly = try container.decodeIfPresent(Bool.self, forKey: .allowQuestionDetectionFromMicrophoneOnly) ?? false
        self.audioCaptureMode = try container.decodeIfPresent(AudioCaptureMode.self, forKey: .audioCaptureMode) ?? .microphoneAndSystem
        self.floatingWindowOpacity = try container.decodeIfPresent(Double.self, forKey: .floatingWindowOpacity) ?? 0.82
        self.compactMode = try container.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        self.highContrastFloatingPanel = try container.decodeIfPresent(Bool.self, forKey: .highContrastFloatingPanel) ?? false
    }
}
