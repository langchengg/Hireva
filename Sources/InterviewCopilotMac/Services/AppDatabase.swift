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

        return migrator
    }
}
