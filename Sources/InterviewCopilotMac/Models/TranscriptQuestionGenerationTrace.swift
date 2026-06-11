import Foundation

struct TranscriptQuestionGenerationTrace: Equatable {
    var transcriptSegmentID: String = ""
    var source: String = ""
    var speaker: String = ""
    var text: String = ""
    var isFinal: Bool = true
    var textLength: Int = 0
    var normalizedText: String = ""
    var extractedQuestionCount: Int = 0
    var extractedQuestionsPreview: [String] = []
    var questionCandidate: Bool = false
    var questionConfidence: Double = 0.0
    var questionIntent: String = ""
    var ignoredReason: String = ""
    var duplicateSuppressed: Bool = false
    var detectedQuestionID: String?
    var generationTriggered: Bool = false
    var generationID: String?
    var generationBlockedReason: String = ""
    var providerStatus: String = ""
    var visibleSuggestionCreated: Bool = false
    var currentGenerationState: String = ""
    var currentSuggestionExists: Bool = false

    static let empty = TranscriptQuestionGenerationTrace()
}
