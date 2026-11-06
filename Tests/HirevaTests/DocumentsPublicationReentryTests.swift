import Foundation
import Combine
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentsPublicationReentryTests {
    @Test(arguments: [false, true])
    func nestedTypedSaveFromDocumentNotificationRemainsTheCurrentProjectionAndSaveCompletion(outerIsSave: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        if !outerIsSave { _ = try repository.saveDocument(type: .cv, title: "Original", content: Self.original) }
        var completions: [DocumentRecord] = []
        let owner = DocumentsState(repository: repository, didSave: { record, _ in completions.append(record) })
        var replaced = false
        let observer = owner.updates.sink { update in
            guard case .documents = update else { return }
            let records = owner.documents
            guard records.contains(where: { $0.content == Self.original }), !replaced else { return }
            replaced = true
            do { _ = try owner.saveDocument(type: .cv, title: "Replacement", content: Self.replacement) }
            catch { Issue.record("Nested synthetic save failed: \(error.localizedDescription)") }
        }
        do {
            if outerIsSave { _ = try owner.saveDocument(type: .cv, title: "Original", content: Self.original) }
            else { try owner.reload() }
            #expect(replaced)
            #expect(try repository.document(type: .cv)?.content == Self.replacement)
            #expect(owner.documents == (try repository.documents()))
            #expect(owner.documents.first?.content == Self.replacement)
            #expect(completions.map(\.content) == [Self.replacement])
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
    func documentNotificationClosingAdmissionPreservesTheCommitAndSuppressesLaterCompletionSideEffects() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        var completions: [DocumentRecord] = []
        let owner = DocumentsState(repository: repository, didSave: { record, _ in completions.append(record) })
        let observer = owner.updates.sink { update in
            guard case .documents = update else { return }
            let records = owner.documents
            if !records.isEmpty { owner.closeAdmission() }
        }
        do {
            let committed = try owner.saveDocument(type: .cv, title: "Original", content: Self.original)
            #expect(try repository.document(type: .cv)?.id == committed.id)
            #expect(try repository.document(type: .cv)?.content == Self.original)
            #expect(owner.documents == (try repository.documents()))
            #expect(completions.isEmpty)
            #expect(owner.importStatus == "Import cancelled")
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

    private static let original = "Synthetic original: I designed a bounded document workflow and reviewed its source locations, cancellation identity, and transactional storage using isolated test material."
    private static let replacement = "Synthetic replacement: I independently validated a second document revision, its persisted content version, and the completion effects bound to that specific revision."
}
