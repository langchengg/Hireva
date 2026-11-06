import Foundation
import Testing
@testable import Hireva

@Suite
struct HybridRetrievalTests {
    @MainActor
    @Test(arguments: [false, true])
    func notesRetrievalBudgetMarksOmittedSourceBlocks(hybrid: Bool) async throws {
        let database = try makeTemporaryDatabase()
        let documents = DocumentRepository(database: database)
        let blocks = (1...4).map { number in
            "[source-\(number)] Database " + Array(repeating: "qualification", count: 136).joined(separator: " ") + " only. https://example.invalid/\(number)"
        }
        _ = try documents.saveDocument(type: .additionalNotes, title: "Conditional source blocks", content: blocks.joined(separator: "\n\n"))
        var settings = AppSettings.default
        settings.enableVectorRAG = false
        let service: any ContextRetrievalService = hybrid
            ? HybridContextRetrievalService(documentRepository: documents, settingsProvider: { [settings] in settings }, embeddingProviderResolver: { nil })
            : SimpleContextRetrievalService(documentRepository: documents)
        let context = try await service.retrieveContext(question: "Database qualification", intent: .technical, maxCVWords: 100, maxJDWords: 100)
        #expect(context.additionalNotesChunks.count == 4)
        #expect(context.additionalNotesChunks.map { $0.content.split(whereSeparator: \.isWhitespace).count }.reduce(0, +) <= 500)
        #expect(context.additionalNotesChunks.last?.content.contains("conditions may be omitted") == true)
        #expect(context.additionalNotesChunks.last?.content.contains("[source-4]") == false)
        #expect(context.additionalNotesChunks.prefix(3).map(\.content) == Array(blocks.prefix(3)))
    }
    
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
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingModelName = "controlled-mock-model"
        settings.hybridSemanticWeight = 0.8
        settings.hybridKeywordWeight = 0.2
        
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { [settings] in settings },
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
    @MainActor
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
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingModelName = "controlled-mock-model"
        settings.hybridSemanticWeight = 0.7
        settings.hybridKeywordWeight = 0.3
        
        let settingsOwner = HybridRetrievalSettingsOwner(settings)
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settingsOwner.settings },
            embeddingProviderResolver: { provider }
        )
        
        // Query should trigger fallback due to low coverage (< 80%)
        let (_, traceLowCov) = try await service.retrieveContextWithTrace(
            question: "Robotics",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(traceLowCov.retrievalMode == "keywordOnly")
        #expect(traceLowCov.fallbackReason?.contains("Low Coverage") == true)
        
        // Now force hybrid RAG -> should succeed despite coverage
        settingsOwner.settings.forceHybridRAG = true
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
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingModelName = "controlled-mock-model"
        
        // Passing nil for the embedding provider resolver should not require any local runtime.
        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { [settings] in settings },
            embeddingProviderResolver: { nil }
        )
        
        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Robotics",
            intent: .technical,
            maxCVWords: 100,
            maxJDWords: 100
        )
        
        #expect(trace.retrievalMode == "keywordOnly")
        #expect(trace.fallbackReason == "Embedding provider not configured")
        #expect(trace.queryEmbeddingGenerated == false)
    }
    
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_NOTE_PARAGRAPH_DIAGNOSTIC"] == "1"), .timeLimit(.minutes(1)))
    @MainActor
    func noteParagraphSelectionDiagnosticUsesActualImportAndFrozenPrompt() async throws {
        let input = try #require(ProcessInfo.processInfo.environment["HIREVA_DIAGNOSTIC_TECHNICAL_NOTES_PATH"])
        let output = try #require(ProcessInfo.processInfo.environment["HIREVA_NOTE_PARAGRAPH_DIAGNOSTIC_OUTPUT"])
        try #require(input.hasPrefix("/") && output.hasPrefix("/") && !FileManager.default.fileExists(atPath: output))
        let raw = try String(contentsOfFile: input, encoding: .utf8)
        let lines = raw.split(separator: "\n").map(String.init)
        try #require(lines.count == 4 && raw.utf8.count <= 4000)
        struct Observation: Encodable {
            let layout, variant, inputPath, inputContent, prompt: String
            let question: DetectedQuestion
            let importedChunks, retrievedNotes, frozenNotes: [DocumentChunk]
            let frozenCitations: [RetrievedChunk]
            let trace: RetrievalTrace
        }
        let questions = [
            ("original", "Explain database transaction atomicity and what happens when an operation fails before commit"),
            ("statement", "What does transaction atomicity guarantee, and does a failed statement necessarily cancel every earlier statement in that transaction?"),
            ("wrapper", "An application explicitly catches every failed statement and rolls back its current database transaction. What remains after one operation fails before commit?"),
            ("fallback", "Explain database transaction atomicity and what happens when an operation fails before commit")
        ]
        var observations: [Observation] = []
        for (layout, separator) in [("single-newline", "\n"), ("double-newline", "\n\n")] {
            let database = try AppDatabase(inMemory: true)
            do {
                let content = lines.joined(separator: separator)
                let documents = DocumentRepository(database: database)
                _ = try documents.saveDocument(type: .additionalNotes, title: "SQLite transactions", content: content)
                let chunks = try documents.chunks(type: .additionalNotes)
                var settings = AppSettings.default
                settings.enableVectorRAG = false
                settings.embeddingProviderKind = .disabled
                let owner = HybridRetrievalSettingsOwner(settings)
                let service = HybridContextRetrievalService(documentRepository: documents, settingsProvider: { owner.settings }, embeddingProviderResolver: { nil })
                for (variant, text) in questions {
                    var question = DetectedQuestion(id: "notes-\(layout)-\(variant)", sessionID: "notes-diagnostic", questionText: text,
                        intent: .technical, answerStrategy: .projectWalkthrough, confidence: 1, shouldTrigger: true, questionComplete: true,
                        modelName: "not-run", promptVersion: "notes-diagnostic", createdAt: Date())
                    var task = InterviewTaskDescriptor(question: text, kind: .generalKnowledge, language: "en")
                    let fallback = variant == "fallback" // Copies M35's fixture decision; no observed provider timeout.
                    task.apply(.init(task: fallback ? .unknown : .generalKnowledge, personalEvidence: fallback ? .uncertain : .notRequired,
                        basis: fallback ? .unknown : .generalKnowledge, relation: .independent, parentQuestionID: nil, parentQuestionText: nil,
                        parentAnswerText: nil, source: fallback ? "safeFallback" : "diagnostic-frozen-decision", routerVersion: InterviewQuestionRouter.version,
                        language: "en", clarification: fallback ? "Please clarify the reference or missing constraints." : "", questionID: question.id,
                        questionRevision: 0, contextSnapshotID: nil, artifactRevision: 0, model: "not-run", failure: fallback ? "timeout" : nil, latencyMS: fallback ? 8050 : 0))
                    question.taskDescriptor = task
                    let (retrieved, trace) = try await service.retrieveContextWithTrace(question: text, intent: question.intent, maxCVWords: 100, maxJDWords: 100, strategy: question.answerStrategy)
                    #expect(trace.retrievalMode == "keywordOnly" && !trace.queryEmbeddingGenerated)
                    let budgeted = RealtimePromptBudgeter.trim(retrieved, question: text, intent: question.intent, strategy: question.answerStrategy)
                    let realtime = AnswerRelevancePolicy.filterContext(budgeted, intent: AnswerRelevancePolicy.intent(for: text))
                    let frozen = PromptContextBuilder.promptSnapshot(question: question, context: realtime, transcriptContext: "", cvSummary: "", jdSummary: "", stage: .firstAnswer)
                    observations.append(.init(layout: layout, variant: variant, inputPath: input, inputContent: content, prompt: frozen.prompt, question: question,
                        importedChunks: chunks, retrievedNotes: retrieved.additionalNotesChunks, frozenNotes: frozen.ragContextSnapshot.additionalNotesChunks,
                        frozenCitations: frozen.ragContextSnapshot.frozenPromptCitations, trace: trace))
                }
                try database.close()
            } catch {
                do { try database.close() } catch { Issue.record(error) }
                throw error
            }
        }
        try JSONEncoder().encode(observations).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaHybridTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}

@MainActor
private final class HybridRetrievalSettingsOwner {
    var settings: AppSettings
    init(_ settings: AppSettings) { self.settings = settings }
}
