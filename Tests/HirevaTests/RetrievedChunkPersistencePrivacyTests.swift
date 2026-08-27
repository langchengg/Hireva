import Foundation
import GRDB
import Testing
@testable import Hireva

// All text in this suite is synthetic canary data, not personal information.
@Suite(.serialized)
struct RetrievedChunkPersistencePrivacyTests {
    private static let migrationID = "v18_discard_retrieved_chunk_content"
    private static let previewCanary = "CV_PREVIEW_CANARY_SYNTHETIC_41D9"
    private static let contentCanary = "JD_CONTENT_CANARY_SYNTHETIC_52EA"
    private static let keywordCanary = "KEYWORD_CANARY_SYNTHETIC_638B"
    private static let sectionCanary = "SECTION_CANARY_SYNTHETIC_74FC"

    private static var textualCanaries: [String] {
        [previewCanary, contentCanary, keywordCanary, sectionCanary]
    }

    @Test
    func databaseConnectionsExplicitlyEnableSecureDelete() throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }

        let secureDelete = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA secure_delete")
        }

        #expect(secureDelete == 1)
    }

    @Test
    func repositoryPersistsOnlyRetrievedChunkAttributionMetadata() throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Synthetic attribution privacy")
        let card = makeCard(id: "metadata-only-card", sessionID: session.id)
        let chunk = makeRetrievedChunk(id: "metadata-only-chunk", documentID: "synthetic-document")

        try suggestions.saveSuggestionCard(card, retrievedChunks: [chunk])

        try database.dbQueue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT * FROM suggestion_card_retrieved_chunks WHERE suggestion_card_id = ?",
                arguments: [card.id]
            ))
            let contentPreview: String = row["content_preview"]
            let fullContent: String = row["full_content"]
            let keywordsJSON: String = row["keywords_json"]
            let sectionTitle: String? = row["section_title"]
            let score: Double = row["score"]
            let semanticScore: Double? = row["semantic_score"]
            let keywordScore: Double? = row["keyword_score_normalized"]
            let finalScore: Double? = row["final_hybrid_score"]

            #expect(contentPreview.isEmpty)
            #expect(fullContent.isEmpty)
            #expect(keywordsJSON == "[]")
            #expect(sectionTitle == nil)
            #expect(row["chunk_id"] as String == chunk.id)
            #expect(row["document_id"] as String == chunk.documentID)
            #expect(row["document_type"] as String == chunk.documentType.rawValue)
            #expect(row["chunk_index"] as Int == chunk.chunkIndex)
            #expect(score == chunk.score)
            #expect(row["keyword_overlap_count"] as Int == chunk.keywordOverlapCount)
            #expect(row["content_overlap_count"] as Int == chunk.contentOverlapCount)
            #expect(row["rank"] as Int == chunk.rank)
            #expect(row["is_included"] as Int == 0)
            #expect(row["word_count"] as Int? == chunk.wordCount)
            #expect(semanticScore == chunk.semanticScore)
            #expect(keywordScore == chunk.keywordScoreNormalized)
            #expect(finalScore == chunk.finalHybridScore)
            #expect(row["retrieval_mode"] as String? == chunk.retrievalMode)
        }

        let loaded = try #require(suggestions.retrievedChunks(suggestionCardID: card.id).first)
        #expect(loaded.contentPreview.isEmpty)
        #expect(loaded.fullContent.isEmpty)
        #expect(loaded.keywords.isEmpty)
        #expect(loaded.sectionTitle == nil)
        #expect(loaded.id == chunk.id)
        #expect(loaded.documentID == chunk.documentID)
        #expect(loaded.documentType == chunk.documentType)
        #expect(loaded.chunkIndex == chunk.chunkIndex)
        #expect(loaded.score == chunk.score)
        #expect(loaded.keywordOverlapCount == chunk.keywordOverlapCount)
        #expect(loaded.contentOverlapCount == chunk.contentOverlapCount)
        #expect(loaded.rank == chunk.rank)
        #expect(loaded.isIncludedInPrompt == chunk.isIncludedInPrompt)
        #expect(loaded.wordCount == chunk.wordCount)
        #expect(loaded.semanticScore == chunk.semanticScore)
        #expect(loaded.keywordScoreNormalized == chunk.keywordScoreNormalized)
        #expect(loaded.finalHybridScore == chunk.finalHybridScore)
        #expect(loaded.retrievalMode == chunk.retrievalMode)
    }

    @Test
    func migrationClearsLegacyRetrievedTextCanariesAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaRetrievedChunkMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("privacy.sqlite")
        let cardID = "legacy-retrieval-card"
        let legacyValues = Self.textualCanaries.map { String(repeating: "\($0)|", count: 8) }

        do {
            let database = try AppDatabase(path: databaseURL)
            let sessions = SessionRepository(database: database)
            let suggestions = SuggestionRepository(database: database)
            let session = try sessions.createSession(mode: .mock, title: "Synthetic legacy attribution")
            try suggestions.saveSuggestionCard(makeCard(id: cardID, sessionID: session.id))

            try database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO suggestion_card_retrieved_chunks (
                        id, suggestion_card_id, chunk_id, document_id, document_type, chunk_index,
                        content_preview, full_content, keywords_json, score, keyword_overlap_count,
                        content_overlap_count, rank, is_included, section_title, word_count,
                        semantic_score, keyword_score_normalized, final_hybrid_score, retrieval_mode, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "legacy-row", cardID, "legacy-chunk", "legacy-document", DocumentType.cv.rawValue, 7,
                        legacyValues[0], legacyValues[1], "[\"\(legacyValues[2])\"]", 9.5, 3,
                        4, 2, 1, legacyValues[3], 88,
                        0.81, 0.72, 0.78, "hybrid", "2001-01-01T00:00:00Z"
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [Self.migrationID]
                )
            }
            try database.close()
        }

        for canary in Self.textualCanaries {
            #expect(try databaseArtifacts(at: root, baseName: databaseURL.lastPathComponent).contain(canary))
        }

        do {
            let database = try AppDatabase(path: databaseURL)
            try assertLegacyAttributionWasSanitized(database: database, cardID: cardID)
            #expect(try migrationCount(database: database) == 1)

            // Remove only the marker, then reopen to prove the migration is safe
            // to apply again to already-sanitized rows.
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [Self.migrationID]
                )
            }
            try database.close()
        }

        do {
            let database = try AppDatabase(path: databaseURL)
            try assertLegacyAttributionWasSanitized(database: database, cardID: cardID)
            #expect(try migrationCount(database: database) == 1)
            try database.close()
        }

        let artifacts = try databaseArtifacts(at: root, baseName: databaseURL.lastPathComponent)
        for canary in Self.textualCanaries {
            #expect(!artifacts.contain(canary))
        }
    }

    @Test
    func deletingDocumentRemovesOnlyItsRetrievedAttributionInTheSameOperation() throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }
        let documents = DocumentRepository(database: database)
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let cv = try documents.saveDocument(
            type: .cv,
            title: "Synthetic candidate profile",
            content: String(repeating: "Synthetic service reliability evidence for deterministic privacy testing. ", count: 3)
        )
        let jd = try documents.saveDocument(
            type: .jobDescription,
            title: "Synthetic opportunity context",
            content: String(repeating: "Synthetic role requirement for deterministic metadata deletion testing. ", count: 3)
        )
        let session = try sessions.createSession(mode: .mock, title: "Synthetic deletion privacy")
        let card = makeCard(id: "document-delete-card", sessionID: session.id)
        try suggestions.saveSuggestionCard(
            card,
            retrievedChunks: [
                makeRetrievedChunk(id: "cv-attribution", documentID: cv.id, type: .cv, rank: 1),
                makeRetrievedChunk(id: "jd-attribution", documentID: jd.id, type: .jobDescription, rank: 2)
            ]
        )

        #expect(try attributionCount(database: database, documentID: cv.id) == 1)
        #expect(try attributionCount(database: database, documentID: jd.id) == 1)

        // Force the second DELETE to fail. If both statements are not enclosed
        // by one transaction, the attribution row would be lost here.
        try database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER block_synthetic_document_delete
                BEFORE DELETE ON documents
                WHEN OLD.id = '\(cv.id)'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic delete rollback');
                END
                """)
        }
        var rollbackObserved = false
        do {
            try documents.deleteDocument(id: cv.id)
        } catch {
            rollbackObserved = true
        }
        #expect(rollbackObserved)
        #expect(try attributionCount(database: database, documentID: cv.id) == 1)
        #expect(try documents.document(type: .cv)?.id == cv.id)

        try database.dbQueue.write { db in
            try db.execute(sql: "DROP TRIGGER block_synthetic_document_delete")
        }
        try documents.deleteDocument(id: cv.id)

        #expect(try attributionCount(database: database, documentID: cv.id) == 0)
        #expect(try attributionCount(database: database, documentID: jd.id) == 1)
        #expect(try documents.document(type: .cv) == nil)
        #expect(try documents.document(type: .jobDescription)?.id == jd.id)
        #expect(try suggestions.retrievedChunks(suggestionCardID: card.id).map(\.documentID) == [jd.id])

        try documents.deleteAllDocuments()

        #expect(try attributionCount(database: database, documentID: jd.id) == 0)
        #expect(try documents.documents().isEmpty)
    }

    private func assertLegacyAttributionWasSanitized(database: AppDatabase, cardID: String) throws {
        try database.dbQueue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT * FROM suggestion_card_retrieved_chunks WHERE suggestion_card_id = ?",
                arguments: [cardID]
            ))
            #expect(row["content_preview"] as String == "")
            #expect(row["full_content"] as String == "")
            #expect(row["keywords_json"] as String == "[]")
            #expect(row["section_title"] as String? == nil)
            #expect(row["chunk_id"] as String == "legacy-chunk")
            #expect(row["document_id"] as String == "legacy-document")
            #expect(row["chunk_index"] as Int == 7)
            #expect(row["score"] as Double == 9.5)
            #expect(row["keyword_overlap_count"] as Int == 3)
            #expect(row["content_overlap_count"] as Int == 4)
            #expect(row["rank"] as Int == 2)
            #expect(row["is_included"] as Int == 1)
            #expect(row["word_count"] as Int? == 88)
            #expect(row["semantic_score"] as Double? == 0.81)
            #expect(row["keyword_score_normalized"] as Double? == 0.72)
            #expect(row["final_hybrid_score"] as Double? == 0.78)
            #expect(row["retrieval_mode"] as String? == "hybrid")
        }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaRetrievedChunkPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try AppDatabase(path: root.appendingPathComponent("privacy.sqlite"))
    }

    private func makeCard(id: String, sessionID: String) -> SuggestionCard {
        SuggestionCard(
            id: id,
            sessionID: sessionID,
            questionID: nil,
            strategy: "Synthetic metadata-only strategy",
            sayFirst: "Synthetic answer opener.",
            keyPoints: ["Synthetic point"],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "synthetic-model",
            promptVersion: "synthetic-v1",
            rawJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1_500)
        )
    }

    private func makeRetrievedChunk(
        id: String,
        documentID: String,
        type: DocumentType = .cv,
        rank: Int = 5
    ) -> RetrievedChunk {
        RetrievedChunk(
            id: id,
            documentID: documentID,
            documentType: type,
            chunkIndex: 3,
            contentPreview: Self.previewCanary,
            fullContent: Self.contentCanary,
            keywords: [Self.keywordCanary],
            score: 7.25,
            keywordOverlapCount: 2,
            contentOverlapCount: 4,
            rank: rank,
            isIncludedInPrompt: false,
            sectionTitle: Self.sectionCanary,
            wordCount: 101,
            semanticScore: 0.72,
            keywordScoreNormalized: 0.63,
            finalHybridScore: 0.69,
            retrievalMode: "hybrid"
        )
    }

    private func migrationCount(database: AppDatabase) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [Self.migrationID]
            ) ?? 0
        }
    }

    private func attributionCount(database: AppDatabase, documentID: String) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM suggestion_card_retrieved_chunks WHERE document_id = ?",
                arguments: [documentID]
            ) ?? 0
        }
    }

    private func databaseArtifacts(at root: URL, baseName: String) throws -> DatabaseArtifactBytes {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { url in
            url.lastPathComponent == baseName || url.lastPathComponent.hasPrefix("\(baseName)-")
        }
        return try DatabaseArtifactBytes(contents: urls.map { try Data(contentsOf: $0) })
    }
}

private struct DatabaseArtifactBytes {
    let contents: [Data]

    func contain(_ value: String) -> Bool {
        let needle = Data(value.utf8)
        return contents.contains { $0.range(of: needle) != nil }
    }
}
