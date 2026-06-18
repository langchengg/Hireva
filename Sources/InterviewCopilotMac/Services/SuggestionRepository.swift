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
        try saveSuggestionCard(card, retrievedChunks: nil)
    }

    func saveSuggestionCard(_ card: SuggestionCard, retrievedChunks: [RetrievedChunk]) throws {
        try saveSuggestionCard(card, retrievedChunks: Optional(retrievedChunks))
    }

    private func saveSuggestionCard(_ card: SuggestionCard, retrievedChunks: [RetrievedChunk]?) throws {
        try database.dbQueue.write { db in
            var card = card
            if card.detectedQuestionID == nil {
                card.detectedQuestionID = card.questionID
            }
            if let questionID = card.detectedQuestionID,
               card.questionText == nil || card.transcriptSegmentID == nil || card.source == nil || card.speaker == nil {
                let bindingRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT dq.question_text, dq.transcript_segment_id, ts.source, ts.speaker
                    FROM detected_questions dq
                    LEFT JOIN transcript_segments ts ON ts.id = dq.transcript_segment_id
                    WHERE dq.id = ?
                    """,
                    arguments: [questionID]
                )
                card.questionText = card.questionText ?? (bindingRow?["question_text"] as String?)
                card.transcriptSegmentID = card.transcriptSegmentID ?? (bindingRow?["transcript_segment_id"] as String?)
                card.source = card.source ?? (bindingRow?["source"] as String?)
                card.speaker = card.speaker ?? (bindingRow?["speaker"] as String?)
            }

            try db.execute(
                sql: """
                INSERT INTO suggestion_cards (
                    id, session_id, question_id, detected_question_id, question_text,
                    transcript_segment_id, generation_id, source, speaker, trigger_path,
                    alignment_score, alignment_verdict,
                    question_intent, answer_intent, prompt_question_text,
                    prompt_token_estimate, prompt_context_preview, mismatch_reason,
                    strategy, say_first, key_points_json,
                    follow_up_ready_json, confidence, caution, evidence_used_json, risk_level,
                    model_name, prompt_version, provider_kind, provider_name, provider_base_url,
                    latency_ms, is_local, raw_json, created_at,
                    say_first_source, stage_a_timed_out, stage_b_completed, stage_b_status,
                    latency_first_token_ms, latency_first_visible_ms, latency_full_card_ms,
                    soft_fallback_used, soft_fallback_latency_ms, deepseek_first_token_ms,
                    deepseek_first_visible_ms, final_visible_source,
                    rag_retrieval_latency_ms, question_asr_first_partial_ms,
                    question_asr_final_ms, question_asr_best_selected_ms,
                    first_visible_answer_ms, first_key_point_visible_ms,
                    all_key_points_visible_ms, follow_up_visible_ms,
                    full_card_visible_ms, db_persisted_ms,
                    stage_b_stream_started_ms, stage_b_first_section_ms
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id = excluded.session_id,
                    question_id = excluded.question_id,
                    detected_question_id = excluded.detected_question_id,
                    question_text = excluded.question_text,
                    transcript_segment_id = excluded.transcript_segment_id,
                    generation_id = excluded.generation_id,
                    source = excluded.source,
                    speaker = excluded.speaker,
                    trigger_path = excluded.trigger_path,
                    alignment_score = excluded.alignment_score,
                    alignment_verdict = excluded.alignment_verdict,
                    question_intent = excluded.question_intent,
                    answer_intent = excluded.answer_intent,
                    prompt_question_text = excluded.prompt_question_text,
                    prompt_token_estimate = excluded.prompt_token_estimate,
                    prompt_context_preview = excluded.prompt_context_preview,
                    mismatch_reason = excluded.mismatch_reason,
                    strategy = excluded.strategy,
                    say_first = excluded.say_first,
                    key_points_json = excluded.key_points_json,
                    follow_up_ready_json = excluded.follow_up_ready_json,
                    confidence = excluded.confidence,
                    caution = excluded.caution,
                    evidence_used_json = excluded.evidence_used_json,
                    risk_level = excluded.risk_level,
                    model_name = excluded.model_name,
                    prompt_version = excluded.prompt_version,
                    provider_kind = excluded.provider_kind,
                    provider_name = excluded.provider_name,
                    provider_base_url = excluded.provider_base_url,
                    latency_ms = excluded.latency_ms,
                    is_local = excluded.is_local,
                    raw_json = excluded.raw_json,
                    say_first_source = excluded.say_first_source,
                    stage_a_timed_out = excluded.stage_a_timed_out,
                    stage_b_completed = excluded.stage_b_completed,
                    stage_b_status = excluded.stage_b_status,
                    latency_first_token_ms = excluded.latency_first_token_ms,
                    latency_first_visible_ms = excluded.latency_first_visible_ms,
                    latency_full_card_ms = excluded.latency_full_card_ms,
                    soft_fallback_used = excluded.soft_fallback_used,
                    soft_fallback_latency_ms = excluded.soft_fallback_latency_ms,
                    deepseek_first_token_ms = excluded.deepseek_first_token_ms,
                    deepseek_first_visible_ms = excluded.deepseek_first_visible_ms,
                    final_visible_source = excluded.final_visible_source,
                    rag_retrieval_latency_ms = excluded.rag_retrieval_latency_ms,
                    question_asr_first_partial_ms = excluded.question_asr_first_partial_ms,
                    question_asr_final_ms = excluded.question_asr_final_ms,
                    question_asr_best_selected_ms = excluded.question_asr_best_selected_ms,
                    first_visible_answer_ms = excluded.first_visible_answer_ms,
                    first_key_point_visible_ms = excluded.first_key_point_visible_ms,
                    all_key_points_visible_ms = excluded.all_key_points_visible_ms,
                    follow_up_visible_ms = excluded.follow_up_visible_ms,
                    full_card_visible_ms = excluded.full_card_visible_ms,
                    db_persisted_ms = excluded.db_persisted_ms,
                    stage_b_stream_started_ms = excluded.stage_b_stream_started_ms,
                    stage_b_first_section_ms = excluded.stage_b_first_section_ms
                """,
                arguments: [
                    card.id,
                    card.sessionID,
                    card.questionID,
                    card.detectedQuestionID,
                    card.questionText,
                    card.transcriptSegmentID,
                    card.generationID,
                    card.source,
                    card.speaker,
                    card.triggerPath?.rawValue,
                    card.alignmentScore,
                    card.alignmentVerdict?.rawValue,
                    card.questionIntent?.rawValue,
                    card.answerIntent?.rawValue,
                    card.promptQuestionText,
                    card.promptTokenEstimate,
                    card.promptContextPreview,
                    card.mismatchReason,
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
                    card.finalVisibleSource,
                    card.ragRetrievalLatencyMS,
                    card.questionASRFirstPartialMS,
                    card.questionASRFinalMS,
                    card.questionASRBestSelectedMS,
                    card.firstVisibleAnswerMS ?? card.latencyFirstVisibleMS,
                    card.firstKeyPointVisibleMS,
                    card.allKeyPointsVisibleMS,
                    card.followUpVisibleMS,
                    card.fullCardVisibleMS ?? card.latencyFullCardMS,
                    card.dbPersistedMS,
                    card.stageBStreamStartedMS,
                    card.stageBFirstSectionMS
                ]
            )

            try db.execute(
                sql: """
                UPDATE suggestion_cards
                SET prompt_primary_question = ?,
                    prompt_contains_previous_question = ?,
                    previous_question_included = ?,
                    previous_question_text = ?,
                    context_bleed_risk = ?,
                    rag_chunk_ids_json = ?,
                    rag_chunk_intents_json = ?,
                    first_question_suppressed_reason = ?
                WHERE id = ?
                """,
                arguments: [
                    card.promptPrimaryQuestion ?? card.promptQuestionText ?? card.questionText,
                    card.promptContainsPreviousQuestion.map { $0 ? 1 : 0 },
                    card.previousQuestionIncluded.map { $0 ? 1 : 0 },
                    card.previousQuestionText,
                    card.contextBleedRisk?.rawValue,
                    JSONParsing.jsonString(card.ragChunkIDs),
                    JSONParsing.jsonString(card.ragChunkIntents.map(\.rawValue)),
                    card.firstQuestionSuppressedReason,
                    card.id
                ]
            )

            guard let retrievedChunks else { return }

            try db.execute(
                sql: "DELETE FROM suggestion_card_retrieved_chunks WHERE suggestion_card_id = ?",
                arguments: [card.id]
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

    func suggestionCount() throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM suggestion_cards") ?? 0
        }
    }

    func latestSuggestion() throws -> SuggestionCard? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM suggestion_cards ORDER BY created_at DESC LIMIT 1"
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
        let promptContainsPreviousQuestionInt: Int? = row["prompt_contains_previous_question"]
        let previousQuestionIncludedInt: Int? = row["previous_question_included"]
        let contextBleedRiskString: String? = row["context_bleed_risk"]
        let ragChunkIntentRawValues = JSONParsing.decodeArray(String.self, from: row["rag_chunk_intents_json"] ?? "[]")
        
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
            questionText: row["question_text"],
            transcriptSegmentID: row["transcript_segment_id"],
            generationID: row["generation_id"],
            source: row["source"],
            speaker: row["speaker"],
            triggerPath: (row["trigger_path"] as String?).flatMap(GenerationTriggerPath.init(rawValue:)),
            alignmentScore: row["alignment_score"],
            alignmentVerdict: (row["alignment_verdict"] as String?).flatMap(AnswerAlignmentVerdict.init(rawValue:)),
            questionIntent: (row["question_intent"] as String?).flatMap(AnswerRelevanceIntent.init(rawValue:)),
            answerIntent: (row["answer_intent"] as String?).flatMap(AnswerRelevanceIntent.init(rawValue:)),
            promptQuestionText: row["prompt_question_text"],
            promptPrimaryQuestion: row["prompt_primary_question"],
            promptContainsPreviousQuestion: promptContainsPreviousQuestionInt.map { $0 == 1 },
            previousQuestionIncluded: previousQuestionIncludedInt.map { $0 == 1 },
            previousQuestionText: row["previous_question_text"],
            contextBleedRisk: contextBleedRiskString.flatMap(ContextBleedRisk.init(rawValue:)),
            ragChunkIDs: JSONParsing.decodeArray(String.self, from: row["rag_chunk_ids_json"] ?? "[]"),
            ragChunkIntents: ragChunkIntentRawValues.compactMap(AnswerRelevanceIntent.init(rawValue:)),
            firstQuestionSuppressedReason: row["first_question_suppressed_reason"],
            promptTokenEstimate: row["prompt_token_estimate"],
            promptContextPreview: row["prompt_context_preview"],
            mismatchReason: row["mismatch_reason"],
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
            finalVisibleSource: row["final_visible_source"],
            ragRetrievalLatencyMS: row["rag_retrieval_latency_ms"],
            questionASRFirstPartialMS: row["question_asr_first_partial_ms"],
            questionASRFinalMS: row["question_asr_final_ms"],
            questionASRBestSelectedMS: row["question_asr_best_selected_ms"],
            firstVisibleAnswerMS: row["first_visible_answer_ms"],
            firstKeyPointVisibleMS: row["first_key_point_visible_ms"],
            allKeyPointsVisibleMS: row["all_key_points_visible_ms"],
            followUpVisibleMS: row["follow_up_visible_ms"],
            fullCardVisibleMS: row["full_card_visible_ms"],
            dbPersistedMS: row["db_persisted_ms"],
            stageBStreamStartedMS: row["stage_b_stream_started_ms"],
            stageBFirstSectionMS: row["stage_b_first_section_ms"]
        )
    }

    // MARK: - Latency Averages

    func fetchLatencyAverages(
        last n: Int = 10,
        provider: String? = nil,
        mode: InterviewMode? = nil
    ) throws -> LatencyAverages {
        try database.dbQueue.read { db in
            var sql = """
                SELECT sc.latency_first_visible_ms, sc.latency_full_card_ms,
                       sc.first_visible_answer_ms, sc.first_key_point_visible_ms,
                       sc.all_key_points_visible_ms, sc.follow_up_visible_ms,
                       sc.full_card_visible_ms, sc.db_persisted_ms,
                       sc.stage_b_stream_started_ms, sc.stage_b_first_section_ms,
                       sc.rag_retrieval_latency_ms, sc.question_asr_best_selected_ms,
                       sc.soft_fallback_used, sc.stage_b_status
                FROM suggestion_cards sc
            """
            var conditions: [String] = []
            var args: [DatabaseValueConvertible?] = []

            if let provider {
                conditions.append("sc.provider_name = ?")
                args.append(provider)
            }
            if let mode {
                sql += " JOIN interview_sessions s ON sc.session_id = s.id"
                conditions.append("s.mode = ?")
                args.append(mode.rawValue)
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY sc.created_at DESC LIMIT ?"
            args.append(n)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args.map { $0 as Any }) ?? [])

            guard !rows.isEmpty else { return .empty }

            var firstVisibles: [Int] = []
            var firstKeyPoints: [Int] = []
            var allKeyPoints: [Int] = []
            var followUps: [Int] = []
            var fullCards: [Int] = []
            var dbPersisted: [Int] = []
            var streamStarted: [Int] = []
            var firstSections: [Int] = []
            var ragRetrievals: [Int] = []
            var asrBests: [Int] = []
            var softFallbackCount = 0
            var failureCount = 0

            for row in rows {
                if let v: Int = row["first_visible_answer_ms"] ?? row["latency_first_visible_ms"] { firstVisibles.append(v) }
                if let v: Int = row["first_key_point_visible_ms"] { firstKeyPoints.append(v) }
                if let v: Int = row["all_key_points_visible_ms"] { allKeyPoints.append(v) }
                if let v: Int = row["follow_up_visible_ms"] { followUps.append(v) }
                if let v: Int = row["full_card_visible_ms"] ?? row["latency_full_card_ms"] { fullCards.append(v) }
                if let v: Int = row["db_persisted_ms"] { dbPersisted.append(v) }
                if let v: Int = row["stage_b_stream_started_ms"] { streamStarted.append(v) }
                if let v: Int = row["stage_b_first_section_ms"] { firstSections.append(v) }
                if let v: Int = row["rag_retrieval_latency_ms"] { ragRetrievals.append(v) }
                if let v: Int = row["question_asr_best_selected_ms"] { asrBests.append(v) }
                if let sf: Int = row["soft_fallback_used"], sf == 1 { softFallbackCount += 1 }
                if let status: String = row["stage_b_status"], status != "completed" { failureCount += 1 }
            }

            let count = rows.count
            return LatencyAverages(
                count: count,
                avgFirstVisibleMS: Self.avg(firstVisibles),
                p50FirstVisibleMS: Self.percentile(firstVisibles, 50),
                p90FirstVisibleMS: Self.percentile(firstVisibles, 90),
                avgFirstKeyPointVisibleMS: Self.avg(firstKeyPoints),
                p50FirstKeyPointVisibleMS: Self.percentile(firstKeyPoints, 50),
                p90FirstKeyPointVisibleMS: Self.percentile(firstKeyPoints, 90),
                avgAllKeyPointsVisibleMS: Self.avg(allKeyPoints),
                avgFollowUpVisibleMS: Self.avg(followUps),
                avgFullCardMS: Self.avg(fullCards),
                p50FullCardMS: Self.percentile(fullCards, 50),
                p90FullCardMS: Self.percentile(fullCards, 90),
                avgDBPersistedMS: Self.avg(dbPersisted),
                avgStageBStreamStartedMS: Self.avg(streamStarted),
                avgStageBFirstSectionMS: Self.avg(firstSections),
                avgRagRetrievalMS: Self.avg(ragRetrievals),
                avgASRBestSelectedMS: Self.avg(asrBests),
                softFallbackRate: Double(softFallbackCount) / Double(count),
                failureRate: Double(failureCount) / Double(count)
            )
        }
    }

    // MARK: - Percentile Helpers

    private static func avg(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func percentile(_ values: [Int], _ p: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(ceil(Double(p) / 100.0 * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
