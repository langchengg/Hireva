import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppStateOwnedPreferenceCleanupTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func actualOwnedUUIDSuiteCleanupDoesNotDependOnMutableDefaultsHandle(clearHandle: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        var app: AppState? = makeApp(database: database, defaults: nil)
        let defaults = try #require(app?.dialogueDefaults)
        // Read only the known immutable test-suite identity for exact teardown.
        // No behavior result is inferred from reflection, and no standard or
        // caller-owned domain is enumerated or cleared.
        let field = try #require(Mirror(reflecting: app!).children.first {
            $0.label == "ownedPreferenceDefaultsSuiteName"
        })
        let suite = try #require((field.value as? String) ??
            (Mirror(reflecting: field.value).children.first?.value as? String))
        try #require(suite.hasPrefix("com.langcheng.Hireva.tests.app-state."))
        let key = "syntheticCleanupMarker." + UUID().uuidString
        weak var releasedApp = app
        var box: AppStateReleaseBox?
        do {
            try await settleKnownStartup(app!)
            defaults.set("synthetic", forKey: key)
            if clearHandle { app?.dialogueDefaults = nil }
            box = AppStateReleaseBox(app!)
            app = nil
            await box?.release()
            #expect(releasedApp == nil, "The release probe must execute the actual AppState deinit.")
            #expect(defaults.string(forKey: key) == nil,
                "The immutable owned-suite identity remains authoritative after the handle changes.")
            if let releasedApp { await releasedApp.shutdownForTesting() }
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        } catch {
            await app?.shutdownForTesting()
            await box?.release()
            if let releasedApp { await releasedApp.shutdownForTesting() }
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func actualCallerOwnedSuiteSurvivesShutdownAndARC(explicitShutdown: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.callerOwnership." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        var app: AppState? = makeApp(database: database, defaults: defaults)
        let key = "syntheticCallerMarker." + UUID().uuidString
        weak var releasedApp = app
        var box: AppStateReleaseBox?
        do {
            try await settleKnownStartup(app!)
            defaults.set("synthetic", forKey: key)
            if explicitShutdown { await app?.shutdownForTesting() }
            box = AppStateReleaseBox(app!)
            app = nil
            await box?.release()
            #expect(releasedApp == nil)
            #expect(defaults.string(forKey: key) == "synthetic",
                "A passed-in suite belongs to the caller, even when its name resembles a test suite.")
            if let releasedApp { await releasedApp.shutdownForTesting() }
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        } catch {
            await app?.shutdownForTesting()
            await box?.release()
            if let releasedApp { await releasedApp.shutdownForTesting() }
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
    }

    private func makeApp(database: AppDatabase, defaults: UserDefaults?) -> AppState {
        AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
    }

    private func settleKnownStartup(_ app: AppState) async throws {
        try Task.checkCancellation()
        await app.automaticContextBuildTask?.value
        await app.refreshLatencyAverages()?.value
        try Task.checkCancellation()
    }
}

// The last explicit AppState reference is dropped on this actor, not assumed
// to be on MainActor. Global-actor AppState is Sendable; no unsafe box or cast.
private actor AppStateReleaseBox {
    private var app: AppState?
    init(_ app: AppState) { self.app = app }
    func release() { app = nil }
}
