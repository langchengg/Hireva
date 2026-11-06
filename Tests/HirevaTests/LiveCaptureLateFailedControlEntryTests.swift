import Foundation
import os
import Testing
@testable import Hireva

/// Actual production APIs: forty fixed orderings use synthetic operations only.
/// Each order/iteration owns one gate, owner and the existing per-case time limit.
@MainActor
struct LiveCaptureLateFailedControlEntryTests {
    @Test(.timeLimit(.minutes(1)), arguments: FailedControlSubmissionOrder.allCases, 0..<20)
    func oldFailureRemainsOwnedAfterNewTeardownAndBlocksFrozenStartup(
        order: FailedControlSubmissionOrder, iteration: Int
    ) async throws {
        let owner = LiveCaptureLifecycle()
        let gate = FailedControlGate()
        let trace = TestEventWaitTrace(label: #function + ".order.\(order.rawValue).iteration.\(iteration)")
        var oldCalls = 0
        var newCalls = 0
        var producerEntries = 0
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let first = owner.queueTeardown(after: nil) { _ in
                    oldCalls += 1
                    await gate.wait()
                    return false
                }
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "old_teardown_operation_entered")
                let replacement: Task<Void, Never>
                let submittedStartup: Task<Void, Never>?
                if order == .startupThenTeardown {
                    submittedStartup = owner.start { _ in producerEntries += 1 }
                    replacement = owner.queueTeardown(after: nil) { _ in newCalls += 1; return true }
                } else {
                    replacement = owner.queueTeardown(after: nil) { _ in newCalls += 1; return true }
                    submittedStartup = owner.start { _ in producerEntries += 1 }
                }
                try #require(submittedStartup != nil,
                    "The first stop is still in flight; this characterizes the post-await failure admission check.")
                gate.release()
                await first.value
                await replacement.value
                await submittedStartup?.value
                await owner.drain()
                try Task.checkCancellation()
                #expect(oldCalls == 1 && newCalls == 1,
                    "Draining/new capture must not implicitly retry the original failed native operation.")
                #expect(owner.hasFailedTeardown,
                    "A late older failure cannot disappear when the newer unrelated teardown completes.")
                #expect(producerEntries == 0,
                    "The submitted startup must recheck all failed cleanup after its frozen prior fence returns.")
                #expect(owner.pendingTaskCount == 0,
                    "Every synthetic Task exited; the false cleanup result must remain a separate observation.")
            } catch {
                gate.release(); owner.closeAdmission(); await owner.drain(); gate.close()
                throw error
            }
            gate.close()
            #expect(!gate.escaped)
        } onCancel: { gate.cancelOwningTest() }
    }
}

enum FailedControlSubmissionOrder: String, CaseIterable, Sendable { case startupThenTeardown, teardownThenStartup }

private final class FailedControlGate: Sendable {
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
