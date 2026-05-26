import Foundation
import GRDB

final class SessionRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func createSession(mode: InterviewMode, title: String? = nil) throws -> InterviewSession {
        let now = Date()
        let session = InterviewSession(
            id: UUID().uuidString,
            title: title ?? "Interview \(Self.titleDateFormatter.string(from: now))",
            company: nil,
            role: nil,
            startedAt: now,
            endedAt: nil,
            mode: mode,
            createdAt: now
        )
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id,
                    session.title,
                    session.company,
                    session.role,
                    DateCoding.string(from: session.startedAt),
                    nil,
                    session.mode.rawValue,
                    DateCoding.string(from: session.createdAt)
                ]
            )
        }
        return session
    }

    func endSession(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE interview_sessions SET ended_at = ? WHERE id = ?",
                arguments: [DateCoding.string(from: Date()), id]
            )
        }
    }

    func listSessions() throws -> [InterviewSession] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM interview_sessions ORDER BY started_at DESC")
                .map(Self.makeSession)
        }
    }

    func session(id: String) throws -> InterviewSession? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM interview_sessions WHERE id = ?", arguments: [id])
            return row.map(Self.makeSession)
        }
    }

    func deleteSession(id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM interview_sessions WHERE id = ?", arguments: [id])
        }
    }

    func deleteAllSessions() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM interview_sessions")
        }
    }

    private static let titleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func makeSession(row: Row) -> InterviewSession {
        let endedAtString: String? = row["ended_at"]
        return InterviewSession(
            id: row["id"],
            title: row["title"],
            company: row["company"],
            role: row["role"],
            startedAt: DateCoding.date(from: row["started_at"]),
            endedAt: endedAtString.map(DateCoding.date),
            mode: InterviewMode(rawValue: row["mode"]) ?? .mock,
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }
}
