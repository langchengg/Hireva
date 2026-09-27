import Foundation
import GRDB

final class PracticeRepository {
    let database: AppDatabase
    init(database: AppDatabase) { self.database = database }
    func save(_ run: PracticeRun) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO practice_runs (session_id, payload_json) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET payload_json = excluded.payload_json", arguments: [run.sessionID, try JSONEncoder().encode(run)])
        }
    }
    func load(sessionID: String) throws -> PracticeRun? {
        try database.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload_json FROM practice_runs WHERE session_id = ?", arguments: [sessionID]).map { try JSONDecoder().decode(PracticeRun.self, from: $0) }
        }
    }
    func saveReview(_ card: KnowledgeReviewCard) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO knowledge_reviews (id, session_id, payload_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json", arguments: [card.id, card.sessionID, try JSONEncoder().encode(card)])
        }
    }
    func reviews() throws -> [KnowledgeReviewCard] {
        try database.dbQueue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload_json FROM knowledge_reviews").map { try JSONDecoder().decode(KnowledgeReviewCard.self, from: $0) }.sorted { $0.card.due < $1.card.due }
        }
    }
    func deleteReview(id: String) throws {
        try database.dbQueue.write { try $0.execute(sql: "DELETE FROM knowledge_reviews WHERE id = ?", arguments: [id]) }
    }
}
