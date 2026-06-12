import Foundation

extension AppState {
    private func normalizedTextHash(_ text: String) -> String {
        let clean = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(clean.hashValue)
    }

    // internal for AppState extension access only
    func ragPrecomputeCacheKey(
        segmentID: String,
        questionText: String,
        intent: AnswerRelevanceIntent
    ) -> String {
        let normalized = AnswerRelevancePolicy.normalizedQuestionText(for: questionText)
        return [segmentID, intent.rawValue, normalizedTextHash(normalized)].joined(separator: "_")
    }

    // internal for AppState extension access only
    func trimContextForRealtime(_ context: RetrievedContext, question: DetectedQuestion) -> RetrievedContext {
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

    func resolveEmbeddingProvider() -> EmbeddingProvider? {
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
        Task { @MainActor [weak self] in
            self?.lastEmbeddingError = message
        }
    }

    func triggerEmbeddingGeneration(for type: DocumentType) {
        guard settings.autoGenerateEmbeddingsOnDocumentSave else { return }
        guard let provider = resolveEmbeddingProvider() else { return }

        let providerID = provider.providerID
        let modelName = provider.modelName

        Task {
            do {
                let dim = try await provider.dimension
                let chunks = try documentRepository.chunks(type: type)

                for chunk in chunks {
                    let expectedHash = documentRepository.calculateContentHash(
                        content: chunk.content,
                        sectionTitle: chunk.sectionTitle,
                        provider: providerID,
                        modelName: modelName,
                        dimension: dim
                    )

                    if chunk.embeddingContentHash == expectedHash && chunk.embedding != nil {
                        continue
                    }

                    let vector = try await provider.embed(text: chunk.content)
                    try documentRepository.updateChunkEmbedding(
                        chunkID: chunk.id,
                        embedding: vector,
                        model: modelName,
                        provider: providerID,
                        dimension: dim,
                        contentHash: expectedHash
                    )
                }

                refreshAll()
            } catch {
                print("[AppState] Background embedding generation failed: \(error.localizedDescription)")
                showError("Background embedding generation failed: \(error.localizedDescription)")
            }
        }
    }

    func rebuildAllEmbeddings() {
        let actionID = ActionID.rebuildEmbeddings
        guard !isActionLoading(actionID) else { return }
        guard let provider = resolveEmbeddingProvider() else {
            isRebuildingEmbeddings = false
            rebuildProgress = 1.0
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            refreshAll()
            infoAction(actionID, title: "Keyword search ready", message: "Embedding provider not configured; keyword context is ready.")
            return
        }

        cancelEmbeddingRebuild()
        beginAction(actionID, title: "Rebuilding embeddings", message: "Preparing clean context chunks for cloud embeddings...")
        isRebuildingEmbeddings = true
        rebuildProgress = 0.0

        let providerID = provider.providerID
        let modelName = provider.modelName

        activeEmbeddingRebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dim = try await provider.dimension
                let all = try self.documentRepository.allChunks()

                if all.isEmpty {
                    await MainActor.run {
                        self.isRebuildingEmbeddings = false
                        self.rebuildProgress = 1.0
                        self.warnAction(actionID, title: "No chunks to embed", message: "Save documents or rebuild the clean context index first.")
                    }
                    return
                }

                for (index, chunk) in all.enumerated() {
                    if Task.isCancelled { break }

                    let expectedHash = self.documentRepository.calculateContentHash(
                        content: chunk.content,
                        sectionTitle: chunk.sectionTitle,
                        provider: providerID,
                        modelName: modelName,
                        dimension: dim
                    )

                    if chunk.embeddingContentHash == expectedHash && chunk.embedding != nil {
                        await MainActor.run {
                            self.rebuildProgress = Double(index + 1) / Double(all.count)
                        }
                        continue
                    }

                    do {
                        let vector = try await provider.embed(text: chunk.content)
                        try self.documentRepository.updateChunkEmbedding(
                            chunkID: chunk.id,
                            embedding: vector,
                            model: modelName,
                            provider: providerID,
                            dimension: dim,
                            contentHash: expectedHash
                        )
                    } catch {
                        print("[AppState] Failed to embed chunk \(chunk.id): \(error.localizedDescription)")
                    }

                    await MainActor.run {
                        self.rebuildProgress = Double(index + 1) / Double(all.count)
                    }
                }

                await MainActor.run {
                    self.isRebuildingEmbeddings = false
                    self.lastEmbeddingTestStatus = "Embedding rebuild complete."
                    self.refreshAll()
                    self.completeAction(actionID, title: "Embeddings rebuilt", message: "\(all.count) chunks checked for cloud embeddings.")
                }
            } catch {
                await MainActor.run {
                    self.isRebuildingEmbeddings = false
                    self.lastEmbeddingError = error.localizedDescription
                    let message = "Failed to rebuild embeddings: \(error.localizedDescription)"
                    self.failAction(actionID, title: "Embedding rebuild failed", message: message)
                    self.showError(message)
                }
            }
        }
    }

    // internal for AppState extension access only
    func currentEmbeddingProviderID(for settings: AppSettings) -> String {
        switch settings.embeddingProviderKind {
        case .openAICompatibleCloud:
            return "cloudOpenAICompatible"
        case .customCloud:
            return "cloudCustom"
        case .mock:
            return "controlled-mock"
        case .disabled:
            return "disabled"
        case .localOllama:
            return "legacyLocalProviderDisabled"
        }
    }

    func cancelEmbeddingRebuild() {
        activeEmbeddingRebuildTask?.cancel()
        activeEmbeddingRebuildTask = nil
        isRebuildingEmbeddings = false
        warnAction(ActionID.rebuildEmbeddings, title: "Embedding rebuild cancelled", message: "Existing context remains available.")
    }

    func rebuildCleanRAGIndex() {
        let actionID = ActionID.rebuildCleanRAG
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Rebuilding clean index", message: "Sanitizing documents and rebuilding chunks...")
        Task {
            do {
                let result = try documentRepository.rebuildCleanRAGIndex()
                await MainActor.run {
                    self.refreshAll()
                    let polluted = self.latexPollutedChunkCount
                    if self.settings.enableVectorRAG {
                        self.completeAction(actionID, title: "Clean index rebuilt", message: "\(result.chunksRebuilt) clean chunks ready. Updating embeddings next...")
                        self.rebuildAllEmbeddings()
                    } else {
                        self.completeAction(actionID, title: "Clean index rebuilt", message: "\(result.chunksRebuilt) clean chunks ready. \(polluted) LaTeX warnings remain.")
                    }
                }
            } catch {
                await MainActor.run {
                    let message = "Failed to rebuild clean RAG index: \(error.localizedDescription)"
                    self.failAction(actionID, title: "Rebuild failed", message: "Existing index preserved. \(message)")
                    self.showError(message)
                }
            }
        }
    }

    public func refreshLatencyAverages() {
        let repository = suggestionRepository
        markSQLiteOperation("Refreshing latency averages in background")
        Task.detached(priority: .utility) { [weak self] in
            do {
                let overall = try repository.fetchLatencyAverages(last: 10)
                let deepSeek = try repository.fetchLatencyAverages(last: 10, provider: "DeepSeek")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.latencyAveragesOverall = overall
                    self.latencyAveragesDeepSeek = deepSeek
                    self.lastSQLiteOperation = "Refreshed latency averages"
                }
            } catch {
                print("[AppState] Failed to refresh latency averages: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    self?.lastSQLiteOperation = "Latency averages refresh failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
