import Foundation
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PreparationStateTests {
    @Test
    func replacementRejectsLatePageAndRetainsBothOperationsUntilExit() async throws {
        let fixture = try Fixture()
        do {
            fixture.state.url = "synthetic-first"
            fixture.state.fetch()
            try await fixture.gate.waitUntilEntered("synthetic-first")
            fixture.state.url = "synthetic-second"
            fixture.state.fetch()
            try await fixture.gate.waitUntilEntered("synthetic-second")
            #expect(fixture.state.pendingTaskCount == 2)
            await fixture.gate.release("synthetic-second")
            await fixture.gate.release("synthetic-first")
            await fixture.state.finishPendingWork()
            #expect(fixture.state.brief?.title == "synthetic-second")
            #expect(fixture.state.pendingTaskCount == 0)
            #expect(!fixture.state.busy)
            let records = try fixture.repository.records()
            #expect(records.count == 1)
            let result = try JSONDecoder().decode(PublicRoleBrief.self, from: try #require(records.first).payload)
            #expect(result.title == "synthetic-second")
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func shutdownCancelsJoinsAndPermanentlyClosesAdmission() async throws {
        let fixture = try Fixture()
        do {
            fixture.state.url = "synthetic-held"
            fixture.state.fetch()
            try await fixture.gate.waitUntilEntered("synthetic-held")
            fixture.state.closeAdmission()
            #expect(fixture.state.pendingTaskCount == 1)
            fixture.state.url = "must-not-start"
            fixture.state.fetch()
            #expect(fixture.state.pendingTaskCount == 1)
            await fixture.gate.releaseAll()
            await fixture.state.shutdown()
            #expect(fixture.state.pendingTaskCount == 0)
            #expect(fixture.state.brief == nil)
            #expect(try fixture.repository.records().isEmpty)
            #expect(await fixture.gate.enteredNames() == ["synthetic-held"])
            await fixture.state.shutdown()
            try fixture.database.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func revokedTicketCannotReviveAfterOffOnButNextResultCanSave() async throws {
        let fixture = try Fixture()
        do {
            fixture.state.url = "synthetic-old-ticket"
            fixture.state.fetch()
            try await fixture.gate.waitUntilEntered("synthetic-old-ticket")
            fixture.consent.update(enabled: false)
            fixture.consent.update(enabled: true)
            await fixture.gate.release("synthetic-old-ticket")
            await fixture.state.finishPendingWork()
            #expect(fixture.state.brief?.title == "synthetic-old-ticket")
            #expect(try fixture.repository.records().isEmpty)
            #expect(fixture.state.error.isEmpty)
            fixture.state.url = "synthetic-new-ticket"
            fixture.state.fetch()
            try await fixture.gate.waitUntilEntered("synthetic-new-ticket")
            await fixture.gate.release("synthetic-new-ticket")
            await fixture.state.finishPendingWork()
            #expect(try fixture.repository.records().count == 1)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func sqlUsesFrozenQueryAndTemporaryResultDoesNotPersist() async throws {
        let fixture = try Fixture(save: false)
        do {
            fixture.state.query = "SELECT COUNT(*) AS total FROM customers;"
            fixture.state.runSQL()
            try await fixture.gate.waitUntilEntered("sql")
            fixture.state.query = "DROP TABLE customers;"
            await fixture.gate.release("sql")
            await fixture.state.finishPendingWork()
            #expect(fixture.state.sql?.query == "SELECT COUNT(*) AS total FROM customers;")
            #expect(fixture.state.sql?.executed == true)
            #expect(fixture.state.sql?.rows == [["3"]])
            #expect(try fixture.repository.records().isEmpty)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @MainActor
    private struct Fixture {
        let database: AppDatabase
        let repository: PreparationRepository
        let consent: PersistenceConsent
        let state: PreparationState
        let gate: PreparationGate
        init(save: Bool = true) throws {
            database = try AppDatabase(inMemory: true)
            repository = PreparationRepository(database: database)
            consent = PersistenceConsent()
            consent.update(enabled: save)
            let gate = PreparationGate()
            self.gate = gate
            state = PreparationState(repository: repository, consent: consent,
                historyEnabled: { save }, fetch: { name in
                    await gate.wait(name)
                    return PublicRoleBrief(url: "https://synthetic.example/role", fetchedAt: Date(),
                        sha256: "synthetic", title: name,
                        excerpts: [.init(location: "synthetic-source", text: "Synthetic source only.")],
                        snapshot: "synthetic")
                }, runSQL: { query in
                    await gate.wait("sql")
                    return PracticeSQLService.run(query)
                })
        }
        func close() async throws {
            await gate.releaseAll()
            await state.shutdown()
            try database.close()
        }
    }
}

/// Noncooperative work is always explicitly released before fixture teardown.
private actor PreparationGate {
    private var entered = Set<String>()
    private var released = Set<String>()
    private var releaseEverything = false
    private var work: [String: CheckedContinuation<Void, Never>] = [:]
    private var observers: [String: AsyncStream<Void>.Continuation] = [:]
    func wait(_ name: String) async {
        entered.insert(name)
        if let observer = observers.removeValue(forKey: name) { observer.yield(()); observer.finish() }
        guard !releaseEverything, !released.contains(name) else { return }
        await withCheckedContinuation { work[name] = $0 }
    }
    func waitUntilEntered(_ name: String) async throws {
        if entered.contains(name) { return }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[name] = pair.continuation
        defer { observers.removeValue(forKey: name)?.finish() }
        for await _ in pair.stream {
            try Task.checkCancellation()
            if entered.contains(name) { return }
        }
        throw CancellationError()
    }
    func release(_ name: String) {
        released.insert(name)
        work.removeValue(forKey: name)?.resume()
    }
    func releaseAll() {
        releaseEverything = true
        let pending = Array(work.values); work.removeAll()
        pending.forEach { $0.resume() }
        let observing = Array(observers.values); observers.removeAll()
        observing.forEach { $0.finish() }
    }
    func enteredNames() -> Set<String> { entered }
}
