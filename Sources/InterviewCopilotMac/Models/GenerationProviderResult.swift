// Provider output model for future generation-coordinator extraction.
// It represents parsed answer content and timing/status metadata only; AppState
// still decides whether a result may update current UI.

import Foundation

/// Coarse provider lifecycle status for one generation call.
enum GenerationProviderStatus: String, Codable, Equatable, Hashable {
    case completed
    case streaming
    case timedOut
    case cancelled
    case failed
}

/// Error category safe for diagnostics and tests.
enum GenerationProviderErrorClassification: String, Codable, Equatable, Hashable {
    case timeout
    case cancellation
    case jsonParsing
    case provider
    case network
    case unknown
}

/// Typed provider output for one answer-generation attempt.
///
/// This struct intentionally has no question-binding authority. A result must
/// still pass active generation and alignment checks before it becomes visible.
struct GenerationProviderResult: Equatable {
    let sayFirst: String
    let keyPoints: [String]
    let followUp: [String]
    let parsedSections: StreamingSuggestionSections?
    let latencyMS: Int?
    let firstTokenMS: Int?
    let firstVisibleMS: Int?
    let providerID: String
    let providerName: String
    let providerModel: String
    let providerKind: LLMProviderKind?
    let safeDiagnostics: [String: String]
    let providerStatus: GenerationProviderStatus
    let errorClassification: GenerationProviderErrorClassification?
    let errorMessage: String?

    init(
        sayFirst: String,
        keyPoints: [String],
        followUp: [String],
        parsedSections: StreamingSuggestionSections?,
        latencyMS: Int?,
        firstTokenMS: Int?,
        firstVisibleMS: Int?,
        providerID: String = "",
        providerName: String = "",
        providerModel: String = "",
        providerKind: LLMProviderKind? = nil,
        safeDiagnostics: [String: String] = [:],
        providerStatus: GenerationProviderStatus,
        errorClassification: GenerationProviderErrorClassification?,
        errorMessage: String? = nil
    ) {
        self.sayFirst = Self.redactSecrets(sayFirst)
        self.keyPoints = keyPoints.map(Self.redactSecrets)
        self.followUp = followUp.map(Self.redactSecrets)
        self.parsedSections = parsedSections.map {
            StreamingSuggestionSections(
                strategy: Self.redactSecrets($0.strategy),
                sayFirst: Self.redactSecrets($0.sayFirst),
                keyPoints: $0.keyPoints.map(Self.redactSecrets),
                followUpReady: $0.followUpReady.map(Self.redactSecrets),
                caution: Self.redactSecrets($0.caution)
            )
        }
        self.latencyMS = latencyMS
        self.firstTokenMS = firstTokenMS
        self.firstVisibleMS = firstVisibleMS
        self.providerID = Self.redactSecrets(providerID)
        self.providerName = Self.redactSecrets(providerName)
        self.providerModel = Self.redactSecrets(providerModel)
        self.providerKind = providerKind
        self.safeDiagnostics = safeDiagnostics.reduce(into: [:]) { result, item in
            result[Self.redactSecrets(item.key)] = Self.redactSecrets(item.value)
        }
        self.providerStatus = providerStatus
        self.errorClassification = errorClassification
        self.errorMessage = errorMessage.map(Self.redactSecrets)
    }

    static func redactSecrets(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_\-]{20,}"#,
                with: "[REDACTED_API_KEY]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(api[_ -]?key\s*[:=]\s*)[A-Za-z0-9_\-]{12,}"#,
                with: "$1[REDACTED_API_KEY]",
                options: .regularExpression
            )
    }
}
