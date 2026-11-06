import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationDeadlineOwnershipTests {
    enum EndState: CaseIterable, Equatable { case terminal, identityReplacement, roleReplacement, shutdown }

    @Test(.timeLimit(.minutes(1)), arguments: EndState.allCases)
    func lateClockReturnCannotPublishOutsideItsOwnedDeadline(state: EndState) async throws {
        let coordinator = GenerationCoordinator()
        let clock = OwnedDeadlineClock()
        let replacementClock = OwnedDeadlineClock()
        let publications = DeadlinePublications()
        let identity = makeIdentity(context: "synthetic-original-context")
        coordinator.activate(identity: identity, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        var tasks: [Task<Void, Never>] = []
        do {
            let requested = coordinator.launchDeadline(identity: identity, role: .fallbackWatchdog,
                nanoseconds: 1_500_000_000, delayProvider: clock) { identity, role in
                    publications.values.append((identity, role))
                }
            let task = try #require(requested)
            tasks.append(task)
            try await clock.waitUntilStarted()
            switch state {
            case .terminal:
                coordinator.markTerminal(generationID: identity.generationID)
                #expect(task.isCancelled)
                #expect(coordinator.fallbackWatchdogTask == nil)
                #expect(!coordinator.canPublish(identity))
                // The held clock ignores cancellation; the owner must retain it until exit.
                #expect(coordinator.pendingCleanupTaskCount == 1)
            case .identityReplacement:
                // A generation-ID check alone passes; the frozen context must not.
                let replacement = makeIdentity(context: "synthetic-new-context")
                coordinator.activate(identity: replacement, persistenceTicket: 2, triggerPath: .manualGenerate, startedAt: Date())
                #expect(coordinator.isCurrent(identity.generationID))
                #expect(!coordinator.canPublish(identity))
                #expect(task.isCancelled)
            case .roleReplacement:
                let next = coordinator.launchDeadline(identity: identity, role: .fallbackWatchdog,
                    nanoseconds: 1_500_000_000, delayProvider: replacementClock) { identity, role in
                        publications.values.append((identity, role))
                    }
                let replacement = try #require(next)
                tasks.append(replacement)
                try await replacementClock.waitUntilStarted()
                #expect(task.isCancelled)
                #expect(!replacement.isCancelled)
            case .shutdown:
                coordinator.closeAdmission()
                #expect(task.isCancelled)
                #expect(coordinator.launchDeadline(identity: identity, role: .fullCardWatchdog,
                    nanoseconds: 1, delayProvider: replacementClock, onDeadline: { _, _ in
                        Issue.record("Closed admission created a new deadline")
                    }) == nil)
            }
            await clock.release()
            await task.value
            #expect(publications.values.isEmpty)
            if state == .roleReplacement {
                await replacementClock.release()
                await tasks.last?.value
                #expect(publications.values.count == 1)
                #expect(publications.values.first?.0 == identity)
                #expect(publications.values.first?.1 == .fallbackWatchdog)
            }
            await close(coordinator, clocks: [clock, replacementClock], tasks: tasks)
            #expect(coordinator.pendingCleanupTaskCount == 0)
        } catch {
            await close(coordinator, clocks: [clock, replacementClock], tasks: tasks)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulDeadlineFiresOnceAndRetiresThroughTheExistingOwner() async throws {
        let coordinator = GenerationCoordinator()
        let clock = OwnedDeadlineClock()
        let publications = DeadlinePublications()
        let identity = makeIdentity(context: "synthetic-success-context")
        coordinator.activate(identity: identity, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        var tasks: [Task<Void, Never>] = []
        do {
            let requested = coordinator.launchDeadline(identity: identity, role: .fullCardWatchdog,
                nanoseconds: 1_000_000_000, delayProvider: clock) { identity, role in
                    publications.values.append((identity, role))
                }
            let task = try #require(requested)
            tasks.append(task)
            try await clock.waitUntilStarted()
            #expect(coordinator.fullCardWatchdogTask != nil)
            await clock.release()
            await task.value
            await clock.release()
            #expect(publications.values.count == 1)
            #expect(publications.values.first?.0 == identity)
            #expect(publications.values.first?.1 == .fullCardWatchdog)
            #expect(coordinator.canPublish(identity))
            coordinator.clearTask(role: .fullCardWatchdog, generationID: identity.generationID, cancel: false)
            await coordinator.drainRetiredTasks()
            #expect(coordinator.pendingCleanupTaskCount == 0)
            await close(coordinator, clocks: [clock], tasks: tasks)
        } catch {
            await close(coordinator, clocks: [clock], tasks: tasks)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mismatchedFullIdentityCannotLaunchADeadline() async {
        let coordinator = GenerationCoordinator()
        let current = makeIdentity(context: "synthetic-current-context")
        coordinator.activate(identity: current, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        let mismatched = makeIdentity(context: "synthetic-stale-context")
        #expect(coordinator.launchDeadline(identity: mismatched, role: .fallbackWatchdog,
            nanoseconds: 1, delayProvider: OwnedDeadlineClock(), onDeadline: { _, _ in
                Issue.record("Mismatched context was admitted")
            }) == nil)
        #expect(coordinator.fallbackWatchdogTask == nil)
        #expect(coordinator.pendingCleanupTaskCount == 0)
        coordinator.closeAdmission()
        await coordinator.drainRetiredTasks()
    }

    private func makeIdentity(context: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-deadline-question", generationID: "synthetic-shared-generation",
            sessionID: "synthetic-deadline-session", questionText: "Explain database transactions.",
            promptPrimaryQuestion: "Explain database transactions.", contextSnapshotID: context)
    }
    private func close(_ coordinator: GenerationCoordinator, clocks: [OwnedDeadlineClock], tasks: [Task<Void, Never>]) async {
        coordinator.closeAdmission()
        for clock in clocks { await clock.release() }
        for task in tasks { await task.value }
        await coordinator.drainRetiredTasks()
    }
}

@MainActor
private final class DeadlinePublications {
    var values: [(GenerationIdentity, GenerationCoordinator.TaskRole)] = []
}

// Every clock is independently releasable, even after its owning task was
// cancelled. Case cancellation releases before joining these actual handles.
private actor OwnedDeadlineClock: DelayProvider {
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(nanoseconds: UInt64) async throws {
        started.continuation.yield(()); started.continuation.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilStarted() async throws {
        _ = try await TestEventWaitTrace(label: "coordinator_deadline.clock").nextEvent(in: started.stream, event: "registered")
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
