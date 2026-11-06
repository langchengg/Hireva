import Foundation
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentsImportLifecycleTests {
    @Test
    func shutdownCancelsAndJoinsActiveExtractionBeforeReturning() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["active.md"])
        try await fixture.run {
            let task = try fixture.importFile("active.md")
            try await fixture.waitUntilStarted("active.md")
            let shutdown = fixture.beginShutdown()
            let first = try await fixture.nextEvent()
            #expect(first == .cancelled("active.md"))
            await fixture.release("active.md")
            await task.value
            await shutdown.value
            #expect(try fixture.app.documentRepository.documents().isEmpty)
            #expect(fixture.app.pendingMaterialImportTaskCount == 0)
        }
    }

    @Test
    func cancelledExtractionRemainsOwnedUntilExitAndShutdownJoinsActiveAndRetiredImports() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["retired.md", "active.md"])
        try await fixture.run {
            let retired = try fixture.importFile("retired.md")
            try await fixture.waitUntilStarted("retired.md")
            fixture.app.cancelMaterialImport()
            #expect(retired.isCancelled)
            #expect(try await fixture.nextEvent() == .cancelled("retired.md"))
            #expect(fixture.app.pendingMaterialImportTaskCount == 1)

            let active = try fixture.importFile("active.md")
            try await fixture.waitUntilStarted("active.md")
            #expect(fixture.app.pendingMaterialImportTaskCount == 2)
            let shutdown = fixture.beginShutdown()
            #expect(try await fixture.nextEvent() == .cancelled("active.md"))
            await fixture.release("active.md")
            await active.value
            #expect(fixture.app.pendingMaterialImportTaskCount == 1)
            await fixture.release("retired.md")
            await retired.value
            await shutdown.value
            #expect(try fixture.app.documentRepository.documents().isEmpty)
            #expect(fixture.app.pendingMaterialImportTaskCount == 0)
        }
    }

    @Test
    func laterTypedSaveWinsOverPendingFileImport() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["old-file.md"])
        try await fixture.run {
            let old = try fixture.importFile("old-file.md")
            try await fixture.waitUntilStarted("old-file.md")
            let typed = "Synthetic typed replacement: I designed a small transactional service, documented its failure modes, and validated concurrency behavior with controlled tests."
            fixture.app.saveDocument(type: .cv, title: "Typed replacement", content: typed)
            #expect(try fixture.app.documentRepository.document(type: .cv)?.content == typed)
            await fixture.release("old-file.md")
            await old.value
            let saved = try #require(try fixture.app.documentRepository.document(type: .cv))
            #expect(saved.content == typed)
            #expect(saved.title == "Typed replacement")
            #expect(try fixture.app.documentRepository.source(documentID: saved.id) == nil)
            #expect(try fixture.app.documentRepository.chunks(documentID: saved.id).allSatisfy { !$0.content.contains("old-file.md") })
        }
    }

    @Test
    func deletedDocumentCannotBeRestoredByOldExtraction() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["deleted.md"])
        try await fixture.run {
            let original = try fixture.saveOriginal("deleted.md")
            let old = try fixture.importFile("deleted.md")
            try await fixture.waitUntilStarted("deleted.md")
            fixture.app.deleteDocument(original)
            await fixture.release("deleted.md")
            await old.value
            #expect(try fixture.app.documentRepository.document(type: .cv) == nil)
            #expect(try fixture.app.documentRepository.source(documentID: original.id) == nil)
            #expect(try fixture.app.documentRepository.chunks(documentID: original.id).isEmpty)
            #expect(!fixture.app.materialImportStatus.hasPrefix("Imported and indexed"))
        }
    }

    @Test
    func clearingLocalDataKeepsNewEmptyContextWhenOldImportReturns() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["cleared.md"])
        try await fixture.run {
            _ = try fixture.saveOriginal("cleared.md")
            let old = try fixture.importFile("cleared.md")
            try await fixture.waitUntilStarted("cleared.md")
            fixture.app.deleteAllLocalData(includeAPIKey: false)
            await fixture.release("cleared.md")
            await old.value
            #expect(try fixture.app.documentRepository.documents().isEmpty)
            #expect(fixture.app.activeCandidateProfileID == nil)
            #expect(fixture.app.activeOpportunityContextID == nil)
            #expect(fixture.app.activeContextSnapshot == nil)
        }
    }

    @Test
    func reprocessRejectsOriginalSourceReplacedByTypedSave() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["reprocess.md"])
        try await fixture.run {
            let original = try fixture.saveOriginal("reprocess.md")
            fixture.app.reprocessDocument(original)
            let old = try fixture.retainImport()
            try await fixture.waitUntilStarted("reprocess.md")
            let typed = "Synthetic replacement for reprocessing: I built an isolated document workflow with exact source references, reviewed extracted text, and tested cancellation before persistence."
            fixture.app.saveDocument(type: .cv, title: "Typed revision", content: typed)
            await fixture.release("reprocess.md")
            await old.value
            #expect(try fixture.app.documentRepository.document(type: .cv)?.content == typed)
            #expect(try fixture.app.documentRepository.source(documentID: original.id) == nil)
            #expect(!fixture.app.materialImportStatus.hasPrefix("Reprocessed from saved original"))
        }
    }

    @Test
    func oldImportCleanupCannotClearNewImportIdentityOrPublishOldContent() async throws {
        let fixture = try DocumentsImportFixture(filenames: ["old.md", "new.md"])
        try await fixture.run {
            let old = try fixture.importFile("old.md")
            try await fixture.waitUntilStarted("old.md")
            let current = try fixture.importFile("new.md")
            let currentID = fixture.app.materialImportID
            try await fixture.waitUntilStarted("new.md")
            await fixture.release("old.md")
            await old.value
            #expect(fixture.app.materialImportID == currentID)
            #expect(fixture.app.materialImportTask != nil)
            #expect(fixture.app.materialImportStatus == "Extracting locally…")
            #expect(try fixture.app.documentRepository.documents().isEmpty)
            await fixture.release("new.md")
            await current.value
            let saved = try #require(try fixture.app.documentRepository.document(type: .cv))
            #expect(saved.content.contains("new.md"))
            #expect(!saved.content.contains("old.md"))
            #expect(try fixture.app.documentRepository.source(documentID: saved.id)?.material.filename == "new.md")
        }
    }
}

private enum DocumentsImportEvent: Equatable, Sendable {
    case cancelled(String)
    case shutdownReturned(allExtractionsReleased: Bool)
}

/// Extraction deliberately ignores cancellation until its test-owned release.
/// The cancellation event is emitted from the real task's cancellation handler.
private actor ControlledMaterialExtraction {
    nonisolated let trace: TestEventWaitTrace
    let material: ExtractedMaterial
    let data: Data
    nonisolated let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let events: AsyncStream<DocumentsImportEvent>.Continuation
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(filename: String, events: AsyncStream<DocumentsImportEvent>.Continuation) throws {
        trace = TestEventWaitTrace(label: "DocumentsImport:\(filename)")
        let data = Data("Synthetic source \(filename): I built an isolated service, measured failure paths, and validated the implementation with controlled concurrency tests and source review.".utf8)
        self.material = try MaterialExtractionService.extract(data: data, filename: filename)
        self.data = data
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.started = start.stream
        self.startedContinuation = start.continuation
        self.events = events
    }

    func extract() async -> (ExtractedMaterial, Data) {
        trace.mark("producer.start.yield.before")
        let yielded = startedContinuation.yield(())
        trace.mark("producer.start.yield.\(yielded)")
        let events = events
        let filename = material.filename
        let trace = trace
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiter = continuation
                }
            }
        } onCancel: {
            trace.mark("producer.cancel.yield.before")
            let yielded = events.yield(.cancelled(filename))
            trace.mark("producer.cancel.yield.\(yielded)")
        }
        trace.mark("producer.extract.return")
        return (material, data)
    }

    func release() {
        trace.mark("producer.release")
        released = true
        waiter?.resume()
        waiter = nil
        startedContinuation.finish()
    }

    func isReleased() -> Bool { released }
}

@MainActor
private final class DocumentsImportFixture {
    let app: AppState
    private let database: AppDatabase
    private let gates: [String: ControlledMaterialExtraction]
    private let events: AsyncStream<DocumentsImportEvent>
    private let eventContinuation: AsyncStream<DocumentsImportEvent>.Continuation
    private var imports: [Task<Void, Never>] = []
    private var shutdowns: [Task<Void, Never>] = []

    init(filenames: [String]) throws {
        let eventPair = AsyncStream<DocumentsImportEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let gates = try Dictionary(uniqueKeysWithValues: filenames.map { filename in
            (filename, try ControlledMaterialExtraction(filename: filename, events: eventPair.continuation))
        })
        let database = try AppDatabase(inMemory: true)
        self.database = database
        self.gates = gates
        self.events = eventPair.stream
        self.eventContinuation = eventPair.continuation
        self.app = AppState(database: database, permissionService: HermeticPermissionService(),
            verificationMocksEnabled: false,
            materialURLExtraction: { url in
                guard let gate = gates[url.lastPathComponent] else { throw MaterialError.invalid("Unknown synthetic import") }
                return await gate.extract()
            },
            materialDataExtraction: { _, filename in
                guard let gate = gates[filename] else { throw MaterialError.invalid("Unknown synthetic reprocess") }
                return await gate.extract().0
            })
    }

    func importFile(_ filename: String) throws -> Task<Void, Never> {
        app.importPlainTextDocument(from: URL(fileURLWithPath: "/HirevaSyntheticImport/\(filename)"), as: .cv)
        return try retainImport()
    }

    func retainImport() throws -> Task<Void, Never> {
        let task = try #require(app.materialImportTask)
        imports.append(task)
        return task
    }

    func saveOriginal(_ filename: String) throws -> DocumentRecord {
        let data = Data("Synthetic original \(filename): I designed a bounded document pipeline, reviewed exact source locations, and tested persistence behavior with isolated records.".utf8)
        let material = try MaterialExtractionService.extract(data: data, filename: filename)
        let saved = try app.documentRepository.saveDocument(type: .cv, title: filename,
            content: material.text, material: material, originalData: data)
        app.refreshAll()
        return saved
    }

    func waitUntilStarted(_ filename: String) async throws {
        let gate = try #require(gates[filename])
        let trace = gate.trace
        _ = try await trace.nextEvent(in: gate.started, event: "start")
    }

    func nextEvent() async throws -> DocumentsImportEvent {
        // Sequential consumers share the retained stream's FIFO context. Keep
        // each non-Sendable iterator inside the child that consumes its event.
        let stream = events
        let trace = TestEventWaitTrace(label: "DocumentsImport:control_event")
        return try await trace.nextEvent(in: stream, event: "control")
    }

    func release(_ filename: String) async {
        await gates[filename]?.release()
    }

    func beginShutdown() -> Task<Void, Never> {
        let task = Task {
            await app.shutdownForTesting()
            var released = true
            for gate in gates.values { released = await gate.isReleased() && released }
            #expect(released)
            eventContinuation.yield(.shutdownReturned(allExtractionsReleased: released))
        }
        shutdowns.append(task)
        return task
    }

    func run(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            try await cleanup()
        } catch {
            try await cleanup()
            throw error
        }
    }

    private func cleanup() async throws {
        for gate in gates.values { await gate.release() }
        for task in imports { task.cancel(); await task.value }
        for task in shutdowns { await task.value }
        await app.shutdownForTesting()
        eventContinuation.finish()
        try database.close()
    }
}
