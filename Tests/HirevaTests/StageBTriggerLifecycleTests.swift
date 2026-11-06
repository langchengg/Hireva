import Foundation
import Testing
@testable import Hireva

@MainActor
struct StageBTriggerLifecycleTests {
    @Test
    func explicitTriggerJoinsCancelledDeadlineBeforeReturning() async throws {
        let clock = ControlledGenerationWatchdogClock()
        let trigger = StageBTrigger(delayProvider: clock)
        let task = Task { await trigger.wait(timeoutMs: 500) }
        do {
            try await clock.waitUntilScheduled()
            trigger.trigger()
            await task.value
            #expect(clock.pendingCount == 0,
                "The Stage B waiter finished, but its timeout operation is still alive.")
        } catch {
            clock.cancelAll()
            trigger.trigger()
            task.cancel()
            await task.value
            throw error
        }
        clock.cancelAll()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func parentCancellationEndsWaitAndJoinsDeadline(cancelBeforeWait: Bool) async throws {
        let trace = TestEventWaitTrace(label: "StageBTrigger.cancelBeforeWait.\(cancelBeforeWait)")
        trace.mark("fixture.created.priority.\(Task.currentPriority.rawValue)")
        let clock = ControlledGenerationWatchdogClock()
        let trigger = StageBTrigger(delayProvider: clock)
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            trace.mark("waiter.entered.priority.\(Task.currentPriority.rawValue)")
            entered.continuation.yield(())
            entered.continuation.finish()
            if cancelBeforeWait { withUnsafeCurrentTask { $0?.cancel() } }
            trace.mark("trigger.wait.begin")
            await trigger.wait(timeoutMs: 500)
            trace.mark("trigger.wait.returned.pending.\(clock.pendingCount)")
            completed.continuation.yield(())
            completed.continuation.finish()
            trace.mark("completion.yielded")
        }
        do {
            // The case time limit bounds logical readiness. MainActor scheduling
            // time is separate from the controlled production deadline below.
            _ = try await trace.nextEvent(in: entered.stream, event: "waiter.entered")
            if !cancelBeforeWait {
                try await clock.waitUntilScheduled()
                trace.mark("business_clock.registered.pending.\(clock.pendingCount)")
                trace.mark("cancellation.requested.priority.\(Task.currentPriority.rawValue)")
                task.cancel()
                trace.mark("cancellation.request.completed")
            }
            // The business clock is never advanced. Case cancellation ends the
            // event wait and enters explicit release/cancel/join cleanup below.
            _ = try await trace.nextEvent(in: completed.stream, event: "waiter.completed")
            trace.mark("completion.observed")
            #expect(clock.pendingCount == 0)
        } catch {
            clock.cancelAll()
            trigger.trigger()
            task.cancel()
            await task.value
            entered.continuation.finish()
            completed.continuation.finish()
            throw error
        }
        clock.cancelAll()
        trigger.trigger()
        task.cancel()
        await task.value
        trace.mark("cleanup.joined.pending.\(clock.pendingCount)")
        entered.continuation.finish()
        completed.continuation.finish()
    }

    @Test
    func timeoutAndRepeatedTriggerFinishOnceWithoutPendingTimer() async throws {
        let clock = ControlledGenerationWatchdogClock()
        let trigger = StageBTrigger(delayProvider: clock)
        let task = Task { await trigger.wait(timeoutMs: 500) }
        do {
            try await clock.waitUntilScheduled()
            clock.advance(by: 499_999_999)
            #expect(clock.pendingCount == 1)
            clock.advance(by: 1)
            await task.value
            trigger.trigger()
            trigger.trigger()
            #expect(clock.pendingCount == 0)
        } catch {
            clock.cancelAll()
            trigger.trigger()
            task.cancel()
            await task.value
            throw error
        }
        clock.cancelAll()
    }

    @Test
    func signalBeforeWaitDoesNotCreateDeadlineWork() async {
        let clock = ControlledGenerationWatchdogClock()
        let trigger = StageBTrigger(delayProvider: clock)
        trigger.trigger()
        await trigger.wait(timeoutMs: 500)
        #expect(clock.requestedNanoseconds.isEmpty)
        #expect(clock.pendingCount == 0)
        clock.cancelAll()
    }
}
