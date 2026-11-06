import Combine
import Foundation
import os
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PreparationPublisherEntryTests {
    @Test(arguments: PreparationPublicationOperation.allCases)
    func closeFromSynchronousRequestNotificationCannotRegisterNewWorkAfterShutdown(
        operation: PreparationPublicationOperation
    ) async throws {
        let fixture = try PreparationPublicationFixture()
        try await fixture.run {
            var armed = true
            let observer = fixture.state.objectWillChange.sink { _ in
                guard armed else { return }
                armed = false
                fixture.state.closeAdmission()
            }
            defer { observer.cancel() }
            armed = false
            switch operation {
            case .page: fixture.state.url = "synthetic-closed"
            case .sql: fixture.state.query = "synthetic-closed"
            }
            armed = true
            switch operation {
            case .page: fixture.state.fetch()
            case .sql: fixture.state.runSQL()
            }
            #expect(!armed)
            #expect(!fixture.state.busy,
                "A synchronous close must not be overwritten by the submitting request's later busy setter.")
            fixture.control.openAll()
            await fixture.state.shutdown()
            #expect(fixture.control.enteredNames.isEmpty,
                "The actual backend closure must never run for an operation invalidated during its submission notification.")
            #expect(fixture.state.pendingTaskCount == 0)
            #expect(fixture.state.brief == nil)
            #expect(fixture.state.sql == nil)
            let savedRecords = try fixture.repository.records()
            #expect(savedRecords.isEmpty)
        }
    }

    @Test(arguments: PreparationPublicationOperation.allCases, [false, true])
    func cancelFromSynchronousResultNotificationPrecedesPersistenceAdmission(
        operation: PreparationPublicationOperation, closeAdmission: Bool
    ) async throws {
        let fixture = try PreparationPublicationFixture()
        try await fixture.run {
            let submitted = "synthetic-result"
            var observedResult = ""
            var armed = true
            let observer = fixture.state.objectWillChange.sink { _ in
                guard armed, let value = operation.resultText(fixture.state) else { return }
                armed = false
                observedResult = value
                if closeAdmission { fixture.state.closeAdmission() }
                else { fixture.state.cancel() }
            }
            defer { observer.cancel() }
            operation.submit(fixture.state, text: submitted)
            try await fixture.control.waitUntilEntered(submitted)
            fixture.control.openAll()
            await fixture.state.finishPendingWork()
            #expect(!armed)
            #expect(observedResult == submitted)
            #expect(operation.resultText(fixture.state) == submitted,
                "A cancelled save can retain the already-delivered temporary result.")
            let savedRecords = try fixture.repository.records()
            #expect(savedRecords.isEmpty,
                "The result observer revoked this exact request before it could save; a valid privacy ticket alone is insufficient.")
            #expect(fixture.state.records.isEmpty)
            #expect(!fixture.state.busy)
            #expect(fixture.state.pendingTaskCount == 0)
            #expect(fixture.control.enteredNames == [submitted])
        }
    }

    #if DEBUG
    @Test(arguments: PreparationPublicationOperation.allCases)
    func replacementDuringSubmissionRetainsBothOriginalTasksWithDistinctIdentities(
        operation: PreparationPublicationOperation
    ) async throws {
        let fixture = try PreparationPublicationFixture()
        try await fixture.run {
            fixture.state.workerRegisteredForTesting = { [registered = fixture.registered] id, task in
                registered.append(id, task)
            }
            var armed = true
            let observer = fixture.state.objectWillChange.sink { _ in
                guard armed else { return }
                armed = false
                operation.submit(fixture.state, text: "synthetic-newer-request")
                // Mutating input after the newer submission cannot authorize
                // the outer, older call to take another input snapshot.
                switch operation {
                case .page: fixture.state.url = "synthetic-outer-resumed"
                case .sql: fixture.state.query = "synthetic-outer-resumed"
                }
            }
            defer { observer.cancel() }
            // Input publication is not a request publication; arm only after
            // setting the input so the nested request runs inside fetch/runSQL.
            armed = false
            switch operation {
            case .page: fixture.state.url = "synthetic-original"
            case .sql: fixture.state.query = "synthetic-original"
            }
            armed = true
            switch operation {
            case .page: fixture.state.fetch()
            case .sql: fixture.state.runSQL()
            }
            #expect(!armed)
            #expect(fixture.registered.tasks.count == 2)
            #expect(Set(fixture.registered.tasks.map { $0.0 }).count == 2,
                "Each actual submission needs its own immutable operation identity.")
            #expect(fixture.state.pendingTaskCount == 2,
                "The older registered request and the newer request are both owned until actual exit.")
            try await fixture.control.waitUntilEntered("synthetic-newer-request")
            fixture.state.closeAdmission()
            fixture.control.openAll()
            fixture.registered.cancelAll()
            await fixture.state.shutdown()
            for (_, task) in fixture.registered.tasks { await task.value }
            #expect(fixture.state.pendingTaskCount == 0)
            #expect(fixture.state.brief == nil && fixture.state.sql == nil)
            let savedRecords = try fixture.repository.records()
            #expect(savedRecords.isEmpty)
        }
    }
    #endif
}

enum PreparationPublicationOperation: String, CaseIterable, Sendable {
    case page, sql
    @MainActor
    func submit(_ state: PreparationState, text: String) {
        switch self {
        case .page: state.url = text; state.fetch()
        case .sql: state.query = text; state.runSQL()
        }
    }
    @MainActor
    func resultText(_ state: PreparationState) -> String? {
        switch self {
        case .page: return state.brief?.title
        case .sql: return state.sql?.query
        }
    }
}

@MainActor
private final class PreparationPublicationFixture {
    let database: AppDatabase
    let repository: PreparationRepository
    let state: PreparationState
    let control = PreparationPublicationControl()
    let registered = PreparationWorkerJournal()

    init() throws {
        database = try AppDatabase(inMemory: true)
        repository = PreparationRepository(database: database)
        let consent = PersistenceConsent()
        consent.update(enabled: true)
        let control = self.control
        state = PreparationState(repository: repository, consent: consent,
            historyEnabled: { true }, fetch: { name in
                await control.wait(name)
                return PublicRoleBrief(url: "https://synthetic.example/role", fetchedAt: Date(),
                    sha256: "synthetic", title: name,
                    excerpts: [.init(location: "synthetic-source", text: "Synthetic source only.")],
                    snapshot: "synthetic")
            }, runSQL: { query in
                await control.wait(query)
                return SQLPracticeResult(query: query, columns: [], rows: [], elapsedMS: 0,
                    truncated: false, error: nil, executed: false)
            })
    }

    func run(_ body: () async throws -> Void) async throws {
        do {
            try await withTaskCancellationHandler {
                try await body()
            } onCancel: { [control, registered] in
                control.openAll()
                registered.cancelAll()
            }
            try await close()
        } catch {
            try? await close()
            throw error
        }
    }

    private func close() async throws {
        control.openAll()
        registered.cancelAll()
        await state.shutdown()
        for (_, task) in registered.tasks { await task.value }
        try database.close()
    }
}

/// Synthetic I/O deliberately ignores task cancellation until its checked gate
/// is opened by the owning test. Every parent-cancellation/error path opens it.
private final class PreparationPublicationControl: Sendable {
    private struct State: Sendable {
        var opened = false
        var enteredNames: [String] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entries = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private let trace = TestEventWaitTrace(label: "preparation_publication_backend_entry")
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

/// Test receipts, not a second production owner: capture the original Task even
/// when the instrumented baseline overwrites its current worker registration.
private final class PreparationWorkerJournal: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [(UUID, Task<Void, Never>)]())
    var tasks: [(UUID, Task<Void, Never>)] { values.withLock { $0 } }
    func append(_ id: UUID, _ task: Task<Void, Never>) { values.withLock { $0.append((id, task)) } }
    func cancelAll() { tasks.forEach { $0.1.cancel() } }
}
