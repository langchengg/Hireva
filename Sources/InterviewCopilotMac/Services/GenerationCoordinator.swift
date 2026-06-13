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

    /// Interprets one Stage B result without applying it.
    ///
    /// AppState still owns active generation checks, UI mutation, task cleanup,
    /// fallback application, and persistence. This method only turns provider
    /// output plus the currently visible answer into a typed decision.
    func interpretStageBResult(
        generationID: String,
        detectedQuestionID: String?,
        activeGenerationID: String?,
        questionText: String,
        providerResult: GenerationProviderResult?,
        sections: StreamingSuggestionSections?,
        sawStreamingSections: Bool,
        visibleSayFirst: String?,
        visibleAnswerExists: Bool
    ) -> GenerationStageBResult {
        if activeGenerationID != generationID {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: .discardStaleResult,
                classification: .staleResult,
                fallbackReason: "Stage B result belongs to an inactive generation.",
                questionText: questionText,
                alignmentResult: nil
            )
        }

        let providerStatus = providerResult?.providerStatus
        let visibleAnswerIsUsable = Self.isVisibleAnswerUsable(
            visibleSayFirst,
            questionText: questionText,
            visibleAnswerExists: visibleAnswerExists
        )

        if providerStatus == .timedOut {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .timedOut,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B timed out before producing an aligned visible answer.",
                questionText: questionText,
                alignmentResult: nil
            )
        }

        if providerStatus == .failed || providerStatus == .cancelled {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .providerFailure,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B provider failed before producing an aligned visible answer.",
                questionText: questionText,
                alignmentResult: nil
            )
        }

        let hasSections = sawStreamingSections || sections?.hasVisibleContent == true
        guard hasSections, let sections else {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: visibleAnswerIsUsable ? .keepFirstVisibleAnswer : .useSemanticFallback,
                classification: .noSections,
                fallbackReason: visibleAnswerIsUsable ? nil : "Stage B completed without usable sections.",
                questionText: questionText,
                alignmentResult: nil
            )
        }

        let alignment = Self.evaluateStageBSections(sections, questionText: questionText)
        if alignment.verdict == .mismatched {
            return makeStageBDecision(
                generationID: generationID,
                detectedQuestionID: detectedQuestionID,
                providerResult: providerResult,
                decision: .useSemanticFallback,
                classification: .fallbackRequired,
                fallbackReason: alignment.reason,
                questionText: questionText,
                alignmentResult: alignment
            )
        }

        return makeStageBDecision(
            generationID: generationID,
            detectedQuestionID: detectedQuestionID,
            providerResult: providerResult,
            decision: .applyFullCard,
            classification: .usableFullCard,
            fallbackReason: nil,
            questionText: questionText,
            alignmentResult: alignment
        )
    }

    /// Converts an interpreted Stage B result into an application plan.
    ///
    /// This is a pure planning boundary. It does not mutate UI, persist cards,
    /// register/cancel tasks, start provider work, read Keychain, or inspect
    /// audio/transcript state.
    func makeStageBApplicationPlan(
        from result: GenerationStageBResult,
        visibleSuggestion: SuggestionCard?,
        activeGenerationID: String?,
        activeQuestionID: String?
    ) -> StageBApplicationPlan {
        let isStale = result.generationID != activeGenerationID ||
            (result.detectedQuestionID != nil &&
             activeQuestionID != nil &&
             result.detectedQuestionID != activeQuestionID)

        var diagnostics = result.safeDiagnostics.reduce(into: [String: String]()) { output, item in
            output[GenerationProviderResult.redactSecrets(item.key)] = GenerationProviderResult.redactSecrets(item.value)
        }
        diagnostics["applicationPlanSource"] = "GenerationCoordinator"
        diagnostics["generationID"] = GenerationProviderResult.redactSecrets(result.generationID)
        diagnostics["detectedQuestionID"] = GenerationProviderResult.redactSecrets(result.detectedQuestionID ?? "")
        diagnostics["activeGenerationMatches"] = isStale ? "false" : "true"
        diagnostics["visibleAnswerExists"] = visibleSuggestion == nil ? "false" : "true"

        if isStale || result.decision == .discardStaleResult {
            diagnostics["stageBApplicationAction"] = StageBApplicationAction.discardStaleResult.rawValue
            return StageBApplicationPlan(
                generationID: result.generationID,
                detectedQuestionID: result.detectedQuestionID,
                action: .discardStaleResult,
                fallbackReason: result.fallbackReason ?? "Stage B result belongs to an inactive generation.",
                shouldPersist: false,
                shouldUpdateVisibleCard: false,
                safeDiagnostics: diagnostics
            )
        }

        let action: StageBApplicationAction
        switch result.decision {
        case .applyFullCard:
            action = .applyFullCard
        case .keepFirstVisibleAnswer:
            action = .keepVisibleFirstAnswer
        case .useSemanticFallback:
            action = .useSemanticFallback
        case .discardStaleResult:
            action = .discardStaleResult
        case .providerFailed:
            action = .markProviderFailed
        }
        diagnostics["stageBApplicationAction"] = action.rawValue

        return StageBApplicationPlan(
            generationID: result.generationID,
            detectedQuestionID: result.detectedQuestionID,
            action: action,
            fallbackReason: result.fallbackReason,
            shouldPersist: Self.shouldPersistStageBPlan(action: action, visibleSuggestion: visibleSuggestion),
            shouldUpdateVisibleCard: Self.shouldUpdateVisibleCard(action: action),
            safeDiagnostics: diagnostics
        )
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

    private func makeStageBDecision(
        generationID: String,
        detectedQuestionID: String?,
        providerResult: GenerationProviderResult?,
        decision: StageBDecision,
        classification: StageBResultClassification,
        fallbackReason: String?,
        questionText: String,
        alignmentResult: AnswerAlignmentResult?
    ) -> GenerationStageBResult {
        var diagnostics = providerResult?.safeDiagnostics ?? [:]
        diagnostics["stageBDecision"] = decision.rawValue
        diagnostics["stageBClassification"] = classification.rawValue
        diagnostics["providerStatus"] = providerResult?.providerStatus.rawValue ?? "streaming"
        diagnostics["questionIntent"] = AnswerRelevancePolicy.intent(for: questionText).rawValue
        if let fallbackReason, !fallbackReason.isEmpty {
            diagnostics["fallbackReason"] = fallbackReason
        }
        if let alignmentResult {
            diagnostics["alignmentVerdict"] = alignmentResult.verdict.rawValue
            diagnostics["alignmentReason"] = alignmentResult.reason
        }

        return GenerationStageBResult(
            generationID: generationID,
            detectedQuestionID: detectedQuestionID,
            providerResult: providerResult,
            decision: decision,
            classification: classification,
            fallbackReason: fallbackReason,
            safeDiagnostics: diagnostics,
            alignmentResult: alignmentResult
        )
    }

    private static func isVisibleAnswerUsable(
        _ visibleSayFirst: String?,
        questionText: String,
        visibleAnswerExists: Bool
    ) -> Bool {
        guard visibleAnswerExists,
              let visibleSayFirst,
              !visibleSayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: visibleSayFirst,
            sayFirst: visibleSayFirst,
            stageBCompleted: false
        )
        return alignment.verdict == .aligned || alignment.verdict == .weaklyAligned
    }

    private static func evaluateStageBSections(
        _ sections: StreamingSuggestionSections,
        questionText: String
    ) -> AnswerAlignmentResult {
        let answerText = ([sections.sayFirst] + sections.keyPoints + sections.followUpReady)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: questionText,
            answerText: answerText,
            sayFirst: sections.sayFirst,
            stageBCompleted: true
        )
    }

    private static func shouldPersistStageBPlan(
        action: StageBApplicationAction,
        visibleSuggestion: SuggestionCard?
    ) -> Bool {
        switch action {
        case .applyFullCard, .useSemanticFallback:
            return true
        case .keepVisibleFirstAnswer, .markProviderFailed:
            return visibleSuggestion != nil
        case .discardStaleResult:
            return false
        }
    }

    private static func shouldUpdateVisibleCard(action: StageBApplicationAction) -> Bool {
        switch action {
        case .applyFullCard, .useSemanticFallback, .markProviderFailed:
            return true
        case .keepVisibleFirstAnswer, .discardStaleResult:
            return false
        }
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
