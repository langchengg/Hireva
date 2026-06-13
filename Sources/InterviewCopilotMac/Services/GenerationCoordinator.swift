// Skeleton service boundary for future generation orchestration.
// In Phase 2D it also owns the provider-execution wrapper for typed
// request/result conversion only.
// It must not mutate AppState, own generation tasks, stream provider output, or
// persist suggestions until ownership is moved deliberately in a later phase.

import Foundation

/// Future home for generation orchestration that currently exposes pure helpers,
/// dependency wiring, and a provider-call execution boundary.
///
/// AppState remains the caller and lifecycle owner. Adding UI mutation,
/// cancellation, or task ownership here would be a behavior change.
final class GenerationCoordinator {
    struct ProviderExecutionFailure: LocalizedError, Equatable {
        let result: GenerationProviderResult

        var errorDescription: String? {
            result.errorMessage ?? "Provider request failed."
        }
    }

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

    /// Executes one non-streaming provider request and converts the result into
    /// the typed provider result model.
    ///
    /// This is intentionally not a lifecycle method. It does not register tasks,
    /// cancel other generations, mutate AppState, persist suggestions, or decide
    /// whether the result is still current for the UI.
    func executeProviderRequest(
        _ request: GenerationProviderRequest,
        question: DetectedQuestion,
        context: RetrievedContext,
        transcriptContext: String,
        sessionID: String,
        cvSummary: String,
        jdSummary: String,
        providerConfiguration: LLMProviderConfiguration? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async -> GenerationProviderResult {
        guard let suggestionGenerationService = dependencies.suggestionGenerationService else {
            return makeFailureResult(
                request: request,
                error: LLMProviderError.notConfigured("Suggestion generation service"),
                status: .failed
            )
        }

        do {
            let output = try await suggestionGenerationService.generateFullCard(
                question: question,
                context: context,
                transcriptContext: transcriptContext,
                sessionID: sessionID,
                cvSummary: cvSummary,
                jdSummary: jdSummary,
                customProviderConfig: providerConfiguration,
                timeoutInterval: timeoutInterval
            )
            let card = output.card
            let response = output.response
            let sections = StreamingSuggestionSections(
                strategy: card.strategy,
                sayFirst: card.sayFirst,
                keyPoints: card.keyPoints,
                followUpReady: card.followUpReady,
                caution: card.caution ?? ""
            )
            var diagnostics = request.safeDiagnostics
            diagnostics["providerName"] = response.providerName
            diagnostics["providerModel"] = response.modelName
            diagnostics["providerKind"] = response.providerKind.rawValue
            diagnostics["latencyMS"] = "\(response.latencyMS)"
            if let caution = card.caution, !caution.isEmpty {
                diagnostics["caution"] = caution
            }

            return GenerationProviderResult(
                sayFirst: card.sayFirst,
                keyPoints: card.keyPoints,
                followUp: card.followUpReady,
                parsedSections: sections,
                latencyMS: response.latencyMS,
                firstTokenMS: nil,
                firstVisibleMS: nil,
                providerID: request.providerID,
                providerName: response.providerName,
                providerModel: response.modelName,
                providerKind: response.providerKind,
                safeDiagnostics: diagnostics,
                providerStatus: .completed,
                errorClassification: nil,
                errorMessage: nil
            )
        } catch {
            return makeFailureResult(request: request, error: error)
        }
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

    private func makeFailureResult(
        request: GenerationProviderRequest,
        error: Error,
        status: GenerationProviderStatus? = nil
    ) -> GenerationProviderResult {
        let classification = Self.classifyProviderError(error)
        var diagnostics = request.safeDiagnostics
        diagnostics["errorClassification"] = classification.rawValue
        diagnostics["providerStatus"] = (status ?? Self.status(for: classification)).rawValue

        return GenerationProviderResult(
            sayFirst: "",
            keyPoints: [],
            followUp: [],
            parsedSections: nil,
            latencyMS: nil,
            firstTokenMS: nil,
            firstVisibleMS: nil,
            providerID: request.providerID,
            providerName: request.providerID,
            providerModel: request.model,
            providerKind: nil,
            safeDiagnostics: diagnostics,
            providerStatus: status ?? Self.status(for: classification),
            errorClassification: classification,
            errorMessage: error.localizedDescription
        )
    }

    static func classifyProviderError(_ error: Error) -> GenerationProviderErrorClassification {
        if error is CancellationError {
            return .cancellation
        }

        let nsError = error as NSError
        let message = error.localizedDescription.lowercased()
        if nsError.domain == "TimeoutDomain" || message.contains("timed out") || message.contains("timeout") {
            return .timeout
        }
        if message.contains("json") {
            return .jsonParsing
        }

        if let providerError = error as? LLMProviderError {
            switch providerError {
            case .networkFailure:
                return .network
            case .invalidResponse:
                return message.contains("json") ? .jsonParsing : .provider
            case .notConfigured,
                 .invalidBaseURL,
                 .missingAPIKey,
                 .modelNotFound,
                 .emptyResponse,
                 .rateLimited,
                 .invalidAPIKey,
                 .serverError:
                return .provider
            }
        }

        return .unknown
    }

    private static func status(for classification: GenerationProviderErrorClassification) -> GenerationProviderStatus {
        switch classification {
        case .timeout:
            return .timedOut
        case .cancellation:
            return .cancelled
        case .jsonParsing, .provider, .network, .unknown:
            return .failed
        }
    }
}
