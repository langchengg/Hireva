import Foundation

struct DeveloperDiagnostics: Hashable {
    var liveState: LiveInterviewState
    var lastAPILatencyMS: Int?
    var lastDetectedQuestionJSON: String?
    var lastSuggestionJSON: String?
    var lastError: String?
    var apiCallCount: Int
    var lastProviderName: String?
    var lastProviderModel: String?

    static let empty = DeveloperDiagnostics(
        liveState: .idle,
        lastAPILatencyMS: nil,
        lastDetectedQuestionJSON: nil,
        lastSuggestionJSON: nil,
        lastError: nil,
        apiCallCount: 0,
        lastProviderName: nil,
        lastProviderModel: nil
    )
}
