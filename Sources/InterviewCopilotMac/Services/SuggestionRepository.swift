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
        try saveSuggestionCard(card, retrievedChunks: [])
    }

    func saveSuggestionCard(_ card: SuggestionCard, retrievedChunks: [RetrievedChunk]) throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO suggestion_cards (
                    id, session_id, question_id, strategy, say_first, key_points_json,
                    follow_up_ready_json, confidence, caution, evidence_used_json, risk_level,
                    model_name, prompt_version, provider_kind, provider_name, provider_base_url,
                    latency_ms, is_local, raw_json, created_at,
                    say_first_source, stage_a_timed_out, stage_b_completed, stage_b_status,
                    latency_first_token_ms, latency_first_visible_ms, latency_full_card_ms,
                    soft_fallback_used, soft_fallback_latency_ms, deepseek_first_token_ms,
                    deepseek_first_visible_ms, final_visible_source
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    DateCoding.string(from: card.createdAt),
                    card.sayFirstSource,
                    card.stageATimedOut == true ? 1 : 0,
                    card.stageBCompleted == true ? 1 : 0,
                    card.stageBStatus,
                    card.latencyFirstTokenMS,
                    card.latencyFirstVisibleMS,
                    card.latencyFullCardMS,
                    card.softFallbackUsed == true ? 1 : 0,
                    card.softFallbackLatencyMS,
                    card.deepseekFirstTokenMS,
                    card.deepseekFirstVisibleMS,
                    card.finalVisibleSource
                ]
            )

            for chunk in retrievedChunks {
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
                        UUID().uuidString,
                        card.id,
                        chunk.id,
                        chunk.documentID,
                        chunk.documentType.rawValue,
                        chunk.chunkIndex,
                        chunk.contentPreview,
                        chunk.fullContent,
                        JSONParsing.jsonString(chunk.keywords),
                        chunk.score,
                        chunk.keywordOverlapCount,
                        chunk.contentOverlapCount,
                        chunk.rank,
                        chunk.isIncludedInPrompt ? 1 : 0,
                        chunk.sectionTitle,
                        chunk.wordCount,
                        chunk.semanticScore,
                        chunk.keywordScoreNormalized,
                        chunk.finalHybridScore,
                        chunk.retrievalMode,
                        DateCoding.string(from: card.createdAt)
                    ]
                )
            }
        }
    }

    func retrievedChunks(suggestionCardID: String) throws -> [RetrievedChunk] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM suggestion_card_retrieved_chunks WHERE suggestion_card_id = ? ORDER BY rank ASC",
                arguments: [suggestionCardID]
            ).map { row in
                let typeString: String = row["document_type"]
                let keywordsString: String = row["keywords_json"]
                let keywords = JSONParsing.decodeArray(String.self, from: keywordsString)
                
                let semanticScore: Double? = row["semantic_score"]
                let keywordScoreNormalized: Double? = row["keyword_score_normalized"]
                let finalHybridScore: Double? = row["final_hybrid_score"]
                let retrievalMode: String? = row["retrieval_mode"]

                return RetrievedChunk(
                    id: row["chunk_id"],
                    documentID: row["document_id"],
                    documentType: DocumentType(rawValue: typeString) ?? .cv,
                    chunkIndex: row["chunk_index"],
                    contentPreview: row["content_preview"],
                    fullContent: row["full_content"],
                    keywords: keywords,
                    score: row["score"],
                    keywordOverlapCount: row["keyword_overlap_count"] ?? 0,
                    contentOverlapCount: row["content_overlap_count"] ?? 0,
                    rank: row["rank"],
                    isIncludedInPrompt: (row["is_included"] as Int) != 0,
                    sectionTitle: row["section_title"],
                    wordCount: row["word_count"],
                    semanticScore: semanticScore,
                    keywordScoreNormalized: keywordScoreNormalized,
                    finalHybridScore: finalHybridScore,
                    retrievalMode: retrievalMode
                )
            }
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
        let stageATimedOutInt: Int? = row["stage_a_timed_out"]
        let stageBCompletedInt: Int? = row["stage_b_completed"]
        let softFallbackUsedInt: Int? = row["soft_fallback_used"]
        
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
            createdAt: DateCoding.date(from: row["created_at"]),
            sayFirstSource: row["say_first_source"],
            stageATimedOut: stageATimedOutInt == 1,
            stageBCompleted: stageBCompletedInt == 1,
            stageBStatus: row["stage_b_status"],
            latencyFirstTokenMS: row["latency_first_token_ms"],
            latencyFirstVisibleMS: row["latency_first_visible_ms"],
            latencyFullCardMS: row["latency_full_card_ms"],
            softFallbackUsed: softFallbackUsedInt == 1,
            softFallbackLatencyMS: row["soft_fallback_latency_ms"],
            deepseekFirstTokenMS: row["deepseek_first_token_ms"],
            deepseekFirstVisibleMS: row["deepseek_first_visible_ms"],
            finalVisibleSource: row["final_visible_source"]
        )
    }
}
