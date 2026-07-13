import Foundation
import GRDB

enum HirevaProductIdentity {
    static let productName = "Hireva"
    static let bundleIdentifier = "com.langcheng.Hireva"
    static let applicationSupportDirectoryName = "Hireva"
    static let databaseFilename = "hireva.sqlite"
    static let keychainService = "com.langcheng.Hireva.LLMProviderKeys"
}

enum HirevaPreferenceKeys {
    static let selectedASRProvider = "Hireva.selectedASRProvider"
    static let activeASRProvider = "Hireva.activeASRProvider"
    static let selectedQwenModel = "Hireva.selectedQwenModel"
    static let answerProviderMode = "Hireva.answerProviderMode"
    static let appleSpeechASRDefaultMigration = "Hireva.asrDefaultMigration.appleSpeech.20260706"
    static let parakeetSidecarPath = "Hireva.parakeetSidecarPath"
    static let interviewContextMode = "Hireva.interviewContextMode"
    static let interviewSessionMode = "Hireva.interviewSessionMode"
    static let answerPanelQuestions = "Hireva.answerPanelQuestions"
    static let suppressPresentation = "Hireva.suppressPresentation"
    static let suppressCandidateQuestions = "Hireva.suppressCandidateQuestions"
    static let legacyListeningMode = "Hireva.interviewListeningMode"
    static let legacyPhase = "Hireva.interviewPhase"
    static let floatingAssistantWindowFrame = "NSWindow Frame HirevaFloatingAssistant"

    static let migrationVersion = "hirevaMigrationVersion"
    static let legacyDataMigrated = "legacyInterviewCopilotDataMigrated"
    static let legacyDataPath = "legacyDataPath"
    static let migrationTimestamp = "migrationTimestamp"
    static let migrationResult = "migrationResult"
}

/// Old product identifiers are intentionally centralized here for one-time,
/// non-destructive migration. Do not use them as current product identity.
enum LegacyHirevaIdentifiers {
    static let productName = "Interview Copilot"
    static let applicationSupportDirectoryName = "InterviewCopilotMac"
    static let databaseFilename = "interview_copilot.sqlite"
    static let bundleIdentifier = "com.langcheng.InterviewCopilotMac"
    static let keychainService = "com.langcheng.InterviewCopilotMac.LLMProviderKeys"
    static let olderBundleIdentifiers = ["com.langcheng.hireva.mac"]
    static let olderKeychainServices = [
        "InterviewCopilotMac",
        "InterviewCopilotMac.LLMProviderKeys",
        "com.langcheng.hireva.mac",
        "com.langcheng.InterviewCopilotMac"
    ]

    enum PreferenceKeys {
        static let selectedASRProvider = "InterviewCopilot.selectedASRProvider"
        static let activeASRProvider = "InterviewCopilot.activeASRProvider"
        static let selectedQwenModel = "InterviewCopilot.selectedQwenModel"
        static let answerProviderMode = "InterviewCopilot.answerProviderMode"
        static let appleSpeechASRDefaultMigration = "InterviewCopilot.asrDefaultMigration.appleSpeech.20260706"
        static let parakeetSidecarPath = "InterviewCopilot.parakeetSidecarPath"
        static let interviewContextMode = "InterviewCopilot.interviewContextMode"
        static let interviewSessionMode = "InterviewCopilot.interviewSessionMode"
        static let answerPanelQuestions = "InterviewCopilot.answerPanelQuestions"
        static let suppressPresentation = "InterviewCopilot.suppressPresentation"
        static let suppressCandidateQuestions = "InterviewCopilot.suppressCandidateQuestions"
        static let legacyListeningMode = "InterviewCopilot.interviewListeningMode"
        static let legacyPhase = "InterviewCopilot.interviewPhase"
        static let floatingAssistantWindowFrame = "NSWindow Frame InterviewCopilotFloatingAssistant"
    }
}

struct HirevaMigrationReport: Equatable {
    enum ApplicationSupportResult: String, Codable {
        case freshInstall
        case copiedLegacyData
        case keptExistingHirevaData
    }

    enum DatabaseResult: String, Codable {
        case noDatabase
        case renamedLegacyCopy
        case usedExistingHirevaDatabase
    }

    let applicationSupport: ApplicationSupportResult
    let database: DatabaseResult
    let migratedPreferenceKeys: [String]
}

struct HirevaMigrationCoordinator {
    static let migrationVersion = 1
    static let markerFilename = "hireva-migration.json"

    let applicationSupportRoot: URL
    let defaults: UserDefaults
    let legacyDefaults: [UserDefaults]
    let fileManager: FileManager
    let now: () -> Date

    init(
        applicationSupportRoot: URL,
        defaults: UserDefaults,
        legacyDefaults: [UserDefaults],
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.fileManager = fileManager
        self.now = now
    }

    static func production() -> HirevaMigrationCoordinator {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let legacyDomains = ([LegacyHirevaIdentifiers.bundleIdentifier] + LegacyHirevaIdentifiers.olderBundleIdentifiers)
            .compactMap(UserDefaults.init(suiteName:))
        return HirevaMigrationCoordinator(
            applicationSupportRoot: root,
            defaults: .standard,
            legacyDefaults: [.standard] + legacyDomains
        )
    }

    func performBeforeDatabaseOpen() throws -> HirevaMigrationReport {
        try fileManager.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        let migratedPreferenceKeys = migratePreferences()
        let legacyDirectory = applicationSupportRoot.appendingPathComponent(
            LegacyHirevaIdentifiers.applicationSupportDirectoryName,
            isDirectory: true
        )
        let hirevaDirectory = applicationSupportRoot.appendingPathComponent(
            HirevaProductIdentity.applicationSupportDirectoryName,
            isDirectory: true
        )
        let legacyExists = fileManager.fileExists(atPath: legacyDirectory.path)
        let hirevaExists = fileManager.fileExists(atPath: hirevaDirectory.path)

        let applicationSupportResult: HirevaMigrationReport.ApplicationSupportResult
        let databaseResult: HirevaMigrationReport.DatabaseResult
        if hirevaExists {
            applicationSupportResult = legacyExists ? .keptExistingHirevaData : .freshInstall
            databaseResult = try prepareDatabaseCopy(in: hirevaDirectory)
            if legacyExists {
                defaults.set(legacyDirectory.path, forKey: HirevaPreferenceKeys.legacyDataPath)
            }
            try writeMarker(
                in: hirevaDirectory,
                applicationSupport: applicationSupportResult,
                database: databaseResult,
                legacyDirectory: legacyExists ? legacyDirectory : nil
            )
        } else if legacyExists {
            let stagingDirectory = applicationSupportRoot.appendingPathComponent(
                ".Hireva.migrating-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.copyItem(at: legacyDirectory, to: stagingDirectory)
                databaseResult = try prepareDatabaseCopy(in: stagingDirectory)
                try writeMarker(
                    in: stagingDirectory,
                    applicationSupport: .copiedLegacyData,
                    database: databaseResult,
                    legacyDirectory: legacyDirectory
                )
                try fileManager.moveItem(at: stagingDirectory, to: hirevaDirectory)
            } catch {
                try? fileManager.removeItem(at: stagingDirectory)
                throw error
            }
            applicationSupportResult = .copiedLegacyData
            defaults.set(legacyDirectory.path, forKey: HirevaPreferenceKeys.legacyDataPath)
        } else {
            applicationSupportResult = .freshInstall
            databaseResult = .noDatabase
        }

        let migrated = applicationSupportResult == .copiedLegacyData
        defaults.set(Self.migrationVersion, forKey: HirevaPreferenceKeys.migrationVersion)
        if migrated || defaults.object(forKey: HirevaPreferenceKeys.legacyDataMigrated) == nil {
            defaults.set(migrated, forKey: HirevaPreferenceKeys.legacyDataMigrated)
        }
        defaults.set(ISO8601DateFormatter().string(from: now()), forKey: HirevaPreferenceKeys.migrationTimestamp)
        defaults.set(
            "applicationSupport=\(applicationSupportResult.rawValue);database=\(databaseResult.rawValue)",
            forKey: HirevaPreferenceKeys.migrationResult
        )

        return HirevaMigrationReport(
            applicationSupport: applicationSupportResult,
            database: databaseResult,
            migratedPreferenceKeys: migratedPreferenceKeys
        )
    }

    private func prepareDatabaseCopy(in directory: URL) throws -> HirevaMigrationReport.DatabaseResult {
        let hirevaDatabase = directory.appendingPathComponent(HirevaProductIdentity.databaseFilename)
        if fileManager.fileExists(atPath: hirevaDatabase.path) {
            try verifyDatabase(at: hirevaDatabase)
            return .usedExistingHirevaDatabase
        }

        let legacyDatabase = directory.appendingPathComponent(LegacyHirevaIdentifiers.databaseFilename)
        guard fileManager.fileExists(atPath: legacyDatabase.path) else {
            return .noDatabase
        }

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacyDatabase.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: hirevaDatabase.path + suffix)
            try fileManager.moveItem(at: source, to: destination)
        }
        try verifyDatabase(at: hirevaDatabase)
        return .renamedLegacyCopy
    }

    private func verifyDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        let integrity = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        guard integrity == "ok" else {
            throw HirevaMigrationError.databaseIntegrityCheckFailed(integrity ?? "no result")
        }
    }

    private func migratePreferences() -> [String] {
        let mappings = [
            (LegacyHirevaIdentifiers.PreferenceKeys.selectedASRProvider, HirevaPreferenceKeys.selectedASRProvider),
            (LegacyHirevaIdentifiers.PreferenceKeys.activeASRProvider, HirevaPreferenceKeys.activeASRProvider),
            (LegacyHirevaIdentifiers.PreferenceKeys.selectedQwenModel, HirevaPreferenceKeys.selectedQwenModel),
            (LegacyHirevaIdentifiers.PreferenceKeys.answerProviderMode, HirevaPreferenceKeys.answerProviderMode),
            (LegacyHirevaIdentifiers.PreferenceKeys.appleSpeechASRDefaultMigration, HirevaPreferenceKeys.appleSpeechASRDefaultMigration),
            (LegacyHirevaIdentifiers.PreferenceKeys.parakeetSidecarPath, HirevaPreferenceKeys.parakeetSidecarPath),
            (LegacyHirevaIdentifiers.PreferenceKeys.interviewContextMode, HirevaPreferenceKeys.interviewContextMode),
            (LegacyHirevaIdentifiers.PreferenceKeys.interviewSessionMode, HirevaPreferenceKeys.interviewSessionMode),
            (LegacyHirevaIdentifiers.PreferenceKeys.answerPanelQuestions, HirevaPreferenceKeys.answerPanelQuestions),
            (LegacyHirevaIdentifiers.PreferenceKeys.suppressPresentation, HirevaPreferenceKeys.suppressPresentation),
            (LegacyHirevaIdentifiers.PreferenceKeys.suppressCandidateQuestions, HirevaPreferenceKeys.suppressCandidateQuestions),
            (LegacyHirevaIdentifiers.PreferenceKeys.legacyListeningMode, HirevaPreferenceKeys.legacyListeningMode),
            (LegacyHirevaIdentifiers.PreferenceKeys.legacyPhase, HirevaPreferenceKeys.legacyPhase),
            (LegacyHirevaIdentifiers.PreferenceKeys.floatingAssistantWindowFrame, HirevaPreferenceKeys.floatingAssistantWindowFrame)
        ]
        var migratedKeys: [String] = []
        for (legacyKey, hirevaKey) in mappings where defaults.object(forKey: hirevaKey) == nil {
            guard let value = legacyDefaults.lazy.compactMap({ $0.object(forKey: legacyKey) }).first else {
                continue
            }
            if hirevaKey == HirevaPreferenceKeys.parakeetSidecarPath,
               let path = value as? String {
                defaults.set(migratedSidecarPath(path), forKey: hirevaKey)
            } else {
                defaults.set(value, forKey: hirevaKey)
            }
            migratedKeys.append(hirevaKey)
        }
        if let storedPath = defaults.string(forKey: HirevaPreferenceKeys.parakeetSidecarPath) {
            let normalizedPath = migratedSidecarPath(storedPath)
            if normalizedPath != storedPath {
                defaults.set(normalizedPath, forKey: HirevaPreferenceKeys.parakeetSidecarPath)
                if !migratedKeys.contains(HirevaPreferenceKeys.parakeetSidecarPath) {
                    migratedKeys.append(HirevaPreferenceKeys.parakeetSidecarPath)
                }
            }
        }
        return migratedKeys
    }

    private func migratedSidecarPath(_ path: String) -> String {
        var components = URL(fileURLWithPath: path).pathComponents
        guard let oldRootIndex = components.lastIndex(of: "ai_interview") else {
            return path
        }
        components[oldRootIndex] = HirevaProductIdentity.productName
        let candidate = NSString.path(withComponents: components)
        return fileManager.fileExists(atPath: candidate) ? candidate : path
    }

    private func writeMarker(
        in directory: URL,
        applicationSupport: HirevaMigrationReport.ApplicationSupportResult,
        database: HirevaMigrationReport.DatabaseResult,
        legacyDirectory: URL?
    ) throws {
        struct Marker: Codable {
            let migrationVersion: Int
            let migrationTimestamp: String
            let applicationSupportResult: String
            let databaseResult: String
            let legacyDataPath: String?
            let legacyDataRetained: Bool
        }
        let marker = Marker(
            migrationVersion: Self.migrationVersion,
            migrationTimestamp: ISO8601DateFormatter().string(from: now()),
            applicationSupportResult: applicationSupport.rawValue,
            databaseResult: database.rawValue,
            legacyDataPath: legacyDirectory?.path,
            legacyDataRetained: legacyDirectory != nil
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(
            to: directory.appendingPathComponent(Self.markerFilename),
            options: .atomic
        )
    }
}

enum HirevaMigrationError: LocalizedError {
    case databaseIntegrityCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseIntegrityCheckFailed(let result):
            return "Hireva database migration failed integrity verification: \(result)"
        }
    }
}

public enum HirevaStartup {
    public static func preparePersistentIdentity() throws {
        _ = try HirevaMigrationCoordinator.production().performBeforeDatabaseOpen()
    }
}
