import Foundation
import GRDB
import Testing
@testable import Hireva

// All marker strings in this suite are synthetic privacy canaries.
@Suite(.serialized)
struct ProviderPersistenceMigrationV19Tests {
    private static let deepSeekDefaultID = "22222222-2222-2222-2222-222222222222"
    private static let customProviderID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private static let fixedTimestamp = "2001-01-01T00:00:00.000Z"
    private static let providerCanary = "SYNTHETIC_PROVIDER_SECRET_CANARY_61C4"
    private static let settingsCanary = "SYNTHETIC_SETTINGS_SECRET_CANARY_72D5"
    private static let invalidIDCanary = "SYNTHETIC_INVALID_UUID_CANARY_83E6"

    @Test
    func migrationSanitizesProviderRowsRepairsActiveSelectionsAndIsIdempotent() throws {
        let fixture = try makeFixture()

        do {
            let database = try AppDatabase(path: fixture.databaseURL)
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM llm_provider_configurations")

                // An unsafe row occupying the fixed DeepSeek ID must be rebuilt,
                // not accepted merely because its identifier is familiar.
                try insertRawProvider(
                    db: db,
                    id: Self.deepSeekDefaultID,
                    kind: "deepSeek",
                    baseURL: "https://user:\(Self.providerCanary)@api.deepseek.com",
                    apiKeyAccount: Self.providerCanary
                )
                try insertRawProvider(
                    db: db,
                    id: Self.customProviderID.lowercased(),
                    name: "  Synthetic Compatible Provider  ",
                    kind: "openAICompatible",
                    baseURL: "HTTPS://API.EXAMPLE.TEST:443/v1/",
                    model: "  synthetic-model  ",
                    apiKeyAccount: Self.providerCanary,
                    createdAt: "not-a-date",
                    updatedAt: "2024-01-02T03:04:05Z"
                )
                try insertRawProvider(
                    db: db,
                    id: Self.invalidIDCanary,
                    kind: "openAICompatible",
                    baseURL: "https://invalid-id.example.test/v1",
                    apiKeyAccount: Self.providerCanary
                )
                try insertRawProvider(
                    db: db,
                    id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                    kind: "openAI",
                    baseURL: "https://unsupported.example.test/v1",
                    apiKeyAccount: Self.providerCanary
                )
                try insertRawProvider(
                    db: db,
                    id: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                    kind: "deepSeek",
                    baseURL: "https://api.deepseek.com.evil.invalid/v1?token=\(Self.providerCanary)",
                    apiKeyAccount: Self.providerCanary
                )

                let unsafeSettings = """
                {
                  "floatingWindowOpacity": 0.73,
                  "embeddingProviderKind": "customCloud",
                  "embeddingBaseURL": "https://user:\(Self.settingsCanary)@embedding.example.test/v1?token=\(Self.settingsCanary)",
                  "embeddingApiKeyAccount": "\(Self.settingsCanary)",
                  "unknownSecretField": "\(Self.settingsCanary)"
                }
                """
                try upsertSetting(
                    db: db,
                    key: "app_settings",
                    value: unsafeSettings,
                    updatedAt: "not-a-date"
                )
                try upsertSetting(
                    db: db,
                    key: "active_realtime_provider_id",
                    value: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
                    updatedAt: "not-a-date"
                )
                try upsertSetting(
                    db: db,
                    key: "active_recap_provider_id",
                    value: "not-a-provider-id",
                    updatedAt: "not-a-date"
                )
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [ProviderPersistenceMigrationV19.identifier]
                )
            }
            try database.close()
        }

        let firstSnapshot: PersistenceSnapshot
        do {
            let database = try AppDatabase(path: fixture.databaseURL)
            firstSnapshot = try snapshot(database)
            try assertSanitized(database)
            #expect(try migrationCount(database) == 1)

            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [ProviderPersistenceMigrationV19.identifier]
                )
            }
            try database.close()
        }

        do {
            let database = try AppDatabase(path: fixture.databaseURL)
            #expect(try snapshot(database) == firstSnapshot)
            try assertSanitized(database)
            #expect(try migrationCount(database) == 1)
            try database.close()
        }

        let artifacts = try fixture.databaseArtifacts()
        for canary in [Self.providerCanary, Self.settingsCanary, Self.invalidIDCanary] {
            #expect(!artifacts.contains(Data(canary.utf8)))
        }
    }

    @Test
    func repositoryStrictlyRejectsMalformedOrUnsupportedRows() throws {
        let fixture = try makeFixture()
        let database = try AppDatabase(path: fixture.databaseURL)
        defer { try? database.close() }
        let repository = SettingsRepository(database: database)

        try database.dbQueue.write { db in
            try insertRawProvider(
                db: db,
                id: "not-a-uuid",
                kind: "openAICompatible",
                baseURL: "https://invalid-id.example.test/v1"
            )
            try insertRawProvider(
                db: db,
                id: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
                kind: "anthropic",
                baseURL: "https://unsupported.example.test/v1"
            )
            try insertRawProvider(
                db: db,
                id: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE",
                kind: "openAICompatible",
                baseURL: "https://malformed-date.example.test/v1",
                createdAt: "not-a-date"
            )
        }

        let providers = try repository.providerConfigurations()
        #expect(Set(providers.map { $0.id.uuidString }) == [
            Self.deepSeekDefaultID,
            "33333333-3333-3333-3333-333333333333"
        ])
        #expect(!providers.contains { $0.kind == .anthropic })
        #expect(try repository.providerConfiguration(
            id: UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
        ) == nil)
    }

    @Test
    func migrationDropsCanonicalUUIDCollisionsAndMalformedBooleanRows() throws {
        let fixture = try makeFixture()
        let collidingID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let malformedBooleanID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

        do {
            let database = try AppDatabase(path: fixture.databaseURL)
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM llm_provider_configurations")
                try insertRawProvider(
                    db: db,
                    id: collidingID,
                    name: "Synthetic Collision Upper",
                    kind: "openAICompatible",
                    baseURL: "https://upper-collision.example.test/v1"
                )
                try insertRawProvider(
                    db: db,
                    id: collidingID.lowercased(),
                    name: "Synthetic Collision Lower",
                    kind: "openAICompatible",
                    baseURL: "https://lower-collision.example.test/v1"
                )
                try insertRawProvider(
                    db: db,
                    id: malformedBooleanID,
                    name: "Synthetic Malformed Boolean",
                    kind: "openAICompatible",
                    baseURL: "https://malformed-boolean.example.test/v1",
                    supportsStreaming: 2
                )
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [ProviderPersistenceMigrationV19.identifier]
                )
            }
            try database.close()
        }

        let database = try AppDatabase(path: fixture.databaseURL)
        defer { try? database.close() }
        let identifiers = Set(try SettingsRepository(database: database)
            .providerConfigurations()
            .map { $0.id.uuidString })

        #expect(identifiers == [
            Self.deepSeekDefaultID,
            "33333333-3333-3333-3333-333333333333"
        ])
        #expect(!identifiers.contains(collidingID))
        #expect(!identifiers.contains(malformedBooleanID))
    }

    @Test
    func repositoryPersistsCanonicalSettingsAndScrubsMalformedPayloads() throws {
        let fixture = try makeFixture()
        let database = try AppDatabase(path: fixture.databaseURL)
        defer { try? database.close() }
        let repository = SettingsRepository(database: database)

        let settingsCanary = "SYNTHETIC_REPOSITORY_SETTINGS_CANARY_94F7"
        let validButNoncanonical = """
        {
          "floatingWindowOpacity": 0.73,
          "embeddingProviderKind": "customCloud",
          "embeddingBaseURL": "HTTPS://EMBEDDING.EXAMPLE.TEST:443/v1/",
          "embeddingApiKeyAccount": "\(settingsCanary)",
          "unknownSecretField": "\(settingsCanary)"
        }
        """
        try database.dbQueue.write { db in
            try upsertSetting(
                db: db,
                key: "app_settings",
                value: validButNoncanonical,
                updatedAt: Self.fixedTimestamp
            )
        }

        let loaded = try repository.loadSettings()
        let rewritten = try storedSetting(database, key: "app_settings")
        #expect(loaded.floatingWindowOpacity == 0.73)
        #expect(loaded.embeddingProviderKind == .customCloud)
        #expect(loaded.embeddingBaseURL == "https://embedding.example.test/v1")
        #expect(loaded.embeddingApiKeyAccount == "embedding.customCloud.https.embedding.example.test.443")
        #expect(!rewritten.contains(settingsCanary))
        #expect(!rewritten.contains("unknownSecretField"))

        let malformedCanary = "SYNTHETIC_MALFORMED_JSON_CANARY_A508"
        try database.dbQueue.write { db in
            try upsertSetting(
                db: db,
                key: "app_settings",
                value: "{\"embeddingBaseURL\":\"\(malformedCanary)\"",
                updatedAt: Self.fixedTimestamp
            )
        }

        #expect(try repository.loadSettings() == .default)
        let scrubbed = try storedSetting(database, key: "app_settings")
        #expect(!scrubbed.contains(malformedCanary))
        #expect(try JSONSerialization.jsonObject(with: Data(scrubbed.utf8)) is [String: Any])
    }

    @Test
    func deletingActiveProviderPersistsDeepSeekFallbackForBothRoles() throws {
        let fixture = try makeFixture()
        let database = try AppDatabase(path: fixture.databaseURL)
        defer { try? database.close() }
        let repository = SettingsRepository(database: database)

        var custom = LLMProviderConfiguration.openAICompatibleDefault()
        custom.id = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
        custom.baseURL = "https://delete-active.example.test/v1"
        custom.model = "synthetic-delete-model"
        try repository.saveProviderConfiguration(custom)
        try repository.setActiveRealtimeProvider(id: custom.id)
        try repository.setActiveRecapProvider(id: custom.id)

        try repository.deleteProviderConfiguration(id: custom.id)

        #expect(try repository.activeRealtimeProvider()?.id.uuidString == Self.deepSeekDefaultID)
        #expect(try repository.activeRecapProvider()?.id.uuidString == Self.deepSeekDefaultID)
        #expect(try storedSetting(database, key: "active_realtime_provider_id") == Self.deepSeekDefaultID)
        #expect(try storedSetting(database, key: "active_recap_provider_id") == Self.deepSeekDefaultID)
    }

    private func assertSanitized(_ database: AppDatabase) throws {
        let repository = SettingsRepository(database: database)
        let providers = try repository.providerConfigurations()
        #expect(providers.count == 2)

        let deepSeek = try #require(providers.first { $0.id.uuidString == Self.deepSeekDefaultID })
        #expect(deepSeek.kind == .deepSeek)
        #expect(deepSeek.baseURL == "https://api.deepseek.com")
        #expect(deepSeek.apiKeyAccount == "deepseek.default")
        #expect(deepSeek.isDefaultForRealtime)
        #expect(deepSeek.isDefaultForRecap)

        let custom = try #require(providers.first { $0.id.uuidString == Self.customProviderID })
        #expect(custom.kind == .openAICompatible)
        #expect(custom.name == "Synthetic Compatible Provider")
        #expect(custom.model == "synthetic-model")
        #expect(custom.baseURL == "https://api.example.test/v1")
        #expect(custom.apiKeyAccount == "provider.openAICompatible.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.https.api.example.test.443")
        #expect(DateCoding.string(from: custom.createdAt) == Self.fixedTimestamp)
        #expect(DateCoding.string(from: custom.updatedAt) == "2024-01-02T03:04:05.000Z")

        #expect(try storedSetting(database, key: "active_realtime_provider_id") == Self.deepSeekDefaultID)
        #expect(try storedSetting(database, key: "active_recap_provider_id") == Self.deepSeekDefaultID)

        let settings = try repository.loadSettings()
        let rawSettings = try storedSetting(database, key: "app_settings")
        #expect(settings.floatingWindowOpacity == 0.73)
        #expect(settings.embeddingProviderKind == .disabled)
        #expect(settings.embeddingBaseURL == AppSettings.default.embeddingBaseURL)
        #expect(settings.embeddingApiKeyAccount == AppSettings.default.embeddingApiKeyAccount)
        #expect(!rawSettings.contains(Self.settingsCanary))
        #expect(!rawSettings.contains("unknownSecretField"))

        let integrity = try database.dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        let foreignKeyViolations = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        }
        #expect(integrity == "ok")
        #expect(foreignKeyViolations.isEmpty)
    }

    private func snapshot(_ database: AppDatabase) throws -> PersistenceSnapshot {
        try database.dbQueue.read { db in
            let providers = try Row.fetchAll(
                db,
                sql: "SELECT * FROM llm_provider_configurations ORDER BY id ASC"
            ).map { row in
                [
                    row["id"] as String,
                    row["name"] as String,
                    row["kind"] as String,
                    row["base_url"] as String,
                    row["model"] as String,
                    row["api_key_account"] as String? ?? "<nil>",
                    String(row["is_default_for_realtime"] as Int),
                    String(row["is_default_for_recap"] as Int),
                    String(row["supports_json_mode"] as Int),
                    String(row["supports_streaming"] as Int),
                    String(row["supports_thinking"] as Int),
                    row["created_at"] as String,
                    row["updated_at"] as String
                ].joined(separator: "\t")
            }
            let settings = try Row.fetchAll(
                db,
                sql: """
                    SELECT key, value, updated_at
                    FROM app_settings
                    WHERE key IN ('app_settings', 'active_realtime_provider_id', 'active_recap_provider_id')
                    ORDER BY key ASC
                    """
            ).map { row in
                "\(row["key"] as String)\t\(row["value"] as String)\t\(row["updated_at"] as String)"
            }
            return PersistenceSnapshot(providers: providers, settings: settings)
        }
    }

    private func migrationCount(_ database: AppDatabase) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [ProviderPersistenceMigrationV19.identifier]
            ) ?? 0
        }
    }

    private func storedSetting(_ database: AppDatabase, key: String) throws -> String {
        try #require(try database.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [key]
            )
        })
    }

    private func makeFixture() throws -> ProviderMigrationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaProviderPersistenceV19Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ProviderMigrationFixture(
            root: root,
            databaseURL: root.appendingPathComponent("provider-migration.sqlite")
        )
    }

    private func insertRawProvider(
        db: Database,
        id: String,
        name: String = "Synthetic Provider",
        kind: String,
        baseURL: String,
        model: String = "synthetic-model",
        apiKeyAccount: String = "synthetic.account",
        isDefaultForRealtime: Int = 0,
        isDefaultForRecap: Int = 0,
        supportsJSONMode: Int = 1,
        supportsStreaming: Int = 1,
        supportsThinking: Int = 0,
        createdAt: String = "2024-01-01T00:00:00.000Z",
        updatedAt: String = "2024-01-01T00:00:00.000Z"
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO llm_provider_configurations (
                    id, name, kind, base_url, model, api_key_account,
                    is_default_for_realtime, is_default_for_recap,
                    supports_json_mode, supports_streaming, supports_thinking,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id,
                name,
                kind,
                baseURL,
                model,
                apiKeyAccount,
                isDefaultForRealtime,
                isDefaultForRecap,
                supportsJSONMode,
                supportsStreaming,
                supportsThinking,
                createdAt,
                updatedAt
            ]
        )
    }

    private func upsertSetting(
        db: Database,
        key: String,
        value: String,
        updatedAt: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
            arguments: [key, value, updatedAt]
        )
    }
}

private struct ProviderMigrationFixture {
    let root: URL
    let databaseURL: URL

    func databaseArtifacts() throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent == databaseURL.lastPathComponent
                    || $0.lastPathComponent.hasPrefix("\(databaseURL.lastPathComponent)-")
            }
            .map { try Data(contentsOf: $0) }
    }
}

private struct PersistenceSnapshot: Equatable {
    let providers: [String]
    let settings: [String]
}
