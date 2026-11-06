import Combine
import Foundation
import os
import Testing
@testable import Hireva

// Post-integration characterizations of the proposed existing-owner launch.
// Unchanged actual ManualSnapshotFixture entry tests protect the UI/DB body.
@MainActor
struct GenerationManualWorkflowOwnershipTests {
    enum Reentry: CaseIterable, Equatable, Sendable {
        case none, registrationPublication, operationPublication
    }

    @Test(.timeLimit(.minutes(1)), arguments: Reentry.allCases)
    func actualOwnerCreatesBeforePublicationAndOldLaunchCannotClearReplacement(reentry: Reentry) async throws {
        let owner = GenerationCoordinator()
        let identity = Self.identity()
        let oldGate = ManualWorkflowGate()
        let replacementGate = ManualWorkflowGate()
        let state = ManualWorkflowPublications()
        owner.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .manualCapture, startedAt: Date())
        func launchReplacement() -> Task<Void, Never>? {
            owner.launchManualWorkflow(identity: identity, operation: { submitted in
                state.replacementEntered = true
                #expect(submitted == identity)
                #expect(owner.stageBTask != nil)
                await replacementGate.wait()
            }, onExit: { _, cleared in state.replacementExits.append(cleared) })
        }
        let observation = owner.objectWillChange.sink { _ in
            guard !state.registrationObserved, let registered = owner.stageBTask else { return }
            state.registrationObserved = true
            state.originalTask = registered
            #expect(!state.originalEntered, "The actual role is committed before its operation can enter")
            if reentry == .registrationPublication { state.replacementTask = launchReplacement() }
        }
        do {
            let launched = owner.launchManualWorkflow(identity: identity, operation: { submitted in
                state.originalEntered = true
                #expect(submitted == identity)
                #expect(owner.stageBTask == state.originalTask)
                #expect(!owner.canDrainFromCurrentTask)
                if reentry == .operationPublication {
                    state.replacementTask = launchReplacement()
                    // This is the old Manual catch's actual finish operation.
                    // Full identity still matches, but its launch receipt does not.
                    state.oldFinishAdmitted = owner.finishManualWorkflow(identity: identity)
                }
                await oldGate.wait()
            }, onExit: { _, cleared in state.originalExits.append(cleared) })
            let original = try #require(state.originalTask)
            try await withTaskCancellationHandler {
                if reentry == .registrationPublication {
                    #expect(launched == nil)
                    #expect(!state.originalEntered)
                } else {
                    #expect(launched == original)
                    try await oldGate.waitUntilEntered(label: "manual-workflow.original")
                }
                #expect(state.registrationObserved)
                if reentry != .none {
                    let replacement = try #require(state.replacementTask)
                    try await replacementGate.waitUntilEntered(label: "manual-workflow.replacement")
                    #expect(original.isCancelled)
                    #expect(!replacement.isCancelled)
                    #expect(owner.canPublish(identity))
                    #expect(owner.stageBTask == replacement)
                    if reentry == .operationPublication { #expect(state.oldFinishAdmitted == false) }
                    oldGate.release()
                    await original.value
                    #expect(owner.stageBTask == replacement)
                    #expect(state.originalExits == [false])
                    replacementGate.release()
                    await replacement.value
                } else {
                    #expect(!original.isCancelled)
                    oldGate.release()
                    await original.value
                    #expect(state.originalExits == [true])
                }
                await owner.drainRetiredTasks()
                #expect(owner.stageBTask == nil)
                #expect(owner.pendingCleanupTaskCount == 0)
            } onCancel: {
                original.cancel(); oldGate.release(); replacementGate.release()
            }
            observation.cancel()
            await close(owner, state: state, gates: [oldGate, replacementGate])
        } catch {
            observation.cancel()
            await close(owner, state: state, gates: [oldGate, replacementGate])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledManualRootRemainsOwnedUntilItsUncooperativeOperationActuallyExits() async throws {
        let owner = GenerationCoordinator()
        let identity = Self.identity()
        let gate = ManualWorkflowGate()
        let clock = ControlledGenerationWatchdogClock()
        let state = ManualWorkflowPublications()
        owner.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .manualCapture, startedAt: Date())
        let worker = try #require(owner.launchManualWorkflow(identity: identity,
            operation: { _ in await gate.wait() }, onExit: { _, _ in }))
        state.originalTask = worker
        var shutdown: Task<Bool, Never>?
        do {
            try await withTaskCancellationHandler {
                try await gate.waitUntilEntered(label: "manual-workflow.retirement")
                let drain = Task { await owner.shutdownAndDrain(timeout: 5, delayProvider: clock) }
                shutdown = drain
                try await clock.waitUntilPending(nanoseconds: 5_000_000_000)
                #expect(worker.isCancelled)
                #expect(!gate.exited)
                #expect(owner.pendingCleanupTaskCount == 1)
                clock.advance(by: 5_000_000_000)
                #expect(await drain.value == false)
                #expect(owner.pendingCleanupTaskCount == 1)
                #expect(owner.launchManualWorkflow(identity: identity,
                    operation: { _ in Issue.record("Closed owner launched Manual work") },
                    onExit: { _, _ in }) == nil)
                gate.release()
                await worker.value
                await owner.drainRetiredTasks()
                #expect(gate.exited)
                #expect(owner.pendingCleanupTaskCount == 0)
            } onCancel: { worker.cancel(); gate.release(); clock.cancelAll() }
            clock.cancelAll()
            _ = await shutdown?.value
            await close(owner, state: state, gates: [gate])
        } catch {
            clock.cancelAll(); shutdown?.cancel(); gate.release()
            await worker.value
            _ = await shutdown?.value
            await close(owner, state: state, gates: [gate])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func executingManualWorkerCannotJoinItsOwnRetirement() async throws {
        let owner = GenerationCoordinator()
        let identity = Self.identity()
        let gate = ManualWorkflowGate()
        let state = ManualWorkflowPublications()
        owner.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .manualCapture, startedAt: Date())
        let worker = try #require(owner.launchManualWorkflow(identity: identity, operation: { _ in
            owner.clearTask(role: .stageB, generationID: identity.generationID, cancel: false)
            state.selfDrainAdmitted = owner.canDrainFromCurrentTask
            await owner.drainRetiredTasks()
            state.selfDrainReturned = true
            await gate.wait()
        }, onExit: { _, _ in }))
        state.originalTask = worker
        do {
            try await withTaskCancellationHandler {
                try await gate.waitUntilEntered(label: "manual-workflow.self-drain")
                #expect(state.selfDrainAdmitted == false)
                #expect(state.selfDrainReturned)
                #expect(owner.pendingCleanupTaskCount == 1)
                gate.release()
                await worker.value
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            } onCancel: { worker.cancel(); gate.release() }
            await close(owner, state: state, gates: [gate])
        } catch {
            await close(owner, state: state, gates: [gate])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func inheritedManualChildMayDrainActualAppOnlyAfterItsParentActuallyExits(expiredParent: Bool) async throws {
        let fixture = try await ManualSnapshotFixture()
        let owner = fixture.app.generationCoordinator
        let identity = Self.identity(sessionID: fixture.session.id, context: fixture.session.contextSnapshotID)
        let gate = ManualWorkflowGate()
        let childGate = ManualWorkflowGate()
        let state = ManualWorkflowPublications()
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        owner.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .manualCapture, startedAt: Date())
        let worker = try #require(owner.launchManualWorkflow(identity: identity, operation: { _ in
            owner.clearTask(role: .stageB, generationID: identity.generationID, cancel: false)
            state.inheritedShutdown = Task { @MainActor in
                if expiredParent { await childGate.wait() }
                state.inheritedDrainAdmitted = owner.canDrainFromCurrentTask
                state.inheritedShutdownResult = await fixture.app.shutdownResources()
                completed.continuation.yield(())
                completed.continuation.finish()
            }
            // Parent never awaits the shutdown child: releasing this gate also
            // breaks a failed guard's cycle during test cancellation/cleanup.
            await gate.wait()
        }, onExit: { _, _ in }))
        state.originalTask = worker
        do {
            try await withTaskCancellationHandler {
                try await gate.waitUntilEntered(label: "manual-workflow.inherited-parent")
                if expiredParent {
                    gate.release()
                    await worker.value
                    await owner.drainRetiredTasks()
                    childGate.release()
                }
                _ = try await TestEventWaitTrace(label: "manual-workflow.inherited-shutdown")
                    .nextEvent(in: completed.stream, event: "actual-shutdown-returned")
                #expect(state.inheritedDrainAdmitted == expiredParent)
                #expect(state.inheritedShutdownResult == expiredParent)
                if !expiredParent {
                    #expect(!worker.isCancelled, "The inherited caller must decline before starting App cleanup")
                    #expect(!fixture.app.isShuttingDown)
                    #expect(owner.pendingCleanupTaskCount == 1)
                }
                gate.release()
                await worker.value
                await state.inheritedShutdown?.value
                await owner.drainRetiredTasks()
                #expect(owner.canDrainFromCurrentTask)
                #expect(owner.pendingCleanupTaskCount == 0)
            } onCancel: {
                worker.cancel(); gate.release(); childGate.release(); completed.continuation.finish()
            }
            try await fixture.close([worker])
        } catch {
            worker.cancel(); gate.release(); childGate.release(); completed.continuation.finish()
            await worker.value
            await state.inheritedShutdown?.value
            try? await fixture.close([worker])
            throw error
        }
    }

    private func close(_ owner: GenerationCoordinator, state: ManualWorkflowPublications,
        gates: [ManualWorkflowGate]) async {
        owner.closeAdmission()
        for gate in gates { gate.release() }
        await state.originalTask?.value
        await state.replacementTask?.value
        await owner.drainRetiredTasks()
    }

    private static func identity(sessionID: String = "synthetic-manual-session",
        context: String? = "synthetic-manual-context") -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-manual-question", generationID: "synthetic-manual-generation",
            sessionID: sessionID, questionText: "Explain database transactions.",
            promptPrimaryQuestion: "Explain database transactions.", contextSnapshotID: context)
    }
}

@MainActor
private final class ManualWorkflowPublications {
    var registrationObserved = false
    var originalEntered = false
    var replacementEntered = false
    var originalTask: Task<Void, Never>?
    var replacementTask: Task<Void, Never>?
    var originalExits: [Bool] = []
    var replacementExits: [Bool] = []
    var oldFinishAdmitted: Bool?
    var selfDrainAdmitted: Bool?
    var selfDrainReturned = false
    var inheritedDrainAdmitted: Bool?
    var inheritedShutdownResult: Bool?
    var inheritedShutdown: Task<Void, Never>?
}

// Adapted from the existing Manual-owned entry gate, with one uncooperative
// waiter, releasable on every outcome, and cooperative logical readiness.
private final class ManualWorkflowGate: Sendable {
    private struct State: Sendable {
        var released = false
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var exited: Bool { state.withLock { $0.exited } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state in
                if state.released { return true }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return false
            }
            entered.continuation.yield(())
            entered.continuation.finish()
            if immediate { continuation.resume() }
        }
        state.withLock { $0.exited = true }
    }
    func waitUntilEntered(label: String) async throws {
        _ = try await TestEventWaitTrace(label: label).nextEvent(in: entered.stream, event: "operation-entered")
    }
    func release() {
        let waiter = state.withLock { state in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
        entered.continuation.finish()
    }
}
