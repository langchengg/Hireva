import Foundation

/// Compatibility boundary for call sites that have not supplied a context
/// snapshot. Candidate answers must never be synthesized without evidence.
enum ProjectGroundedFallbackPolicy {
    static func fallbackAnswer(for question: DetectedQuestion) -> IntentFallbackAnswer {
        IntentFallbackAnswer(sayFirst: "", keyPoints: [])
    }
}
