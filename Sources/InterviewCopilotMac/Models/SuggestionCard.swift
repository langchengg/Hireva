import Foundation

struct SuggestionCard: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var questionID: String?
    var strategy: String
    var sayFirst: String
    var keyPoints: [String]
    var followUpReady: [String]
    var confidence: Double?
    var caution: String?
    var evidenceUsed: [String]
    var riskLevel: RiskLevel?
    var modelName: String
    var promptVersion: String
    var providerKind: LLMProviderKind? = nil
    var providerName: String? = nil
    var providerBaseURL: String? = nil
    var latencyMS: Int? = nil
    var isLocal: Bool = false
    var rawJSON: String?
    var createdAt: Date

    // Question-answer binding metadata. questionID remains the legacy storage
    // name; detectedQuestionID is the explicit product term for the same ID.
    var questionText: String? = nil
    var transcriptSegmentID: String? = nil
    var generationID: String? = nil
    var source: String? = nil
    var speaker: String? = nil
    var triggerPath: GenerationTriggerPath? = nil
    var alignmentScore: Double? = nil
    var alignmentVerdict: AnswerAlignmentVerdict? = nil
    var questionIntent: AnswerRelevanceIntent? = nil
    var answerIntent: AnswerRelevanceIntent? = nil
    var promptQuestionText: String? = nil
    var promptPrimaryQuestion: String? = nil
    var promptContainsPreviousQuestion: Bool? = nil
    var previousQuestionIncluded: Bool? = nil
    var previousQuestionText: String? = nil
    var contextBleedRisk: ContextBleedRisk? = nil
    var ragChunkIDs: [String] = []
    var ragChunkIntents: [AnswerRelevanceIntent] = []
    var firstQuestionSuppressedReason: String? = nil
    var promptTokenEstimate: Int? = nil
    var promptContextPreview: String? = nil
    var mismatchReason: String? = nil

    var detectedQuestionID: String? {
        get { questionID }
        set { questionID = newValue }
    }

    // Streaming & Provenance
    var sayFirstSource: String? = nil
    var stageATimedOut: Bool? = nil
    var stageBCompleted: Bool? = nil
    var stageBStatus: String? = nil // skipped, cancelled, timed_out, completed
    var latencyFirstTokenMS: Int? = nil
    var latencyFirstVisibleMS: Int? = nil
    var latencyFullCardMS: Int? = nil

    // Soft Fallback & Advanced Telemetry
    var softFallbackUsed: Bool? = nil
    var softFallbackLatencyMS: Int? = nil
    var deepseekFirstTokenMS: Int? = nil
    var deepseekFirstVisibleMS: Int? = nil
    var finalVisibleSource: String? = nil

    // Pipeline Latency Metrics (v8)
    var ragRetrievalLatencyMS: Int? = nil
    var questionASRFirstPartialMS: Int? = nil
    var questionASRFinalMS: Int? = nil
    var questionASRBestSelectedMS: Int? = nil

    // Full visible-content latency metrics
    var firstVisibleAnswerMS: Int? = nil
    var firstKeyPointVisibleMS: Int? = nil
    var allKeyPointsVisibleMS: Int? = nil
    var followUpVisibleMS: Int? = nil
    var fullCardVisibleMS: Int? = nil
    var dbPersistedMS: Int? = nil
    var stageBStreamStartedMS: Int? = nil
    var stageBFirstSectionMS: Int? = nil

    // In-memory flag to prevent persisting partial ASR results to DB
    var isPartial: Bool = false
}

struct SuggestionCardPayload: Decodable {
    var strategy: String
    var sayFirst: String
    var keyPoints: [String]
    var followUpReady: [String]
    var confidence: Double
    var caution: String?
    var evidenceUsed: [String]?
    var riskLevel: RiskLevel?

    enum CodingKeys: String, CodingKey {
        case strategy
        case sayFirst = "say_first"
        case keyPoints = "key_points"
        case followUpReady = "follow_up_ready"
        case confidence
        case caution
        case evidenceUsed = "evidence_used"
        case riskLevel = "risk_level"
    }
}

enum RiskLevel: String, CaseIterable, Identifiable, Codable {
    case low
    case medium
    case high

    var id: String { rawValue }
}
