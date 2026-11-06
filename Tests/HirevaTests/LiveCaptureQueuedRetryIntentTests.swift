import Foundation
import os
import Testing
@testable import Hireva

/// Twenty independent schedules: five native phases at submission crossed
/// with no, monitor, startup, or both exact cleanup fences. No real audio.
@MainActor
struct LiveCaptureQueuedRetryIntentTests {
    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func queuedPublicStopFreezesRetryAuthorizationBeforeAnyFence(order: Int) async throws {
        let phase = SubmissionPhase(rawValue: order % 5)!
        let fences = order / 5
        let owner = LiveCaptureLifecycle()
        let native = QueuedRetryIntentGate()
        let monitor = QueuedRetryIntentGate()
        let startup = QueuedRetryIntentGate()
        let progress = AsyncStream<QueuedStopProgress>.makeStream(bufferingPolicy: .bufferingOldest(2))
        var originalIDs: [UUID] = []
        var originalAuthorizations: [Bool] = []
        var currentIDs: [UUID] = []
        var currentAuthorizations: [Bool] = []
        var originalCallsAtCurrentEntry: [Int] = []
        var initialTask: Task<Void, Never>?
        var retiredReplacement: Task<Void, Never>?
        var retryBorrower: Task<Void, Never>?
        var monitorFence: Task<Void, Never>?
        var startupFence: Task<Void, Never>?
        var submittedStop: Task<Void, Never>?
        var laterStop: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                initialTask = owner.queueTeardown(after: nil) { id, retryAuthorized in
                    originalIDs.append(id)
                    originalAuthorizations.append(retryAuthorized)
                    let call = originalIDs.count
                    if phase == .initialPending, call == 1 { await native.wait() }
                    if call == 1 { return false }
                    if call == 2 {
                        if phase == .failedCurrent || phase == .failedRetired {
                            progress.continuation.yield(.retainedNativeAttemptEntered)
                        }
                        await native.wait()
                        return phase != .retryingFailure
                    }
                    return true
                }
                if phase == .initialPending {
                    _ = try await TestEventWaitTrace(label: #function)
                        .nextEvent(in: native.entered.stream, event: "initial_native_stop_pending")
                } else {
                    await initialTask?.value
                    await owner.drain()
                    #expect(owner.hasFailedTeardown)
                    if phase == .failedRetired {
                        retiredReplacement = owner.queueTeardown(after: nil) { _, retryAuthorized in
                            #expect(!retryAuthorized)
                            return true
                        }
                        await retiredReplacement?.value
                        await owner.drain()
                        #expect(owner.hasFailedTeardown,
                            "An unrelated successful stop cannot release the original native resource.")
                    }
                    if phase.isRetrying {
                        retryBorrower = Task { @MainActor in await owner.retryFailedTeardowns() }
                        _ = try await TestEventWaitTrace(label: #function)
                            .nextEvent(in: native.entered.stream, event: "authorized_native_retry_pending")
                        #expect(originalAuthorizations == [false, true])
                    }
                }
                let originalID = try #require(originalIDs.first)
                if fences == 1 || fences == 3 {
                    monitorFence = Task { @MainActor in await monitor.wait() }
                    _ = try await TestEventWaitTrace(label: #function)
                        .nextEvent(in: monitor.entered.stream, event: "monitor_fence_registered")
                }
                if fences == 2 || fences == 3 {
                    startupFence = Task { @MainActor in await startup.wait() }
                    _ = try await TestEventWaitTrace(label: #function)
                        .nextEvent(in: startup.entered.stream, event: "startup_fence_registered")
                }
                submittedStop = owner.queueTeardown(
                    after: startupFence, quiescing: monitorFence, retryRetainedFailures: true
                ) { id, retryAuthorized in
                    progress.continuation.yield(.currentOperationEntered)
                    currentIDs.append(id)
                    currentAuthorizations.append(retryAuthorized)
                    originalCallsAtCurrentEntry.append(originalIDs.count)
                    return true
                }
                #expect(currentIDs.isEmpty)
                #expect(originalAuthorizations.first == false)
                // Reverse the physical release order for the two-fence case;
                // the owner must still respect its monitor->startup await order.
                if fences == 3 { startup.release(); await startupFence?.value }
                monitor.release(); await monitorFence?.value
                startup.release(); await startupFence?.value
                if phase == .failedCurrent || phase == .failedRetired {
                    let first = try await TestEventWaitTrace(label: #function)
                        .nextEvent(in: progress.stream, event: "retained_retry_or_current_operation")
                    try #require(first == .retainedNativeAttemptEntered,
                        "The new operation ran without retrying the failed resource frozen at submission.")
                    #expect(currentIDs.isEmpty,
                        "The current operation must await the frozen batch's real attempt exit.")
                }
                if phase.isRetrying, fences.isMultiple(of: 2) { retryBorrower?.cancel() }
                native.release()
                await submittedStop?.value
                await retryBorrower?.value
                await owner.drain()
                let expectedOriginalCalls = phase == .initialPending ? 1 : 2
                #expect(originalCallsAtCurrentEntry == [expectedOriginalCalls],
                    "The frozen failed batch must be joined/retried before this stop's operation runs.")
                #expect(originalIDs.count == expectedOriginalCalls)
                #expect(currentAuthorizations == [false],
                    "The newly submitted operation is an initial close, not a native retry.")
                #expect(currentIDs.count == 1)
                #expect(currentIDs.first != originalID)
                #expect(originalIDs.allSatisfy { $0 == originalID })
                #expect(originalAuthorizations == (phase == .initialPending ? [false] : [false, true]))
                let failureMustRemain = phase == .initialPending || phase == .retryingFailure
                #expect(owner.hasFailedTeardown == failureMustRemain,
                    "A request admitted during an initial attempt or retry cannot authorize its new failure.")
                #expect(owner.pendingTaskCount == 0)
                if failureMustRemain {
                    laterStop = owner.queueTeardown(after: nil, retryRetainedFailures: true) { _, retryAuthorized in
                        #expect(!retryAuthorized)
                        return true
                    }
                    await laterStop?.value
                    await owner.drain()
                    #expect(originalIDs.count == expectedOriginalCalls + 1)
                    #expect(originalAuthorizations.last == true)
                    #expect(originalIDs.allSatisfy { $0 == originalID })
                }
                #expect(!owner.hasFailedTeardown)
                #expect(owner.failedTeardownCount == 0)
                #expect(owner.pendingTaskCount == 0)
                #expect(owner.teardownTask == nil)
                #expect(owner.retiringTaskCount == 0)
            } catch {
                native.release(); monitor.release(); startup.release(); owner.closeAdmission()
                await initialTask?.value; await retiredReplacement?.value; await retryBorrower?.value
                await monitorFence?.value; await startupFence?.value
                await submittedStop?.value; await laterStop?.value; await owner.drain()
                native.close(); monitor.close(); startup.close(); progress.continuation.finish()
                throw error
            }
            native.release(); monitor.release(); startup.release(); owner.closeAdmission()
            await initialTask?.value; await retiredReplacement?.value; await retryBorrower?.value
            await monitorFence?.value; await startupFence?.value
            await submittedStop?.value; await laterStop?.value; await owner.drain()
            native.close(); monitor.close(); startup.close(); progress.continuation.finish()
            #expect(!native.escaped && !monitor.escaped && !startup.escaped)
        } onCancel: {
            native.cancelOwningTest(); monitor.cancelOwningTest(); startup.cancelOwningTest()
            progress.continuation.finish()
        }
    }
}

private enum QueuedStopProgress: Sendable, Equatable {
    case retainedNativeAttemptEntered, currentOperationEntered
}

private enum SubmissionPhase: Int, Sendable {
    case failedCurrent, failedRetired, initialPending, retryingSuccess, retryingFailure
    var isRetrying: Bool { self == .retryingSuccess || self == .retryingFailure }
}

private final class QueuedRetryIntentGate: Sendable {
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
