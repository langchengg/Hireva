import Foundation
import os
import Testing
@testable import Hireva

/// New retry API characterization. Both callers share one controlled attempt;
/// borrower cancellation cannot force the concrete operation to exit.
@MainActor
struct LiveCaptureFailedOperationRetryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func concurrentExplicitRetriesJoinOneAttemptWithoutRetryingItsNewFailure(retrySucceeds: Bool) async throws {
        let owner = LiveCaptureLifecycle()
        let gate = FailedRetryOperationGate()
        let secondEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var calls = 0
        var authorizations: [Bool] = []
        var operationIDs: [UUID] = []
        var firstBorrower: Task<Void, Never>?
        var secondBorrower: Task<Void, Never>?
        var secondCompleted = false
        try await withTaskCancellationHandler {
            do {
                let initial = owner.queueTeardown(after: nil) { id, retryAuthorized in
                    calls += 1
                    authorizations.append(retryAuthorized)
                    operationIDs.append(id)
                    if calls == 1 { return false }
                    if calls == 2 { await gate.wait(); return retrySucceeds }
                    return true
                }
                await initial.value
                await owner.drain()
                #expect(owner.hasFailedTeardown)
                #expect(authorizations == [false], "Initial close/join does not authorize native failure retry.")
                firstBorrower = Task { @MainActor in await owner.retryFailedTeardowns() }
                _ = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: gate.entered.stream, event: "exact_retry_operation_entered")
                let actualRetry = try #require(owner.teardownTask)
                #expect(actualRetry != initial)
                #expect(owner.hasFailedTeardown,
                    "The failed native resource remains unreleased while its authorized retry is running.")
                #expect(owner.start(operation: { _ in Issue.record("Failed cleanup admitted a new capture") }) == nil)
                secondBorrower = Task { @MainActor in
                    secondEntered.continuation.yield(())
                    await owner.retryFailedTeardowns()
                    secondCompleted = true
                }
                _ = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: secondEntered.stream, event: "concurrent_explicit_join_entered")
                #expect(!secondCompleted)
                #expect(calls == 2)
                #expect(authorizations == [false, true])
                #expect(operationIDs[0] == operationIDs[1])
                firstBorrower?.cancel()
                #expect(!actualRetry.isCancelled,
                    "Cancelling a borrower must not cancel the retained native cleanup attempt.")
                gate.release()
                await firstBorrower?.value
                await secondBorrower?.value
                await owner.drain()
                #expect(secondCompleted)
                #expect(calls == 2,
                    "A concurrent joiner cannot turn the retry's new failure into another implicit attempt.")
                #expect(owner.hasFailedTeardown == !retrySucceeds)
                #expect(owner.pendingTaskCount == 0)
                if !retrySucceeds {
                    await owner.retryFailedTeardowns()
                    await owner.drain()
                    #expect(calls == 3)
                    #expect(authorizations == [false, true, true])
                    #expect(operationIDs.allSatisfy { $0 == operationIDs[0] })
                }
                #expect(!owner.hasFailedTeardown)
                #expect(owner.failedTeardownCount == 0)
                #expect(owner.teardownTask == nil)
                #expect(owner.retiringTaskCount == 0)
            } catch {
                gate.release(); owner.closeAdmission()
                await firstBorrower?.value; await secondBorrower?.value; await owner.drain()
                gate.close(); secondEntered.continuation.finish()
                throw error
            }
            gate.release(); await owner.drain()
            await firstBorrower?.value; await secondBorrower?.value
            gate.close(); secondEntered.continuation.finish()
            #expect(!gate.escaped)
        } onCancel: {
            gate.cancelOwningTest(); secondEntered.continuation.finish()
        }
    }
}

private final class FailedRetryOperationGate: Sendable {
    private struct State: Sendable {
        var released = false
        var escaped = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var escaped: Bool { state.withLock { $0.escaped } }
    func wait() async {
        entered.continuation.yield(())
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
        release(); entered.continuation.finish()
    }
    func close() { entered.continuation.finish() }
}
