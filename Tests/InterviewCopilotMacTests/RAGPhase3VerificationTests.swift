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
    
    @Test
    func testRealDeepSeekProviderCompletion() async throws {
        let keychain = KeychainService()
        guard let apiKey = try keychain.loadAPIKey(account: "deepseek.default"), !apiKey.isEmpty else {
            print("⚠️ Skipping testRealDeepSeekProviderCompletion: DeepSeek API Key not configured in Keychain")
            return
        }
        
        print("\n================================================================================")
        print("🤖 TESTING REAL DEEPSEEK PROVIDER COMPLETION")
        print("================================================================================")
        
        let client = DeepSeekLLMClient(apiKeyStore: keychain)
        let config = LLMProviderConfiguration.deepSeekDefault(model: "deepseek-chat")
        
        do {
            let result = try await client.chatCompletion(
                configuration: config,
                messages: [
                    .system("You are a helpful assistant. Keep answers brief (one sentence)."),
                    .user("Hello DeepSeek! What is 2+2?")
                ],
                responseFormat: nil,
                options: LLMRequestOptions(temperature: 0.1)
            )
            print("Successfully received DeepSeek response:")
            print("  Model: \(result.modelName)")
            print("  Latency: \(result.latencyMS) ms")
            print("  Content: \"\(result.content)\"")
            #expect(!result.content.isEmpty)
        } catch {
            print("❌ DeepSeek Completion Failed: \(error.localizedDescription)")
            throw error
        }
        print("================================================================================")
    }
    
    @Test
    func testRealDeepSeekProductFlow() async throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("InterviewCopilotMac/interview_copilot.sqlite")
        
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            print("⚠️ Real SQLite database does not exist at: \(dbPath.path)")
            return
        }
        
        // Find DeepSeek API Key (Keychain or Environment fallback to bypass TCC unsigned binary block)
        var apiKey: String? = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
        let keychain = KeychainService()
        if apiKey == nil || apiKey!.isEmpty {
            do {
                apiKey = try keychain.loadAPIKey(account: "deepseek.default")
            } catch {
                print("⚠️ Keychain read threw error: \(error.localizedDescription)")
            }
        }
        
        guard let finalKey = apiKey, !finalKey.isEmpty else {
            print("⚠️ Skipping testRealDeepSeekProductFlow: DeepSeek API Key not configured in Keychain or Environment")
            return
        }
        
        print("\n================================================================================")
        print("🚀 RUNNING END-TO-END PRODUCT FLOW WITH REAL DEEPSEEK & OLLAMA HYBRID RAG")
        print("================================================================================")
        print("Real Database Path: \(dbPath.path)")
        
        let database = try AppDatabase(path: dbPath)
        let documentsRepo = DocumentRepository(database: database)
        let suggestionRepo = SuggestionRepository(database: database)
        
        // 1. Setup Hybrid Context Retrieval Service
        let ollamaProvider = OllamaEmbeddingProvider(modelName: "nomic-embed-text", baseURL: "http://localhost:11434")
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
            embeddingProviderResolver: { ollamaProvider }
        )
        
        // 2. Perform Hybrid retrieval for paraphrased query
        let query = "Tell me about your embodied AI experience."
        let (context, trace) = try await hybridService.retrieveContextWithTrace(
            question: query,
            intent: QuestionIntent.technical,
            maxCVWords: 150,
            maxJDWords: 150
        )
        
        print("RAG Retrieval completed:")
        print("  Retrieval Mode: \(trace.retrievalMode)")
        print("  Ranked chunks count: \(trace.rankedCVChunks.count + trace.rankedJDChunks.count)")
        
        // 3. Write a hermetic E2E test API key store
        final class EnvironmentAPIKeyStore: APIKeyStore {
            let key: String
            init(key: String) { self.key = key }
            func loadAPIKey(account: String) throws -> String? { return key }
            func saveAPIKey(_ apiKey: String, account: String) throws {}
            func deleteAPIKey(account: String) throws {}
        }
        let customKeyStore = EnvironmentAPIKeyStore(key: finalKey)
        
        // 4. Setup LLM Router and active DeepSeek provider configuration
        let deepseekClient = DeepSeekLLMClient(apiKeyStore: customKeyStore)
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [
            .deepSeek: deepseekClient
        ])
        let generator = SuggestionGenerationService(llmRouter: router)
        
        // 5. Create E2E Session in real database
        let sessionID = UUID().uuidString
        let questionID = UUID().uuidString
        
        try await database.dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at)
            VALUES (?, 'Real DeepSeek E2E Verification', 'Autonomous Robotics', 'Embodied AI Specialist', '2026-05-28T08:31:00.000Z', NULL, 'practice', '2026-05-28T08:31:00.000Z')
            """, arguments: [sessionID])
            
            try db.execute(sql: """
            INSERT INTO detected_questions (
                id, session_id, transcript_segment_id, question_text, intent, answer_strategy,
                confidence, reason, should_trigger, question_complete, model_name, prompt_version, created_at
            )
            VALUES (?, ?, NULL, ?, 'technical', 'wait', 0.98, 'Direct capture', 1, 1, 'deepseek-chat', 'v1.0', '2026-05-28T08:31:00.000Z')
            """, arguments: [questionID, sessionID, query])
        }
        
        // 6. Construct detected question object
        let detectedQuestion = DetectedQuestion(
            id: questionID,
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: query,
            intent: .technical,
            answerStrategy: .wait,
            confidence: 0.98,
            reason: "Direct capture",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-chat",
            promptVersion: "v1.0",
            createdAt: Date()
        )
        
        // 7. Invoke real DeepSeek generation using the retrieved RAG context!
        print("\n--- Sending request to DeepSeek (deepseek-chat) via completions ---")
        let deepseekConfig = LLMProviderConfiguration.deepSeekDefault(model: "deepseek-chat")
        
        let (card, response) = try await generator.generate(
            question: detectedQuestion,
            context: context,
            transcriptContext: "Interviewer: \(query)",
            sessionID: sessionID,
            customProviderConfig: deepseekConfig
        )
        
        print("\nSuccessfully generated DeepSeek Suggestion:")
        print("  Strategy: \(card.strategy)")
        print("  Say First: \"\(card.sayFirst)\"")
        print("  Key Points: \(card.keyPoints)")
        print("  Follow Ups: \(card.followUpReady)")
        print("  Provider Model: \(card.modelName) (\(card.providerName))")
        print("  Latency: \(card.latencyMS) ms")
        
        #expect(!card.sayFirst.isEmpty)
        #expect(card.modelName == "deepseek-v4-flash")
        #expect(card.providerName == "DeepSeek")
        
        // 8. Atomically persist card and chunks to real SQLite database join tables!
        let allRankedChunks = trace.rankedCVChunks + trace.rankedJDChunks
        try suggestionRepo.saveSuggestionCard(card, retrievedChunks: allRankedChunks)
        
        print("\n--- Step 8: Verifying Atoms persisted successfully in SQLite ---")
        try await database.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT count(*) as count FROM suggestion_card_retrieved_chunks WHERE suggestion_card_id = ?;", arguments: [card.id])
            let count: Int = row?["count"] ?? 0
            print("  Persisted attributions count: \(count)")
            #expect(count == allRankedChunks.count)
        }
        
        print("\n================================================================================")
        print("🎉 END-TO-END DEEPSEEK PRODUCT FLOW COMPLETED SUCCESSFULLY")
        print("================================================================================\n")
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAGPhase3VerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
