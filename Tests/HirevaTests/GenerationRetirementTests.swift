import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationRetirementTests {
    enum Removal: String, CaseIterable {
        case invalidate, replaceGeneration, replaceTask, clearCancelled, clearCompleted
    }

    @Test(arguments: Removal.allCases, [GenerationCoordinator.TaskRole.stageATimeout,
        .stageB, .fallbackWatchdog, .fullCardWatchdog, .queuedQuestionHandoff])
    func cancelledOrClearedChildRemainsOwnedUntilActualExit(
        removal: Removal, role: GenerationCoordinator.TaskRole
    ) async {
        let owner = GenerationCoordinator()
        let old = Self.identity("old")
        let gate = RetirementGate()
        let task = Task { await gate.wait() }
        owner.activate(identity: old, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        #expect(owner.registerTask(task, role: role, generationID: old.generationID))
        await gate.waitUntilEntered()
        #expect(owner.pendingCleanupTaskCount == 1)
        var replacement: Task<Void, Never>?
        switch removal {
        case .invalidate: owner.invalidateAndCancel()
        case .replaceGeneration:
            owner.activate(identity: Self.identity("new"), persistenceTicket: 2,
                triggerPath: .regenerate, startedAt: Date())
        case .replaceTask:
            let next = Task {}
            replacement = next
            #expect(owner.registerTask(next, role: role, generationID: old.generationID))
        case .clearCancelled: owner.clearTask(role: role, generationID: old.generationID)
        case .clearCompleted: owner.clearTask(role: role, generationID: old.generationID, cancel: false)
        }
        let activeReplacementCount = replacement == nil ? 0 : 1
        #expect(owner.pendingCleanupTaskCount == activeReplacementCount + 1,
            "Dropping a task handle is not resource cleanup; this noncooperative operation is still suspended.")
        #expect(task.isCancelled == (removal != .clearCompleted))
        owner.invalidateAndCancel()
        await gate.release()
        await task.value
        await replacement?.value
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func replacedRequestAndClearedStageARemainOwned() async {
        let owner = GenerationCoordinator()
        let gate = RetirementGate()
        let requestID = owner.beginRequest(triggerPath: .manualGenerate)
        let root = Task { await gate.wait() }
        #expect(owner.registerRequestTask(root, requestID: requestID))
        await gate.waitUntilEntered()
        _ = owner.beginRequest(triggerPath: .regenerate)
        #expect(root.isCancelled)
        #expect(owner.pendingCleanupTaskCount == 1)
        await gate.release()
        await root.value
        owner.invalidateAndCancel()
        await owner.drainRetiredTasks()

        let stageGate = RetirementGate()
        let current = Self.identity("stage-a")
        owner.activate(identity: current, persistenceTicket: 3, triggerPath: .regenerate, startedAt: Date())
        let stageA = Task<String, Error> { await stageGate.wait(); return "late" }
        #expect(owner.registerStageATask(stageA, generationID: current.generationID))
        await stageGate.waitUntilEntered()
        owner.clearStageATask(generationID: current.generationID)
        #expect(stageA.isCancelled)
        #expect(owner.pendingCleanupTaskCount >= 1)
        owner.invalidateAndCancel()
        await stageGate.release()
        _ = try? await stageA.value
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func shutdownDeadlineReportsUnfinishedWorkAndLaterDrainCanJoinIt() async throws {
        let owner = GenerationCoordinator()
        let gate = RetirementGate()
        let clock = ControlledGenerationWatchdogClock()
        let id = owner.beginRequest(triggerPath: .manualGenerate)
        let task = Task { await gate.wait() }
        #expect(owner.registerRequestTask(task, requestID: id))
        await gate.waitUntilEntered()
        let shutdown = Task { await owner.shutdownAndDrain(timeout: 5, delayProvider: clock) }
        do {
            try await clock.waitUntilScheduled(minimumCount: 1)
            #expect(task.isCancelled)
            #expect(owner.retiringTaskCount == 1)
            clock.advance(by: 5_000_000_000)
            #expect(await shutdown.value == false)
            #expect(owner.pendingCleanupTaskCount == 1)
            #expect(clock.pendingCount == 0)
            // Shutdown permanently prevents new request publication.
            let rejectedID = owner.beginRequest(triggerPath: .regenerate)
            #expect(!owner.isCurrentRequest(rejectedID))
            await gate.release()
            await task.value
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(await owner.shutdownAndDrain(delayProvider: clock))
        } catch {
            clock.cancelAll()
            shutdown.cancel()
            await gate.release()
            await task.value
            _ = await shutdown.value
            await owner.drainRetiredTasks()
            throw error
        }
        clock.cancelAll()
    }

    @Test
    func rootCanFinishItselfWithoutWaitingOnItsOwnJoin() async {
        let owner = GenerationCoordinator()
        let id = owner.beginRequest(triggerPath: .manualGenerate)
        var reachedEnd = false
        let task = Task { @MainActor in
            owner.finishRequest(requestID: id)
            reachedEnd = true
        }
        #expect(owner.registerRequestTask(task, requestID: id))
        await task.value
        await owner.drainRetiredTasks()
        #expect(reachedEnd)
        #expect(owner.activeRequest == nil)
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func launchOwnsRootAndReplacementCannotFinishNewRequest() async throws {
        let owner = GenerationCoordinator()
        let firstGate = RetirementGate()
        let first = owner.launchRequest(triggerPath: .manualGenerate) { _ in await firstGate.wait() }
        let firstTask = try #require(owner.requestTask)
        await firstGate.waitUntilEntered()
        let nextGate = RetirementGate()
        let next = owner.launchRequest(triggerPath: .regenerate) { _ in await nextGate.wait() }
        let nextTask = try #require(owner.requestTask)
        await nextGate.waitUntilEntered()
        #expect(firstTask.isCancelled)
        #expect(owner.retiringTaskCount == 1)
        #expect(!owner.isCurrentRequest(first))
        await firstGate.release()
        await firstTask.value
        #expect(owner.isCurrentRequest(next))
        await nextGate.release()
        await nextTask.value
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    enum FallbackTerminalEntry: CaseIterable, Equatable, Sendable {
        case caller, ownedWorker, terminalSubscriberReplacement
    }

    /// Actual App projection, existing owner registration/terminal entry, and
    /// the existing releasable uncooperative gate. No provider or wall sleep.
    @Test(.timeLimit(.minutes(1)), arguments: FallbackTerminalEntry.allCases)
    func terminalFallbackRoleRetiresBeforeCommittedAppObservation(entry: FallbackTerminalEntry) async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FallbackRoleProjection")
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: SimpleContextRetrievalService(documentRepository: DocumentRepository(database: database)), dialogueDefaults: nil)
        let owner = app.generationCoordinator
        let identity = Self.identity("synthetic-fallback-old")
        let replacementIdentity = Self.identity("synthetic-fallback-new")
        let oldGate = RetirementGate()
        let replacementGate = RetirementGate()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var oldTask: Task<Void, Never>?
        var replacementTask: Task<Void, Never>?
        var terminalObserved = false
        var committedInactive = false
        var retainedAtPublication = false
        var reentered = false
        var subscription: AnyCancellable?
        func cleanup() async {
            subscription?.cancel()
            entered.continuation.finish()
            owner.invalidateAndCancel()
            await oldGate.release()
            await replacementGate.release()
            await oldTask?.value
            await replacementTask?.value
            #expect(await app.shutdownResources())
            try? database.close()
        }
        do {
            owner.activate(identity: identity, persistenceTicket: 1,
                triggerPath: .autoDetect, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
            subscription = owner.objectWillChange.sink { _ in
                guard !terminalObserved, owner.terminalGenerationIDs.contains(identity.generationID) else { return }
                terminalObserved = true
                committedInactive = owner.fallbackWatchdogTask == nil && !app.fallbackWatchdogActive
                retainedAtPublication = owner.retiringTaskCount == 1 && owner.pendingCleanupTaskCount == 1
                if entry == .terminalSubscriberReplacement {
                    reentered = true
                    owner.activate(identity: replacementIdentity, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                    let next = Task { await replacementGate.wait() }
                    replacementTask = next
                    app.registerFallbackWatchdogTask(next, generationID: replacementIdentity.generationID)
                    app.generationUIState = .idle
                }
            }
            let child = Task { @MainActor in
                if entry == .ownedWorker {
                    app.setGenerationUIState(.answerReady(questionID: identity.acceptedQuestionID,
                        generationID: identity.generationID, triggerPath: .autoDetect),
                        generationID: identity.generationID)
                }
                entered.continuation.yield(())
                // This exact worker deliberately keeps running after cancel.
                await oldGate.wait()
            }
            oldTask = child
            app.registerFallbackWatchdogTask(child, generationID: identity.generationID)
            #expect(owner.fallbackWatchdogTask == child)
            #expect(app.fallbackWatchdogActive)
            try await withTaskCancellationHandler {
                for await _ in entered.stream { break }
                try Task.checkCancellation()
            } onCancel: { entered.continuation.finish() }
            if entry != .ownedWorker {
                app.setGenerationUIState(.answerReady(questionID: identity.acceptedQuestionID,
                    generationID: identity.generationID, triggerPath: .autoDetect),
                    generationID: identity.generationID)
            }
            #expect(terminalObserved && committedInactive && retainedAtPublication,
                "The terminal mutation must publish a nil current role and retain its actual suspended worker.")
            #expect(child.isCancelled && owner.retiringTaskCount == 1)
            if entry == .terminalSubscriberReplacement {
                let replacement = try #require(replacementTask)
                #expect(reentered && owner.isCurrent(replacementIdentity))
                #expect(owner.fallbackWatchdogTask == replacement && app.fallbackWatchdogActive)
                #expect(!replacement.isCancelled && owner.pendingCleanupTaskCount == 2)
            } else {
                #expect(owner.fallbackWatchdogTask == nil && !app.fallbackWatchdogActive)
                #expect(owner.pendingCleanupTaskCount == 1)
            }
            await cleanup()
            #expect(owner.pendingCleanupTaskCount == 0 && !app.fallbackWatchdogActive)
        } catch {
            await cleanup()
            throw error
        }
    }

    private static func identity(_ id: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-question-\(id)", generationID: id,
            sessionID: "synthetic-session", questionText: "Explain database transactions",
            promptPrimaryQuestion: "Explain database transactions", contextSnapshotID: "synthetic-context")
    }
}

/// Deliberately ignores cancellation; every test explicitly releases and joins.
private actor RetirementGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let ready = enteredWaiters; enteredWaiters.removeAll()
        ready.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
