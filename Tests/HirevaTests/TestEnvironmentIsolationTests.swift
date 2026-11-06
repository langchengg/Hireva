import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct TestEnvironmentIsolationTests {
    @Test
    func missingLocalFixtureProviderFailsClosedWithoutChangingDefaultMode() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "TestEnvironmentIsolation-local")
        do {
            let provider = try #require(environment.appState.localLLMProviderOverride)
            #expect(environment.appState.selectedAnswerProviderMode == .localQwenPrimary)
            #expect(await provider.healthCheck(modelName: "synthetic").isReady == false)
            let request = LocalLLMRequest(prompt: #"{"question":"Explain bounded retries."}"#,
                systemPrompt: nil, modelName: "synthetic", temperature: 0)
            await #expect(throws: LLMProviderError.self) {
                _ = try await provider.generateAnswer(request: request)
            }
            await #expect(throws: LLMProviderError.self) {
                for try await _ in provider.pullModel("synthetic") { Issue.record("Unexpected model download.") }
            }
            environment.appState.localLLMProviderOverride = HermeticQuestionRoutingProvider()
            let replacement = try #require(environment.appState.localLLMProviderOverride)
            #expect(await replacement.healthCheck(modelName: "synthetic").isReady)
            var text = ""
            for try await token in try await replacement.generateAnswer(request: request) { text += token.text }
            #expect(!text.isEmpty)
            try await environment.shutdown()
        } catch {
            try await environment.shutdown()
            throw error
        }
    }

    @Test
    func environmentsUseDistinctDatabaseAndUserDefaultsState() async throws {
        let first = try await HirevaTestEnvironment(
            prefix: "TestEnvironmentIsolation-first",
            candidateProfile: TestSupport.makeCandidateProfile(id: "first-candidate")
        )
        let second: HirevaTestEnvironment
        do { second = try await HirevaTestEnvironment(prefix: "TestEnvironmentIsolation-second") }
        catch {
            do { try await first.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }

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
    func preCancelledEnvironmentPreparationRemovesItsOwnedTemporaryRoot() async throws {
        let prefix = "Hireva-pre-cancelled-environment-" + UUID().uuidString
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HirevaTestEnvironment(prefix: prefix)
        }
        switch await cancelled.result {
        case .success(let unexpected):
            Issue.record("A pre-cancelled environment initializer unexpectedly succeeded.")
            try await unexpected.shutdown()
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let remaining = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
        #expect(remaining.isEmpty)
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
        let environment = try await HirevaTestEnvironment(prefix: "TestEnvironmentIsolation-shutdown")
        let root = environment.rootDirectory

        #expect(FileManager.default.fileExists(atPath: root.path))
        try await environment.shutdown()

        #expect(environment.database.isClosed)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try await environment.shutdown()
    }
}
