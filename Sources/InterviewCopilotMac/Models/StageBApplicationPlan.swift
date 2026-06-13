import Foundation

/// Side-effect-free plan for how AppState should apply one Stage B result.
///
/// This model deliberately carries only data. AppState remains responsible for
/// checking active tasks, mutating the visible card, updating generation state,
/// and persisting suggestions.
struct StageBApplicationPlan: Equatable {
    let generationID: String
    let detectedQuestionID: String?
    let action: StageBApplicationAction
    let fallbackReason: String?
    let shouldPersist: Bool
    let shouldUpdateVisibleCard: Bool
    let safeDiagnostics: [String: String]
}

enum StageBApplicationAction: String, Codable, Equatable, Hashable {
    case applyFullCard
    case keepVisibleFirstAnswer
    case useSemanticFallback
    case discardStaleResult
    case markProviderFailed
}
