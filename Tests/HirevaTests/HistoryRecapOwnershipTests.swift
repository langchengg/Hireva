import Combine
import Foundation
import Testing
@testable import Hireva

/// Requires the new HistoryState lifecycle API. These are characterizations,
/// not claims of baseline RED execution. Every held fixture is always released.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HistoryRecapOwnershipTests {
    enum Order: CaseIterable, Equatable { case oldExitFirst, newExitFirst, stopBoth, privacyOffOn }

    @Test(arguments: Order.allCases, 0..<5)
    func actualCorrectionAndNewRecapKeepCancelledRootsOwned(order: Order, iteration: Int) async throws {
        // Four specified orders, five repetitions each: 20 controlled cases.
        // Repetition adds scheduling coverage, not a proof of all interleavings.
        let trace = TestEventWaitTrace(label: "recap.ownership.\(order).iteration.\(iteration)")
        trace.mark("iteration.begin")
        trace.mark("fixture.create.requested")
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        trace.mark("fixture.create.completed")
        let nextGate = RecapEntryGate()
        let nextProvider = RecapEntryLocalProvider(id: "next-recap-provider", gate: nextGate, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        func cleanup() async throws {
            trace.mark("cleanup.release.requested")
            nextGate.releaseAll()
            fixture.routingGate.releaseAll()
            trace.mark("cleanup.release.completed")
            try await fixture.close(roots, trace: trace)
            trace.mark("cleanup.completed")
        }
        do {
            trace.mark("old.submit.requested")
            fixture.app.generateRecap(for: fixture.session)
            let old = try #require(fixture.app.recapTask)
            trace.mark("old.submit.completed")
            roots.append(old)
            trace.mark("old.provider-entry.wait.requested")
            try await fixture.routingGate.waitUntilEntered()
            trace.mark("old.provider-entry.wait.completed")
            trace.mark("correction.requested")
            fixture.app.saveTranscriptCorrection(fixture.answer,
                text: "Atomicity rolls back all operations on failure.",
                speaker: .candidate, startsQuestion: false, question: "")
            trace.mark("correction.completed")
            #expect(old.isCancelled)
            #expect(fixture.app.historyState.retiringRecapTaskCount == 1)
            #expect(fixture.app.historyState.pendingRecapTaskCount == 1)
            fixture.app.localLLMProviderOverride = nextProvider
            trace.mark("next.submit.requested")
            fixture.app.generateRecap(for: fixture.session)
            let next = try #require(fixture.app.recapTask)
            trace.mark("next.submit.completed")
            roots.append(next)
            trace.mark("next.provider-entry.wait.requested")
            try await nextGate.waitUntilEntered()
            trace.mark("next.provider-entry.wait.completed")
            #expect(fixture.app.historyState.pendingRecapTaskCount == 2)

            switch order {
            case .oldExitFirst:
                trace.mark("old.release.requested")
                fixture.routingGate.releaseAll()
                trace.mark("old.release.completed")
                trace.mark("old.join.requested")
                try await fixture.join(old)
                trace.mark("old.join.completed")
                #expect(fixture.app.historyState.retiringRecapTaskCount == 0)
                #expect(fixture.app.historyState.pendingRecapTaskCount == 1)
                #expect(fixture.app.recapTask != nil && !next.isCancelled)
                #expect(fixture.app.isGeneratingRecap)
                trace.mark("next.release.requested")
                nextGate.releaseAll()
                trace.mark("next.release.completed")
                trace.mark("next.join.requested")
                try await fixture.join(next)
                trace.mark("next.join.completed")
            case .newExitFirst:
                trace.mark("next.release.requested")
                nextGate.releaseAll()
                trace.mark("next.release.completed")
                trace.mark("next.join.requested")
                try await fixture.join(next)
                trace.mark("next.join.completed")
                #expect(fixture.app.historyState.pendingRecapTaskCount == 1)
                #expect(fixture.app.historyState.retiringRecapTaskCount == 1)
                #expect(fixture.app.recapTask == nil && !fixture.app.isGeneratingRecap)
                trace.mark("old.release.requested")
                fixture.routingGate.releaseAll()
                trace.mark("old.release.completed")
                trace.mark("old.join.requested")
                try await fixture.join(old)
                trace.mark("old.join.completed")
            case .stopBoth:
                fixture.app.pausePreparationForLive()
                #expect(next.isCancelled)
                #expect(fixture.app.historyState.retiringRecapTaskCount == 2)
                trace.mark("old.release.requested")
                fixture.routingGate.releaseAll()
                trace.mark("old.release.completed")
                trace.mark("next.release.requested")
                nextGate.releaseAll()
                trace.mark("next.release.completed")
                trace.mark("old.join.requested")
                try await fixture.join(old)
                trace.mark("old.join.completed")
                trace.mark("next.join.requested")
                try await fixture.join(next)
                trace.mark("next.join.completed")
            case .privacyOffOn:
                var settings = fixture.app.settings
                settings.saveTranscriptsLocally = false
                fixture.app.saveSettings(settings)
                settings.saveTranscriptsLocally = true
                fixture.app.saveSettings(settings)
                #expect(next.isCancelled)
                #expect(fixture.app.historyState.retiringRecapTaskCount == 2)
                trace.mark("old.release.requested")
                fixture.routingGate.releaseAll()
                trace.mark("old.release.completed")
                trace.mark("next.release.requested")
                nextGate.releaseAll()
                trace.mark("next.release.completed")
                trace.mark("old.join.requested")
                try await fixture.join(old)
                trace.mark("old.join.completed")
                trace.mark("next.join.requested")
                try await fixture.join(next)
                trace.mark("next.join.completed")
            }
            let reports = try fixture.app.recapRepository.versions(sessionID: fixture.session.id)
            if order == .oldExitFirst || order == .newExitFirst {
                #expect(reports.count == 1)
                #expect(reports.first?.contentRevision == 1)
                #expect(reports.first?.markdown.contains("rolls back all operations") == true)
                var displayed = try #require(fixture.app.selectedSessionRecap)
                // RecapRepository uses DateCoding, rather than GRDB's Date
                // codec. Normalize only this field through that same codec.
                displayed.createdAt = DateCoding.date(from: DateCoding.string(from: displayed.createdAt))
                #expect(displayed == reports.first)
            } else {
                #expect(reports.isEmpty)
                #expect(fixture.app.selectedSessionRecap == nil)
            }
            #expect(fixture.app.historyState.pendingRecapTaskCount == 0)
            #expect(!fixture.app.isGeneratingRecap)
            try await cleanup()
            trace.mark("iteration.completed")
        } catch {
            trace.mark("iteration.catch")
            try? await cleanup()
            throw error
        }
    }

    @Test
    func shutdownDeadlineDoesNotDiscardAnUncooperativeRoot() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        let clock = ControlledGenerationWatchdogClock()
        var roots: [Task<Void, Never>] = []
        var shutdown: Task<Bool, Never>?
        func cleanup() async throws {
            fixture.routingGate.releaseAll()
            clock.cancelAll()
            _ = await shutdown?.value
            try await fixture.close(roots)
        }
        do {
            fixture.app.generateRecap(for: fixture.session)
            let root = try #require(fixture.app.recapTask)
            roots.append(root)
            try await fixture.routingGate.waitUntilEntered()
            let owner = fixture.app.historyState
            let stopping = Task { await owner.shutdownAndDrain(timeout: 2, delayProvider: clock) }
            shutdown = stopping
            try await clock.waitUntilPending(nanoseconds: 2_000_000_000)
            #expect(root.isCancelled)
            #expect(owner.pendingRecapTaskCount == 1)
            clock.advance(by: 2_000_000_000)
            #expect(await stopping.value == false)
            #expect(owner.retiringRecapTaskCount == 1)
            #expect(owner.pendingRecapTaskCount == 1)
            fixture.routingGate.releaseAll()
            try await fixture.join(root)
            await owner.drainRetiredRecaps()
            #expect(owner.pendingRecapTaskCount == 0)
            fixture.app.generateRecap(for: fixture.session)
            #expect(fixture.app.recapTask == nil)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }

    @Test
    func directHistoryObservationSeesTheSameDerivedRecapLifecycle() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        var observed: [Bool] = []
        let history = fixture.app.historyState
        let observer = history.objectWillChange.sink { observed.append(history.isGeneratingRecap) }
        defer { observer.cancel() }
        do {
            fixture.app.generateRecap(for: fixture.session)
            let root = try #require(fixture.app.recapTask)
            roots.append(root)
            try await fixture.routingGate.waitUntilEntered()
            #expect(fixture.app.isGeneratingRecap && history.isGeneratingRecap)
            #expect(observed.contains(true))
            fixture.routingGate.releaseAll()
            try await fixture.join(root)
            #expect(!fixture.app.isGeneratingRecap && !history.isGeneratingRecap)
            #expect(observed.last == false)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }
}
