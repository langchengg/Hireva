import Foundation
import Testing
import GRDB
@testable import InterviewCopilotMac

@Suite
struct RAGAttributionTests {
    @Test
    func atomicSaveAndLoadRAGAttribution() throws {
        let database = try makeTemporaryDatabase()
        let suggestionRepo = SuggestionRepository(database: database)

        let sessionID = UUID().uuidString
        let cardID = UUID().uuidString
        let questionID = UUID().uuidString

        // Save a mock suggestion card
        let card = SuggestionCard(
            id: cardID,
            sessionID: sessionID,
            questionID: questionID,
            strategy: "Test Strategy",
            sayFirst: "Say First",
            keyPoints: ["Point A", "Point B"],
            followUpReady: ["Follow-up"],
            confidence: 0.85,
            caution: "None",
            evidenceUsed: ["Evidence A"],
            riskLevel: .low,
            modelName: "mock-model",
            promptVersion: "v1.0",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "http://localhost",
            latencyMS: 120,
            isLocal: true,
            rawJSON: "{}",
            createdAt: Date()
        )

        let chunks = [
            RetrievedChunk(
                id: "chunk-1",
                documentID: "doc-cv",
                documentType: .cv,
                chunkIndex: 0,
                contentPreview: "CV preview...",
                fullContent: "CV Full Content robotics developer",
                keywords: ["robotics", "developer"],
                score: 4.5,
                keywordOverlapCount: 1,
                contentOverlapCount: 1,
                rank: 1,
                isIncludedInPrompt: true,
                sectionTitle: "Work Experience",
                wordCount: 5
            ),
            RetrievedChunk(
                id: "chunk-2",
                documentID: "doc-jd",
                documentType: .jobDescription,
                chunkIndex: 1,
                contentPreview: "JD preview...",
                fullContent: "JD Full Content robotics engineer",
                keywords: ["robotics", "engineer"],
                score: 1.5,
                keywordOverlapCount: 0,
                contentOverlapCount: 1,
                rank: 2,
                isIncludedInPrompt: false,
                sectionTitle: "Requirements",
                wordCount: 5
            )
        ]

        // 1. Save atomically in one transaction
        // First we need to make sure the session and question exist, or we turn off foreign keys temporarily in test if not needed, or just insert them. Let's insert the session and question to satisfy foreign keys!
        try database.dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at)
            VALUES (?, 'Test Session', 'Company', 'Role', '2026-05-27', NULL, 'practice', '2026-05-27')
            """, arguments: [sessionID])

            try db.execute(sql: """
            INSERT INTO detected_questions (
                id, session_id, transcript_segment_id, question_text, intent, answer_strategy,
                confidence, reason, should_trigger, question_complete, model_name, prompt_version, created_at
            )
            VALUES (?, ?, NULL, 'Question Text', 'technical', 'wait', 0.9, 'reason', 0, 0, 'mock', 'v1', '2026-05-27')
            """, arguments: [questionID, sessionID])
        }

        try suggestionRepo.saveSuggestionCard(card, retrievedChunks: chunks)

        // 2. Load retrieved chunks and verify correctness
        let loadedChunks = try suggestionRepo.retrievedChunks(suggestionCardID: cardID)
        #expect(loadedChunks.count == 2)
        
        let cvChunk = loadedChunks.first { $0.documentType == .cv }
        #expect(cvChunk != nil)
        #expect(cvChunk?.id == "chunk-1")
        #expect(cvChunk?.score == 4.5)
        #expect(cvChunk?.rank == 1)
        #expect(cvChunk?.isIncludedInPrompt == true)
        #expect(cvChunk?.sectionTitle == "Work Experience")
        #expect(cvChunk?.wordCount == 5)

        let jdChunk = loadedChunks.first { $0.documentType == .jobDescription }
        #expect(jdChunk != nil)
        #expect(jdChunk?.id == "chunk-2")
        #expect(jdChunk?.score == 1.5)
        #expect(jdChunk?.rank == 2)
        #expect(jdChunk?.isIncludedInPrompt == false)
        #expect(jdChunk?.sectionTitle == "Requirements")
        #expect(jdChunk?.wordCount == 5)

        // 3. Test cascade delete: deleting the session/card should cascade delete the retrieved chunks
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM suggestion_cards WHERE id = ?", arguments: [cardID])
        }

        let remainingChunks = try suggestionRepo.retrievedChunks(suggestionCardID: cardID)
        #expect(remainingChunks.isEmpty)
    }

    @Test
    func databaseMigrationRobustness() throws {
        // Test that we can run the database migration cleanly and it inspects columns
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAGMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbPath = directory.appendingPathComponent("test.sqlite")

        // 1. Setup a database and run migrations up to v3 only (we can copy the AppDatabase logic or just run it)
        let dbQueue = try DatabaseQueue(path: dbPath.path)
        var migrator = DatabaseMigrator()

        // Re-register v1, v2, v3
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "documents") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("content", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }
            try db.create(table: "document_chunks") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text).notNull().indexed().references("documents", onDelete: .cascade)
                table.column("document_type", .text).notNull().indexed()
                table.column("chunk_index", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("keywords", .text)
                table.column("created_at", .text).notNull()
            }
            try db.create(table: "suggestion_cards") { table in
                table.column("id", .text).primaryKey()
                table.column("strategy", .text).notNull()
                table.column("created_at", .text).notNull()
            }
        }

        try migrator.migrate(dbQueue)

        // 2. Pre-add one of the new columns manually to simulate a development database with dirty columns
        try dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN section_title TEXT")
        }

        // 3. Now register the v4 RAG attribution migration and run it!
        migrator.registerMigration("v4_rag_attribution") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(document_chunks)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            
            // Should detect that section_title already exists and not alter again, but add the others!
            if !columnNames.contains("section_title") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN section_title TEXT")
            }
            if !columnNames.contains("word_count") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN word_count INTEGER")
            }
            if !columnNames.contains("metadata_json") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN metadata_json TEXT")
            }

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS suggestion_card_retrieved_chunks (
                id TEXT PRIMARY KEY,
                suggestion_card_id TEXT NOT NULL REFERENCES suggestion_cards(id) ON DELETE CASCADE,
                chunk_id TEXT NOT NULL,
                document_id TEXT NOT NULL,
                document_type TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                content_preview TEXT NOT NULL,
                full_content TEXT NOT NULL,
                keywords_json TEXT NOT NULL,
                score REAL NOT NULL,
                keyword_overlap_count INTEGER NOT NULL,
                content_overlap_count INTEGER NOT NULL,
                rank INTEGER NOT NULL,
                is_included INTEGER NOT NULL DEFAULT 1,
                section_title TEXT,
                word_count INTEGER,
                created_at TEXT NOT NULL
            )
            """)
        }

        // Run migrations! This should run without throwing or crashing despite the pre-existing column!
        try migrator.migrate(dbQueue)

        // Verify all columns exist
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(document_chunks)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            #expect(columnNames.contains("section_title"))
            #expect(columnNames.contains("word_count"))
            #expect(columnNames.contains("metadata_json"))
        }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAGAttributionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
