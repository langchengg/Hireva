import Foundation
import Testing
import Combine
@testable import Hireva

@MainActor
struct DiagnosticsLatencyLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func shutdownCancelsAndJoinsActualLatencyRefreshBeforeReturning() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        let gate = LatencyQueryGate()
        let events = AsyncStream<LatencyQueryEvent>.makeStream()
        let trace = TestEventWaitTrace(label: "actual-latency-shutdown")
        app.latencyQueryOverride = {
            events.continuation.yield(.queryEntered)
            return await withTaskCancellationHandler {
                await gate.wait()
                return (.empty, .empty)
            } onCancel: { events.continuation.yield(.queryCancelled) }
        }
        var work: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        do {
            work = app.refreshLatencyAverages()
            #expect(work != nil)
            #expect(try await trace.nextEvent(in: events.stream, event: "query.start") == .queryEntered)
            shutdown = Task {
                let result = await app.shutdownResources()
                events.continuation.yield(.shutdownReturned)
                return result
            }
            let first = try await trace.nextEvent(in: events.stream, event: "query.cancel.or.shutdown")
            #expect(first == .queryCancelled,
                "Shutdown must retain the real query until its cancellation and eventual exit; no detached query may outlive cleanup.")
            await gate.release()
            await work?.value
            #expect(await shutdown?.value == true)
            let lateWork = app.refreshLatencyAverages()
            #expect(lateWork == nil,
                "Permanent shutdown rejects new statistics work.")
            lateWork?.cancel()
            await lateWork?.value
            events.continuation.finish()
            try database.close()
        } catch {
            await gate.release()
            work?.cancel(); shutdown?.cancel()
            await work?.value
            _ = await shutdown?.value
            _ = await app.shutdownResources()
            events.continuation.finish()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<4))
    func replacementRejectsOldSuccessAndErrorAcrossTwentyFixedInterleavings(group: Int) async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = SuggestionRepository(database: database)
        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Synthetic latency")
        try repository.saveSuggestionCard(SuggestionCard(id: UUID().uuidString, sessionID: session.id,
            strategy: "Synthetic", sayFirst: "Synthetic answer", keyPoints: [], followUpReady: [],
            evidenceUsed: [], modelName: "synthetic", promptVersion: "test", providerName: "DeepSeek", createdAt: Date()))
        let accepted = try await repository.makeLatencyQuery()()
        #expect(accepted.overall.count == 1)
        let owner = DiagnosticsState(traceLogURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva-unused-latency-\(UUID().uuidString).jsonl"))
        var statuses: [String] = []
        var publications = 0
        let subscription = owner.$latencyAverages.dropFirst().sink { _ in publications += 1 }
        // Four owned five-round sequences preserve all twenty logical orders.
        // Publication/status counts remain cumulative within each sequence;
        // this replaces the former single twenty-round owner lifetime.
        for round in 0..<5 {
            let order = group * 5 + round
            let gate = LatencyQueryGate()
            let events = AsyncStream<LatencyQueryEvent>.makeStream()
            let trace = TestEventWaitTrace(label: "latency-replacement-\(order)")
            owner.latencyQueryOverride = {
                events.continuation.yield(.queryEntered)
                await gate.wait() // Deliberately non-cooperative but always releasable.
                if order % 2 == 0 { throw LatencySyntheticError.failed }
                return (.empty, .empty)
            }
            let old = owner.refreshLatencyAverages { statuses.append($0) }
            var replacement: Task<Void, Never>?
            do {
                #expect(old != nil)
                #expect(try await trace.nextEvent(in: events.stream, event: "old.entered") == .queryEntered)
                owner.latencyQueryOverride = { accepted }
                replacement = owner.refreshLatencyAverages { statuses.append($0) }
                #expect(replacement != nil)
                if order % 4 < 2 { await gate.release(); await old?.value }
                await replacement?.value
                await gate.release(); await old?.value
                #expect(owner.latencyAveragesOverall.count == 1)
                #expect(owner.latencyAveragesDeepSeek.count == 1)
                #expect(owner.pendingLatencyTaskCount == 0)
                #expect(statuses.count == round + 1)
                #expect(statuses.last == "Refreshed latency averages")
                #expect(publications == round + 1)
                events.continuation.finish()
            } catch {
                await gate.release(); old?.cancel(); replacement?.cancel()
                await old?.value; await replacement?.value
                await owner.shutdown()
                events.continuation.finish(); try? database.close()
                throw error
            }
        }
        await owner.shutdown()
        withExtendedLifetime(subscription) {}
        try database.close()
    }

    @Test
    func asyncRepositoryQueryKeepsProviderProjectionAndLegacyLatencyFallback() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let repository = SuggestionRepository(database: database)
        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Synthetic metrics")
        for (provider, latency, status) in [("DeepSeek", 120, "completed"),
            ("Synthetic local", 240, "timed_out"), ("DeepSeek", 900, "needs_personal_evidence")] {
            var card = SuggestionCard(id: UUID().uuidString, sessionID: session.id,
                strategy: "Synthetic", sayFirst: "Synthetic answer", keyPoints: [], followUpReady: [],
                evidenceUsed: [], modelName: "synthetic", promptVersion: "test", providerName: provider, createdAt: Date())
            card.latencyFirstVisibleMS = latency
            card.latencyFullCardMS = latency * 2
            card.stageBStatus = status
            try repository.saveSuggestionCard(card)
        }
        let pair = try await repository.makeLatencyQuery()()
        #expect(pair.overall.count == 2)
        #expect(pair.overall.avgFirstVisibleMS == 180)
        #expect(pair.overall.avgFullCardMS == 360)
        #expect(pair.overall.failureRate == 0.5)
        #expect(pair.deepSeek.count == 1)
        #expect(pair.deepSeek.avgFirstVisibleMS == 120)
        #expect(pair.deepSeek.failureRate == 0)
        let syncOverall = try repository.fetchLatencyAverages()
        let syncDeepSeek = try repository.fetchLatencyAverages(provider: "DeepSeek")
        #expect(pair.overall.p50FirstVisibleMS == syncOverall.p50FirstVisibleMS)
        #expect(pair.deepSeek.p90FullCardMS == syncDeepSeek.p90FullCardMS)
    }

}

private enum LatencyQueryEvent: Sendable { case queryEntered, queryCancelled, shutdownReturned }
private actor LatencyQueryGate {
    private var open = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { pending.append($0) } } }
    func release() {
        open = true
        let owned = pending; pending.removeAll()
        owned.forEach { $0.resume() }
    }
}

private enum LatencySyntheticError: Error { case failed }
