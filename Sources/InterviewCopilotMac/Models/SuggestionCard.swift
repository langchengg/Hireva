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
