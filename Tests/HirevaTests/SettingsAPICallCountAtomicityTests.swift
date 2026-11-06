import Dispatch
import Foundation
import GRDB
import Testing
import os
@testable import Hireva

struct SettingsAPICallCountAtomicityTests {
    @Test(.timeLimit(.minutes(1)))
    func admittedConcurrentIncrementsEachReceiveAndPersistTheirOwnValue() async throws {
        for _ in 0..<10 {
            let database = try AppDatabase(inMemory: true)
            let repository = SettingsRepository(database: database)
            let gate = APICountWriteAdmissionGate()
            do {
                #expect(try repository.apiCallCount() == 0)
                gate.start(repository: repository)
                // Two real repository operations reach their write-admission
                // boundary before either is released; no counter logic is copied.
                try await gate.waitForBothAdmissions()
                #expect(gate.enteredCount == 2)
                gate.releaseBoth()
                await gate.join()
                #expect(!gate.hitSafetyDeadline)
                #expect(gate.results.count == 2)
                let values = gate.results.compactMap { try? $0.get() }.sorted()
                #expect(values == [1, 2])
                #expect(try repository.apiCallCount() == 2)
                try database.close()
            } catch {
                gate.releaseBoth()
                await gate.join()
                try? database.close()
                throw error
            }
        }
    }

    @Test
    func defaultCounterAndMalformedLegacyValueKeepExistingCompatibility() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let repository = SettingsRepository(database: database)
        #expect(try repository.apiCallCount() == 0)
        #expect(try repository.incrementAPICallCount() == 1)
        #expect(try repository.incrementAPICallCount() == 2)
        #expect(try repository.apiCallCount() == 2)
        try database.dbQueue.write { db in
            try db.execute(sql: "UPDATE app_settings SET value = ? WHERE key = ?",
                arguments: ["synthetic-malformed-legacy-value", "api_call_count"])
        }
        #expect(try repository.apiCallCount() == 0)
        #expect(try repository.incrementAPICallCount() == 1)
        #expect(try repository.apiCallCount() == 1)
    }
}

private struct APICountWorkerFailure: Error, Sendable { let description: String }

private final class APICountWriteAdmissionGate: Sendable {
    private struct State: Sendable {
        var enteredCount = 0
        var released = false
        var hitSafetyDeadline = false
        var results: [Result<Int, APICountWorkerFailure>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let release = DispatchSemaphore(value: 0)
    private let group = DispatchGroup()
    private let queues = [DispatchQueue(label: "synthetic.api-count.first"),
                          DispatchQueue(label: "synthetic.api-count.second")]
    private let admissions: AsyncStream<Void>
    private let admissionContinuation: AsyncStream<Void>.Continuation
    private let trace = TestEventWaitTrace(label: "apiCount.atomicity")

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
        admissions = pair.stream
        admissionContinuation = pair.continuation
    }
    var enteredCount: Int { state.withLock { $0.enteredCount } }
    var hitSafetyDeadline: Bool { state.withLock { $0.hitSafetyDeadline } }
    var results: [Result<Int, APICountWorkerFailure>] { state.withLock { $0.results } }

    func start(repository: SettingsRepository) {
        for queue in queues {
            group.enter()
            queue.async {
                defer { self.group.leave() }
                let result: Result<Int, APICountWorkerFailure>
                do {
                    result = .success(try repository.incrementAPICallCount(beforeWriteAdmission: {
                        self.admitAndWait()
                    }))
                } catch { result = .failure(.init(description: error.localizedDescription)) }
                self.state.withLock { $0.results.append(result) }
            }
        }
    }

    private func admitAndWait() {
        state.withLock { $0.enteredCount += 1 }
        admissionContinuation.yield(())
        // Dedicated synchronous queue workers have an explicit release and a
        // fixture-only safety bound. No ordinary lock covers the wait or SQL.
        if release.wait(timeout: .now() + 30) == .timedOut {
            state.withLock { $0.hitSafetyDeadline = true }
        }
    }

    func waitForBothAdmissions() async throws {
        var iterator = admissions.makeAsyncIterator()
        for _ in 0..<2 {
            try Task.checkCancellation()
            guard await iterator.next() != nil else { throw TestEventWaitFailure.endedBeforeEvent }
            try Task.checkCancellation()
        }
        trace.mark("two.actual.write.admissions")
    }
    func releaseBoth() {
        let first = state.withLock { state in
            guard !state.released else { return false }
            state.released = true
            return true
        }
        guard first else { return }
        release.signal()
        release.signal()
        admissionContinuation.finish()
    }
    func join() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
}
