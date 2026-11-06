// Handles document-context retrieval setup, RAG cache keys, and embedding
// provider resolution.
// RAG here is supporting evidence only: it must never override the current
// detected question or change generation ownership.

import Foundation

extension AppState {
    // MARK: - Realtime Context Selection

    // Compatibility for existing key consumers; the cache owner defines it.
    func ragPrecomputeCacheKey(segmentID: String, questionText: String,
        intent: AnswerRelevanceIntent) -> String {
        LiveRAGPrefetch.cacheKey(contextID: activeContextSnapshot?.id ?? currentSession?.contextSnapshotID ?? "legacy-context",
            segmentID: segmentID, questionText: questionText, intent: intent)
    }

    // internal for AppState extension access only
    func trimContextForRealtime(_ context: RetrievedContext, question: DetectedQuestion) -> RetrievedContext {
        // Intent-specific trimming keeps high-signal project chunks near the
        // prompt while preserving the invariant that the current question, not
        // retrieved text, defines what must be answered.
        let budgeted = RealtimePromptBudgeter.trim(
            context,
            question: question.questionText,
            intent: question.intent,
            strategy: question.answerStrategy
        )
        return AnswerRelevancePolicy.filterContext(
            budgeted,
            intent: AnswerRelevancePolicy.intent(for: question.questionText)
        )
    }

    // internal for AppState extension access only
    func makeCompactSummary(_ doc: DocumentRecord?) -> String {
        guard let doc = doc else { return "None provided." }
        let title = doc.title
        let cleanContent = doc.content.replacingOccurrences(of: "\n", with: " ")
        let excerpt = cleanContent.prefix(250)
        return "Title: \(title) | Excerpt: \(excerpt)..."
    }

    // MARK: - Embedding Providers

    func resolveEmbeddingProvider(settings snapshot: AppSettings? = nil) -> EmbeddingProvider? {
        let settings = snapshot ?? self.settings
        if let resolve = embeddingProviderResolverOverride { return resolve(settings) }
        let kind = settings.embeddingProviderKind
        let model = settings.embeddingModelName
        let timeout = TimeInterval(settings.embeddingTimeoutSeconds)
        switch kind {
        case .openAICompatibleCloud:
            guard keychainService.hasAPIKey(account: settings.embeddingApiKeyAccount) else {
                recordEmbeddingResolutionError("Keyword RAG ready; vector embeddings not configured.")
                return nil
            }
            return CloudEmbeddingProvider(
                providerID: currentEmbeddingProviderID(for: settings),
                displayName: "Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: model,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychainService,
                timeoutInterval: timeout
            )
        case .customCloud:
            guard keychainService.hasAPIKey(account: settings.embeddingApiKeyAccount) else {
                recordEmbeddingResolutionError("Keyword RAG ready; vector embeddings not configured.")
                return nil
            }
            return CloudEmbeddingProvider(
                providerID: currentEmbeddingProviderID(for: settings),
                displayName: "Custom Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: model,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychainService,
                timeoutInterval: timeout
            )
        case .localOllama:
            recordEmbeddingResolutionError("Local embeddings are disabled. Please choose a cloud embedding provider.")
            return nil
        case .disabled:
            recordEmbeddingResolutionError("Keyword RAG ready; vector embeddings not configured.")
            return nil
        case .mock:
            return ControlledMockEmbeddingProvider()
        }
    }

    private func recordEmbeddingResolutionError(_ message: String) {
        lastEmbeddingError = message
    }

    @discardableResult
    func triggerEmbeddingGeneration(for type: DocumentType) -> Task<Void, Never>? {
        documentsState.embeddings.generateAutomatically(type: type)
    }

    func rebuildAllEmbeddings() { documentsState.embeddings.rebuildAll() }
    func currentEmbeddingProviderID(for settings: AppSettings) -> String {
        DocumentEmbeddingState.providerID(for: settings)
    }
    func cancelEmbeddingRebuild() { documentsState.embeddings.cancelRebuild() }
    func rebuildCleanRAGIndex() { documentsState.rebuildCleanIndex() }

    @discardableResult
    public func refreshLatencyAverages() -> Task<Void, Never>? {
        guard !isShuttingDown else { return nil }
        markSQLiteOperation("Refreshing latency averages in background")
        return diagnosticsState.refreshLatencyAverages { [weak self] status in
            guard let self, !self.isShuttingDown else { return }
            self.lastSQLiteOperation = status
        }
    }
}
