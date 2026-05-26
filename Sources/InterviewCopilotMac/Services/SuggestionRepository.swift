import Foundation
import GRDB

final class SuggestionRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func saveDetectedQuestion(_ question: DetectedQuestion) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO detected_questions (
                    id, session_id, transcript_segment_id, question_text, intent, answer_strategy,
                    confidence, reason, should_trigger, question_complete, model_name, prompt_version,
                    provider_kind, provider_name, provider_base_url, latency_ms, is_local, raw_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    question.id,
                    question.sessionID,
                    question.transcriptSegmentID,
                    question.questionText,
                    question.intent.rawValue,
                    question.answerStrategy.rawValue,
                    question.confidence,
                    question.reason,
                    question.shouldTrigger,
                    question.questionComplete,
                    question.modelName,
                    question.promptVersion,
                    question.providerKind?.rawValue,
                    question.providerName,
                    question.providerBaseURL,
                    question.latencyMS,
                    question.isLocal,
                    question.rawJSON,
                    DateCoding.string(from: question.createdAt)
                ]
            )
        }
    }

    func saveSuggestionCard(_ card: SuggestionCard) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO suggestion_cards (
                    id, session_id, question_id, strategy, say_first, key_points_json,
                    follow_up_ready_json, confidence, caution, evidence_used_json, risk_level,
                    model_name, prompt_version, provider_kind, provider_name, provider_base_url,
                    latency_ms, is_local, raw_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    card.id,
                    card.sessionID,
                    card.questionID,
                    card.strategy,
                    card.sayFirst,
                    JSONParsing.jsonString(card.keyPoints),
                    JSONParsing.jsonString(card.followUpReady),
                    card.confidence,
                    card.caution,
                    JSONParsing.jsonString(card.evidenceUsed),
                    card.riskLevel?.rawValue,
                    card.modelName,
                    card.promptVersion,
                    card.providerKind?.rawValue,
                    card.providerName,
                    card.providerBaseURL,
                    card.latencyMS,
                    card.isLocal,
                    card.rawJSON,
                    DateCoding.string(from: card.createdAt)
                ]
            )
        }
    }

    func questions(sessionID: String) throws -> [DetectedQuestion] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM detected_questions WHERE session_id = ? ORDER BY created_at ASC",
                arguments: [sessionID]
            ).map(Self.makeQuestion)
        }
    }

    func suggestions(sessionID: String) throws -> [SuggestionCard] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM suggestion_cards WHERE session_id = ? ORDER BY created_at ASC",
                arguments: [sessionID]
            ).map(Self.makeCard)
        }
    }

    func latestSuggestion(sessionID: String) throws -> SuggestionCard? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM suggestion_cards WHERE session_id = ? ORDER BY created_at DESC LIMIT 1",
                arguments: [sessionID]
            )
            return row.map(Self.makeCard)
        }
    }

    private static func makeQuestion(row: Row) -> DetectedQuestion {
        DetectedQuestion(
            id: row["id"],
            sessionID: row["session_id"],
            transcriptSegmentID: row["transcript_segment_id"],
            questionText: row["question_text"],
            intent: QuestionIntent(rawValue: row["intent"]) ?? .unclear,
            answerStrategy: AnswerStrategy(rawValue: row["answer_strategy"]) ?? .wait,
            confidence: row["confidence"],
            reason: row["reason"],
            shouldTrigger: row["should_trigger"],
            questionComplete: row["question_complete"],
            modelName: row["model_name"],
            promptVersion: row["prompt_version"],
            providerKind: (row["provider_kind"] as String?).flatMap(LLMProviderKind.init(rawValue:)),
            providerName: row["provider_name"],
            providerBaseURL: row["provider_base_url"],
            latencyMS: row["latency_ms"],
            isLocal: row["is_local"],
            rawJSON: row["raw_json"],
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }

    private static func makeCard(row: Row) -> SuggestionCard {
        let riskString: String? = row["risk_level"]
        return SuggestionCard(
            id: row["id"],
            sessionID: row["session_id"],
            questionID: row["question_id"],
            strategy: row["strategy"],
            sayFirst: row["say_first"],
            keyPoints: JSONParsing.decodeArray(String.self, from: row["key_points_json"]),
            followUpReady: JSONParsing.decodeArray(String.self, from: row["follow_up_ready_json"]),
            confidence: row["confidence"],
            caution: row["caution"],
            evidenceUsed: JSONParsing.decodeArray(String.self, from: row["evidence_used_json"] ?? "[]"),
            riskLevel: riskString.flatMap(RiskLevel.init(rawValue:)),
            modelName: row["model_name"],
            promptVersion: row["prompt_version"],
            providerKind: (row["provider_kind"] as String?).flatMap(LLMProviderKind.init(rawValue:)),
            providerName: row["provider_name"],
            providerBaseURL: row["provider_base_url"],
            latencyMS: row["latency_ms"],
            isLocal: row["is_local"],
            rawJSON: row["raw_json"],
            createdAt: DateCoding.date(from: row["created_at"])
        )
    }
}
