import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct TestEnvironmentIsolationTests {
    @Test
    func environmentsUseDistinctDatabaseAndUserDefaultsState() async throws {
        let first = try HirevaTestEnvironment(
            prefix: "TestEnvironmentIsolation-first",
            candidateProfile: TestSupport.makeCandidateProfile(id: "first-candidate")
        )
        let second = try HirevaTestEnvironment(prefix: "TestEnvironmentIsolation-second")

        #expect(first.databaseURL != second.databaseURL)
        #expect(first.userDefaultsSuiteName != second.userDefaultsSuiteName)
        #expect(first.appState.candidateProfiles.map(\.id) == ["first-candidate"])
        #expect(second.appState.candidateProfiles.isEmpty)

        first.userDefaults.set("first-only", forKey: "isolation-key")
        #expect(second.userDefaults.string(forKey: "isolation-key") == nil)

        try await first.shutdown()
        try await second.shutdown()
    }

    @Test
    func appStateDefaultsToInMemoryKeychainDuringTests() throws {
        let database = try AppDatabase(inMemory: true)
        let appState = AppState(database: database)

        #expect(appState.keychainService.store is InMemoryMockKeychainStore)
        #expect(appState.keychainLastReadStatus != "Deferred")
    }

    @Test
    func shutdownClosesDatabaseBeforeRemovingTemporaryRoot() async throws {
        let environment = try HirevaTestEnvironment(prefix: "TestEnvironmentIsolation-shutdown")
        let root = environment.rootDirectory

        #expect(FileManager.default.fileExists(atPath: root.path))
        try await environment.shutdown()

        #expect(environment.database.isClosed)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try await environment.shutdown()
    }
}
