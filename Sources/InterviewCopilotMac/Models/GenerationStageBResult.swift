// Typed decision model for Stage B result interpretation.
// This is data only: AppState remains responsible for applying decisions to
// current UI state, task state, and persistence.

import Foundation

/// Coarse classification of the Stage B output before AppState applies it.
enum StageBResultClassification: String, Codable, Equatable, Hashable {
    case usableFullCard
    case noSections
    case timedOut
    case providerFailure
    case staleResult
    case fallbackRequired
}

/// Decision AppState should apply after interpreting one Stage B result.
enum StageBDecision: String, Codable, Equatable, Hashable {
    case applyFullCard
    case keepFirstVisibleAnswer
    case useSemanticFallback
    case discardStaleResult
    case providerFailed
}

/// Pure Stage B decision output.
///
/// The decision has no authority to mutate UI or persistence. It only explains
/// how the already-owned AppState generation lifecycle should treat a result.
struct GenerationStageBResult: Equatable {
    let generationID: String
    let detectedQuestionID: String?
    let providerResult: GenerationProviderResult?
    let decision: StageBDecision
    let classification: StageBResultClassification
    let fallbackReason: String?
    let safeDiagnostics: [String: String]
    let alignmentResult: AnswerAlignmentResult?
}
