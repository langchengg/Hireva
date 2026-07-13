import Foundation
import GRDB

public struct CleanRAGMaintenanceResult: Equatable {
    public let documentsRebuilt: Int
    public let chunksRebuilt: Int
    public let embeddingsUpdated: Int
    public let embeddingErrors: [String]
    public let sanitizedRetrievedSources: Int
    public let sanitizedSuggestionCards: Int
    public let pollutedChunkCount: Int
    public let pollutedRetrievedSourceCount: Int
    public let pollutedSuggestionCardCount: Int
}

public enum HirevaMaintenance {
    public static func rebuildCleanRAGIndex(regenerateEmbeddings: Bool = true) async throws -> CleanRAGMaintenanceResult {
        let database = try AppDatabase(path: AppPaths.databaseURL)
        let documents = DocumentRepository(database: database)
        let rebuild = try documents.rebuildCleanRAGIndex()

        var embeddingsUpdated = 0
        var embeddingErrors: [String] = []

        if regenerateEmbeddings {
            let settingsRepository = SettingsRepository(database: database)
            let settings = try settingsRepository.loadSettings()
            _ = (try? settingsRepository.ensureDefaultProviderConfigurations()) ?? []

            if let provider = makeEmbeddingProvider(settings: settings) {
                do {
                    let dimension = try await provider.dimension
                    let chunks = try documents.allChunks()

                    for chunk in chunks {
                        do {
                            let embedding = try await provider.embed(text: chunk.content)
                            let hash = documents.calculateContentHash(
                                content: chunk.content,
                                sectionTitle: chunk.sectionTitle,
                                provider: provider.providerID,
                                modelName: provider.modelName,
                                dimension: dimension
                            )
                            try documents.updateChunkEmbedding(
                                chunkID: chunk.id,
                                embedding: embedding,
                                model: provider.modelName,
                                provider: provider.providerID,
                                dimension: dimension,
                                contentHash: hash
                            )
                            embeddingsUpdated += 1
                        } catch {
                            embeddingErrors.append("Chunk \(chunk.id): \(error.localizedDescription)")
                        }
                    }
                } catch {
                    embeddingErrors.append(error.localizedDescription)
                }
            } else {
                embeddingErrors.append("Keyword RAG ready; vector embeddings not configured.")
            }
        }

        let artifactRepair = try sanitizeHistoricalRAGArtifacts(database: database)

        let pollutedCount = try await database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM document_chunks
                WHERE content LIKE '%documentclass%'
                   OR content LIKE '%usepackage%'
                   OR content LIKE '%geometry%'
                   OR content LIKE '%begin{document}%'
                """
            ) ?? 0
        }

        return CleanRAGMaintenanceResult(
            documentsRebuilt: rebuild.documentsRebuilt,
            chunksRebuilt: rebuild.chunksRebuilt,
            embeddingsUpdated: embeddingsUpdated,
            embeddingErrors: embeddingErrors,
            sanitizedRetrievedSources: artifactRepair.sources,
            sanitizedSuggestionCards: artifactRepair.cards,
            pollutedChunkCount: pollutedCount,
            pollutedRetrievedSourceCount: artifactRepair.pollutedSources,
            pollutedSuggestionCardCount: artifactRepair.pollutedCards
        )
    }

    private static func sanitizeHistoricalRAGArtifacts(database: AppDatabase) throws -> (
        sources: Int,
        cards: Int,
        pollutedSources: Int,
        pollutedCards: Int
    ) {
        try database.dbQueue.write { db in
            var sanitizedSources = 0
            let sourceRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, content_preview, full_content
                FROM suggestion_card_retrieved_chunks
                WHERE content_preview LIKE '%documentclass%'
                   OR content_preview LIKE '%usepackage%'
                   OR content_preview LIKE '%geometry%'
                   OR content_preview LIKE '%begin{document}%'
                   OR full_content LIKE '%documentclass%'
                   OR full_content LIKE '%usepackage%'
                   OR full_content LIKE '%geometry%'
                   OR full_content LIKE '%begin{document}%'
                   OR content_preview LIKE '%---%'
                   OR full_content LIKE '%---%'
                """
            )

            for row in sourceRows {
                let id: String = row["id"]
                let preview: String = row["content_preview"]
                let fullContent: String = row["full_content"]
                let sanitizedFull = sanitizeVisibleText(fullContent, preserveOriginalWhenEmpty: false)
                let sanitizedPreview = String(sanitizeVisibleText(preview, preserveOriginalWhenEmpty: false).prefix(200))
                try db.execute(
                    sql: """
                    UPDATE suggestion_card_retrieved_chunks
                    SET content_preview = ?, full_content = ?
                    WHERE id = ?
                    """,
                    arguments: [sanitizedPreview, sanitizedFull, id]
                )
                sanitizedSources += 1
            }

            var sanitizedCards = 0
            let cardRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, say_first, key_points_json, follow_up_ready_json, caution, evidence_used_json
                FROM suggestion_cards
                WHERE say_first LIKE '%documentclass%'
                   OR say_first LIKE '%usepackage%'
                   OR say_first LIKE '%geometry%'
                   OR say_first LIKE '%begin{document}%'
                   OR say_first LIKE '%---%'
                   OR key_points_json LIKE '%documentclass%'
                   OR key_points_json LIKE '%usepackage%'
                   OR key_points_json LIKE '%geometry%'
                   OR key_points_json LIKE '%begin{document}%'
                   OR follow_up_ready_json LIKE '%documentclass%'
                   OR follow_up_ready_json LIKE '%usepackage%'
                   OR follow_up_ready_json LIKE '%geometry%'
                   OR follow_up_ready_json LIKE '%begin{document}%'
                   OR caution LIKE '%documentclass%'
                   OR caution LIKE '%usepackage%'
                   OR caution LIKE '%geometry%'
                   OR caution LIKE '%begin{document}%'
                """
            )

            for row in cardRows {
                let id: String = row["id"]
                let sayFirst: String = row["say_first"]
                let keyPointsJSON: String = row["key_points_json"]
                let followUpJSON: String = row["follow_up_ready_json"]
                let caution: String? = row["caution"]
                let evidenceJSON: String? = row["evidence_used_json"]

                try db.execute(
                    sql: """
                    UPDATE suggestion_cards
                    SET say_first = ?,
                        key_points_json = ?,
                        follow_up_ready_json = ?,
                        caution = ?,
                        evidence_used_json = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        sanitizeVisibleText(sayFirst),
                        sanitizeJSONStringArray(keyPointsJSON),
                        sanitizeJSONStringArray(followUpJSON),
                        caution.map { sanitizeVisibleText($0) },
                        evidenceJSON.map(sanitizeJSONStringArray),
                        id
                    ]
                )
                sanitizedCards += 1
            }

            let pollutedSources = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM suggestion_card_retrieved_chunks
                WHERE is_included = 1
                  AND (
                    content_preview LIKE '%documentclass%'
                    OR content_preview LIKE '%usepackage%'
                    OR content_preview LIKE '%geometry%'
                    OR content_preview LIKE '%begin{document}%'
                    OR full_content LIKE '%documentclass%'
                    OR full_content LIKE '%usepackage%'
                    OR full_content LIKE '%geometry%'
                    OR full_content LIKE '%begin{document}%'
                  )
                """
            ) ?? 0

            let pollutedCards = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM suggestion_cards
                WHERE say_first LIKE '%documentclass%'
                   OR say_first LIKE '%usepackage%'
                   OR say_first LIKE '%geometry%'
                   OR say_first LIKE '%begin{document}%'
                   OR key_points_json LIKE '%documentclass%'
                   OR key_points_json LIKE '%usepackage%'
                   OR key_points_json LIKE '%geometry%'
                   OR key_points_json LIKE '%begin{document}%'
                   OR follow_up_ready_json LIKE '%documentclass%'
                   OR follow_up_ready_json LIKE '%usepackage%'
                   OR follow_up_ready_json LIKE '%geometry%'
                   OR follow_up_ready_json LIKE '%begin{document}%'
                   OR caution LIKE '%documentclass%'
                   OR caution LIKE '%usepackage%'
                   OR caution LIKE '%geometry%'
                   OR caution LIKE '%begin{document}%'
                """
            ) ?? 0

            return (sanitizedSources, sanitizedCards, pollutedSources, pollutedCards)
        }
    }

    private static func sanitizeVisibleText(_ value: String, preserveOriginalWhenEmpty: Bool = true) -> String {
        let sanitized = DocumentTextSanitizer.sanitize(value).sanitizedContent
        return sanitized.isEmpty && preserveOriginalWhenEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : sanitized
    }

    private static func sanitizeJSONStringArray(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return value
        }
        let sanitized = decoded.map { sanitizeVisibleText($0) }
        return JSONParsing.jsonString(sanitized)
    }

    private static func makeEmbeddingProvider(
        settings: AppSettings
    ) -> EmbeddingProvider? {
        switch settings.embeddingProviderKind {
        case .openAICompatibleCloud:
            let keychain = KeychainService()
            guard keychain.hasAPIKey(account: settings.embeddingApiKeyAccount) else { return nil }
            return CloudEmbeddingProvider(
                providerID: "cloudOpenAICompatible",
                displayName: "Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: settings.embeddingModelName,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychain,
                timeoutInterval: TimeInterval(settings.embeddingTimeoutSeconds)
            )
        case .customCloud:
            let keychain = KeychainService()
            guard keychain.hasAPIKey(account: settings.embeddingApiKeyAccount) else { return nil }
            return CloudEmbeddingProvider(
                providerID: "cloudCustom",
                displayName: "Custom Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: settings.embeddingModelName,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychain,
                timeoutInterval: TimeInterval(settings.embeddingTimeoutSeconds)
            )
        case .mock:
            return ControlledMockEmbeddingProvider()
        case .disabled, .localOllama:
            return nil
        }
    }
}
