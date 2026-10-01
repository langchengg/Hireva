import Foundation
import GRDB

struct HistoryCorrection: Codable, Identifiable, Equatable {
    var id: Int { revision }
    let sessionID: String
    let revision: Int
    let segmentID: String
    let originalText: String
    let text: String
    let speaker: SpeakerRole
    let startsQuestion: Bool
    let questionText: String
    let createdAt: Date
}

/// Original ASR rows are preserved. Effective input is an explicit overlay;
/// deletion cascades both original and corrected text in the same transaction.
final class HistoryCorrectionRepository {
    let database: AppDatabase
    init(database: AppDatabase) { self.database = database }
    func revisions(sessionID: String) throws -> [HistoryCorrection] {
        try database.dbQueue.read { db in
            try Self.revisions(sessionID: sessionID, db: db)
        }
    }
    private static func revisions(sessionID: String, db: Database) throws -> [HistoryCorrection] {
        try Data.fetchAll(db, sql: "SELECT payload_json FROM history_corrections WHERE session_id = ? ORDER BY revision", arguments: [sessionID]).map { try JSONDecoder().decode(HistoryCorrection.self, from: $0) }
    }
    func save(segment: TranscriptSegment, text: String, speaker: SpeakerRole, startsQuestion: Bool, question: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 24000, question.count <= 6000 else { throw MaterialError.invalid("Correction text is empty or exceeds the input budget.") }
        try database.dbQueue.write { db in
            guard let revision = try Int.fetchOne(db, sql: "SELECT content_revision FROM interview_sessions WHERE id = ?", arguments: [segment.sessionID]),
                  let original = try String.fetchOne(db, sql: "SELECT text FROM transcript_segments WHERE id = ? AND session_id = ?", arguments: [segment.id, segment.sessionID]) else { throw CancellationError() }
            let history = try Self.revisions(sessionID: segment.sessionID, db: db)
            if let previous = history.last(where: { $0.segmentID == segment.id }), previous.text == clean, previous.speaker == speaker, previous.startsQuestion == startsQuestion, previous.questionText == question { return }
            let correction = HistoryCorrection(sessionID: segment.sessionID, revision: revision + 1, segmentID: segment.id, originalText: original, text: clean, speaker: speaker, startsQuestion: startsQuestion, questionText: question, createdAt: Date())
            try db.execute(sql: "INSERT INTO history_corrections (session_id, revision, payload_json) VALUES (?, ?, ?)", arguments: [segment.sessionID, revision + 1, try JSONEncoder().encode(correction)])
            try db.execute(sql: "UPDATE interview_sessions SET content_revision = ? WHERE id = ?", arguments: [revision + 1, segment.sessionID])
        }
    }
    func effectiveTranscript(_ original: [TranscriptSegment], sessionID: String) throws -> [TranscriptSegment] {
        let history = try revisions(sessionID: sessionID)
        return original.map { segment in
            guard let revision = history.last(where: { $0.segmentID == segment.id }) else { return segment }
            var result = segment; result.text = revision.text; result.speaker = revision.speaker
            return result
        }
    }
    func effectiveQuestions(_ original: [DetectedQuestion], transcript: [TranscriptSegment], sessionID: String) throws -> [DetectedQuestion] {
        let history = try revisions(sessionID: sessionID)
        var result = original
        for segment in transcript {
            guard let correction = history.last(where: { $0.segmentID == segment.id }) else { continue }
            if !correction.startsQuestion { result.removeAll { $0.transcriptSegmentID == segment.id }; continue }
            let text = correction.questionText.isEmpty ? correction.text : correction.questionText
            if let index = result.firstIndex(where: { $0.transcriptSegmentID == segment.id }) {
                result[index].questionText = text; result[index].taskDescriptor = nil
            } else {
                // Reuse the source occurrence ID; no synthetic classifier ID system.
                result.append(DetectedQuestion(id: segment.id, sessionID: sessionID, transcriptSegmentID: segment.id, questionText: text, intent: .unclear, answerStrategy: .clarifyFirst, confidence: 0, shouldTrigger: false, questionComplete: true, modelName: "User correction", promptVersion: "history-v1", createdAt: segment.createdAt))
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
}
