import Foundation
import GRDB

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
        let record = DocumentRecord(
            id: existing?.id ?? UUID().uuidString,
            type: type,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? type.title : title,
            content: trimmed,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        let chunks = TextChunker.chunks(from: trimmed)

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO documents (id, type, title, content, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type = excluded.type,
                    title = excluded.title,
                    content = excluded.content,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    record.id,
                    record.type.rawValue,
                    record.title,
                    record.content,
                    DateCoding.string(from: record.createdAt),
                    DateCoding.string(from: record.updatedAt)
                ]
            )
            try db.execute(sql: "DELETE FROM document_chunks WHERE document_id = ?", arguments: [record.id])
            for (index, chunk) in chunks.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO document_chunks (id, document_id, document_type, chunk_index, content, keywords, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        record.id,
                        record.type.rawValue,
                        index,
                        chunk.content,
                        chunk.keywords.joined(separator: ","),
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
            updatedAt: DateCoding.date(from: row["updated_at"])
        )
    }

    private static func makeChunk(row: Row) -> DocumentChunk {
        let typeString: String = row["resolved_document_type"] ?? row["document_type"]
        let keywordsString: String? = row["keywords"]
        return DocumentChunk(
            id: row["id"],
            documentID: row["document_id"],
            documentType: DocumentType(rawValue: typeString) ?? .cv,
            chunkIndex: row["chunk_index"],
            content: row["content"],
            keywords: keywordsString?.split(separator: ",").map(String.init) ?? [],
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }
}
