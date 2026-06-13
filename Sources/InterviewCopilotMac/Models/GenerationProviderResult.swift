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
    let providerStatus: GenerationProviderStatus
    let errorClassification: GenerationProviderErrorClassification?
}
