import Foundation
import GRDB
import CommonCrypto

public struct CleanRAGIndexRebuildResult: Equatable {
    public let documentsRebuilt: Int
    public let chunksRebuilt: Int
}

final class DocumentRepository {
    private let database: AppDatabase
    private let meaningfulMinimumCharacters = 80

    init(database: AppDatabase) {
        self.database = database
    }

    func saveDocument(type: DocumentType, title: String, content: String) throws -> DocumentRecord {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let existing = try document(type: type)
        
        let sanitizedResult = DocumentTextSanitizer.sanitize(trimmed)
        let sanitizedText = sanitizedResult.sanitizedContent
        let preview = sanitizedResult.sanitizedPreview
        let warningsStr = sanitizedResult.sanitizationWarnings.joined(separator: "\n")
        
        let record = DocumentRecord(
            id: existing?.id ?? UUID().uuidString,
            type: type,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? type.title : title,
            content: trimmed,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            sanitizedContent: sanitizedText,
            sanitizedPreview: preview,
            sanitizationWarnings: warningsStr
        )
        let chunks = TextChunker.chunks(from: sanitizedText)

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO documents (
                    id, type, title, content, created_at, updated_at,
                    sanitized_content, sanitized_preview, sanitization_warnings
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type = excluded.type,
                    title = excluded.title,
                    content = excluded.content,
                    updated_at = excluded.updated_at,
                    sanitized_content = excluded.sanitized_content,
                    sanitized_preview = excluded.sanitized_preview,
                    sanitization_warnings = excluded.sanitization_warnings
                """,
                arguments: [
                    record.id,
                    record.type.rawValue,
                    record.title,
                    record.content,
                    DateCoding.string(from: record.createdAt),
                    DateCoding.string(from: record.updatedAt),
                    record.sanitizedContent,
                    record.sanitizedPreview,
                    record.sanitizationWarnings
                ]
            )
            try db.execute(sql: "DELETE FROM document_chunks WHERE document_id = ?", arguments: [record.id])
            for (index, chunk) in chunks.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO document_chunks (
                        id, document_id, document_type, chunk_index, content, keywords,
                        section_title, word_count, metadata_json, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        record.id,
                        record.type.rawValue,
                        index,
                        chunk.content,
                        chunk.keywords.joined(separator: ","),
                        chunk.sectionTitle,
                        chunk.wordCount,
                        chunk.metadataJSON,
                        DateCoding.string(from: now)
                    ]
                )
            }
        }
        return record
    }

    func document(type: DocumentType) throws -> DocumentRecord? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE type = ? ORDER BY updated_at DESC LIMIT 1", arguments: [type.rawValue])
            return row.map(Self.makeDocument)
        }
    }

    func documents() throws -> [DocumentRecord] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM documents ORDER BY updated_at DESC")
                .map(Self.makeDocument)
        }
    }

    func chunks(type: DocumentType) throws -> [DocumentChunk] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT document_chunks.*, documents.type AS resolved_document_type
                FROM document_chunks
                JOIN documents ON documents.id = document_chunks.document_id
                WHERE documents.type = ?
                ORDER BY chunk_index ASC
                """,
                arguments: [type.rawValue]
            ).map(Self.makeChunk)
        }
    }

    func chunks(documentID: String) throws -> [DocumentChunk] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM document_chunks WHERE document_id = ? ORDER BY chunk_index ASC",
                arguments: [documentID]
            ).map(Self.makeChunk)
        }
    }

    func deleteDocument(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
        }
    }

    func onboardingCompletion() throws -> (hasCV: Bool, hasJD: Bool) {
        let cv = try document(type: .cv)
        let jd = try document(type: .jobDescription)
        return (
            hasMeaningfulContent(cv?.content),
            hasMeaningfulContent(jd?.content)
        )
    }

    func isOnboardingComplete() throws -> Bool {
        let completion = try onboardingCompletion()
        return completion.hasCV && completion.hasJD
    }

    func deleteAllDocuments() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM documents")
        }
    }

    func latexPollutedChunkCount() throws -> Int {
        try database.dbQueue.read { db in
            let contents = try String.fetchAll(
                db,
                sql: """
                SELECT content
                FROM document_chunks
                """
            )
            return contents.filter(DocumentTextSanitizer.containsResidualLatexFormattingNoise).count
        }
    }

    @discardableResult
    func rebuildCleanRAGIndex() throws -> CleanRAGIndexRebuildResult {
        let storedDocuments = try documents()
        let now = Date()
        var chunksRebuilt = 0

        try database.dbQueue.write { db in
            for document in storedDocuments {
                let rawContent = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let sanitized = DocumentTextSanitizer.sanitize(rawContent)
                let chunks = TextChunker.chunks(from: sanitized.sanitizedContent)
                chunksRebuilt += chunks.count

                try db.execute(
                    sql: """
                    UPDATE documents
                    SET content = ?,
                        sanitized_content = ?,
                        sanitized_preview = ?,
                        sanitization_warnings = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        rawContent,
                        sanitized.sanitizedContent,
                        sanitized.sanitizedPreview,
                        sanitized.sanitizationWarnings.joined(separator: "\n"),
                        document.id
                    ]
                )

                try db.execute(
                    sql: "DELETE FROM document_chunks WHERE document_id = ?",
                    arguments: [document.id]
                )

                for (index, chunk) in chunks.enumerated() {
                    try db.execute(
                        sql: """
                        INSERT INTO document_chunks (
                            id, document_id, document_type, chunk_index, content, keywords,
                            section_title, word_count, metadata_json, created_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            UUID().uuidString,
                            document.id,
                            document.type.rawValue,
                            index,
                            chunk.content,
                            chunk.keywords.joined(separator: ","),
                            chunk.sectionTitle,
                            chunk.wordCount,
                            chunk.metadataJSON,
                            DateCoding.string(from: now)
                        ]
                    )
                }
            }
        }

        return CleanRAGIndexRebuildResult(
            documentsRebuilt: storedDocuments.count,
            chunksRebuilt: chunksRebuilt
        )
    }

    private func hasMeaningfulContent(_ content: String?) -> Bool {
        guard let content else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).count >= meaningfulMinimumCharacters
    }

    private static func makeDocument(row: Row) -> DocumentRecord {
        DocumentRecord(
            id: row["id"],
            type: DocumentType(rawValue: row["type"]) ?? .cv,
            title: row["title"],
            content: row["content"],
            createdAt: DateCoding.date(from: row["created_at"]),
            updatedAt: DateCoding.date(from: row["updated_at"]),
            sanitizedContent: row["sanitized_content"],
            sanitizedPreview: row["sanitized_preview"],
            sanitizationWarnings: row["sanitization_warnings"]
        )
    }

    private static func makeChunk(row: Row) -> DocumentChunk {
        let typeString: String = row["resolved_document_type"] ?? row["document_type"]
        let keywordsString: String? = row["keywords"]
        
        let embeddingData: Data? = row["embedding"]
        let embeddingModel: String? = row["embedding_model"]
        let embeddingProvider: String? = row["embedding_provider"]
        let embeddingDimension: Int? = row["embedding_dimension"]
        let embeddingContentHash: String? = row["embedding_content_hash"]
        let embeddingCreatedAtStr: String? = row["embedding_created_at"]
        let embeddingCreatedAt = embeddingCreatedAtStr.flatMap { DateCoding.date(from: $0) }

        return DocumentChunk(
            id: row["id"],
            documentID: row["document_id"],
            documentType: DocumentType(rawValue: typeString) ?? .cv,
            chunkIndex: row["chunk_index"],
            content: row["content"],
            keywords: keywordsString?.split(separator: ",").map(String.init) ?? [],
            sectionTitle: row["section_title"],
            wordCount: row["word_count"],
            metadataJSON: row["metadata_json"],
            createdAt: DateCoding.date(from: row["created_at"]),
            embedding: embeddingData,
            embeddingModel: embeddingModel,
            embeddingProvider: embeddingProvider,
            embeddingDimension: embeddingDimension,
            embeddingContentHash: embeddingContentHash,
            embeddingCreatedAt: embeddingCreatedAt
        )
    }

    // MARK: - Embedding Repository Extensions

    func chunksWithEmbeddings(type: DocumentType) throws -> [DocumentChunk] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT document_chunks.*, documents.type AS resolved_document_type
                FROM document_chunks
                JOIN documents ON documents.id = document_chunks.document_id
                WHERE documents.type = ? AND document_chunks.embedding IS NOT NULL
                ORDER BY chunk_index ASC
                """,
                arguments: [type.rawValue]
            ).map(Self.makeChunk)
        }
    }

    func updateChunkEmbedding(
        chunkID: String,
        embedding: [Float],
        model: String,
        provider: String,
        dimension: Int,
        contentHash: String
    ) throws {
        let data = VectorStore.encodeEmbedding(embedding)
        let now = DateCoding.string(from: Date())
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE document_chunks
                SET embedding = ?,
                    embedding_model = ?,
                    embedding_provider = ?,
                    embedding_dimension = ?,
                    embedding_content_hash = ?,
                    embedding_created_at = ?
                WHERE id = ?
                """,
                arguments: [data, model, provider, dimension, contentHash, now, chunkID]
            )
        }
    }

    func allChunks() throws -> [DocumentChunk] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT document_chunks.*, documents.type AS resolved_document_type
                FROM document_chunks
                JOIN documents ON documents.id = document_chunks.document_id
                ORDER BY chunk_index ASC
                """
            ).map(Self.makeChunk)
        }
    }

    func calculateContentHash(
        content: String,
        sectionTitle: String?,
        chunkerVersion: String = "v1",
        provider: String,
        modelName: String,
        dimension: Int
    ) -> String {
        let secTitle = sectionTitle ?? ""
        let raw = content + "|" + secTitle + "|" + chunkerVersion + "|" + provider + "|" + modelName + "|" + String(dimension)
        guard let data = raw.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func embeddingCoverage(currentProvider: String, currentModel: String) throws -> EmbeddingCoverage {
        let chunks = try allChunks()
        let total = chunks.count
        
        let validChunks = chunks.filter { chunk in
            guard let hash = chunk.embeddingContentHash,
                  let provider = chunk.embeddingProvider,
                  let model = chunk.embeddingModel,
                  let dim = chunk.embeddingDimension,
                  chunk.embedding != nil else {
                return false
            }
            let expectedHash = calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: currentProvider,
                modelName: currentModel,
                dimension: dim
            )
            return hash == expectedHash && provider == currentProvider && model == currentModel
        }
        
        let chunksWithEmbeddings = validChunks.count
        let coveragePercent = total > 0 ? (Double(chunksWithEmbeddings) / Double(total) * 100.0) : 100.0
        let staleChunksCount = total - chunksWithEmbeddings
        let dimension = validChunks.first?.embeddingDimension
        
        return EmbeddingCoverage(
            totalChunks: total,
            chunksWithEmbeddings: chunksWithEmbeddings,
            coveragePercent: coveragePercent,
            modelName: currentModel,
            provider: currentProvider,
            dimension: dimension,
            staleChunksCount: staleChunksCount
        )
    }
}

public struct EmbeddingCoverage: Codable, Equatable {
    public let totalChunks: Int
    public let chunksWithEmbeddings: Int
    public let coveragePercent: Double
    public let modelName: String?
    public let provider: String?
    public let dimension: Int?
    public let staleChunksCount: Int
}
