import Combine
import Foundation
import os
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentsCancelSubmissionReentryTests {
    @Test(arguments: DocumentsSubmissionCase.all)
    func cancellationNotificationCannotLetAnOlderSubmissionReplaceTheNewerRequest(
        scenario: DocumentsSubmissionCase
    ) async throws {
        let operation = scenario.operation, observerKind = scenario.observer
        let existingWorker = scenario.existingWorker
        let fixture = try DocumentsSubmissionFixture()
        try await fixture.run {
            if existingWorker {
                fixture.owner.importDocument(from: DocumentsSubmissionFixture.previousURL, as: .additionalNotes)
                fixture.captureCurrentTask()
                try await fixture.control.waitUntilEntered("previous.md")
            }
            var armed = true
            var replacementID: UUID?
            var replacementTask: Task<Void, Never>?
            let submitNewer = {
                guard armed, fixture.owner.importStatus == "Import cancelled" else { return }
                armed = false
                fixture.captureCurrentTask()
                fixture.owner.importDocument(from: DocumentsSubmissionFixture.newerURL, as: .cv)
                replacementID = fixture.owner.importID
                replacementTask = fixture.owner.importTask
                fixture.captureCurrentTask()
            }
            let observation: AnyCancellable
            switch observerKind {
            case .objectPublisher:
                observation = fixture.owner.objectWillChange.sink { _ in submitNewer() }
            case .typedUpdates:
                observation = fixture.owner.updates.sink { update in
                    if case .importStatus = update { submitNewer() }
                }
            }
            defer { observation.cancel() }
            switch operation {
            case .fileImport:
                fixture.owner.importDocument(from: DocumentsSubmissionFixture.outerURL, as: .cv)
            case .reprocess:
                fixture.owner.reprocessDocument(fixture.original)
            }
            fixture.captureCurrentTask()
            #expect(!armed)
            let newer = try #require(replacementTask,
                "The synchronous newer entry must register its actual extraction worker.")
            #expect(fixture.owner.importID == replacementID,
                "The older submitting stack must not acquire a new identity after its cancellation notification returns.")
            #expect(fixture.owner.importTask == newer,
                "The newer registered Task is the sole active import owner.")
            #expect(!newer.isCancelled)
            #expect(fixture.owner.pendingImportTaskCount == (existingWorker ? 2 : 1))

            // The baseline can make B obsolete before its Task starts. Never
            // await an impossible B entry event; release all controlled I/O,
            // then join every exact public handle captured above.
            fixture.control.openAll()
            for task in fixture.tasks.tasks { await task.value }
            let savedRecord = try fixture.repository.document(type: .cv)
            let saved = try #require(savedRecord)
            #expect(saved.title == "newer")
            #expect(saved.content == fixture.newerMaterial.text)
            let entered = fixture.control.enteredNames
            #expect(entered == (existingWorker ? ["previous.md", "newer.md"] : ["newer.md"]))
            let storedDocuments = try fixture.repository.documents()
            #expect(fixture.owner.documents == storedDocuments)
            #expect(fixture.owner.importStatus.hasPrefix("Imported and indexed"))
            #expect(fixture.owner.pendingImportTaskCount == 0)
            #expect(fixture.owner.importTask == nil)
        }
    }
}

enum DocumentsSubmissionOperation: String, CaseIterable, Sendable { case fileImport, reprocess }
enum DocumentsSubmissionObserver: String, CaseIterable, Sendable { case objectPublisher, typedUpdates }

struct DocumentsSubmissionCase: Sendable {
    let operation: DocumentsSubmissionOperation
    let observer: DocumentsSubmissionObserver
    let existingWorker: Bool
    static let all: [Self] = DocumentsSubmissionOperation.allCases.flatMap { operation in
        DocumentsSubmissionObserver.allCases.flatMap { observer in
            [false, true].map { Self(operation: operation, observer: observer, existingWorker: $0) }
        }
    }
}

@MainActor
private final class DocumentsSubmissionFixture {
    nonisolated static let outerURL = URL(fileURLWithPath: "/HirevaSyntheticDocuments/outer.md")
    nonisolated static let newerURL = URL(fileURLWithPath: "/HirevaSyntheticDocuments/newer.md")
    nonisolated static let previousURL = URL(fileURLWithPath: "/HirevaSyntheticDocuments/previous.md")
    let database: AppDatabase
    let repository: DocumentRepository
    let owner: DocumentsState
    let original: DocumentRecord
    let newerMaterial: ExtractedMaterial
    let control = DocumentsSubmissionControl()
    let tasks = DocumentsSubmissionTaskReceipts()

    init() throws {
        database = try AppDatabase(inMemory: true)
        repository = DocumentRepository(database: database)
        let originalBytes = Data("Synthetic original: I designed an isolated document workflow, reviewed exact source locations, and validated cancellation and persistence with controlled tests.".utf8)
        let originalMaterial = try MaterialExtractionService.extract(data: originalBytes, filename: "outer.md")
        original = try repository.saveDocument(type: .cv, title: "Original", content: originalMaterial.text,
            material: originalMaterial, originalData: originalBytes)
        let newerBytes = Data("Synthetic newer: I built a different bounded document workflow, reviewed precise source references, and verified persistence and resource ownership with controlled fixtures.".utf8)
        let newer = try MaterialExtractionService.extract(data: newerBytes, filename: "newer.md")
        newerMaterial = newer
        let previousBytes = Data("Synthetic previous: this independent test source describes an older pending extraction and authorizes no real user material, cloud call, or uncontrolled native resource.".utf8)
        let previous = try MaterialExtractionService.extract(data: previousBytes, filename: "previous.md")
        let control = self.control
        owner = DocumentsState(repository: repository,
            extractURL: { url in
                await control.wait(url.lastPathComponent)
                switch url.lastPathComponent {
                case "newer.md": return (newer, newerBytes)
                case "previous.md": return (previous, previousBytes)
                default: return (originalMaterial, originalBytes)
                }
            }, extractData: { _, filename in
                await control.wait(filename)
                return originalMaterial
            })
        try owner.reload()
    }

    func captureCurrentTask() {
        if let task = owner.importTask { tasks.append(task) }
    }

    func run(_ body: () async throws -> Void) async throws {
        do {
            try await withTaskCancellationHandler {
                try await body()
            } onCancel: { [control, tasks] in
                control.openAll()
                tasks.cancelAll()
            }
            try await close()
        } catch {
            try? await close()
            throw error
        }
    }

    private func close() async throws {
        captureCurrentTask()
        owner.closeAdmission()
        control.openAll()
        tasks.cancelAll()
        for task in tasks.tasks { await task.value }
        await owner.shutdown()
        try database.close()
    }
}

/// All I/O is synthetic; it can ignore cancellation only until the owning
/// fixture opens this checked gate on success, error, or parent cancellation.
private final class DocumentsSubmissionControl: Sendable {
    private struct State: Sendable {
        var opened = false
        var enteredNames: [String] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entries = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private let trace = TestEventWaitTrace(label: "documents_cancel_submission_entry")
    var enteredNames: [String] { state.withLock { $0.enteredNames } }

    func wait(_ name: String) async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                value.enteredNames.append(name)
                if value.opened { return true }
                value.waiting.append(continuation)
                return false
            }
            entries.continuation.yield(name)
            if resume { continuation.resume() }
        }
    }

    func waitUntilEntered(_ name: String) async throws {
        while !enteredNames.contains(name) {
            _ = try await trace.nextEvent(in: entries.stream, event: name)
        }
    }

    func openAll() {
        let waiting = state.withLock { value in
            value.opened = true
            let pending = value.waiting
            value.waiting.removeAll()
            return pending
        }
        waiting.forEach { $0.resume() }
        entries.continuation.finish()
    }
}

/// Captured immutable public Task receipts guarantee baseline cleanup. They
/// neither replace the feature's owner nor synthesize its import identities.
private final class DocumentsSubmissionTaskReceipts: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    var tasks: [Task<Void, Never>] { values.withLock { $0 } }
    func append(_ task: Task<Void, Never>) {
        values.withLock { if !$0.contains(task) { $0.append(task) } }
    }
    func cancelAll() { tasks.forEach { $0.cancel() } }
}
