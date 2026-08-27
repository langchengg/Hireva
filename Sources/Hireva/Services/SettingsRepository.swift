import Foundation
import GRDB

final class SettingsRepository {
    private let database: AppDatabase
    private let settingsKey = "app_settings"
    private let apiCallCountKey = "api_call_count"
    private let activeRealtimeProviderIDKey = "active_realtime_provider_id"
    private let activeRecapProviderIDKey = "active_recap_provider_id"

    init(database: AppDatabase) {
        self.database = database
    }

    func loadSettings() throws -> AppSettings {
        let rawValue: String? = try database.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [settingsKey]
            )
        }

        let decoded: AppSettings
        if let value = rawValue,
           let data = value.data(using: .utf8),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            decoded = stored
        } else {
            decoded = .default
        }
        let settings: AppSettings
        if let validated = try? decoded.validatedForLiveUse() {
            settings = validated
        } else {
            var safe = decoded
            safe.enableVectorRAG = false
            safe.forceHybridRAG = false
            safe.embeddingProviderKind = .disabled
            safe.embeddingBaseURL = AppSettings.default.embeddingBaseURL
            safe.embeddingApiKeyAccount = AppSettings.default.embeddingApiKeyAccount
            settings = safe
        }
        let canonicalValue = try Self.encodedSettings(settings)
        if rawValue != canonicalValue {
            try setValue(canonicalValue, forKey: settingsKey)
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        try setValue(
            Self.encodedSettings(settings.validatedForLiveUse()),
            forKey: settingsKey
        )
    }

    func apiCallCount() throws -> Int {
        try database.dbQueue.read { db in
            guard let value: String = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [apiCallCountKey]
            ) else {
                return 0
            }
            return Int(value) ?? 0
        }
    }

    func incrementAPICallCount() throws -> Int {
        let next = (try apiCallCount()) + 1
        try setValue(String(next), forKey: apiCallCountKey)
        return next
    }

    func deleteAllSettings() throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM app_settings")
        }
    }

    @discardableResult
    func ensureDefaultProviderConfigurations() throws -> [LLMProviderConfiguration] {
        try disableLegacyLocalProviderRows()
        var existing = try providerConfigurations()
        if try hasStoredProviderRows() {
            if !existing.contains(where: { $0.kind == .deepSeek }),
               try !hasStoredProviderRow(kind: .deepSeek) {
                try saveProviderConfiguration(.deepSeekDefault())
                existing = try providerConfigurations()
            }
            if !existing.contains(where: { $0.kind == .openAICompatible }),
               try !hasStoredProviderRow(kind: .openAICompatible) {
                try saveProviderConfiguration(.openAICompatibleDefault())
                existing = try providerConfigurations()
            }
            let realtimeProvider = try activeRealtimeProvider()
            if realtimeProvider == nil || realtimeProvider?.kind == .ollamaLocal {
                if let realtime = existing.first(where: { $0.kind == .deepSeek }) ?? existing.first(where: { $0.isDefaultForRealtime }) ?? existing.first {
                    try setActiveRealtimeProvider(id: realtime.id)
                }
            }
            let recapProvider = try activeRecapProvider()
            if recapProvider == nil || recapProvider?.kind == .ollamaLocal {
                if let recap = existing.first(where: { $0.kind == .deepSeek }) ?? existing.first(where: { $0.isDefaultForRecap }) ?? existing.first {
                    try setActiveRecapProvider(id: recap.id)
                }
            }
            return try providerConfigurations()
        }

        let defaults = [
            LLMProviderConfiguration.deepSeekDefault(),
            LLMProviderConfiguration.openAICompatibleDefault()
        ]
        for provider in defaults {
            try saveProviderConfiguration(provider)
        }
        if let realtime = defaults.first(where: { $0.isDefaultForRealtime }) {
            try setActiveRealtimeProvider(id: realtime.id)
        }
        if let recap = defaults.first(where: { $0.isDefaultForRecap }) {
            try setActiveRecapProvider(id: recap.id)
        }
        return defaults
    }

    private func hasStoredProviderRows() throws -> Bool {
        try database.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM llm_provider_configurations") ?? 0) > 0
        }
    }

    private func hasStoredProviderRow(kind: LLMProviderKind) throws -> Bool {
        try database.dbQueue.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM llm_provider_configurations WHERE kind = ?",
                arguments: [kind.rawValue]
            ) ?? 0) > 0
        }
    }

    private func disableLegacyLocalProviderRows() throws {
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE llm_provider_configurations
                SET name = 'Legacy Local Provider (Disabled)',
                    is_default_for_realtime = 0,
                    is_default_for_recap = 0,
                    updated_at = ?
                WHERE kind = ? OR base_url LIKE '%localhost:11434%'
                """,
                arguments: [DateCoding.string(from: Date()), LLMProviderKind.ollamaLocal.rawValue]
            )
        }
    }

    func providerConfigurations() throws -> [LLMProviderConfiguration] {
        try database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM llm_provider_configurations ORDER BY created_at ASC, id ASC"
            )
            .compactMap(Self.makeProviderConfiguration)
        }
    }

    func providerConfiguration(id: UUID) throws -> LLMProviderConfiguration? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM llm_provider_configurations WHERE id = ?",
                arguments: [id.uuidString]
            )
            return row.flatMap(Self.makeProviderConfiguration)
        }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) throws {
        guard provider.kind == .deepSeek || provider.kind == .openAICompatible else {
            throw LLMProviderError.notConfigured(provider.kind.displayName)
        }
        var provider = try provider.validatedForLiveUse()
        provider.updatedAt = Date()
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO llm_provider_configurations (
                    id, name, kind, base_url, model, api_key_account,
                    is_default_for_realtime, is_default_for_recap, supports_json_mode,
                    supports_streaming, supports_thinking, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    kind = excluded.kind,
                    base_url = excluded.base_url,
                    model = excluded.model,
                    api_key_account = excluded.api_key_account,
                    is_default_for_realtime = excluded.is_default_for_realtime,
                    is_default_for_recap = excluded.is_default_for_recap,
                    supports_json_mode = excluded.supports_json_mode,
                    supports_streaming = excluded.supports_streaming,
                    supports_thinking = excluded.supports_thinking,
                    updated_at = excluded.updated_at
                """,
                arguments: Self.providerArguments(provider)
            )
        }
    }

    func deleteProviderConfiguration(id: UUID) throws {
        let updatedAt = DateCoding.string(from: Date())
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM llm_provider_configurations WHERE id = ?", arguments: [id.uuidString])

            let providers = try Row.fetchAll(
                db,
                sql: "SELECT * FROM llm_provider_configurations ORDER BY created_at ASC, id ASC"
            )
            .compactMap(Self.makeProviderConfiguration)
            let validIDs = Set(providers.map { $0.id.uuidString })
            let fallback = providers.first(where: { $0.id == LLMProviderConfiguration.deepSeekDefaultID })
                ?? providers.first(where: { $0.kind == .deepSeek })
                ?? providers.first

            for key in [activeRealtimeProviderIDKey, activeRecapProviderIDKey] {
                let rawValue = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM app_settings WHERE key = ?",
                    arguments: [key]
                )
                let canonicalID = rawValue.flatMap(UUID.init(uuidString:)).map(\.uuidString)
                if let canonicalID, validIDs.contains(canonicalID) {
                    if rawValue != canonicalID {
                        try Self.upsertValue(canonicalID, forKey: key, updatedAt: updatedAt, db: db)
                    }
                } else if let fallback {
                    try Self.upsertValue(fallback.id.uuidString, forKey: key, updatedAt: updatedAt, db: db)
                } else {
                    try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [key])
                }
            }
        }
    }

    func activeRealtimeProvider() throws -> LLMProviderConfiguration? {
        guard let id = try activeProviderID(forKey: activeRealtimeProviderIDKey) else {
            let providers = try providerConfigurations()
            return providers.first(where: { $0.isDefaultForRealtime }) ?? providers.first
        }
        return try providerConfiguration(id: id)
    }

    func activeRecapProvider() throws -> LLMProviderConfiguration? {
        guard let id = try activeProviderID(forKey: activeRecapProviderIDKey) else {
            let providers = try providerConfigurations()
            return providers.first(where: { $0.isDefaultForRecap }) ?? providers.first
        }
        return try providerConfiguration(id: id)
    }

    func setActiveRealtimeProvider(id: UUID) throws {
        try setValue(id.uuidString, forKey: activeRealtimeProviderIDKey)
    }

    func setActiveRecapProvider(id: UUID) throws {
        try setValue(id.uuidString, forKey: activeRecapProviderIDKey)
    }

    private func activeProviderID(forKey key: String) throws -> UUID? {
        try database.dbQueue.read { db in
            guard let value: String = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [key]
            ) else {
                return nil
            }
            return UUID(uuidString: value)
        }
    }

    private func setValue(_ value: String, forKey key: String) throws {
        try database.dbQueue.write { db in
            try Self.upsertValue(
                value,
                forKey: key,
                updatedAt: DateCoding.string(from: Date()),
                db: db
            )
        }
    }

    private static func upsertValue(
        _ value: String,
        forKey key: String,
        updatedAt: String,
        db: Database
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

    private static func providerArguments(_ provider: LLMProviderConfiguration) -> StatementArguments {
        [
            provider.id.uuidString,
            provider.name,
            provider.kind.rawValue,
            provider.baseURL,
            provider.model,
            provider.apiKeyAccount,
            provider.isDefaultForRealtime,
            provider.isDefaultForRecap,
            provider.supportsJSONMode,
            provider.supportsStreaming,
            provider.supportsThinking,
            DateCoding.string(from: provider.createdAt),
            DateCoding.string(from: provider.updatedAt)
        ]
    }

    private static func makeProviderConfiguration(row: Row) -> LLMProviderConfiguration? {
        guard let rawID = row["id"] as String?,
              let id = UUID(uuidString: rawID),
              rawID == id.uuidString,
              let rawKind = row["kind"] as String?,
              let kind = LLMProviderKind(rawValue: rawKind),
              kind == .deepSeek || kind == .openAICompatible,
              let name = row["name"] as String?,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let baseURL = row["base_url"] as String?,
              let model = row["model"] as String?,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let isDefaultForRealtime = strictBoolean(row, column: "is_default_for_realtime"),
              let isDefaultForRecap = strictBoolean(row, column: "is_default_for_recap"),
              let supportsJSONMode = strictBoolean(row, column: "supports_json_mode"),
              let supportsStreaming = strictBoolean(row, column: "supports_streaming"),
              let supportsThinking = strictBoolean(row, column: "supports_thinking"),
              let createdAtString = row["created_at"] as String?,
              let createdAt = strictDate(createdAtString),
              let updatedAtString = row["updated_at"] as String?,
              let updatedAt = strictDate(updatedAtString) else {
            return nil
        }

        let rawProvider = LLMProviderConfiguration(
            id: id,
            name: name,
            kind: kind,
            baseURL: baseURL,
            model: model,
            apiKeyAccount: row["api_key_account"],
            isDefaultForRealtime: isDefaultForRealtime,
            isDefaultForRecap: isDefaultForRecap,
            supportsJSONMode: supportsJSONMode,
            supportsStreaming: supportsStreaming,
            supportsThinking: supportsThinking,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        return try? rawProvider.validatedForLiveUse()
    }

    private static func strictBoolean(_ row: Row, column: String) -> Bool? {
        guard let value = row[column] as Int?, value == 0 || value == 1 else { return nil }
        return value == 1
    }

    private static func strictDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }

    private static func encodedSettings(_ settings: AppSettings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(settings), as: UTF8.self)
    }
}
