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
    var rawTranscript: String?
    var cleanedQuestion: String?
    var lastRetrievalTrace: RetrievalTrace?
    var storedCVChunkCount: Int
    var storedJDChunkCount: Int

    static let empty = DeveloperDiagnostics(
        liveState: .idle,
        lastAPILatencyMS: nil,
        lastDetectedQuestionJSON: nil,
        lastSuggestionJSON: nil,
        lastError: nil,
        apiCallCount: 0,
        lastProviderName: nil,
        lastProviderModel: nil,
        rawTranscript: nil,
        cleanedQuestion: nil,
        lastRetrievalTrace: nil,
        storedCVChunkCount: 0,
        storedJDChunkCount: 0
    )
}
