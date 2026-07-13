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
                INSERT INTO transcript_segments (
                    id, session_id, speaker, text, start_time, end_time, created_at,
                    source, input_device_name, output_device_name, device_id, confidence,
                    asr_first_partial_ms, asr_final_ms, asr_best_selected_ms, asr_finalization_reason,
                    asr_source
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id = excluded.session_id,
                    speaker = excluded.speaker,
                    text = excluded.text,
                    start_time = excluded.start_time,
                    end_time = excluded.end_time,
                    created_at = excluded.created_at,
                    source = excluded.source,
                    input_device_name = excluded.input_device_name,
                    output_device_name = excluded.output_device_name,
                    device_id = excluded.device_id,
                    confidence = excluded.confidence,
                    asr_first_partial_ms = excluded.asr_first_partial_ms,
                    asr_final_ms = excluded.asr_final_ms,
                    asr_best_selected_ms = excluded.asr_best_selected_ms,
                    asr_finalization_reason = excluded.asr_finalization_reason,
                    asr_source = excluded.asr_source
                """,
                arguments: [
                    segment.id,
                    segment.sessionID,
                    segment.speaker.rawValue,
                    segment.text,
                    segment.startTime,
                    segment.endTime,
                    DateCoding.string(from: segment.createdAt),
                    segment.source.rawValue,
                    segment.inputDeviceName,
                    segment.outputDeviceName,
                    segment.deviceID,
                    segment.confidence,
                    segment.asrFirstPartialMS,
                    segment.asrFinalMS,
                    segment.asrBestSelectedMS,
                    segment.asrFinalizationReason,
                    segment.asrSource?.rawValue
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

    func segmentByID(_ id: String) throws -> TranscriptSegment? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transcript_segments WHERE id = ?",
                arguments: [id]
            )
            return row.map(Self.makeSegment)
        }
    }

    private static func makeSegment(row: Row) -> TranscriptSegment {
        let speakerStr: String = row["speaker"]
        let speaker: SpeakerRole
        if speakerStr == "audio_input" {
            speaker = .unknown
        } else {
            speaker = SpeakerRole(rawValue: speakerStr) ?? .unknown
        }

        let sourceStr: String? = row["source"]
        let source = sourceStr.flatMap(AudioSourceType.init(rawValue:)) ?? .microphone
        let asrSourceStr: String? = row["asr_source"]

        let confidence: Double? = row["confidence"]

        return TranscriptSegment(
            id: row["id"],
            sessionID: row["session_id"],
            source: source,
            speaker: speaker,
            text: row["text"],
            startTime: row["start_time"],
            endTime: row["end_time"],
            createdAt: DateCoding.date(from: row["created_at"]),
            inputDeviceName: row["input_device_name"],
            outputDeviceName: row["output_device_name"],
            deviceID: row["device_id"],
            confidence: confidence ?? 1.0,
            asrSource: asrSourceStr.flatMap(ASRSource.init(rawValue:)),
            asrFirstPartialMS: row["asr_first_partial_ms"],
            asrFinalMS: row["asr_final_ms"],
            asrBestSelectedMS: row["asr_best_selected_ms"],
            asrFinalizationReason: row["asr_finalization_reason"]
        )
    }
}
