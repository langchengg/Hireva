import Foundation
import os
import Testing
@testable import Hireva

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualFixtureJoinCancellationTests {
    @Test
    func cancellationOfPendingWaitAllowsCallerToReleaseItsRootLatch() async throws {
        let fixture = try await ManualSnapshotFixture()
        let gate = ManualFixtureJoinGate()
        let root = Task { await gate.hold() }
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiter = Task {
            do {
                try await fixture.join(root, onWaitEntered: {
                    entered.continuation.yield(())
                    entered.continuation.finish()
                })
                Issue.record("A cancelled pending wait must propagate cancellation.")
            } catch {
                #expect(error is CancellationError)
            }
        }
        try await withTaskCancellationHandler {
            do {
                _ = try await TestEventWaitTrace(label: "fixture.join.entered")
                    .nextEvent(in: entered.stream, event: "entered")
                waiter.cancel()
                // The root has not been released. Returning here proves the caller
                // can open its latch before fixture.close actually joins the root.
                await waiter.value
                #expect(root.isCancelled)
                gate.release()
                try await fixture.close([])
            } catch {
                waiter.cancel()
                gate.release()
                await waiter.value
                try? await fixture.close([root])
                throw error
            }
        } onCancel: {
            // Release synchronously even if the fixture regresses to awaiting
            // a noncooperative root. No cleanup task is spawned or left unowned.
            gate.release()
            waiter.cancel()
            root.cancel()
            entered.continuation.finish()
        }
    }

    @Test
    func cancellationBeforeJoinStillCancelsTheRetainedRoot() async throws {
        let fixture = try await ManualSnapshotFixture()
        let gate = ManualFixtureJoinGate()
        let root = Task { await gate.hold() }
        let waiter = Task {
            do {
                try await fixture.join(root)
                Issue.record("A cancelled fixture wait must propagate cancellation.")
            } catch {
                #expect(error is CancellationError)
            }
        }
        // No MainActor suspension: cancellation precedes join's first instruction.
        waiter.cancel()
        try await withTaskCancellationHandler {
            await waiter.value
            #expect(root.isCancelled,
                "The fixture must cancel the original root even when the waiter was already cancelled.")
            // Always release the noncooperative test latch before joining.
            gate.release()
            try await fixture.close([root])
        } onCancel: {
            gate.release()
            waiter.cancel()
            root.cancel()
        }
    }
}

private final class ManualFixtureJoinGate: Sendable {
    private struct State: Sendable {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func hold() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                if state.released { return true }
                state.continuation = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }

    func release() {
        let held = state.withLock { state in
            state.released = true
            let held = state.continuation
            state.continuation = nil
            return held
        }
        held?.resume()
    }
}
