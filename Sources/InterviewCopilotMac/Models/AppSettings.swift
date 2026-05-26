import Foundation

enum DeepSeekModel: String, CaseIterable, Identifiable, Codable {
    case realtime = "deepseek-v4-flash"
    case analysis = "deepseek-v4-pro"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtime:
            return "deepseek-v4-flash"
        case .analysis:
            return "deepseek-v4-pro"
        }
    }
}

struct AppSettings: Hashable, Codable {
    var realtimeModel: DeepSeekModel
    var recapModel: DeepSeekModel
    var automaticQuestionDetectionEnabled: Bool
    var manualOnlyMode: Bool
    var saveTranscriptsLocally: Bool

    static let `default` = AppSettings(
        realtimeModel: .realtime,
        recapModel: .analysis,
        automaticQuestionDetectionEnabled: true,
        manualOnlyMode: false,
        saveTranscriptsLocally: true
    )
}
