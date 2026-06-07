import Foundation
import GRDB
import Testing
@testable import InterviewCopilotMac

@Suite
struct RAGPhase3VerificationTests {
    @Test
    func cleanRAGRebuildWorksWithoutEmbeddings() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)

        _ = try documents.saveDocument(
            type: .cv,
            title: "LaTeX Resume",
            content: """
            \\documentclass{article}
            \\usepackage{geometry}
            \\begin{document}
            Robotics project: built VLA grasping and ROS2 control loops.
            \\end{document}
            """
        )

        let result = try documents.rebuildCleanRAGIndex()
        #expect(result.chunksRebuilt > 0)

        let pollutedCount = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM document_chunks
            WHERE content LIKE '%documentclass%'
               OR content LIKE '%usepackage%'
               OR content LIKE '%geometry%'
               OR content LIKE '%begin{document}%'
            """) ?? 0
        }
        #expect(pollutedCount == 0)

        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.embeddingProviderKind = .disabled

        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { nil }
        )

        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Tell me about your robotics project.",
            intent: .technical,
            maxCVWords: 150,
            maxJDWords: 150
        )

        #expect(trace.retrievalMode == "keywordOnly")
        #expect(trace.queryEmbeddingGenerated == false)
    }

    @Test
    func cleanRAGRebuildWithMockCloudEmbeddingsGivesHybridRetrieval() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)

        _ = try documents.saveDocument(
            type: .cv,
            title: "Robotics CV",
            content: """
            Vision-language-action robotic manipulation project using ROS2 and VLM grasp reranking.

            Database indexing project using SQLite query optimization.
            """
        )
        _ = try documents.saveDocument(
            type: .jobDescription,
            title: "JD",
            content: "Looking for an embodied AI engineer with robotics manipulation and computer vision experience."
        )

        _ = try documents.rebuildCleanRAGIndex()

        let provider = ControlledMockEmbeddingProvider()
        let chunks = try documents.allChunks()
        for chunk in chunks {
            let embedding = try await provider.embed(text: chunk.content)
            let hash = documents.calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: "cloudOpenAICompatible",
                modelName: provider.modelName,
                dimension: 384
            )
            try documents.updateChunkEmbedding(
                chunkID: chunk.id,
                embedding: embedding,
                model: provider.modelName,
                provider: "cloudOpenAICompatible",
                dimension: 384,
                contentHash: hash
            )
        }

        let coverage = try documents.embeddingCoverage(currentProvider: "cloudOpenAICompatible", currentModel: provider.modelName)
        #expect(coverage.totalChunks == chunks.count)
        #expect(coverage.chunksWithEmbeddings == chunks.count)
        #expect(coverage.coveragePercent == 100.0)

        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = true
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingModelName = provider.modelName
        settings.hybridSemanticWeight = 0.7
        settings.hybridKeywordWeight = 0.3

        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { provider }
        )

        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Tell me about your embodied AI robotics experience.",
            intent: .technical,
            maxCVWords: 150,
            maxJDWords: 150
        )

        #expect(trace.retrievalMode == "hybrid")
        #expect(trace.queryEmbeddingGenerated == true)
        #expect(trace.rankedCVChunks.first?.semanticScore != nil)
        #expect(trace.rankedCVChunks.first?.finalHybridScore != nil)
    }

    @Test
    func realDeepSeekProviderCompletionIsExplicitlyGated() async throws {
        guard TestSupport.realAppDatabaseTestsEnabled else {
            print("Skipping real DeepSeek provider test: set REAL_APP_DB_TESTS=1 to allow real provider/keychain access.")
            return
        }

        let keychain = KeychainService()
        guard let apiKey = try keychain.loadAPIKey(account: KeychainConstants.deepSeekAccount), !apiKey.isEmpty else {
            print("Skipping real DeepSeek provider test: DeepSeek API key is not configured in Keychain.")
            return
        }

        final class EnvironmentAPIKeyStore: APIKeyStore {
            let key: String
            init(key: String) { self.key = key }
            func loadAPIKey(account: String) throws -> String? { key }
            func saveAPIKey(_ apiKey: String, account: String) throws {}
            func deleteAPIKey(account: String) throws {}
        }

        let client = DeepSeekLLMClient(apiKeyStore: EnvironmentAPIKeyStore(key: apiKey))
        let result = try await client.chatCompletion(
            configuration: .deepSeekDefault(model: "deepseek-chat"),
            messages: [
                .system("You are a helpful assistant. Keep answers brief."),
                .user("Return a single short sentence confirming readiness.")
            ],
            responseFormat: nil,
            options: LLMRequestOptions(temperature: 0.1)
        )

        #expect(!result.content.isEmpty)
        #expect(result.providerKind == .deepSeek)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacRAGPhase3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
