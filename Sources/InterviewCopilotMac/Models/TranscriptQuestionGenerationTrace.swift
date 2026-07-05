import Foundation

/// Diagnostic trace connecting one transcript segment to question detection and
/// generation decisions.
///
/// This is for readiness/diagnostics only; product UI should translate these
/// fields into simple states such as Ready, Listening, or Needs Attention.
struct TranscriptQuestionGenerationTrace: Equatable {
    var transcriptSegmentID: String = ""
    var source: String = ""
    var asrSource: String = ""
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
    var firstQuestionSuppressedReason: String = ""
    var providerStatus: String = ""
    var visibleSuggestionCreated: Bool = false
    var currentGenerationState: String = ""
    var currentSuggestionExists: Bool = false

    // Diagnostics for partial-to-final ASR question transition
    var acceptedFromPartial: Bool = false
    var supersededByFinal: Bool = false
    var partialToFinalDeltaMs: Int?

    static let empty = TranscriptQuestionGenerationTrace()
}
