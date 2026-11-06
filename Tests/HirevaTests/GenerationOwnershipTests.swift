import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite
struct GenerationOwnershipTests {
    @Test
    func requestReplacementRejectsLateLaunchAndOldFinishCannotClearNewRoot() async {
        let coordinator = GenerationCoordinator()
        let oldGate = GenerationOwnershipGate()
        let newGate = GenerationOwnershipGate()
        var published: [String] = []
        let oldID = coordinator.beginRequest(triggerPath: .autoDetect)
        #expect(coordinator.autoLaunchPending)
        let oldTask = Task {
            await oldGate.wait()
            if coordinator.isCurrentRequest(oldID) { published.append("old") }
            coordinator.finishRequest(requestID: oldID)
        }
        #expect(coordinator.registerRequestTask(oldTask, requestID: oldID))
        await oldGate.waitUntilSuspended()
        let generation = identity("owned-generation")
        coordinator.activate(identity: generation, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        #expect(!oldTask.isCancelled)
        #expect(!coordinator.autoLaunchPending)
        let newID = coordinator.beginRequest(triggerPath: .regenerate)
        #expect(oldTask.isCancelled)
        #expect(!coordinator.canPublish(generation))
        let newTask = Task {
            await newGate.wait()
            if coordinator.isCurrentRequest(newID) { published.append("new") }
            coordinator.finishRequest(requestID: newID)
        }
        #expect(coordinator.registerRequestTask(newTask, requestID: newID))
        await newGate.waitUntilSuspended()
        await oldGate.release()
        await oldTask.value
        #expect(published.isEmpty)
        #expect(coordinator.isCurrentRequest(newID))
        #expect(coordinator.requestTask != nil)
        await newGate.release()
        await newTask.value
        #expect(published == ["new"])
        #expect(coordinator.activeRequest == nil)
    }

    @Test
    func finishedRootLeavesItsExpansionOwnedUntilStop() async {
        let coordinator = GenerationCoordinator()
        let requestID = coordinator.beginRequest(triggerPath: .manualGenerate)
        let current = identity("expansion")
        coordinator.activate(identity: current, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        let gate = GenerationOwnershipGate()
        let child = Task { await gate.wait() }
        #expect(coordinator.registerTask(child, role: .stageB, generationID: current.generationID))
        await gate.waitUntilSuspended()
        coordinator.finishRequest(requestID: requestID)
        #expect(coordinator.activeRequest == nil)
        #expect(coordinator.canPublish(current))
        #expect(!child.isCancelled)
        coordinator.invalidateAndCancel()
        #expect(child.isCancelled)
        await gate.release()
        await child.value
    }

    @Test
    func replacementRejectsLateResultAndOldCleanupCannotClearNewTask() async {
        let coordinator = GenerationCoordinator()
        let first = identity("first")
        let second = identity("second")
        let oldGate = GenerationOwnershipGate()
        let newGate = GenerationOwnershipGate()
        var published: [String] = []
        coordinator.activate(identity: first, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        let oldTask = Task {
            await oldGate.wait()
            // This provider deliberately ignores cancellation until released.
            if coordinator.canPublish(first) { published.append("old") }
            coordinator.clearTask(role: .stageB, generationID: first.generationID, cancel: false)
        }
        #expect(coordinator.registerTask(oldTask, role: .stageB, generationID: first.generationID))
        await oldGate.waitUntilSuspended()

        coordinator.activate(identity: second, persistenceTicket: 2, triggerPath: .autoDetect, startedAt: Date())
        let newTask = Task {
            await newGate.wait()
            if coordinator.canPublish(second) { published.append("new") }
        }
        #expect(coordinator.registerTask(newTask, role: .stageB, generationID: second.generationID))
        await newGate.waitUntilSuspended()
        #expect(oldTask.isCancelled)
        #expect(coordinator.isCurrent(second))
        #expect(!coordinator.canPublish(first))

        await oldGate.release()
        await oldTask.value
        #expect(published.isEmpty)
        #expect(coordinator.stageBTask != nil)
        await newGate.release()
        await newTask.value
        #expect(published == ["new"])
        coordinator.invalidateAndCancel()
    }

    @Test
    func stopInvalidatesAndCancelsEveryRegisteredRoleIdempotently() async {
        let coordinator = GenerationCoordinator()
        let current = identity("stop")
        coordinator.activate(identity: current, persistenceTicket: 7, triggerPath: .manualGenerate, startedAt: Date())
        let gate = GenerationOwnershipGate()
        let stageA = Task<String, Error> { await gate.wait(); return "late" }
        #expect(coordinator.registerStageATask(stageA, generationID: current.generationID))
        let roles: [GenerationCoordinator.TaskRole] = [.stageATimeout, .stageB, .fallbackWatchdog, .fullCardWatchdog]
        let tasks = roles.map { role in
            let task = Task { await gate.wait() }
            #expect(coordinator.registerTask(task, role: role, generationID: current.generationID))
            return task
        }
        await gate.waitUntilSuspended()
        let stopped = coordinator.invalidateAndCancel()
        #expect(stopped?.identity == current)
        #expect(coordinator.activeGeneration == nil)
        #expect(!coordinator.canPublish(current))
        #expect(stageA.isCancelled)
        let allCancelled = tasks.allSatisfy { $0.isCancelled }
        #expect(allCancelled)
        #expect(coordinator.invalidateAndCancel() == nil)
        await gate.release()
        _ = try? await stageA.value
        for task in tasks { await task.value }
    }

    @Test
    func staleRegistrationIsCancelledWithoutReplacingCurrentTask() async {
        let coordinator = GenerationCoordinator()
        let current = identity("current")
        let gate = GenerationOwnershipGate()
        coordinator.activate(identity: current, persistenceTicket: 1, triggerPath: .regenerate, startedAt: Date())
        let accepted = Task { await gate.wait() }
        #expect(coordinator.registerTask(accepted, role: .stageB, generationID: current.generationID))
        let stale = Task { await gate.wait() }
        #expect(!coordinator.registerTask(stale, role: .stageB, generationID: "old"))
        #expect(stale.isCancelled)
        #expect(coordinator.stageBTask != nil)
        coordinator.invalidateAndCancel()
        await gate.release()
        await accepted.value
        await stale.value
    }

    @Test
    func terminalFenceRejectsTokensAndTaskRegistrationButNextAttemptCanStart() async {
        let coordinator = GenerationCoordinator()
        let first = identity("terminal", questionID: "same-question")
        coordinator.activate(identity: first, persistenceTicket: 1, triggerPath: .regenerate, startedAt: Date())
        coordinator.markTerminal(generationID: first.generationID)
        coordinator.markTerminal(generationID: first.generationID)
        #expect(coordinator.terminalGenerationIDs == [first.generationID])
        #expect(coordinator.isCurrent(first))
        #expect(!coordinator.canPublish(first))
        let late = Task<String, Error> { "late token" }
        #expect(!coordinator.registerStageATask(late, generationID: first.generationID))
        #expect(late.isCancelled)
        _ = try? await late.value

        let second = identity("next", questionID: "same-question")
        coordinator.activate(identity: second, persistenceTicket: 2, triggerPath: .regenerate, startedAt: Date())
        #expect(coordinator.canPublish(second))
        #expect(!coordinator.canPublish(first))
        coordinator.invalidateAndCancel()
        coordinator.resetTerminalHistory()
        #expect(coordinator.terminalGenerationIDs.isEmpty)
    }

    @Test
    func publicationRequiresCompleteSessionQuestionAndContextIdentity() {
        let coordinator = GenerationCoordinator()
        let current = identity("shared-id")
        coordinator.activate(identity: current, persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date())
        #expect(coordinator.canPublish(current))
        let mismatches = [
            identity("shared-id", questionID: "different-question"),
            identity("shared-id", sessionID: "different-session"),
            identity("shared-id", contextID: "different-context"),
            identity("shared-id", questionText: "What would you improve next?")
        ]
        for candidate in mismatches {
            #expect(!coordinator.canPublish(candidate))
        }
        coordinator.invalidateAndCancel()
    }

    @Test
    func deadlineCancelsButJoinsNoncooperativeOperationUntilExplicitRelease() async {
        let delay = GenerationOwnershipDelay()
        let operationGate = GenerationOwnershipGate()
        let (cancellations, signal) = AsyncStream<Void>.makeStream()
        var finished = false
        let request = Task {
            defer { finished = true }
            return try await GenerationCoordinator.withTimeout(seconds: 10, delayProvider: delay) {
                await withTaskCancellationHandler {
                    await operationGate.wait()
                } onCancel: {
                    signal.yield(())
                }
                return "must not succeed"
            }
        }
        await operationGate.waitUntilSuspended()
        await delay.gate.waitUntilSuspended()
        await delay.gate.release()
        var iterator = cancellations.makeAsyncIterator()
        _ = await iterator.next()
        #expect(!finished)
        await operationGate.release()
        do {
            _ = try await request.value
            Issue.record("Timed out operation published success")
        } catch {
            #expect((error as NSError).domain == "TimeoutDomain")
        }
        #expect(finished)
        signal.finish()
    }

    @Test
    func parentCancellationCancelsOwnedUnstructuredStageAAndNeverPublishesSuccess() async {
        let delay = GenerationOwnershipDelay()
        let operationGate = GenerationOwnershipGate()
        let (cancellations, signal) = AsyncStream<Void>.makeStream()
        let ownedStageA = Task<String, Error> {
            await withTaskCancellationHandler {
                await operationGate.wait()
            } onCancel: {
                signal.yield(())
            }
            return "late result"
        }
        var finished = false
        let request = Task {
            defer { finished = true }
            return try await GenerationCoordinator.withTimeout(seconds: 10, delayProvider: delay) {
                try await withTaskCancellationHandler {
                    try await ownedStageA.value
                } onCancel: {
                    ownedStageA.cancel()
                }
            }
        }
        await operationGate.waitUntilSuspended()
        await delay.gate.waitUntilSuspended()
        request.cancel()
        var iterator = cancellations.makeAsyncIterator()
        _ = await iterator.next()
        #expect(ownedStageA.isCancelled)
        #expect(!finished)
        await operationGate.release()
        await delay.gate.release()
        do {
            _ = try await request.value
            Issue.record("Cancelled request published a late success")
        } catch {
            #expect(error is CancellationError)
        }
        _ = try? await ownedStageA.value
        signal.finish()
    }

    private func identity(
        _ generationID: String,
        questionID: String = "question",
        sessionID: String = "session",
        contextID: String = "context",
        questionText: String = "How do you validate a robot controller?"
    ) -> GenerationIdentity {
        GenerationIdentity(
            acceptedQuestionID: questionID,
            generationID: generationID,
            sessionID: sessionID,
            questionText: questionText,
            promptPrimaryQuestion: questionText,
            contextSnapshotID: contextID
        )
    }
}

/// Every noncooperative wait in these tests has an explicit, owned release.
private actor GenerationOwnershipGate {
    private var open = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let awaitingStart = startWaiters
        startWaiters.removeAll()
        awaitingStart.forEach { $0.resume() }
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilSuspended() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        open = true
        let awaitingRelease = waiters
        waiters.removeAll()
        awaitingRelease.forEach { $0.resume() }
    }
}

private struct GenerationOwnershipDelay: DelayProvider {
    let gate = GenerationOwnershipGate()

    func sleep(nanoseconds: UInt64) async throws {
        await gate.wait()
    }
}
