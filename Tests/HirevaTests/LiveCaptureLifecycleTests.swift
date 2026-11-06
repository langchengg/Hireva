import Foundation
import os
import Testing
@testable import Hireva

/// Synthetic control operations exercise the production lifecycle owner. They
/// do not start a microphone, ScreenCaptureKit, ASR, or any native helper.
@MainActor
struct LiveCaptureLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func revokedStartupClearsItsRegistrationOnlyAfterActualExit() async throws {
        let owner = LiveCaptureLifecycle()
        let gate = LiveCaptureControlGate()
        try await withTaskCancellationHandler {
            let task = try #require(owner.start { id in await gate.wait(id: id) })
            do {
                let id = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: gate.entered.stream, event: "startup_operation_entered")
                #expect(owner.isStartupCurrent(id))
                #expect(owner.invalidateStartup() == task)
                #expect(owner.startupID == nil)
                #expect(owner.startupTask == task,
                    "Cancellation revokes admission without pretending the suspended task exited.")
                #expect(owner.pendingTaskCount == 1)
                gate.release()
                await task.value
                await owner.drain()
                #expect(owner.startupTask == nil)
                #expect(owner.retiringTaskCount == 0)
                #expect(owner.pendingTaskCount == 0)
            } catch {
                gate.release()
                owner.closeAdmission()
                await owner.drain()
                gate.closeAfterJoin()
                throw error
            }
            gate.closeAfterJoin()
            #expect(!gate.escaped)
        } onCancel: { gate.cancelOwningTest() }
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementRetainsOldStartupAndShutdownJoinsBothExactEpochs() async throws {
        let owner = LiveCaptureLifecycle()
        let oldGate = LiveCaptureControlGate()
        let newGate = LiveCaptureControlGate()
        let drainEntry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var drain: Task<Void, Never>?
        var didDrain = false
        try await withTaskCancellationHandler {
            do {
                let first = try #require(owner.start { id in await oldGate.wait(id: id) })
                let trace = TestEventWaitTrace(label: #function)
                let oldID = try await trace.nextEvent(in: oldGate.entered.stream, event: "old_startup_entered")
                let second = try #require(owner.start { id in await newGate.wait(id: id) })
                let newID = try #require(owner.startupID)
                #expect(newID != oldID)
                #expect(owner.startupTask == second)
                #expect(owner.retiringTaskCount == 1)
                #expect(newGate.entryCount == 0,
                    "The replacement cannot enter its provider before the cancelled old startup exits.")
                oldGate.release()
                let submittedID = try await trace.nextEvent(in: newGate.entered.stream, event: "new_startup_entered_after_old_exit")
                await first.value
                #expect(submittedID == newID)
                #expect(owner.startupID == newID)
                #expect(owner.startupTask == second,
                    "Old completion cannot clear the new registration.")
                owner.closeAdmission()
                #expect(owner.startupID == nil)
                #expect(owner.start(operation: { _ in }) == nil)
                drain = Task { @MainActor in
                    drainEntry.continuation.yield(())
                    await owner.drain()
                    didDrain = true
                }
                _ = try await trace.nextEvent(in: drainEntry.stream, event: "external_cleanup_wait_entered")
                #expect(!didDrain,
                    "A closed owner still retains the noncooperative new startup until its controlled release.")
                newGate.release()
                await second.value
                await drain?.value
                #expect(didDrain)
                #expect(owner.startupTask == nil)
                #expect(owner.pendingTaskCount == 0)
                #expect(owner.retiringTaskCount == 0)
            } catch {
                oldGate.release()
                newGate.release()
                owner.closeAdmission()
                await owner.drain()
                await drain?.value
                oldGate.closeAfterJoin()
                newGate.closeAfterJoin()
                drainEntry.continuation.finish()
                throw error
            }
            oldGate.release()
            newGate.release()
            await owner.drain()
            await drain?.value
            oldGate.closeAfterJoin()
            newGate.closeAfterJoin()
            drainEntry.continuation.finish()
            #expect(!oldGate.escaped && !newGate.escaped)
        } onCancel: {
            oldGate.cancelOwningTest()
            newGate.cancelOwningTest()
            drainEntry.continuation.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileWaitingPriorTeardownNeverEntersNewProvider() async throws {
        let owner = LiveCaptureLifecycle()
        let gate = LiveCaptureControlGate()
        var providerEntries = 0
        try await withTaskCancellationHandler {
            let teardown = owner.queueTeardown(after: nil) { id in
                await gate.wait(id: id)
                return true
            }
            do {
                _ = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: gate.entered.stream, event: "prior_teardown_entered")
                let startup = try #require(owner.start { _ in providerEntries += 1 })
                _ = owner.invalidateStartup()
                gate.release()
                await teardown.value
                await startup.value
                await owner.drain()
                #expect(providerEntries == 0)
                #expect(owner.startupID == nil)
                #expect(owner.startupTask == nil)
                #expect(owner.teardownTask == nil)
                #expect(owner.pendingTaskCount == 0)
            } catch {
                gate.release()
                owner.closeAdmission()
                await owner.drain()
                gate.closeAfterJoin()
                throw error
            }
            gate.closeAfterJoin()
            #expect(!gate.escaped)
        } onCancel: { gate.cancelOwningTest() }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedTeardownRemainsOwnedUntilItsOriginalOperationRetrySucceeds() async throws {
        let owner = LiveCaptureLifecycle()
        let gate = LiveCaptureControlGate()
        var originalReleased = false
        try await withTaskCancellationHandler {
            let failed = owner.queueTeardown(after: nil) { _ in originalReleased }
            await failed.value
            await owner.drain()
            #expect(owner.hasFailedTeardown)
            #expect(owner.teardownTask == failed)
            #expect(owner.teardownID != nil)
            #expect(owner.pendingTaskCount == 0,
                "Execution has ended; this does not certify the native resource was released.")
            let replacement = owner.queueTeardown(after: nil) { id in
                await gate.wait(id: id)
                return true
            }
            do {
                _ = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: gate.entered.stream, event: "replacement_teardown_entered")
                #expect(owner.teardownTask == replacement)
                #expect(owner.pendingTaskCount >= 1)
                gate.release()
                await replacement.value
                await owner.drain()
                #expect(owner.teardownTask == nil)
                #expect(owner.hasFailedTeardown,
                    "Successful cleanup of an unrelated replacement cannot release the original failed operation.")
                #expect(owner.pendingTaskCount == 0)
                originalReleased = true
                await owner.retryFailedTeardowns()
                await owner.drain()
                #expect(!owner.hasFailedTeardown)
                #expect(owner.retiringTaskCount == 0)
            } catch {
                gate.release()
                owner.closeAdmission()
                await owner.drain()
                gate.closeAfterJoin()
                throw error
            }
            gate.closeAfterJoin()
            #expect(!gate.escaped)
        } onCancel: { gate.cancelOwningTest() }
    }
}

/// The owning-test cancellation handler can release all controlled waits from
/// any executor. It never asks MainActor to run cleanup while MainActor waits.
private final class LiveCaptureControlGate: Sendable {
    private struct State: Sendable {
        var released = false
        var escaped = false
        var entries = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingOldest(4))
    var entryCount: Int { state.withLock { $0.entries } }
    var escaped: Bool { state.withLock { $0.escaped } }
    func wait(id: UUID) async {
        state.withLock { $0.entries += 1 }
        entered.continuation.yield(id)
        await withCheckedContinuation { waiter in
            let released = state.withLock { value in
                if value.released { return true }
                value.waiting.append(waiter)
                return false
            }
            if released { waiter.resume() }
        }
    }
    func release() {
        let waiting = state.withLock { value in
            value.released = true
            let waiting = value.waiting
            value.waiting.removeAll()
            return waiting
        }
        waiting.forEach { $0.resume() }
    }
    func cancelOwningTest() {
        state.withLock { $0.escaped = true }
        release()
        entered.continuation.finish()
    }
    func closeAfterJoin() { entered.continuation.finish() }
}
