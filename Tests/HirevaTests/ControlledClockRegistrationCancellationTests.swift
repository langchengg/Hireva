import Foundation
import Testing
@testable import Hireva

@MainActor
struct ControlledClockRegistrationCancellationTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeAlreadyReadyWaitCannotReturnSuccess() async throws {
        let fixture = RegistrationCancellationFixture(label: "beforeAlreadyReady")
        try await fixture.run {
            fixture.sleeper = Task { try await fixture.clock.sleep(nanoseconds: 1_000_000_000) }
            try await fixture.clock.waitUntilScheduled()
            #expect(fixture.clock.requestedNanoseconds == [1_000_000_000])
            // This task inherits MainActor. Cancellation is requested before the
            // current actor job yields, so the already-ready branch runs cancelled.
            let waiter = Task { try await fixture.clock.waitUntilScheduled() }
            fixture.waiter = waiter
            waiter.cancel()
            switch await waiter.result {
            case .success: Issue.record("A cancelled readiness wait must not report success.")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(fixture.clock.pendingCount == 1)
        }
        #expect(fixture.clock.pendingCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringPendingRegistrationEndsActualWait() async throws {
        let fixture = RegistrationCancellationFixture(label: "duringPending")
        try await fixture.run {
            let waiter = Task { try await fixture.clock.waitUntilScheduled() }
            fixture.waiter = waiter
            try await fixture.waitUntilWaitEntered()
            #expect(fixture.clock.requestedNanoseconds.isEmpty)
            waiter.cancel()
            switch await waiter.result {
            case .success: Issue.record("Cancelling a pending readiness wait must not report success.")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(fixture.clock.pendingCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func prematureClockFinishCannotInventARegistration() async throws {
        let fixture = RegistrationCancellationFixture(label: "prematureFinish")
        try await fixture.run {
            let waiter = Task { try await fixture.clock.waitUntilScheduled() }
            fixture.waiter = waiter
            try await fixture.waitUntilWaitEntered()
            fixture.clock.cancelAll()
            #expect(!waiter.isCancelled)
            switch await waiter.result {
            case .success: Issue.record("An ended registration stream without a registration must not report success.")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(fixture.clock.requestedNanoseconds.isEmpty)
            #expect(fixture.clock.pendingCount == 0)
        }
    }
}

@MainActor
private final class RegistrationCancellationFixture {
    let trace: TestEventWaitTrace
    let clock: ControlledGenerationWatchdogClock
    private let waitEntered: AsyncStream<Void>
    private let waitEnteredContinuation: AsyncStream<Void>.Continuation
    var sleeper: Task<Void, Error>?
    var waiter: Task<Void, Error>?

    init(label: String) {
        trace = TestEventWaitTrace(label: "clockRegistration.\(label)")
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waitEntered = pair.stream
        waitEnteredContinuation = pair.continuation
        clock = ControlledGenerationWatchdogClock(trace: trace,
            onRegistrationWaitEntered: { pair.continuation.yield(()) })
    }

    func waitUntilWaitEntered() async throws {
        _ = try await trace.nextEvent(in: waitEntered, event: "wait_entered")
    }

    func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    private func cleanup() async {
        trace.mark("cleanup.requested")
        clock.cancelAll()
        waitEnteredContinuation.finish()
        waiter?.cancel()
        sleeper?.cancel()
        _ = await waiter?.result
        _ = await sleeper?.result
        trace.mark("cleanup.joined")
    }
}
