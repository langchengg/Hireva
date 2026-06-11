import Foundation
import GRDB

final class AppDatabase {
    let dbQueue: DatabaseQueue

    init(path: URL = AppPaths.databaseURL) throws {
        try AppPaths.ensureDirectoriesExist()
        let configuration = Self.makeConfiguration()
        dbQueue = try DatabaseQueue(path: path.path, configuration: configuration)
        try migrator.migrate(dbQueue)
    }

    init(inMemory: Bool) throws {
        dbQueue = try DatabaseQueue(configuration: Self.makeConfiguration())
        try migrator.migrate(dbQueue)
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return configuration
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "documents") { table in
                table.column("id", .text).primaryKey()
                table.column("type", .text).notNull().indexed()
                table.column("title", .text).notNull()
                table.column("content", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }

            try db.create(table: "document_chunks") { table in
                table.column("id", .text).primaryKey()
                table.column("document_id", .text).notNull().indexed().references("documents", onDelete: .cascade)
                table.column("document_type", .text).notNull().indexed()
                table.column("chunk_index", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("keywords", .text)
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "interview_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("company", .text)
                table.column("role", .text)
                table.column("started_at", .text).notNull()
                table.column("ended_at", .text)
                table.column("mode", .text).notNull()
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "transcript_segments") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull().indexed().references("interview_sessions", onDelete: .cascade)
                table.column("speaker", .text).notNull()
                table.column("text", .text).notNull()
                table.column("start_time", .double)
                table.column("end_time", .double)
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "detected_questions") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull().indexed().references("interview_sessions", onDelete: .cascade)
                table.column("transcript_segment_id", .text).references("transcript_segments", onDelete: .setNull)
                table.column("question_text", .text).notNull()
                table.column("intent", .text).notNull()
                table.column("answer_strategy", .text).notNull()
                table.column("confidence", .double).notNull()
                table.column("reason", .text)
                table.column("should_trigger", .boolean).notNull().defaults(to: false)
                table.column("question_complete", .boolean).notNull().defaults(to: false)
                table.column("model_name", .text).notNull()
                table.column("prompt_version", .text).notNull()
                table.column("raw_json", .text)
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "suggestion_cards") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull().indexed().references("interview_sessions", onDelete: .cascade)
                table.column("question_id", .text).references("detected_questions", onDelete: .setNull)
                table.column("strategy", .text).notNull()
                table.column("say_first", .text).notNull()
                table.column("key_points_json", .text).notNull()
                table.column("follow_up_ready_json", .text).notNull()
                table.column("confidence", .double)
                table.column("caution", .text)
                table.column("evidence_used_json", .text)
                table.column("risk_level", .text)
                table.column("model_name", .text).notNull()
                table.column("prompt_version", .text).notNull()
                table.column("raw_json", .text)
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "recap_reports") { table in
                table.column("id", .text).primaryKey()
                table.column("session_id", .text).notNull().indexed().references("interview_sessions", onDelete: .cascade)
                table.column("markdown", .text).notNull()
                table.column("model_name", .text).notNull()
                table.column("prompt_version", .text).notNull()
                table.column("created_at", .text).notNull()
            }

            try db.create(table: "app_settings") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
                table.column("updated_at", .text).notNull()
            }
        }

        migrator.registerMigration("v2_llm_providers") { db in
            try db.create(table: "llm_provider_configurations") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("kind", .text).notNull().indexed()
                table.column("base_url", .text).notNull()
                table.column("model", .text).notNull()
                table.column("api_key_account", .text)
                table.column("is_default_for_realtime", .boolean).notNull().defaults(to: false)
                table.column("is_default_for_recap", .boolean).notNull().defaults(to: false)
                table.column("supports_json_mode", .boolean).notNull().defaults(to: true)
                table.column("supports_streaming", .boolean).notNull().defaults(to: false)
                table.column("supports_thinking", .boolean).notNull().defaults(to: false)
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }

            try db.execute(sql: "ALTER TABLE detected_questions ADD COLUMN provider_kind TEXT")
            try db.execute(sql: "ALTER TABLE detected_questions ADD COLUMN provider_name TEXT")
            try db.execute(sql: "ALTER TABLE detected_questions ADD COLUMN provider_base_url TEXT")
            try db.execute(sql: "ALTER TABLE detected_questions ADD COLUMN latency_ms INTEGER")
            try db.execute(sql: "ALTER TABLE detected_questions ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0")

            try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN provider_kind TEXT")
            try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN provider_name TEXT")
            try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN provider_base_url TEXT")
            try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN latency_ms INTEGER")
            try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0")

            try db.execute(sql: "ALTER TABLE recap_reports ADD COLUMN provider_kind TEXT")
            try db.execute(sql: "ALTER TABLE recap_reports ADD COLUMN provider_name TEXT")
            try db.execute(sql: "ALTER TABLE recap_reports ADD COLUMN provider_base_url TEXT")
            try db.execute(sql: "ALTER TABLE recap_reports ADD COLUMN latency_ms INTEGER")
            try db.execute(sql: "ALTER TABLE recap_reports ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0")
        }

        migrator.registerMigration("v3_speaker_attribution") { db in
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN source TEXT")
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN input_device_name TEXT")
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN output_device_name TEXT")
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN device_id TEXT")
            try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN confidence REAL")
        }

        migrator.registerMigration("v4_rag_attribution") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(document_chunks)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            
            if !columnNames.contains("section_title") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN section_title TEXT")
            }
            if !columnNames.contains("word_count") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN word_count INTEGER")
            }
            if !columnNames.contains("metadata_json") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN metadata_json TEXT")
            }
            
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS suggestion_card_retrieved_chunks (
                id TEXT PRIMARY KEY,
                suggestion_card_id TEXT NOT NULL REFERENCES suggestion_cards(id) ON DELETE CASCADE,
                chunk_id TEXT NOT NULL,
                document_id TEXT NOT NULL,
                document_type TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                content_preview TEXT NOT NULL,
                full_content TEXT NOT NULL,
                keywords_json TEXT NOT NULL,
                score REAL NOT NULL,
                keyword_overlap_count INTEGER NOT NULL,
                content_overlap_count INTEGER NOT NULL,
                rank INTEGER NOT NULL,
                is_included INTEGER NOT NULL DEFAULT 1,
                section_title TEXT,
                word_count INTEGER,
                created_at TEXT NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_suggestion_card_retrieved_chunks_card_id ON suggestion_card_retrieved_chunks(suggestion_card_id)")
        }

        migrator.registerMigration("v5_rag_embeddings") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(document_chunks)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            
            if !columnNames.contains("embedding") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding BLOB")
            }
            if !columnNames.contains("embedding_model") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding_model TEXT")
            }
            if !columnNames.contains("embedding_provider") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding_provider TEXT")
            }
            if !columnNames.contains("embedding_dimension") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding_dimension INTEGER")
            }
            if !columnNames.contains("embedding_content_hash") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding_content_hash TEXT")
            }
            if !columnNames.contains("embedding_created_at") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN embedding_created_at TEXT")
            }
            
            let scRows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_card_retrieved_chunks)")
            let scColumnNames = scRows.compactMap { $0["name"] as? String }
            
            if !scColumnNames.contains("semantic_score") {
                try db.execute(sql: "ALTER TABLE suggestion_card_retrieved_chunks ADD COLUMN semantic_score REAL")
            }
            if !scColumnNames.contains("keyword_score_normalized") {
                try db.execute(sql: "ALTER TABLE suggestion_card_retrieved_chunks ADD COLUMN keyword_score_normalized REAL")
            }
            if !scColumnNames.contains("final_hybrid_score") {
                try db.execute(sql: "ALTER TABLE suggestion_card_retrieved_chunks ADD COLUMN final_hybrid_score REAL")
            }
            if !scColumnNames.contains("retrieval_mode") {
                try db.execute(sql: "ALTER TABLE suggestion_card_retrieved_chunks ADD COLUMN retrieval_mode TEXT")
            }
        }

        migrator.registerMigration("v6_suggestion_provenance") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            
            if !columnNames.contains("say_first_source") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN say_first_source TEXT")
            }
            if !columnNames.contains("stage_a_timed_out") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN stage_a_timed_out INTEGER")
            }
            if !columnNames.contains("stage_b_completed") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN stage_b_completed INTEGER")
            }
            if !columnNames.contains("stage_b_status") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN stage_b_status TEXT")
            }
            if !columnNames.contains("latency_first_token_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN latency_first_token_ms INTEGER")
            }
            if !columnNames.contains("latency_first_visible_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN latency_first_visible_ms INTEGER")
            }
            if !columnNames.contains("latency_full_card_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN latency_full_card_ms INTEGER")
            }
        }

        migrator.registerMigration("v7_suggestion_soft_fallback") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }
            
            if !columnNames.contains("soft_fallback_used") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN soft_fallback_used INTEGER")
            }
            if !columnNames.contains("soft_fallback_latency_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN soft_fallback_latency_ms INTEGER")
            }
            if !columnNames.contains("deepseek_first_token_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN deepseek_first_token_ms INTEGER")
            }
            if !columnNames.contains("deepseek_first_visible_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN deepseek_first_visible_ms INTEGER")
            }
            if !columnNames.contains("final_visible_source") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN final_visible_source TEXT")
            }
        }

        migrator.registerMigration("v8_latency_metrics") { db in
            // transcript_segments: utterance-level ASR latency
            let tsRows = try Row.fetchAll(db, sql: "PRAGMA table_info(transcript_segments)")
            let tsColumns = tsRows.compactMap { $0["name"] as? String }
            
            if !tsColumns.contains("asr_first_partial_ms") {
                try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN asr_first_partial_ms INTEGER")
            }
            if !tsColumns.contains("asr_final_ms") {
                try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN asr_final_ms INTEGER")
            }
            if !tsColumns.contains("asr_best_selected_ms") {
                try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN asr_best_selected_ms INTEGER")
            }
            if !tsColumns.contains("asr_finalization_reason") {
                try db.execute(sql: "ALTER TABLE transcript_segments ADD COLUMN asr_finalization_reason TEXT")
            }

            // suggestion_cards: pipeline latency persistence
            let scRows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let scColumns = scRows.compactMap { $0["name"] as? String }
            
            if !scColumns.contains("rag_retrieval_latency_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN rag_retrieval_latency_ms INTEGER")
            }
            if !scColumns.contains("question_asr_first_partial_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN question_asr_first_partial_ms INTEGER")
            }
            if !scColumns.contains("question_asr_final_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN question_asr_final_ms INTEGER")
            }
            if !scColumns.contains("question_asr_best_selected_ms") {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN question_asr_best_selected_ms INTEGER")
            }
        }

        migrator.registerMigration("v9_sanitized_content") { db in
            let docRows = try Row.fetchAll(db, sql: "PRAGMA table_info(documents)")
            let docColumns = docRows.compactMap { $0["name"] as? String }
            
            if !docColumns.contains("sanitized_content") {
                try db.execute(sql: "ALTER TABLE documents ADD COLUMN sanitized_content TEXT")
            }
            if !docColumns.contains("sanitized_preview") {
                try db.execute(sql: "ALTER TABLE documents ADD COLUMN sanitized_preview TEXT")
            }
            if !docColumns.contains("sanitization_warnings") {
                try db.execute(sql: "ALTER TABLE documents ADD COLUMN sanitization_warnings TEXT")
            }
        }

        migrator.registerMigration("v10_visible_content_latency_metrics") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }

            let columns: [(String, String)] = [
                ("first_visible_answer_ms", "INTEGER"),
                ("first_key_point_visible_ms", "INTEGER"),
                ("all_key_points_visible_ms", "INTEGER"),
                ("follow_up_visible_ms", "INTEGER"),
                ("full_card_visible_ms", "INTEGER"),
                ("db_persisted_ms", "INTEGER"),
                ("stage_b_stream_started_ms", "INTEGER"),
                ("stage_b_first_section_ms", "INTEGER")
            ]

            for (name, type) in columns where !columnNames.contains(name) {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN \(name) \(type)")
            }
        }

        migrator.registerMigration("v11_question_answer_alignment") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }

            let columns: [(String, String)] = [
                ("detected_question_id", "TEXT REFERENCES detected_questions(id) ON DELETE SET NULL"),
                ("question_text", "TEXT"),
                ("transcript_segment_id", "TEXT"),
                ("generation_id", "TEXT"),
                ("source", "TEXT"),
                ("speaker", "TEXT"),
                ("trigger_path", "TEXT"),
                ("alignment_score", "REAL"),
                ("alignment_verdict", "TEXT")
            ]

            for (name, type) in columns where !columnNames.contains(name) {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN \(name) \(type)")
            }

            try db.execute(sql: """
                UPDATE suggestion_cards
                SET detected_question_id = question_id
                WHERE detected_question_id IS NULL
                  AND question_id IS NOT NULL
                """)

            try db.execute(sql: """
                UPDATE suggestion_cards
                SET question_text = (
                    SELECT dq.question_text
                    FROM detected_questions dq
                    WHERE dq.id = suggestion_cards.detected_question_id
                )
                WHERE question_text IS NULL
                  AND detected_question_id IS NOT NULL
                """)
        }

        migrator.registerMigration("v12_answer_relevance_diagnostics") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }

            let columns: [(String, String)] = [
                ("question_intent", "TEXT"),
                ("answer_intent", "TEXT"),
                ("prompt_question_text", "TEXT"),
                ("prompt_token_estimate", "INTEGER"),
                ("prompt_context_preview", "TEXT"),
                ("mismatch_reason", "TEXT")
            ]

            for (name, type) in columns where !columnNames.contains(name) {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN \(name) \(type)")
            }

            try db.execute(sql: """
                UPDATE suggestion_cards
                SET prompt_question_text = question_text
                WHERE prompt_question_text IS NULL
                  AND question_text IS NOT NULL
                """)
        }

        migrator.registerMigration("v13_generation_context_isolation") { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let columnNames = rows.compactMap { $0["name"] as? String }

            let columns: [(String, String)] = [
                ("prompt_primary_question", "TEXT"),
                ("prompt_contains_previous_question", "INTEGER"),
                ("previous_question_included", "INTEGER"),
                ("previous_question_text", "TEXT"),
                ("context_bleed_risk", "TEXT"),
                ("rag_chunk_ids_json", "TEXT"),
                ("rag_chunk_intents_json", "TEXT"),
                ("first_question_suppressed_reason", "TEXT")
            ]

            for (name, type) in columns where !columnNames.contains(name) {
                try db.execute(sql: "ALTER TABLE suggestion_cards ADD COLUMN \(name) \(type)")
            }

            try db.execute(sql: """
                UPDATE suggestion_cards
                SET prompt_primary_question = COALESCE(prompt_question_text, question_text)
                WHERE prompt_primary_question IS NULL
                """)
        }

        return migrator
    }
}
