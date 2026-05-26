import Foundation
import GRDB

final class TranscriptRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func saveSegment(_ segment: TranscriptSegment) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, session_id, speaker, text, start_time, end_time, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    segment.id,
                    segment.sessionID,
                    segment.speaker.rawValue,
                    segment.text,
                    segment.startTime,
                    segment.endTime,
                    DateCoding.string(from: segment.createdAt)
                ]
            )
        }
    }

    func segments(sessionID: String) throws -> [TranscriptSegment] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE session_id = ? ORDER BY created_at ASC",
                arguments: [sessionID]
            ).map(Self.makeSegment)
        }
    }

    func recentSegments(sessionID: String, limit: Int = 24) throws -> [TranscriptSegment] {
        try database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE session_id = ? ORDER BY created_at DESC LIMIT ?",
                arguments: [sessionID, limit]
            )
            return rows.map(Self.makeSegment).reversed()
        }
    }

    private static func makeSegment(row: Row) -> TranscriptSegment {
        TranscriptSegment(
            id: row["id"],
            sessionID: row["session_id"],
            speaker: SpeakerRole(rawValue: row["speaker"]) ?? .audioInput,
            text: row["text"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }
}
