import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.serialized)
struct HirevaRenameMigrationTests {
    @Test
    func canonicalIdentityUsesHirevaEverywhere() {
        #expect(HirevaProductIdentity.productName == "Hireva")
        #expect(HirevaProductIdentity.bundleIdentifier == "com.langcheng.Hireva")
        #expect(HirevaProductIdentity.applicationSupportDirectoryName == "Hireva")
        #expect(HirevaProductIdentity.databaseFilename == "hireva.sqlite")
        #expect(HirevaProductIdentity.keychainService == "com.langcheng.Hireva.LLMProviderKeys")
        #expect(AppPaths.applicationSupportDirectory.lastPathComponent == "Hireva")
        #expect(AppPaths.databaseURL.lastPathComponent == "hireva.sqlite")
    }

    @Test
    @MainActor
    func temporaryDatabaseKeepsRuntimeTraceOutOfProductionApplicationSupport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaTraceIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let database = try AppDatabase(path: databaseURL)
        let appState = AppState(
            database: database,
            keychainService: KeychainService(store: InMemoryMockKeychainStore())
        )

        #expect(appState.runtimeTranscriptTraceLogURL.deletingLastPathComponent() == directory)
        #expect(appState.runtimeTranscriptTraceLogURL != AppPaths.runtimeTranscriptTraceURL)
    }

    @Test
    func legacyApplicationSupportAndDatabaseAreCopiedWithoutDeletingOriginals() throws {
        let fixture = try makeFixture()
        let legacyDirectory = fixture.supportRoot
            .appendingPathComponent(LegacyHirevaIdentifiers.applicationSupportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyDatabase = legacyDirectory.appendingPathComponent(LegacyHirevaIdentifiers.databaseFilename)

        do {
            let database = try AppDatabase(path: legacyDatabase)
            _ = try DocumentRepository(database: database).saveDocument(
                type: .cv,
                title: "Preserved CV",
                content: String(repeating: "Robotics systems evidence ", count: 30)
            )
        }
        let modelMarker = legacyDirectory.appendingPathComponent("LocalModels/parakeet/model.ready")
        try FileManager.default.createDirectory(
            at: modelMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ready".utf8).write(to: modelMarker)

        let report = try fixture.coordinator.performBeforeDatabaseOpen()
        let newDirectory = fixture.supportRoot.appendingPathComponent("Hireva", isDirectory: true)
        let newDatabase = newDirectory.appendingPathComponent("hireva.sqlite")

        #expect(report.applicationSupport == .copiedLegacyData)
        #expect(report.database == .renamedLegacyCopy)
        #expect(FileManager.default.fileExists(atPath: legacyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: legacyDatabase.path))
        #expect(FileManager.default.fileExists(atPath: newDatabase.path))
        #expect(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("LocalModels/parakeet/model.ready").path))
        #expect(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent(HirevaMigrationCoordinator.markerFilename).path))
        #expect(fixture.defaults.bool(forKey: HirevaPreferenceKeys.legacyDataMigrated))

        let migrated = try AppDatabase(path: newDatabase)
        #expect(try DocumentRepository(database: migrated).documents().map(\.title) == ["Preserved CV"])
        let integrity = try migrated.dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        #expect(integrity == "ok")

        let secondReport = try fixture.coordinator.performBeforeDatabaseOpen()
        #expect(secondReport.applicationSupport == .keptExistingHirevaData)
        #expect(fixture.defaults.bool(forKey: HirevaPreferenceKeys.legacyDataMigrated))
        #expect(FileManager.default.fileExists(atPath: legacyDatabase.path))
    }

    @Test
    func existingHirevaDirectoryWinsWithoutLegacyOverwrite() throws {
        let fixture = try makeFixture()
        let legacyDirectory = fixture.supportRoot.appendingPathComponent("InterviewCopilotMac", isDirectory: true)
        let newDirectory = fixture.supportRoot.appendingPathComponent("Hireva", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDirectory.appendingPathComponent("identity.txt"))
        try Data("hireva".utf8).write(to: newDirectory.appendingPathComponent("identity.txt"))

        let report = try fixture.coordinator.performBeforeDatabaseOpen()

        #expect(report.applicationSupport == .keptExistingHirevaData)
        #expect(try String(contentsOf: newDirectory.appendingPathComponent("identity.txt"), encoding: .utf8) == "hireva")
        #expect(FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("identity.txt").path))
        #expect(fixture.defaults.string(forKey: HirevaPreferenceKeys.legacyDataPath) == legacyDirectory.path)
    }

    @Test
    func legacyWALDatabaseIsCopiedWithCommittedRowsAndOriginalFilesRemain() throws {
        let fixture = try makeFixture()
        let legacyDirectory = fixture.supportRoot.appendingPathComponent(
            LegacyHirevaIdentifiers.applicationSupportDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyDatabase = legacyDirectory.appendingPathComponent(LegacyHirevaIdentifiers.databaseFilename)
        let queue = try DatabaseQueue(path: legacyDatabase.path)
        try queue.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
            try db.execute(sql: "CREATE TABLE migration_fixture (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO migration_fixture (value) VALUES ('preserved')")
        }
        #expect(FileManager.default.fileExists(atPath: legacyDatabase.path + "-wal"))
        #expect(FileManager.default.fileExists(atPath: legacyDatabase.path + "-shm"))

        let report = try fixture.coordinator.performBeforeDatabaseOpen()
        let newDatabase = fixture.supportRoot.appendingPathComponent("Hireva/hireva.sqlite")
        let migratedQueue = try DatabaseQueue(path: newDatabase.path)
        let value = try migratedQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM migration_fixture")
        }

        #expect(report.database == .renamedLegacyCopy)
        #expect(value == "preserved")
        #expect(FileManager.default.fileExists(atPath: legacyDatabase.path))
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM migration_fixture") } == "preserved")
    }

    @Test
    func userDefaultsMigrationCopiesLegacyValuesButNeverOverwritesNewValues() throws {
        let fixture = try makeFixture()
        let oldSidecar = fixture.root.appendingPathComponent("ai_interview/scripts/parakeet_asr_sidecar")
        let newSidecar = fixture.root.appendingPathComponent("Hireva/scripts/parakeet_asr_sidecar")
        try FileManager.default.createDirectory(at: oldSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: oldSidecar)
        try Data().write(to: newSidecar)

        fixture.legacyDefaults.set("localParakeet", forKey: LegacyHirevaIdentifiers.PreferenceKeys.selectedASRProvider)
        fixture.legacyDefaults.set("deepSeekPrimary", forKey: LegacyHirevaIdentifiers.PreferenceKeys.answerProviderMode)
        fixture.legacyDefaults.set(oldSidecar.path, forKey: LegacyHirevaIdentifiers.PreferenceKeys.parakeetSidecarPath)
        fixture.defaults.set("localQwenPrimary", forKey: HirevaPreferenceKeys.answerProviderMode)

        let report = try fixture.coordinator.performBeforeDatabaseOpen()

        #expect(report.migratedPreferenceKeys.contains(HirevaPreferenceKeys.selectedASRProvider))
        #expect(fixture.defaults.string(forKey: HirevaPreferenceKeys.selectedASRProvider) == "localParakeet")
        #expect(fixture.defaults.string(forKey: HirevaPreferenceKeys.answerProviderMode) == "localQwenPrimary")
        #expect(fixture.defaults.string(forKey: HirevaPreferenceKeys.parakeetSidecarPath) == newSidecar.path)
        #expect(fixture.legacyDefaults.string(forKey: LegacyHirevaIdentifiers.PreferenceKeys.parakeetSidecarPath) == oldSidecar.path)
    }

    @Test
    func keychainCopiesLegacyServiceOnceAndRetainsLegacyItem() throws {
        let store = InMemoryMockKeychainStore()
        let legacySecret = "sk-legacy-value-that-must-not-be-logged"
        try store.saveGenericPassword(
            data: Data(legacySecret.utf8),
            service: LegacyHirevaIdentifiers.keychainService,
            account: KeychainConstants.deepSeekAccount
        )
        let service = KeychainService(store: store)

        service.performMigrationIfNeeded()

        #expect(service.migrationPerformed)
        #expect(try store.loadGenericPassword(
            service: KeychainConstants.service,
            account: KeychainConstants.deepSeekAccount
        ) == legacySecret)
        #expect(try store.loadGenericPassword(
            service: LegacyHirevaIdentifiers.keychainService,
            account: KeychainConstants.deepSeekAccount
        ) == legacySecret)
        #expect(service.lastWriteStatus.contains(legacySecret) == false)
    }

    @Test
    func keychainPrefersExistingHirevaItemAndMissingLegacyIsHarmless() throws {
        let store = InMemoryMockKeychainStore()
        try store.saveGenericPassword(
            data: Data("sk-new-value".utf8),
            service: KeychainConstants.service,
            account: KeychainConstants.deepSeekAccount
        )
        try store.saveGenericPassword(
            data: Data("sk-old-value".utf8),
            service: LegacyHirevaIdentifiers.keychainService,
            account: KeychainConstants.deepSeekAccount
        )
        let service = KeychainService(store: store)

        service.performMigrationIfNeeded()

        #expect(service.migrationPerformed == false)
        #expect(try service.loadAPIKey() == "sk-new-value")

        let empty = KeychainService(store: InMemoryMockKeychainStore())
        empty.performMigrationIfNeeded()
        #expect(empty.migrationPerformed == false)
        #expect(try empty.loadAPIKey() == nil)
    }

    @Test
    func currentViewsAndProductionSourcesDoNotUseLegacyProductIdentity() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/Hireva", isDirectory: true)
        let viewsRoot = sourceRoot.appendingPathComponent("Views", isDirectory: true)
        let oldIdentityTokens = [
            "Interview Copilot",
            "InterviewCopilotMacRunner",
            "InterviewCopilotMac",
            "ai_interview",
            "interview_copilot"
        ]

        let productionViolations = try swiftFiles(under: sourceRoot).flatMap { url -> [String] in
            guard url.lastPathComponent != "HirevaMigration.swift" else { return [] }
            let contents = try String(contentsOf: url, encoding: .utf8)
            return oldIdentityTokens.filter(contents.contains).map { "\(url.path): \($0)" }
        }
        #expect(productionViolations.isEmpty, "Unexpected legacy identities: \(productionViolations)")

        let visibleViolations = try swiftFiles(under: viewsRoot).flatMap { url -> [String] in
            let contents = try String(contentsOf: url, encoding: .utf8)
            return ["Interview Copilot", "InterviewCopilotMac", "Synthetic Data Candidate"]
                .filter(contents.contains)
                .map { "\(url.path): \($0)" }
        }
        #expect(visibleViolations.isEmpty, "Unexpected legacy UI branding: \(visibleViolations)")
    }

    private func makeFixture() throws -> MigrationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaRenameMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let supportRoot = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)

        let destinationSuite = "HirevaRenameMigrationTests.destination.\(UUID().uuidString)"
        let legacySuite = "HirevaRenameMigrationTests.legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: destinationSuite))
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        defaults.removePersistentDomain(forName: destinationSuite)
        legacyDefaults.removePersistentDomain(forName: legacySuite)

        return MigrationFixture(
            root: root,
            supportRoot: supportRoot,
            defaults: defaults,
            legacyDefaults: legacyDefaults,
            coordinator: HirevaMigrationCoordinator(
                applicationSupportRoot: supportRoot,
                defaults: defaults,
                legacyDefaults: [legacyDefaults]
            )
        )
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}

private struct MigrationFixture {
    let root: URL
    let supportRoot: URL
    let defaults: UserDefaults
    let legacyDefaults: UserDefaults
    let coordinator: HirevaMigrationCoordinator
}
