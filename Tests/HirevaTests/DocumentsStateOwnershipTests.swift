import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
struct DocumentsStateOwnershipTests {
    private static let content = "Synthetic document: I designed an isolated transaction pipeline, reviewed source references, and validated cancellation and persistence with controlled tests."

    @Test
    func documentOwnerPublishesDirectlyAndCompletionComesFromStoredDocuments() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let owner = DocumentsState(repository: repository)
        var firstObserver: [[DocumentRecord]] = []
        var secondObserver: [[DocumentRecord]] = []
        let first = owner.updates.sink { update in
            if case .documents = update { firstObserver.append(owner.documents) }
        }
        let second = owner.updates.sink { update in
            if case .documents = update { secondObserver.append(owner.documents) }
        }
        #expect(!owner.hasCV && !owner.hasJD)
        let cv = try owner.saveDocument(type: .cv, title: "Synthetic CV", content: Self.content)
        #expect(owner.documents == (try repository.documents()))
        #expect(owner.documents.first?.id == cv.id)
        #expect(owner.documents.first?.content == cv.content)
        #expect(owner.hasCV && !owner.hasJD)

        // Legacy short records remain readable; they do not satisfy completion.
        _ = try repository.saveDocument(type: .jobDescription, title: "Legacy short JD", content: "Legacy short document.")
        try owner.reload()
        #expect(owner.hasCV && !owner.hasJD)
        _ = try owner.saveDocument(type: .jobDescription, title: "Synthetic JD", content: Self.content)
        #expect(owner.hasCV && owner.hasJD)
        try owner.deleteDocument(cv)
        #expect(!owner.hasCV && owner.hasJD)
        #expect(firstObserver.count == 4)
        #expect(firstObserver == secondObserver)
        #expect(firstObserver.last == owner.documents)
        first.cancel(); second.cancel()
        await owner.shutdown()
        try database.close()
    }

    @Test
    func importOwnerPublishesSourceAndTypedReplacementRemovesOriginalWithoutAppContainer() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let bytes = Data(Self.content.utf8)
        let material = try MaterialExtractionService.extract(data: bytes, filename: "synthetic.md")
        var origins: [DocumentsState.SaveOrigin] = []
        let owner = DocumentsState(repository: repository, extractURL: { _ in (material, bytes) },
            didSave: { _, origin in origins.append(origin) })
        var status: [String] = []
        let observation = owner.updates.sink { update in
            if case .importStatus = update { status.append(owner.importStatus) }
        }
        owner.importDocument(from: URL(fileURLWithPath: "/HirevaSyntheticImport/synthetic.md"), as: .cv)
        let task = try #require(owner.importTask)
        await task.value
        let imported = try #require(owner.documents.first)
        #expect(imported.content == material.text)
        #expect(try owner.source(documentID: imported.id)?.data == bytes)
        #expect(owner.chunkCount(type: .cv) > 0)
        #expect(owner.hasCV && !owner.hasJD)
        #expect(status.contains("Extracting locally…"))
        #expect(status.last?.hasPrefix("Imported and indexed") == true)
        #expect(owner.pendingImportTaskCount == 0)
        #expect(origins.count == 1)
        if case .some(.fileImport) = origins.first {} else { Issue.record("The import must retain its save origin.") }

        _ = try owner.saveDocument(type: .cv, title: "Typed replacement", content: Self.content)
        #expect(try owner.source(documentID: imported.id) == nil)
        #expect(origins.count == 2)
        if case .some(.typed) = origins.last {} else { Issue.record("The typed replacement must retain its save origin.") }
        observation.cancel()
        await owner.shutdown()
        try database.close()
    }

    @Test
    func closedOwnerRejectsNewImportReprocessAndSaveWithoutRevivingIdentity() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        let bytes = Data(Self.content.utf8)
        let material = try MaterialExtractionService.extract(data: bytes, filename: "synthetic.md")
        let saved = try repository.saveDocument(type: .cv, title: "Synthetic CV",
            content: material.text, material: material, originalData: bytes)
        var extractionCalls = 0
        let owner = DocumentsState(repository: repository,
            extractURL: { _ in extractionCalls += 1; return (material, bytes) },
            extractData: { _, _ in extractionCalls += 1; return material })
        try owner.reload()
        await owner.shutdown()
        let stoppedID = owner.importID
        let stoppedStatus = owner.importStatus
        owner.importDocument(from: URL(fileURLWithPath: "/HirevaSyntheticImport/synthetic.md"), as: .cv)
        owner.reprocessDocument(saved)
        #expect(owner.importTask == nil)
        #expect(owner.importID == stoppedID)
        #expect(owner.importStatus == stoppedStatus)
        #expect(extractionCalls == 0)
        #expect(throws: CancellationError.self) {
            _ = try owner.saveDocument(type: .cv, title: "Rejected replacement", content: Self.content)
        }
        #expect(try repository.document(type: .cv)?.content == material.text)
        await owner.shutdown()
        #expect(owner.pendingImportTaskCount == 0)
        try database.close()
    }

    @Test
    func compatibilityProjectsTheSameOwnerWithoutCopiedDocumentFacts() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(), verificationMocksEnabled: false)
        let owner = app.documentsState
        var changes = 0
        let observer = app.objectWillChange.sink { changes += 1 }
        let before = changes
        _ = try owner.saveDocument(type: .cv, title: "Synthetic CV", content: Self.content)
        #expect(app.documentsState === owner)
        #expect(app.documents == owner.documents)
        #expect(app.hasCV == owner.hasCV)
        #expect(app.hasJD == owner.hasJD)
        #expect(app.materialImportID == owner.importID)
        #expect(app.materialImportStatus == owner.importStatus)
        #expect(app.pendingMaterialImportTaskCount == owner.pendingImportTaskCount)
        #expect(changes > before)
        observer.cancel()
        await app.shutdownForTesting()
        try database.close()
    }
}
