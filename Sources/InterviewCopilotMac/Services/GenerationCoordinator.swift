// Skeleton service boundary for future generation orchestration.
// In Phase 2B/2C it contains dependencies and pure helpers only.
// It must not mutate AppState, own generation tasks, stream provider output, or
// persist suggestions until ownership is moved deliberately in a later phase.

import Foundation

/// Future home for generation orchestration that currently exposes only pure,
/// testable helpers and dependency wiring.
///
/// AppState remains the caller and lifecycle owner. Adding UI mutation,
/// cancellation, or task ownership here would be a behavior change.
final class GenerationCoordinator {
    /// Dependencies that can be passed to future coordinator operations without
    /// requiring an AppState instance.
    struct Dependencies {
        var suggestionGenerationService: SuggestionGenerationService?
        var delayProvider: DelayProvider

        init(
            suggestionGenerationService: SuggestionGenerationService? = nil,
            delayProvider: DelayProvider = RealDelayProvider()
        ) {
            self.suggestionGenerationService = suggestionGenerationService
            self.delayProvider = delayProvider
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    static func elapsedMS(since start: Date, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(start) * 1000)
    }

    static func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds)s"])
            }

            guard let result = try await group.next() else {
                throw NSError(domain: "TimeoutDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown error during race"])
            }
            group.cancelAll()
            return result
        }
    }

    static func isSpecificAnswer(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.count < 30 {
            return false
        }
        let genericPhrases = [
            "based on my experience",
            "i can speak to my background",
            "focus on explaining",
            "as a software engineer"
        ]
        for phrase in genericPhrases {
            if cleaned.contains(phrase) && cleaned.count < 80 {
                return false
            }
        }
        return true
    }
}
