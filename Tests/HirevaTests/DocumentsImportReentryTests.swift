import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DocumentsImportReentryTests {
    @Test(arguments: ImportCallbackPoint.allCases)
    func completedImportCanStartANewOwnedImportFromItsActualCallback(_ point: ImportCallbackPoint) async throws {
        let fixture = try ImportReentryFixture(point: point)
        try await fixture.run {
            fixture.owner.importDocument(from: ImportReentryFixture.aURL, as: .cv)
            let a = try #require(fixture.owner.importTask)
            fixture.tasks.append(a)
            try await fixture.expectEntered("A")
            await fixture.extractor.release("A")
            await a.value

            #expect(fixture.box.requestedReplacement)
            #expect(a.isCancelled)
            // The old callback's Task was cancelled while admitting B. That must
            // invalidate A, without making the distinct B request unregistrable.
            let b = try #require(fixture.owner.importTask, "The actual replacement import must retain its own worker.")
            fixture.tasks.append(b)
            #expect(!b.isCancelled)
            #expect(fixture.owner.importID != fixture.box.originalImportID)
            try await fixture.expectEntered("B")
            await fixture.extractor.release("B")
            await b.value

            #expect(fixture.owner.documents == (try fixture.repository.documents()))
            #expect(fixture.owner.documents.first?.title == "synthetic-B")
            #expect(fixture.owner.documents.first?.content == fixture.bMaterial.text)
            #expect(fixture.box.completedTitles == ["synthetic-A", "synthetic-B"])
            #expect(fixture.owner.importStatus.hasPrefix("Imported and indexed"))
            #expect(fixture.owner.pendingImportTaskCount == 0)
        }
    }
}

enum ImportCallbackPoint: String, CaseIterable, Sendable { case didSave, completionStatus }
private enum ImportReentryEvent: Equatable, Sendable { case entered(String), cancelled(String) }

private actor ImportReentryExtractor {
    let a: ExtractedMaterial
    let b: ExtractedMaterial
    private let events: AsyncStream<ImportReentryEvent>.Continuation
    private var released: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(a: ExtractedMaterial, b: ExtractedMaterial, events: AsyncStream<ImportReentryEvent>.Continuation) {
        self.a = a; self.b = b; self.events = events
    }
    func extract(_ url: URL) async throws -> (ExtractedMaterial, Data) {
        let name = url == ImportReentryFixture.aURL ? "A" : "B"
        let events = events
        await withTaskCancellationHandler {
            if !released.contains(name) {
                await withCheckedContinuation { continuation in
                    waiters[name, default: []].append(continuation)
                    events.yield(.entered(name))
                }
            }
        } onCancel: { events.yield(.cancelled(name)) }
        let material = name == "A" ? a : b
        return (material, Data(material.text.utf8))
    }
    func release(_ name: String) {
        released.insert(name)
        let pending = waiters.removeValue(forKey: name) ?? []
        pending.forEach { $0.resume() }
    }
    func releaseAll() { release("A"); release("B") }
}

@MainActor
private final class ImportReentryBox {
    weak var owner: DocumentsState?
    var requestedReplacement = false
    var originalImportID: UUID?
    var completedTitles: [String] = []
    func requestReplacement() {
        guard !requestedReplacement, let owner else { return }
        requestedReplacement = true
        originalImportID = owner.importID
        owner.importDocument(from: ImportReentryFixture.bURL, as: .cv)
    }
}

@MainActor
private final class ImportReentryFixture {
    nonisolated static let aURL = URL(fileURLWithPath: "/HirevaSyntheticImport/synthetic-A.md")
    nonisolated static let bURL = URL(fileURLWithPath: "/HirevaSyntheticImport/synthetic-B.md")
    let database: AppDatabase
    let repository: DocumentRepository
    let owner: DocumentsState
    let extractor: ImportReentryExtractor
    let bMaterial: ExtractedMaterial
    let box = ImportReentryBox()
    let trace = TestEventWaitTrace(label: "DocumentsImportReentry")
    private let events: AsyncStream<ImportReentryEvent>
    private let continuation: AsyncStream<ImportReentryEvent>.Continuation
    private var observation: AnyCancellable?
    var tasks: [Task<Void, Never>] = []

    init(point: ImportCallbackPoint) throws {
        database = try AppDatabase(inMemory: true)
        repository = DocumentRepository(database: database)
        let a = try MaterialExtractionService.extract(data: Data("Synthetic A: I designed an isolated transactional service, reviewed exact source locations, and validated its ownership and cancellation using controlled regressions.".utf8), filename: Self.aURL.lastPathComponent)
        let b = try MaterialExtractionService.extract(data: Data("Synthetic B: I designed a different bounded document workflow, reviewed exact source locations, and validated its persistence and cancellation using independent fixtures.".utf8), filename: Self.bURL.lastPathComponent)
        bMaterial = b
        let pair = AsyncStream<ImportReentryEvent>.makeStream(bufferingPolicy: .bufferingOldest(16))
        events = pair.stream; continuation = pair.continuation
        let extractor = ImportReentryExtractor(a: a, b: b, events: pair.continuation)
        self.extractor = extractor
        let box = box
        owner = DocumentsState(repository: repository, extractURL: { url in try await extractor.extract(url) },
            didSave: { document, origin in
                box.completedTitles.append(document.title)
                if point == .didSave, case .fileImport = origin, document.title == "synthetic-A" { box.requestReplacement() }
            })
        box.owner = owner
        if point == .completionStatus {
            observation = owner.updates.sink { update in
                if case .importStatus = update, box.owner?.importStatus.hasPrefix("Imported and indexed") == true {
                    box.requestReplacement()
                }
            }
        }
    }

    func expectEntered(_ name: String) async throws {
        let event = try await trace.nextEvent(in: events, event: "entered-\(name)")
        #expect(event == .entered(name))
    }
    func run(_ operation: () async throws -> Void) async throws {
        do { try await operation(); try await cleanup() }
        catch { try await cleanup(); throw error }
    }
    private func cleanup() async throws {
        observation?.cancel()
        owner.closeAdmission()
        await extractor.releaseAll()
        for task in tasks { task.cancel(); await task.value }
        await owner.shutdown()
        continuation.finish()
        try database.close()
    }
}
