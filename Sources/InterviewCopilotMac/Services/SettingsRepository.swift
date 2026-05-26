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
        try database.dbQueue.read { db in
            guard let value: String = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_settings WHERE key = ?",
                arguments: [settingsKey]
            ), let data = value.data(using: .utf8) else {
                return .default
            }
            return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? .default
        }
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let value = String(data: data, encoding: .utf8) ?? "{}"
        try setValue(value, forKey: settingsKey)
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
        let existing = try providerConfigurations()
        if !existing.isEmpty {
            if try activeRealtimeProvider() == nil, let realtime = existing.first(where: { $0.isDefaultForRealtime }) ?? existing.first {
                try setActiveRealtimeProvider(id: realtime.id)
            }
            if try activeRecapProvider() == nil, let recap = existing.first(where: { $0.isDefaultForRecap }) ?? existing.first {
                try setActiveRecapProvider(id: recap.id)
            }
            return existing
        }

        let defaults = [
            LLMProviderConfiguration.localOllamaDefault(),
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

    func providerConfigurations() throws -> [LLMProviderConfiguration] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM llm_provider_configurations ORDER BY created_at ASC")
                .map(Self.makeProviderConfiguration)
        }
    }

    func providerConfiguration(id: UUID) throws -> LLMProviderConfiguration? {
        try database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM llm_provider_configurations WHERE id = ?",
                arguments: [id.uuidString]
            )
            return row.map(Self.makeProviderConfiguration)
        }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) throws {
        var provider = provider
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
        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM llm_provider_configurations WHERE id = ?", arguments: [id.uuidString])
        }
        if try activeRealtimeProvider()?.id == id {
            let fallback = try providerConfigurations().first
            if let fallback {
                try setActiveRealtimeProvider(id: fallback.id)
            }
        }
        if try activeRecapProvider()?.id == id {
            let fallback = try providerConfigurations().first
            if let fallback {
                try setActiveRecapProvider(id: fallback.id)
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
            try db.execute(
                sql: """
                INSERT INTO app_settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                arguments: [key, value, DateCoding.string(from: Date())]
            )
        }
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

    private static func makeProviderConfiguration(row: Row) -> LLMProviderConfiguration {
        LLMProviderConfiguration(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            name: row["name"],
            kind: LLMProviderKind(rawValue: row["kind"]) ?? .openAICompatible,
            baseURL: row["base_url"],
            model: row["model"],
            apiKeyAccount: row["api_key_account"],
            isDefaultForRealtime: row["is_default_for_realtime"],
            isDefaultForRecap: row["is_default_for_recap"],
            supportsJSONMode: row["supports_json_mode"],
            supportsStreaming: row["supports_streaming"],
            supportsThinking: row["supports_thinking"],
            createdAt: DateCoding.date(from: row["created_at"]),
            updatedAt: DateCoding.date(from: row["updated_at"])
        )
    }
}
