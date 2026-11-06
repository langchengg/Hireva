import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct HybridRetrievalIsolationTests {
    @Test(.timeLimit(.minutes(1)))
    func actualRetrievalSamplesBothApplicationCallbacksOnMainActor() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let settings = AppSettings.default
        let service = HybridContextRetrievalService(
            documentRepository: DocumentRepository(database: database),
            settingsProvider: {
                events.continuation.yield(Thread.isMainThread)
                return settings
            },
            embeddingProviderResolver: {
                events.continuation.yield(Thread.isMainThread)
                return nil
            })
        _ = try await service.retrieveContextWithTrace(question: "Explain an index trade off",
            intent: .technical, maxCVWords: 100, maxJDWords: 100)
        events.continuation.finish()
        var observations: [Bool] = []
        for await observation in events.stream { observations.append(observation) }
        #expect(observations == [true, true])
    }

    @Test(.timeLimit(.minutes(1)))
    func keywordRetrievalPublishesItsActualApplicationDiagnosticOnMainActor() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database,
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(8))
        // This is the same real publisher that reaches the application's
        // SwiftUI graph. No test copy of provider resolution is involved.
        let observation = app.settingsState.objectWillChange.sink {
            events.continuation.yield(Thread.isMainThread)
        }
        do {
            _ = try await app.contextRetrievalService.retrieveContextWithTrace(
                question: "Explain transaction atomicity", intent: .technical,
                maxCVWords: 100, maxJDWords: 100)
            observation.cancel()
            events.continuation.finish()
            var observations: [Bool] = []
            for await observation in events.stream { observations.append(observation) }
            #expect(!observations.isEmpty)
            #expect(observations.allSatisfy { $0 })
            #expect(app.lastEmbeddingError != nil)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            observation.cancel()
            events.continuation.finish()
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }
}
