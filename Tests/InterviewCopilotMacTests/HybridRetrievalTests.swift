import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct HybridRetrievalTests {
    
    // --- 1. Vector Store Embeddings Serialization ---
    @Test
    func testFloatSerializationRoundtrip() {
        let floats: [Float] = [0.15, -0.98, 3.14, 0.0, -100.005]
        let encoded = VectorStore.encodeEmbedding(floats)
        let decoded = VectorStore.decodeEmbedding(encoded)
        
        #expect(decoded.count == floats.count)
        for i in 0..<floats.count {
            #expect(abs(decoded[i] - floats[i]) < 1e-5)
        }
    }
    
    // --- 2. Cosine Similarity ---
    @Test
    func testCosineSimilarity() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0, 0.0]
        let simIdentical = VectorStore.cosineSimilarity(v1, v2)
        #expect(abs(simIdentical - 1.0) < 1e-5)
        
        let vOrthogonal: [Float] = [0.0, 1.0, 0.0]
        let simOrthogonal = VectorStore.cosineSimilarity(v1, vOrthogonal)
        #expect(abs(simOrthogonal - 0.0) < 1e-5)
        
        let vOpposite: [Float] = [-1.0, 0.0, 0.0]
        let simOpposite = VectorStore.cosineSimilarity(v1, vOpposite)
        #expect(abs(simOpposite - (-1.0)) < 1e-5)
    }
    
    // --- 3. ControlledMock Paraphrase Matching ---
    @Test
    func testControlledMockParaphraseMatching() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)
        
        // Save CV document
        _ = try documents.saveDocument(
            type: .cv,
            title: "Robotics and Software Resume",
            content: """
            Robotics grasping: built a language-conditioned grasping pipeline using MuJoCo and VLA models.
            
            ROS2 software engineer specializing in navigation and rover autonomy.
            
            Database engineer focusing on SQLite and indexing tables.
            """
        )
        
        let provider = ControlledMockEmbeddingProvider()
        let chunks = try documents.chunks(type: .cv)
        
        // Generate embeddings for the chunks using mock provider and save them
        for chunk in chunks {
            let emb = try await provider.embed(text: chunk.content)
            let hash = documents.calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: "controlled-mock",
                modelName: "controlled-mock-model",
                dimension: 384
            )
            try documents.updateChunkEmbedding(
                chunkID: chunk.id,
                embedding: emb,
                model: "controlled-mock-model",
                provider: "controlled-mock",
                dimension: 384,
                contentHash: hash
            )
        }
        
        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = true
        settings.embeddingProviderKind = .localOllama
        settings.embeddingModelName = "controlled-mock-model"
        settings.hybridSemanticWeight = 0.8
        settings.hybridKeywordWeight = 0.2
        
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { provider }
        )
        
        // Test query A: "embodied experience" -> Should pull the robotics chunk first semantically
        let (_, traceA) = try await service.retrieveContextWithTrace(
            question: "embodied experience VLA",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(traceA.retrievalMode == "hybrid")
        #expect(traceA.rankedCVChunks.first?.contentPreview.contains("grasping") == true)
        #expect(traceA.rankedCVChunks.first?.semanticScore != nil)
        
        // Test query B: "navigation" -> Should pull the ROS2 chunk first semantically
        let (_, traceB) = try await service.retrieveContextWithTrace(
            question: "navigation rover C++ autonomy",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(traceB.retrievalMode == "hybrid")
        #expect(traceB.rankedCVChunks.first?.contentPreview.contains("ROS2") == true)
    }
    
    // --- 4. 80% Coverage Check Fallbacks ---
    @Test
    func testCoverageCheckFallbacks() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)
        
        // Save 5 chunks
        _ = try documents.saveDocument(
            type: .cv,
            title: "Resume",
            content: """
            Chunk 1: Robotics.
            
            Chunk 2: ROS2.
            
            Chunk 3: Database.
            
            Chunk 4: Autonomy.
            
            Chunk 5: Embeddings.
            """
        )
        
        let chunks = try documents.chunks(type: .cv)
        #expect(chunks.count == 5)
        
        // Embed only 1 chunk (20% coverage)
        let provider = ControlledMockEmbeddingProvider()
        let emb = try await provider.embed(text: chunks[0].content)
        let hash = documents.calculateContentHash(
            content: chunks[0].content,
            sectionTitle: chunks[0].sectionTitle,
            provider: "controlled-mock",
            modelName: "controlled-mock-model",
            dimension: 384
        )
        try documents.updateChunkEmbedding(
            chunkID: chunks[0].id,
            embedding: emb,
            model: "controlled-mock-model",
            provider: "controlled-mock",
            dimension: 384,
            contentHash: hash
        )
        
        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = false // DO NOT force
        settings.embeddingProviderKind = .localOllama
        settings.embeddingModelName = "controlled-mock-model"
        settings.hybridSemanticWeight = 0.7
        settings.hybridKeywordWeight = 0.3
        
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { provider }
        )
        
        // Query should trigger fallback due to low coverage (< 80%)
        let (_, traceLowCov) = try await service.retrieveContextWithTrace(
            question: "Robotics",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(traceLowCov.retrievalMode == "vectorFallback")
        #expect(traceLowCov.fallbackReason?.contains("Low Coverage") == true)
        
        // Now force hybrid RAG -> should succeed despite coverage
        settings.forceHybridRAG = true
        let (_, traceForced) = try await service.retrieveContextWithTrace(
            question: "Robotics",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        #expect(traceForced.retrievalMode == "hybrid")
    }
    
    // --- 5. Offline/Unavailable Provider Fallback ---
    @Test
    func testOfflineProviderFallback() async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)
        
        _ = try documents.saveDocument(
            type: .cv,
            title: "Resume",
            content: "Robotics project."
        )
        
        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = true
        settings.embeddingProviderKind = .localOllama
        settings.embeddingModelName = "controlled-mock-model"
        
        // Passing nil for the embedding provider resolver (e.g. offline Ollama)
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { nil }
        )
        
        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Robotics",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(trace.retrievalMode == "vectorFallback")
        #expect(trace.fallbackReason == "No Provider Available")
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacHybridTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
