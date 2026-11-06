import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
struct DocumentsObjectPublisherContractTests {
    private static let original = "Synthetic original: I designed an isolated transaction pipeline, reviewed exact source references, and validated cancellation with controlled ownership tests."
    private static let replacement = "Synthetic replacement: I designed a different bounded document workflow, reviewed exact source references, and verified its persistence with controlled owner tests."

    @Test
    func documentPublisherRetainsIdentityAndNestedSaveReadsCommittedSource() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        var completed: [String] = []
        let owner = DocumentsState(repository: repository, didSave: { document, _ in completed.append(document.content) })
        let publisher = owner.objectWillChange
        var observed: [String] = []
        var replaced = false
        let observer = publisher.sink {
            #expect(owner.objectWillChange === publisher)
            if let content = owner.documents.first?.content { observed.append(content) }
            guard !replaced, owner.documents.first?.content == Self.original else { return }
            replaced = true
            do { _ = try owner.saveDocument(type: .cv, title: "Synthetic replacement", content: Self.replacement) }
            catch { Issue.record(error) }
        }
        do {
            _ = try owner.saveDocument(type: .cv, title: "Synthetic original", content: Self.original)
            #expect(replaced)
            #expect(observed == [Self.original, Self.replacement])
            #expect(owner.documents == (try repository.documents()))
            #expect(owner.documents.first?.content == Self.replacement)
            #expect(completed == [Self.replacement])
            #expect(owner.objectWillChange === publisher)
            observer.cancel()
            await owner.shutdown()
            try database.close()
        } catch {
            observer.cancel()
            await owner.shutdown()
            try database.close()
            throw error
        }
    }

    @Test
    func embeddingPublisherRetainsIdentityAndNotifiesCommittedPhaseProgressAndCoverage() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let owner = DocumentEmbeddingState(repository: repository)
        let publisher = owner.objectWillChange
        var first: [Double] = [], second: [Double] = []
        let a = publisher.sink { first.append(owner.progress) }
        let b = owner.objectWillChange.sink { second.append(owner.progress) }
        do {
            try owner.reloadCoverage()
            #expect(owner.coverage != nil)
            #expect(owner.objectWillChange === publisher)
            #expect(owner.rebuildAll() == nil)
            #expect(owner.phase == .idle)
            #expect(owner.progress == 1)
            #expect(first == second)
            #expect(first.contains(0) && first.last == 1)
            #expect(owner.objectWillChange === publisher)
            a.cancel(); b.cancel()
            await owner.shutdown()
            try database.close()
        } catch {
            a.cancel(); b.cancel()
            await owner.shutdown()
            try database.close()
            throw error
        }
    }

    @Test
    func directObjectNotificationCanCloseAdmissionBeforeLaterPublicationOrSQL() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let owner = DocumentEmbeddingState(repository: repository)
        let publisher = owner.objectWillChange
        var notifications = 0
        let observer = publisher.sink {
            notifications += 1
            if notifications == 1 { owner.closeAdmission() }
        }
        #expect(owner.rebuildAll() == nil)
        #expect(notifications == 1)
        #expect(owner.progress == 0)
        #expect(owner.objectWillChange === publisher)
        #expect(owner.rebuildCleanIndex(willChangeSources: { Issue.record("Closed owner reached the source-write hook.") }) == nil)
        #expect(owner.pendingTaskCount == 0)
        observer.cancel()
        await owner.shutdown()
        try database.close()
    }

    @Test
    func sdkDefaultPublisherWithoutPublishedStorageIsRecordedWithoutAssumingItsIdentity() {
        let noStorage = NoPublishedStorage()
        let first = noStorage.objectWillChange
        let second = noStorage.objectWillChange
        var received = 0
        let observation = first.sink { received += 1 }
        second.send()
        print("COMBINE_PUBLISHER_CHARACTERIZATION noPublishedStableIdentity=\(first === second) crossAccessNotifications=\(received)")
        observation.cancel()
    }
}

private final class NoPublishedStorage: ObservableObject {}
