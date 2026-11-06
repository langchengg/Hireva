import Foundation
import os
import Testing
@testable import Hireva

/// Characterizes the new consumer registration on the existing capture owner.
/// Gates ignore consumer cancellation but always release on owning-test cancel.
/// This does not characterize a native ASR/helper resource or real audio.
@MainActor
struct LiveCaptureConsumerOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func replacementConsumesWhileRetiredConsumerRemainsOwnedUntilActualExit() async throws {
        let owner = LiveCaptureLifecycle()
        let oldGate = LiveConsumerOperationGate()
        let newGate = LiveConsumerOperationGate()
        let draining = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var drain: Task<Void, Never>?
        var finishedDrain = false
        try await withTaskCancellationHandler {
            do {
                let trace = TestEventWaitTrace(label: #function)
                let old = try #require(owner.consume { id in await oldGate.wait(id: id) })
                let oldID = try await trace.nextEvent(in: oldGate.entered.stream,
                    event: "old_consumer_operation_entered")
                let current = try #require(owner.consume { id in await newGate.wait(id: id) })
                let currentID = try await trace.nextEvent(in: newGate.entered.stream,
                    event: "new_consumer_operation_entered_before_old_release")
                #expect(oldID != currentID)
                #expect(old.isCancelled)
                #expect(!owner.isConsumerCurrent(oldID))
                #expect(owner.isConsumerCurrent(currentID))
                #expect(owner.transcriptionTask == current)
                #expect(owner.retiringTaskCount == 1)
                #expect(owner.pendingTaskCount == 2)
                owner.closeAdmission()
                #expect(owner.consumerID == nil)
                #expect(owner.transcriptionTask == current)
                #expect(owner.consume(operation: { _ in }) == nil)
                drain = Task { @MainActor in
                    draining.continuation.yield(())
                    await owner.drain()
                    finishedDrain = true
                }
                _ = try await trace.nextEvent(in: draining.stream, event: "external_drain_entered")
                #expect(!finishedDrain,
                    "Cancellation cannot certify exit while both exact controlled operations are suspended.")
                oldGate.release()
                await old.value
                #expect(owner.transcriptionTask == current,
                    "Old completion cannot clear the replacement consumer registration.")
                #expect(!finishedDrain)
                newGate.release()
                await current.value
                await drain?.value
                #expect(finishedDrain)
                #expect(owner.transcriptionTask == nil)
                #expect(owner.consumerID == nil)
                #expect(owner.retiringTaskCount == 0)
                #expect(owner.pendingTaskCount == 0)
            } catch {
                oldGate.release(); newGate.release()
                owner.closeAdmission()
                await owner.drain()
                await drain?.value
                oldGate.close(); newGate.close(); draining.continuation.finish()
                throw error
            }
            oldGate.release(); newGate.release()
            await owner.drain(); await drain?.value
            oldGate.close(); newGate.close(); draining.continuation.finish()
            #expect(!oldGate.escaped && !newGate.escaped)
        } onCancel: {
            oldGate.cancelOwningTest(); newGate.cancelOwningTest()
            draining.continuation.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledBeforeFirstExecutionNeverEntersConsumerAndClearsExactRegistration() async throws {
        let owner = LiveCaptureLifecycle()
        var entries = 0
        let task = try #require(owner.consume { _ in entries += 1 })
        #expect(owner.invalidateConsumer() == task)
        #expect(owner.consumerID == nil)
        #expect(owner.transcriptionTask == task)
        await task.value
        await owner.drain()
        #expect(entries == 0)
        #expect(owner.transcriptionTask == nil)
        #expect(owner.pendingTaskCount == 0)
        #expect(owner.retiringTaskCount == 0)
    }
}

private final class LiveConsumerOperationGate: Sendable {
    private struct State: Sendable {
        var released = false
        var escaped = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var escaped: Bool { state.withLock { $0.escaped } }
    func wait(id: UUID) async {
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
    func close() { entered.continuation.finish() }
}
