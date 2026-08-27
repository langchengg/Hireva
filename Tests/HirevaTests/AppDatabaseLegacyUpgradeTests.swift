import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.serialized)
struct AppDatabaseLegacyUpgradeTests {
    // Frozen from AppDatabase.swift at ae2c6d64ee4af7793b17d17cf5d8d37949f13c8b.
    private static let legacyMigrationIdentifiers: Set<String> = [
        "v1_initial",
        "v2_llm_providers",
        "v3_speaker_attribution",
        "v4_rag_attribution",
        "v5_rag_embeddings",
        "v6_suggestion_provenance",
        "v7_suggestion_soft_fallback",
        "v8_latency_metrics",
        "v9_sanitized_content",
        "v10_visible_content_latency_metrics",
        "v11_question_answer_alignment",
        "v12_answer_relevance_diagnostics",
        "v13_generation_context_isolation",
        "v14_asr_source_metadata",
        "v15_suggestion_fallback_reason",
        "v16_dynamic_candidate_context"
    ]

    private static let currentMigrationIdentifiers: Set<String> = legacyMigrationIdentifiers.union([
        "v17_discard_raw_provider_context",
        "v18_discard_retrieved_chunk_content",
        "v19_sanitize_provider_persistence"
    ])

    private static let documentID = "synthetic-legacy-document"
    private static let sessionID = "synthetic-legacy-session"
    private static let questionID = "synthetic-legacy-question"
    private static let suggestionID = "synthetic-legacy-suggestion"
    private static let retrievedChunkID = "synthetic-legacy-retrieved-chunk"
    private static let providerID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private static let timestamp = "2001-01-01T00:00:00.000Z"

    @Test
    func renamedV16DatabaseUpgradesToCurrentSchemaWithoutLosingSyntheticRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaLegacyDatabaseUpgrade-\(UUID().uuidString)", isDirectory: true)
        let supportRoot = root.appendingPathComponent("Application Support", isDirectory: true)
        let legacyDirectory = supportRoot.appendingPathComponent("InterviewCopilotMac", isDirectory: true)
        let legacyDatabaseURL = legacyDirectory.appendingPathComponent("interview_copilot.sqlite")
        let defaultsSuite = "AppDatabaseLegacyUpgradeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try createSyntheticLegacyV16Database(at: legacyDatabaseURL)
        let legacyBytesBeforeMigration = try Data(contentsOf: legacyDatabaseURL)
        #expect(try migrationIdentifiers(at: legacyDatabaseURL) == Self.legacyMigrationIdentifiers)

        let coordinator = HirevaMigrationCoordinator(
            applicationSupportRoot: supportRoot,
            defaults: defaults,
            legacyDefaults: [],
            now: { Date(timeIntervalSince1970: 978_307_200) }
        )
        let report = try coordinator.performBeforeDatabaseOpen()
        let migratedDatabaseURL = supportRoot
            .appendingPathComponent("Hireva", isDirectory: true)
            .appendingPathComponent("hireva.sqlite")

        #expect(report.applicationSupport == .copiedLegacyData)
        #expect(report.database == .renamedLegacyCopy)
        #expect(FileManager.default.fileExists(atPath: legacyDatabaseURL.path))
        #expect(FileManager.default.fileExists(atPath: migratedDatabaseURL.path))

        let firstSnapshot: UpgradeSnapshot
        do {
            let database = try AppDatabase(path: migratedDatabaseURL)
            firstSnapshot = try snapshot(database)
            try assertHealthy(database)
            try database.close()
        }

        #expect(firstSnapshot.records == [
            "document|1|Synthetic Legacy Document|Synthetic migration evidence with no personal data.",
            "session|1|Synthetic Legacy Session|Synthetic Test Role",
            "provider|2|Synthetic Legacy Provider|https://legacy-provider.example.test/v1|synthetic-legacy-model|provider.openAICompatible.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.https.legacy-provider.example.test.443|\(Self.providerID)",
            "scrubbed|<null>|<null>|<null>",
            "retrieved|1|||[]|<null>"
        ])
        #expect(firstSnapshot.migrationIdentifiers == Self.currentMigrationIdentifiers)

        do {
            let reopened = try AppDatabase(path: migratedDatabaseURL)
            #expect(try snapshot(reopened) == firstSnapshot)
            try assertHealthy(reopened)
            try reopened.close()
        }

        #expect(FileManager.default.fileExists(atPath: legacyDatabaseURL.path))
        #expect(try Data(contentsOf: legacyDatabaseURL) == legacyBytesBeforeMigration)
        #expect(try migrationIdentifiers(at: legacyDatabaseURL) == Self.legacyMigrationIdentifiers)
    }

    private func createSyntheticLegacyV16Database(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }

        try queue.write { db in
            // Minimal schema slice derived from the historical v1/v2/v4/v9/v16
            // migrations. It includes every table and column read by v17-v19,
            // plus the three record types whose preservation is asserted.
            let schema = [
                """
                CREATE TABLE documents (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    sanitized_content TEXT,
                    sanitized_preview TEXT,
                    sanitization_warnings TEXT,
                    profile_id TEXT,
                    opportunity_context_id TEXT,
                    document_classification TEXT,
                    source_format TEXT,
                    content_hash TEXT
                )
                """,
                """
                CREATE TABLE interview_sessions (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    company TEXT,
                    role TEXT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    mode TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    context_snapshot_id TEXT
                )
                """,
                """
                CREATE TABLE detected_questions (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES interview_sessions(id) ON DELETE CASCADE,
                    raw_json TEXT
                )
                """,
                """
                CREATE TABLE suggestion_cards (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES interview_sessions(id) ON DELETE CASCADE,
                    raw_json TEXT,
                    prompt_context_preview TEXT
                )
                """,
                """
                CREATE TABLE suggestion_card_retrieved_chunks (
                    id TEXT PRIMARY KEY,
                    suggestion_card_id TEXT NOT NULL REFERENCES suggestion_cards(id) ON DELETE CASCADE,
                    content_preview TEXT NOT NULL,
                    full_content TEXT NOT NULL,
                    keywords_json TEXT NOT NULL,
                    section_title TEXT
                )
                """,
                """
                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """,
                """
                CREATE TABLE llm_provider_configurations (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    base_url TEXT NOT NULL,
                    model TEXT NOT NULL,
                    api_key_account TEXT,
                    is_default_for_realtime INTEGER NOT NULL DEFAULT 0,
                    is_default_for_recap INTEGER NOT NULL DEFAULT 0,
                    supports_json_mode INTEGER NOT NULL DEFAULT 1,
                    supports_streaming INTEGER NOT NULL DEFAULT 0,
                    supports_thinking INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            ]
            for statement in schema {
                try db.execute(sql: statement)
            }

            try db.execute(
                sql: """
                    INSERT INTO documents (
                        id, type, title, content, created_at, updated_at,
                        sanitized_content, sanitized_preview, sanitization_warnings,
                        document_classification, source_format, content_hash
                    ) VALUES (?, 'additionalNotes', ?, ?, ?, ?, ?, ?, '[]', 'interview_notes', 'pasted_text', ?)
                    """,
                arguments: [
                    Self.documentID,
                    "Synthetic Legacy Document",
                    "Synthetic migration evidence with no personal data.",
                    Self.timestamp,
                    Self.timestamp,
                    "Synthetic migration evidence with no personal data.",
                    "Synthetic migration evidence",
                    "synthetic-content-hash"
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO interview_sessions (
                        id, title, company, role, started_at, mode, created_at
                    ) VALUES (?, ?, 'Example Test Organisation', 'Synthetic Test Role', ?, 'manual', ?)
                    """,
                arguments: [Self.sessionID, "Synthetic Legacy Session", Self.timestamp, Self.timestamp]
            )
            try db.execute(
                sql: "INSERT INTO detected_questions (id, session_id, raw_json) VALUES (?, ?, ?)",
                arguments: [Self.questionID, Self.sessionID, "{\"synthetic\":\"legacy-provider-context\"}"]
            )
            try db.execute(
                sql: """
                    INSERT INTO suggestion_cards (
                        id, session_id, raw_json, prompt_context_preview
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    Self.suggestionID,
                    Self.sessionID,
                    "{\"synthetic\":\"legacy-provider-response\"}",
                    "Synthetic prompt context slated for v17 removal."
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO suggestion_card_retrieved_chunks (
                        id, suggestion_card_id, content_preview, full_content,
                        keywords_json, section_title
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Self.retrievedChunkID,
                    Self.suggestionID,
                    "Synthetic preview slated for v18 removal.",
                    "Synthetic full content slated for v18 removal.",
                    "[\"synthetic\"]",
                    "Synthetic Section"
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO llm_provider_configurations (
                        id, name, kind, base_url, model, api_key_account,
                        is_default_for_realtime, is_default_for_recap,
                        supports_json_mode, supports_streaming, supports_thinking,
                        created_at, updated_at
                    ) VALUES (?, ?, 'openAICompatible', ?, ?, 'synthetic.legacy.account', 1, 1, 1, 1, 0, ?, ?)
                    """,
                arguments: [
                    Self.providerID,
                    "Synthetic Legacy Provider",
                    "https://legacy-provider.example.test/v1",
                    "synthetic-legacy-model",
                    Self.timestamp,
                    Self.timestamp
                ]
            )
            try db.execute(
                sql: "INSERT INTO app_settings (key, value, updated_at) VALUES ('active_realtime_provider_id', ?, ?)",
                arguments: [Self.providerID, Self.timestamp]
            )
        }

        var legacyMigrator = DatabaseMigrator()
        for identifier in Self.legacyMigrationIdentifiers.sorted() {
            legacyMigrator.registerMigration(identifier) { _ in }
        }
        try legacyMigrator.migrate(queue)
    }

    private func snapshot(_ database: AppDatabase) throws -> UpgradeSnapshot {
        try database.dbQueue.read { db in
            UpgradeSnapshot(
                records: Set(try String.fetchAll(
                    db,
                    sql: """
                        SELECT 'document|' || COUNT(*) || '|' || MAX(title) || '|' || MAX(content)
                        FROM documents
                        UNION ALL
                        SELECT 'session|' || COUNT(*) || '|' || MAX(title) || '|' || MAX(role)
                        FROM interview_sessions
                        UNION ALL
                        SELECT 'provider|' ||
                               (SELECT COUNT(*) FROM llm_provider_configurations) || '|' ||
                               name || '|' || base_url || '|' || model || '|' || api_key_account || '|' ||
                               (SELECT value FROM app_settings WHERE key = 'active_realtime_provider_id')
                        FROM llm_provider_configurations
                        WHERE id = ?
                        UNION ALL
                        SELECT 'scrubbed|' ||
                               COALESCE((SELECT raw_json FROM detected_questions LIMIT 1), '<null>') || '|' ||
                               COALESCE((SELECT raw_json FROM suggestion_cards LIMIT 1), '<null>') || '|' ||
                               COALESCE((SELECT prompt_context_preview FROM suggestion_cards LIMIT 1), '<null>')
                        UNION ALL
                        SELECT 'retrieved|' || COUNT(*) || '|' || MAX(content_preview) || '|' ||
                               MAX(full_content) || '|' || MAX(keywords_json) || '|' ||
                               COALESCE(MAX(section_title), '<null>')
                        FROM suggestion_card_retrieved_chunks
                        """,
                    arguments: [Self.providerID]
                )),
                migrationIdentifiers: Set(try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations"
                ))
            )
        }
    }

    private func migrationIdentifiers(at url: URL) throws -> Set<String> {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
    }

    private func assertHealthy(_ database: AppDatabase) throws {
        let integrity = try database.dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        let foreignKeyViolations = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        }
        #expect(integrity == "ok")
        #expect(foreignKeyViolations.isEmpty)
    }
}

private struct UpgradeSnapshot: Equatable {
    let records: Set<String>
    let migrationIdentifiers: Set<String>
}
