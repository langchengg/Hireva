import CoreFoundation
import Foundation
import GRDB

/// The release-candidate provider persistence contract as it existed at v19.
///
/// Keep this implementation self-contained. Database migrations are historical
/// records: changing the live provider/settings validators later must not change
/// what an already-shipped migration does when an older database is reopened.
enum ProviderPersistenceMigrationV19 {
    static let identifier = "v19_sanitize_provider_persistence"

    private static let migrationTimestamp = "2001-01-01T00:00:00.000Z"
    private static let deepSeekDefaultID = "22222222-2222-2222-2222-222222222222"
    private static let openAICompatibleDefaultID = "33333333-3333-3333-3333-333333333333"
    private static let appSettingsKey = "app_settings"
    private static let activeRealtimeKey = "active_realtime_provider_id"
    private static let activeRecapKey = "active_recap_provider_id"

    private enum ProviderKind: String {
        case deepSeek
        case openAICompatible
    }

    private struct Endpoint {
        let absoluteString: String
        let scheme: String
        let host: String
        let port: Int
    }

    private struct ProviderRow {
        let id: String
        let name: String
        let kind: ProviderKind
        let baseURL: String
        let model: String
        let apiKeyAccount: String
        let isDefaultForRealtime: Bool
        let isDefaultForRecap: Bool
        let supportsJSONMode: Bool
        let supportsStreaming: Bool
        let supportsThinking: Bool
        let createdAt: String
        let updatedAt: String
    }

    static func migrate(_ db: Database) throws {
        let rawRows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, kind, base_url, model, api_key_account,
                       is_default_for_realtime, is_default_for_recap,
                       supports_json_mode, supports_streaming, supports_thinking,
                       created_at, updated_at
                FROM llm_provider_configurations
                ORDER BY id COLLATE BINARY ASC
                """
        )

        // SQLite's TEXT primary key treats differently-cased UUID spellings as
        // distinct rows, while Foundation canonicalizes them to the same UUID.
        // Drop every member of such a collision group instead of allowing row
        // ordering to choose which configuration survives.
        var canonicalIDCounts: [String: Int] = [:]
        for row in rawRows {
            guard let rawID = row["id"] as String?,
                  let id = UUID(uuidString: rawID) else {
                continue
            }
            canonicalIDCounts[id.uuidString, default: 0] += 1
        }

        var providers = rawRows.compactMap(sanitizedProvider).filter {
            canonicalIDCounts[$0.id] == 1
        }

        // The fixed DeepSeek row is the release fallback and the stable
        // Keychain-account boundary. A colliding historical row of another kind
        // must not be allowed to occupy this identifier.
        providers.removeAll { $0.id == deepSeekDefaultID && $0.kind != .deepSeek }
        if let index = providers.firstIndex(where: { $0.id == deepSeekDefaultID }) {
            let existing = providers[index]
            providers[index] = ProviderRow(
                id: deepSeekDefaultID,
                name: "DeepSeek",
                kind: .deepSeek,
                baseURL: "https://api.deepseek.com",
                model: sanitizedText(existing.model, fallback: "deepseek-v4-flash", maximumUTF8Count: 256),
                apiKeyAccount: "deepseek.default",
                isDefaultForRealtime: true,
                isDefaultForRecap: true,
                supportsJSONMode: true,
                supportsStreaming: true,
                supportsThinking: true,
                createdAt: existing.createdAt,
                updatedAt: existing.updatedAt
            )
        } else {
            providers.append(deepSeekDefaultProvider())
        }

        if !providers.contains(where: { $0.kind == .openAICompatible }) {
            providers.removeAll { $0.id == openAICompatibleDefaultID }
            providers.append(openAICompatibleDefaultProvider())
        }
        providers.sort { $0.id < $1.id }

        // Rebuild the data set inside GRDB's migration transaction. This both
        // removes unsafe rows and avoids primary-key collisions when a valid UUID
        // had previously been stored in a non-canonical textual representation.
        try db.execute(sql: "DELETE FROM llm_provider_configurations")
        for provider in providers {
            try insert(provider, db: db)
        }

        let validIDs = Set(providers.map(\.id))
        try repairActiveProviderSelection(
            key: activeRealtimeKey,
            validIDs: validIDs,
            db: db
        )
        try repairActiveProviderSelection(
            key: activeRecapKey,
            validIDs: validIDs,
            db: db
        )
        try sanitizeAppSettings(db)
    }

    private static func sanitizedProvider(_ row: Row) -> ProviderRow? {
        guard let rawID = row["id"] as String?,
              let uuid = UUID(uuidString: rawID),
              let rawKind = row["kind"] as String?,
              let kind = ProviderKind(rawValue: rawKind),
              let rawBaseURL = row["base_url"] as String?,
              let endpoint = canonicalEndpoint(rawBaseURL, kind: kind),
              let rawName = row["name"] as String?,
              let rawModel = row["model"] as String?,
              let rawCreatedAt = row["created_at"] as String?,
              let rawUpdatedAt = row["updated_at"] as String?,
              let isDefaultForRealtime = strictBoolean(row, column: "is_default_for_realtime"),
              let isDefaultForRecap = strictBoolean(row, column: "is_default_for_recap"),
              let supportsJSONMode = strictBoolean(row, column: "supports_json_mode"),
              let supportsStreaming = strictBoolean(row, column: "supports_streaming"),
              let supportsThinking = strictBoolean(row, column: "supports_thinking") else {
            return nil
        }

        let id = uuid.uuidString
        let fallbackName = kind == .deepSeek ? "DeepSeek" : "OpenAI-compatible"
        let fallbackModel = kind == .deepSeek ? "deepseek-v4-flash" : "model-name"
        let account = credentialAccount(id: uuid, kind: kind, endpoint: endpoint)

        return ProviderRow(
            id: id,
            name: sanitizedText(rawName, fallback: fallbackName, maximumUTF8Count: 256),
            kind: kind,
            baseURL: endpoint.absoluteString,
            model: sanitizedText(rawModel, fallback: fallbackModel, maximumUTF8Count: 256),
            apiKeyAccount: account,
            isDefaultForRealtime: isDefaultForRealtime,
            isDefaultForRecap: isDefaultForRecap,
            supportsJSONMode: supportsJSONMode,
            supportsStreaming: supportsStreaming,
            supportsThinking: supportsThinking,
            createdAt: canonicalTimestamp(rawCreatedAt),
            updatedAt: canonicalTimestamp(rawUpdatedAt)
        )
    }

    private static func deepSeekDefaultProvider() -> ProviderRow {
        ProviderRow(
            id: deepSeekDefaultID,
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKeyAccount: "deepseek.default",
            isDefaultForRealtime: true,
            isDefaultForRecap: true,
            supportsJSONMode: true,
            supportsStreaming: true,
            supportsThinking: true,
            createdAt: migrationTimestamp,
            updatedAt: migrationTimestamp
        )
    }

    private static func openAICompatibleDefaultProvider() -> ProviderRow {
        let endpoint = Endpoint(
            absoluteString: "https://api.example.com",
            scheme: "https",
            host: "api.example.com",
            port: 443
        )
        let id = UUID(uuidString: openAICompatibleDefaultID)!
        return ProviderRow(
            id: openAICompatibleDefaultID,
            name: "Custom OpenAI-compatible",
            kind: .openAICompatible,
            baseURL: endpoint.absoluteString,
            model: "model-name",
            apiKeyAccount: credentialAccount(id: id, kind: .openAICompatible, endpoint: endpoint),
            isDefaultForRealtime: false,
            isDefaultForRecap: false,
            supportsJSONMode: true,
            supportsStreaming: true,
            supportsThinking: false,
            createdAt: migrationTimestamp,
            updatedAt: migrationTimestamp
        )
    }

    private static func insert(_ provider: ProviderRow, db: Database) throws {
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
                provider.id,
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
                provider.createdAt,
                provider.updatedAt
            ]
        )
    }

    private static func repairActiveProviderSelection(
        key: String,
        validIDs: Set<String>,
        db: Database
    ) throws {
        let rawValue = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_settings WHERE key = ?",
            arguments: [key]
        )
        guard rawValue != nil else { return }
        let canonicalID = rawValue
            .flatMap(UUID.init(uuidString:))
            .map(\.uuidString)
        let repairedID = canonicalID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? deepSeekDefaultID

        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
            arguments: [key, repairedID, migrationTimestamp]
        )
    }

    private static func sanitizeAppSettings(_ db: Database) throws {
        let rawValue = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_settings WHERE key = ?",
            arguments: [appSettingsKey]
        )
        guard rawValue != nil else { return }
        let sanitized = try sanitizedAppSettingsJSON(rawValue)
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
            arguments: [appSettingsKey, sanitized, migrationTimestamp]
        )
    }

    private static func sanitizedAppSettingsJSON(_ rawValue: String?) throws -> String {
        let source: [String: Any]
        if let rawValue,
           let data = rawValue.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            source = dictionary
        } else {
            source = [:]
        }

        var output = defaultSettingsObject()

        copyString(
            "realtimeModel",
            from: source,
            to: &output,
            allowed: ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
        copyString(
            "recapModel",
            from: source,
            to: &output,
            allowed: ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
        copyString(
            "diagnosticTraceMode",
            from: source,
            to: &output,
            allowed: ["off", "metadataOnly", "fullText"]
        )
        copyString(
            "audioCaptureMode",
            from: source,
            to: &output,
            allowed: ["microphoneOnly", "systemAudioOnly", "microphoneAndSystem"]
        )
        copyString(
            "manualCaptureSource",
            from: source,
            to: &output,
            allowed: ["systemAudio", "microphone"]
        )

        let booleanKeys = [
            "automaticQuestionDetectionEnabled",
            "manualOnlyMode",
            "saveTranscriptsLocally",
            "allowQuestionDetectionFromMicrophoneOnly",
            "highContrastFloatingPanel",
            "autoSendAfterTranscription",
            "showTranscriptBeforeSending",
            "saveManualClips",
            "dontShowCloudWarningAgain",
            "enableVectorRAG",
            "forceHybridRAG",
            "autoGenerateEmbeddingsOnDocumentSave"
        ]
        for key in booleanKeys {
            if let value = jsonBoolean(source[key]) {
                output[key] = value
            }
        }

        if let value = jsonDouble(source["floatingWindowOpacity"]), (0...1).contains(value) {
            output["floatingWindowOpacity"] = value
        }
        copyInteger(
            "maxManualCaptureSeconds",
            from: source,
            to: &output,
            acceptedRange: 1...3_600
        )
        if source["generationRequestTimeoutSeconds"] != nil {
            copyInteger(
                "generationRequestTimeoutSeconds",
                from: source,
                to: &output,
                acceptedRange: 1...3_600
            )
        } else if let legacyTimeout = jsonInteger(source["ollamaRequestTimeoutSeconds"]),
                  (1...3_600).contains(legacyTimeout) {
            output["generationRequestTimeoutSeconds"] = legacyTimeout
        }
        copyInteger(
            "embeddingDimension",
            from: source,
            to: &output,
            acceptedRange: 1...65_536
        )
        copyInteger(
            "embeddingTimeoutSeconds",
            from: source,
            to: &output,
            acceptedRange: 1...3_600
        )
        for key in ["hybridSemanticWeight", "hybridKeywordWeight"] {
            if let value = jsonDouble(source[key]), (0...1).contains(value) {
                output[key] = value
            }
        }

        let displayMode: String
        if let rawDisplayMode = source["floatingAssistantDisplayMode"] as? String,
           ["compact", "normal", "diagnostic"].contains(rawDisplayMode) {
            displayMode = rawDisplayMode
        } else if jsonBoolean(source["compactMode"]) == true {
            displayMode = "compact"
        } else {
            displayMode = "normal"
        }
        output["floatingAssistantDisplayMode"] = displayMode
        output["compactMode"] = displayMode == "compact"

        let requestedEmbeddingKind = source["embeddingProviderKind"] as? String
        let embeddingKind: String
        switch requestedEmbeddingKind {
        case "openAICompatibleCloud", "customCloud":
            embeddingKind = requestedEmbeddingKind!
        default:
            embeddingKind = "disabled"
        }

        let rawEmbeddingBaseURL = source["embeddingBaseURL"] as? String
        if embeddingKind != "disabled",
           let rawEmbeddingBaseURL,
           let endpoint = canonicalEndpoint(rawEmbeddingBaseURL, kind: .openAICompatible) {
            output["embeddingProviderKind"] = embeddingKind
            output["embeddingBaseURL"] = endpoint.absoluteString
            output["embeddingApiKeyAccount"] = embeddingCredentialAccount(
                kind: embeddingKind,
                endpoint: endpoint
            )
            if let model = source["embeddingModelName"] as? String {
                output["embeddingModelName"] = sanitizedText(
                    model,
                    fallback: "text-embedding-3-small",
                    maximumUTF8Count: 256
                )
            }
        } else {
            output["enableVectorRAG"] = false
            output["forceHybridRAG"] = false
            output["embeddingProviderKind"] = "disabled"
            output["embeddingBaseURL"] = "https://api.openai.com/v1"
            output["embeddingApiKeyAccount"] = "openai.embedding.default"
            let model = source["embeddingModelName"] as? String
            output["embeddingModelName"] = model == "nomic-embed-text"
                ? "text-embedding-3-small"
                : sanitizedText(
                    model ?? "text-embedding-3-small",
                    fallback: "text-embedding-3-small",
                    maximumUTF8Count: 256
                )
        }

        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func defaultSettingsObject() -> [String: Any] {
        [
            "realtimeModel": "deepseek-v4-flash",
            "recapModel": "deepseek-v4-pro",
            "automaticQuestionDetectionEnabled": true,
            "manualOnlyMode": false,
            "saveTranscriptsLocally": true,
            "diagnosticTraceMode": "off",
            "allowQuestionDetectionFromMicrophoneOnly": false,
            "audioCaptureMode": "microphoneAndSystem",
            "floatingWindowOpacity": 0.82,
            "compactMode": false,
            "floatingAssistantDisplayMode": "normal",
            "highContrastFloatingPanel": false,
            "manualCaptureSource": "systemAudio",
            "autoSendAfterTranscription": true,
            "maxManualCaptureSeconds": 60,
            "showTranscriptBeforeSending": false,
            "saveManualClips": false,
            "dontShowCloudWarningAgain": false,
            "generationRequestTimeoutSeconds": 180,
            "enableVectorRAG": false,
            "forceHybridRAG": false,
            "embeddingProviderKind": "disabled",
            "embeddingBaseURL": "https://api.openai.com/v1",
            "embeddingModelName": "text-embedding-3-small",
            "embeddingApiKeyAccount": "openai.embedding.default",
            "embeddingDimension": 1_536,
            "hybridSemanticWeight": 0.7,
            "hybridKeywordWeight": 0.3,
            "autoGenerateEmbeddingsOnDocumentSave": true,
            "embeddingTimeoutSeconds": 60
        ]
    }

    private static func copyString(
        _ key: String,
        from source: [String: Any],
        to output: inout [String: Any],
        allowed: Set<String>
    ) {
        guard let value = source[key] as? String, allowed.contains(value) else { return }
        output[key] = value
    }

    private static func copyInteger(
        _ key: String,
        from source: [String: Any],
        to output: inout [String: Any],
        acceptedRange: ClosedRange<Int>
    ) {
        guard let value = jsonInteger(source[key]), acceptedRange.contains(value) else { return }
        output[key] = value
    }

    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func jsonInteger(_ value: Any?) -> Int? {
        guard let number = jsonNumber(value) else { return nil }
        let double = number.doubleValue
        guard double.rounded(.towardZero) == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        jsonNumber(value)?.doubleValue
    }

    private static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        return number
    }

    private static func strictBoolean(_ row: Row, column: String) -> Bool? {
        guard let value = row[column] as Int?, value == 0 || value == 1 else { return nil }
        return value == 1
    }

    private static func sanitizedText(
        _ value: String,
        fallback: String,
        maximumUTF8Count: Int
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumUTF8Count,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return fallback
        }
        return trimmed
    }

    private static func canonicalTimestamp(_ rawValue: String) -> String {
        let output = ISO8601DateFormatter()
        output.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: rawValue) {
            return output.string(from: date)
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        if let date = regular.date(from: rawValue) {
            return output.string(from: date)
        }
        return migrationTimestamp
    }

    private static func canonicalEndpoint(_ input: String, kind: ProviderKind) -> Endpoint? {
        guard input.utf8.count <= 2_048,
              !input.isEmpty,
              !input.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              !input.contains("\\"),
              !input.contains("%"),
              let parsed = URLComponents(string: input, encodingInvalidCharacters: false),
              parsed.url != nil,
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil,
              let rawScheme = parsed.scheme,
              let rawHost = parsed.host,
              !rawHost.isEmpty else {
            return nil
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let host = rawHost.lowercased()
        guard isCanonicalHost(host) else { return nil }
        let isLoopback = isCanonicalLoopbackHost(host)
        guard scheme != "http" || isLoopback else { return nil }
        guard let path = canonicalPath(parsed.path) else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        let effectivePort = parsed.port ?? defaultPort
        if kind == .deepSeek {
            guard scheme == "https",
                  host == "api.deepseek.com",
                  effectivePort == 443,
                  path.isEmpty || path == "/v1" else {
                return nil
            }
        }

        var canonical = URLComponents()
        canonical.scheme = scheme
        canonical.host = host
        canonical.port = parsed.port == defaultPort ? nil : parsed.port
        canonical.path = path
        guard let absoluteString = canonical.string else { return nil }
        return Endpoint(
            absoluteString: absoluteString,
            scheme: scheme,
            host: host,
            port: effectivePort
        )
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.utf8.count <= 512 else { return nil }
        if path.isEmpty || path == "/" {
            return ""
        }
        guard path.hasPrefix("/"), !path.dropFirst().contains("//") else { return nil }

        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        for segment in normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !segment.isEmpty,
                  segment != ".",
                  segment != "..",
                  segment.unicodeScalars.allSatisfy(allowed.contains) else {
                return nil
            }
        }
        return normalized
    }

    private static func isCanonicalHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              !host.contains(".."),
              host.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }

        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
            let body = host.dropFirst().dropLast()
            return !body.isEmpty && body.allSatisfy { $0.isHexDigit || $0 == ":" }
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return host.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isCanonicalLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]"
    }

    private static func credentialAccount(
        id: UUID,
        kind: ProviderKind,
        endpoint: Endpoint
    ) -> String {
        switch kind {
        case .deepSeek:
            if id.uuidString == deepSeekDefaultID {
                return "deepseek.default"
            }
            return "deepseek.\(id.uuidString.lowercased())"
        case .openAICompatible:
            return "provider.openAICompatible.\(id.uuidString.lowercased()).\(endpointScope(endpoint))"
        }
    }

    private static func embeddingCredentialAccount(kind: String, endpoint: Endpoint) -> String {
        if kind == "openAICompatibleCloud",
           endpoint.absoluteString == "https://api.openai.com/v1" {
            return "openai.embedding.default"
        }
        return "embedding.\(kind).\(endpointScope(endpoint))"
    }

    private static func endpointScope(_ endpoint: Endpoint) -> String {
        let host = endpoint.host.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "_"
        }
        return "\(endpoint.scheme).\(String(host)).\(endpoint.port)"
    }
}
