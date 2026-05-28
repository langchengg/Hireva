import Foundation
import Testing
import GRDB
@testable import InterviewCopilotMac

@Suite
struct RAGPhase3VerificationTests {
    
    // Helper to check if local Ollama is available
    private func isOllamaAvailable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    @Test
    func testRealOllamaRAGPhase3Pipeline() async throws {
        // Only run this test if local Ollama is running (to avoid failing build environments without Ollama)
        let ollamaOnline = await isOllamaAvailable()
        guard ollamaOnline else {
            print("⚠️ Skipping RAGPhase3VerificationTests: Local Ollama is offline or not running at http://localhost:11434")
            return
        }
        
        print("\n================================================================================")
        print("🔍 RUNTIME VERIFICATION — RAG PHASE 3: REAL OLLAMA & HYBRID RETRIEVAL")
        print("================================================================================")
        
        // 1. Setup real database and repos
        let database = try makeTemporaryDatabase()
        let documentsRepo = DocumentRepository(database: database)
        
        // 2. Insert CV text containing Vision-language-action robotics paragraph
        let cvContent = """
        # PROJECTS
        Vision-language-action robotic manipulation project using ROS2 and VLM grasp reranking. Developed high-precision control loops.
        
        # EDUCATION
        Bachelor of Science in Computer Science.
        """
        _ = try documentsRepo.saveDocument(type: .cv, title: "Robotics CV", content: cvContent)
        
        let jdContent = """
        # ROLE REQUIREMENTS
        Looking for an Embodied AI engineer experienced in robotics manipulation, computer vision, and ROS2 frameworks.
        """
        _ = try documentsRepo.saveDocument(type: .jobDescription, title: "Robotics JD", content: jdContent)
        
        // Let's verify chunks were generated
        let cvChunks = try documentsRepo.chunks(type: .cv)
        let jdChunks = try documentsRepo.chunks(type: .jobDescription)
        #expect(cvChunks.count > 0)
        #expect(jdChunks.count > 0)
        
        print("Inserted documents: CV chunks count = \(cvChunks.count), JD chunks count = \(jdChunks.count)")
        
        // 3. Rebuild embeddings using Ollama embedding provider with nomic-embed-text
        let provider = OllamaEmbeddingProvider(modelName: "nomic-embed-text", baseURL: "http://localhost:11434")
        
        print("\n--- Step 1: Rebuilding Chunks Embeddings via Ollama (nomic-embed-text) ---")
        let allChunks = cvChunks + jdChunks
        for chunk in allChunks {
            let embedding = try await provider.embed(text: chunk.content)
            let hash = documentsRepo.calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: provider.providerID,
                modelName: provider.modelName,
                dimension: 768
            )
            try documentsRepo.updateChunkEmbedding(
                chunkID: chunk.id,
                embedding: embedding,
                model: provider.modelName,
                provider: provider.providerID,
                dimension: 768,
                contentHash: hash
            )
            print("Successfully updated chunk \(chunk.id.prefix(8)): dimension = \(embedding.count), model = \(provider.modelName)")
            #expect(embedding.count == 768)
        }
        
        // 4. Verify database storage via SQLite (Requirement 3)
        print("\n--- Step 2: Database Embeddings SQLite Query Verification ---")
        try await database.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS total, 
                   sum(CASE WHEN embedding IS NOT NULL THEN 1 ELSE 0 END) AS embedded, 
                   embedding_model, 
                   embedding_provider, 
                   embedding_dimension 
            FROM document_chunks 
            GROUP BY embedding_model, embedding_provider, embedding_dimension;
            """)
            
            #expect(row != nil)
            if let result = row {
                let total: Int = result["total"]
                let embedded: Int = result["embedded"]
                let model: String? = result["embedding_model"]
                let prov: String? = result["embedding_provider"]
                let dim: Int? = result["embedding_dimension"]
                
                print("SQLite Group By Results:")
                print("  Total Chunks: \(total)")
                print("  Embedded Chunks: \(embedded)")
                print("  Embedding Model: \(model ?? "nil")")
                print("  Embedding Provider: \(prov ?? "nil")")
                print("  Embedding Dimension: \(dim ?? 0)")
                
                #expect(total == allChunks.count)
                #expect(embedded == allChunks.count)
                #expect(model == "nomic-embed-text")
                #expect(prov == "localOllama")
                #expect(dim == 768)
                
                // Confirm BLOB exists and is non-empty
                let blobRow = try Row.fetchOne(db, sql: "SELECT embedding FROM document_chunks LIMIT 1;")
                let blobData: Data? = blobRow?["embedding"]
                #expect(blobData != nil)
                #expect(blobData!.count == 768 * 4) // 768 floats * 4 bytes/float
                print("  Embedding BLOB verified successfully (size = \(blobData!.count) bytes)")
            }
        }
        
        // 5. Verify hybrid retrieval with real embeddings (Requirement 4)
        print("\n--- Step 3: Hybrid Retrieval Verification with Paraphrased Query ---")
        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = true
        settings.embeddingProviderKind = .localOllama
        settings.embeddingModelName = "nomic-embed-text"
        settings.hybridSemanticWeight = 0.5
        settings.hybridKeywordWeight = 0.5
        
        let hybridService = HybridContextRetrievalService(
            documentRepository: documentsRepo,
            settingsProvider: { settings },
            embeddingProviderResolver: { provider }
        )
        
        let query = "Tell me about your embodied AI experience."
        let (_, trace) = try await hybridService.retrieveContextWithTrace(
            question: query,
            intent: QuestionIntent.technical,
            maxCVWords: 150,
            maxJDWords: 150
        )
        
        print("Retrieval Trace Metadata:")
        print("  Retrieval Mode: \(String(describing: trace.retrievalMode))")
        print("  Query Embedding Generated: \(trace.queryEmbeddingGenerated)")
        print("  Query Embedding Latency: \(String(describing: trace.queryEmbeddingLatencyMS)) ms")
        print("  Vector Search Latency: \(String(describing: trace.vectorSearchLatencyMS)) ms")
        print("  Embedding Coverage Percent: \(String(describing: trace.embeddingCoveragePercent))%")
        
        #expect(trace.retrievalMode == "hybrid")
        #expect(trace.queryEmbeddingGenerated == true)
        #expect(trace.embeddingCoveragePercent == 100.0)
        
        // Confirm the VLA / robotic manipulation chunk ranks highly
        print("\nRanked CV Chunks Scores:")
        for chunk in trace.rankedCVChunks {
            print("  - Content: \"\(chunk.contentPreview)\"")
            print("    Semantic Score: \(chunk.semanticScore ?? -1.0)")
            print("    Keyword Score Normalized: \(chunk.keywordScoreNormalized ?? -1.0)")
            print("    Final Hybrid Score: \(chunk.finalHybridScore ?? -1.0)")
            
            #expect(chunk.semanticScore != nil)
            #expect(chunk.keywordScoreNormalized != nil)
            #expect(chunk.finalHybridScore != nil)
        }
        
        let vlaChunk = trace.rankedCVChunks.first(where: { $0.contentPreview.contains("Vision-language-action") })
        #expect(vlaChunk != nil)
        #expect(vlaChunk!.semanticScore! > 0.4)
        print("Success: The Vision-language-action robotics chunk scored \(vlaChunk!.semanticScore!) (> 0.4) semantically")
        
        // 6. Verify keyword precision still works (Requirement 5)
        print("\n--- Step 4: Keyword Precision Verification ---")
        let keywordQuery = "Tell me about ROS2."
        let (_, traceKeyword) = try await hybridService.retrieveContextWithTrace(
            question: keywordQuery,
            intent: QuestionIntent.technical,
            maxCVWords: 150,
            maxJDWords: 150
        )
        
        print("Keyword Query Ranked CV Chunks:")
        for chunk in traceKeyword.rankedCVChunks {
            print("  - Content: \"\(chunk.contentPreview)\"")
            print("    Semantic Score: \(chunk.semanticScore ?? -1.0)")
            print("    Keyword Score Normalized: \(chunk.keywordScoreNormalized ?? -1.0)")
            print("    Final Hybrid Score: \(chunk.finalHybridScore ?? -1.0)")
            
            #expect(chunk.semanticScore != nil)
            #expect(chunk.keywordScoreNormalized != nil)
            #expect(chunk.finalHybridScore != nil)
        }
        
        let topKeywordChunk = traceKeyword.rankedCVChunks.first
        #expect(topKeywordChunk != nil)
        #expect(topKeywordChunk!.contentPreview.contains("ROS2") == true)
        #expect(topKeywordChunk!.keywordScoreNormalized! > 0.0)
        print("Success: Keyword precision is active, exact matches rank highly")
        
        // 7. Verify Fallback (Requirement 6)
        print("\n--- Step 5: Fallback Verification with Invalid Embedding Model ---")
        let offlineProvider = OllamaEmbeddingProvider(modelName: "invalid-nonexistent-model", baseURL: "http://localhost:11434")
        let fallbackService = HybridContextRetrievalService(
            documentRepository: documentsRepo,
            settingsProvider: { settings },
            embeddingProviderResolver: { offlineProvider }
        )
        
        let (_, traceFallback) = try await fallbackService.retrieveContextWithTrace(
            question: "Tell me about your embodied AI experience.",
            intent: QuestionIntent.technical,
            maxCVWords: 150,
            maxJDWords: 150
        )
        
        print("Fallback Retrieval Trace:")
        print("  Retrieval Mode: \(String(describing: traceFallback.retrievalMode))")
        print("  Fallback Reason: \(traceFallback.fallbackReason ?? "nil")")
        
        #expect(traceFallback.retrievalMode == "vectorFallback")
        #expect(traceFallback.fallbackReason != nil)
        #expect(traceFallback.fallbackReason!.contains("missing") || traceFallback.fallbackReason!.contains("Ollama") || traceFallback.fallbackReason!.contains("Query Embed Failed") == true)
        print("Success: Falling back gracefully when Ollama fails")
        
        print("\n================================================================================")
        print("✅ RAG PHASE 3 VERIFICATION PASSED")
        print("================================================================================\n")
    }
    
    @Test
    func testRebuildRealAppDatabaseEmbeddings() async throws {
        let ollamaOnline = await isOllamaAvailable()
        guard ollamaOnline else {
            print("⚠️ Skipping testRebuildRealAppDatabaseEmbeddings: Local Ollama is offline")
            return
        }
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("InterviewCopilotMac/interview_copilot.sqlite")
        
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            print("⚠️ Real SQLite database does not exist at: \(dbPath.path)")
            return
        }
        
        print("\n================================================================================")
        print("⚡️ REBUILDING REAL APPLICATION DATABASE EMBEDDINGS")
        print("================================================================================")
        print("Real Database Path: \(dbPath.path)")
        
        let database = try AppDatabase(path: dbPath)
        let documentsRepo = DocumentRepository(database: database)
        
        let cvChunks = try documentsRepo.chunks(type: .cv)
        let jdChunks = try documentsRepo.chunks(type: .jobDescription)
        let allChunks = cvChunks + jdChunks
        print("Total CV chunks: \(cvChunks.count) | Total JD chunks: \(jdChunks.count)")
        
        let provider = OllamaEmbeddingProvider(modelName: "nomic-embed-text", baseURL: "http://localhost:11434")
        
        for (index, chunk) in allChunks.enumerated() {
            print("Processing chunk \(index + 1)/\(allChunks.count) [\(chunk.id.prefix(8))]...")
            let embedding = try await provider.embed(text: chunk.content)
            let hash = documentsRepo.calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: provider.providerID,
                modelName: provider.modelName,
                dimension: 768
            )
            try documentsRepo.updateChunkEmbedding(
                chunkID: chunk.id,
                embedding: embedding,
                model: provider.modelName,
                provider: provider.providerID,
                dimension: 768,
                contentHash: hash
            )
        }
        
        print("================================================================================")
        print("🎉 REAL APPLICATION DATABASE EMBEDDINGS REBUILT SUCCESSFULLY")
        print("================================================================================\n")
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAGPhase3VerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
