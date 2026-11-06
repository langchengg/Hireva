import AppKit
import Testing
@testable import Hireva

@MainActor
struct AppTerminationLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func repeatedQuitJoinsOneCleanupAndRepliesOnceAfterResourceExit() async throws {
        let fixture = TerminationFixture(label: "repeatedQuit")
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            #expect(fixture.delegate.hasPendingCleanup)
            #expect(fixture.replies.isEmpty)
            await fixture.gate.release(result: true)
            await fixture.delegate.finishPendingCleanup()
            #expect(await fixture.gate.calls == 1)
            #expect(fixture.replies == [true])
            #expect(fixture.delegate.requestTermination() == .terminateNow)
            #expect(fixture.clock.pendingCount == 0)
            #expect(!fixture.delegate.hasPendingCleanup)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineRejectsQuitWhileRetainingNonCooperativeCleanup() async throws {
        let fixture = TerminationFixture(label: "deadlineRejectsQuit")
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            fixture.clock.advance(by: 5_000_000_000)
            try await fixture.waitForReply()
            #expect(fixture.replies == [false])
            #expect(fixture.pendingReports == 1)
            #expect(fixture.delegate.hasPendingCleanup)
            #expect(fixture.delegate.requestTermination() == .terminateLater)
            await fixture.gate.release(result: true)
            await fixture.delegate.finishPendingCleanup()
            #expect(await fixture.gate.calls == 1)
            #expect(fixture.replies == [false, true])
            #expect(!fixture.delegate.hasPendingCleanup)
            #expect(fixture.clock.pendingCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func resourceStopFailureCannotAuthorizeQuit() async throws {
        let fixture = TerminationFixture(label: "resourceStopFailure")
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            await fixture.gate.release(result: false)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.replies == [false])
            #expect(fixture.pendingReports == 1)
            #expect(fixture.delegate.requestTermination() == .terminateLater)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.replies == [false, false], "A second failed stop must still veto exit.")
            #expect(fixture.pendingReports == 2)
            #expect(await fixture.gate.calls == 2)
            #expect(fixture.clock.pendingCount == 0)
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func failedCleanupCanRecoverOnASeparateExplicitQuit() async throws {
        let fixture = TerminationFixture(label: "failureThenRecovery")
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            await fixture.gate.release(result: false)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.replies == [false])
            #expect(!fixture.delegate.hasPendingCleanup)
            // Existing gate updates the next operation's return value. No new
            // waiter or native resource is created after its stream finished.
            await fixture.gate.release(result: true)
            #expect(fixture.delegate.requestTermination() == .terminateLater,
                "A failed cleanup result must not permanently forbid retrying a later explicit quit.")
            await fixture.delegate.finishPendingCleanup()
            #expect(await fixture.gate.calls == 2)
            #expect(fixture.replies == [false, true])
            #expect(fixture.pendingReports == 1)
            #expect(fixture.delegate.requestTermination() == .terminateNow)
            #expect(fixture.clock.pendingCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedFailedCleanupRepliesOncePerExplicitQuitAndNeverAuthorizesExit() async throws {
        let fixture = TerminationFixture(label: "repeatedFailure")
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            await fixture.gate.release(result: false)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.replies == [false])
            #expect(fixture.delegate.requestTermination() == .terminateLater)
            await fixture.delegate.finishPendingCleanup()
            #expect(await fixture.gate.calls == 2)
            #expect(fixture.replies == [false, false])
            #expect(fixture.pendingReports == 2)
            #expect(!fixture.delegate.hasPendingCleanup)
            #expect(fixture.clock.pendingCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func oldDeadlineDeferCannotDiscardAReentrantQuitDeadline() async throws {
        let fixture = TerminationFixture(label: "reentrantDeadline", reenterOnFirstDeniedReply: true)
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            fixture.clock.advance(by: 5_000_000_000)
            try await fixture.waitForReply()
            try await fixture.clock.waitUntilScheduled(minimumCount: 2)
            #expect(fixture.reentrantDecision == .terminateLater)
            #expect(fixture.capturedDeadlines.count == 1,
                "The test retains the exact new deadline before old defer runs, so RED cleanup can join it.")
            await fixture.gate.release(result: true)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.replies == [false, true])
            #expect(await fixture.gate.calls == 1)
            #expect(fixture.clock.pendingCount == 0,
                "Completing cleanup must cancel and join the new timer; the old defer cannot erase its slot.")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completedFailureReplyCanSynchronouslyRetryWithoutLosingTheNewCleanup() async throws {
        let fixture = TerminationFixture(label: "reentrantCompletedFailure", reenterOnFirstDeniedReply: true)
        #expect(fixture.delegate.requestTermination() == .terminateLater)
        try await fixture.run {
            try await fixture.waitForStartup()
            await fixture.gate.release(result: false)
            await fixture.delegate.finishPendingCleanup()
            #expect(fixture.reentrantDecision == .terminateLater)
            #expect(await fixture.gate.calls == 2,
                "The completed failed worker must retire before a callback creates the retry worker.")
            #expect(fixture.replies == [false, false])
            #expect(fixture.pendingReports == 2)
            #expect(!fixture.delegate.hasPendingCleanup)
            #expect(fixture.clock.pendingCount == 0)
        }
    }

}

private actor TerminationGate {
    let trace: TestEventWaitTrace

    init(trace: TestEventWaitTrace) { self.trace = trace }
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var waiter: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private(set) var calls = 0

    func stop() async -> Bool {
        trace.mark("producer.stop.entered")
        defer { trace.mark("producer.stop.return") }
        calls += 1
        let yieldResult = started.continuation.yield(())
        trace.mark("producer.started.yield.\(yieldResult)")
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func release(result: Bool) {
        trace.mark("producer.stop.release.\(result)")
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
        started.continuation.finish()
    }

    func waitUntilStarted() async throws {
        _ = try await trace.nextEvent(in: started.stream, event: "started")
    }
}

@MainActor
private final class TerminationFixture {
    let clock: ControlledGenerationWatchdogClock
    let gate: TerminationGate
    let clockTrace: TestEventWaitTrace
    let replyTrace: TestEventWaitTrace
    let replyEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var replies: [Bool] = []
    private(set) var pendingReports = 0
    private let reenterOnFirstDeniedReply: Bool
    private(set) var reentrantDecision: NSApplication.TerminateReply?
    private(set) var capturedDeadlines: [Task<Void, Never>] = []
    lazy var delegate: AppDelegate = AppDelegate(delayProvider: clock, reply: { [weak self] result in
        self?.replyTrace.mark("producer.reply.entered.\(result)")
        self?.replies.append(result)
        if let self, !result, self.reenterOnFirstDeniedReply, self.replies.count == 1 {
            self.reentrantDecision = self.delegate.requestTermination()
            if let deadline = self.delegate.ownedDeadlineTaskForTesting { self.capturedDeadlines.append(deadline) }
        }
        let yieldResult = self?.replyEvents.continuation.yield(())
        self?.replyTrace.mark("producer.reply.yield.\(String(describing: yieldResult))")
    })

    init(label: String, reenterOnFirstDeniedReply: Bool = false) {
        self.reenterOnFirstDeniedReply = reenterOnFirstDeniedReply
        let gateTrace = TestEventWaitTrace(label: "termination.\(label).gate")
        clockTrace = TestEventWaitTrace(label: "termination.\(label).clock")
        replyTrace = TestEventWaitTrace(label: "termination.\(label).reply")
        clock = ControlledGenerationWatchdogClock(trace: clockTrace)
        gate = TerminationGate(trace: gateTrace)
        delegate.configureShutdown(operation: { [gate] in await gate.stop() },
            reportPending: { [weak self] in self?.pendingReports += 1 })
    }

    func waitForStartup() async throws {
        try await gate.waitUntilStarted()
        clockTrace.mark("consumer.startup_clock.requested")
        defer { clockTrace.mark("consumer.startup_clock.return") }
        try await clock.waitUntilScheduled()
        clockTrace.mark("consumer.startup_clock.event_consumed")
    }

    func waitForReply() async throws {
        _ = try await replyTrace.nextEvent(in: replyEvents.stream, event: "reply")
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
        replyTrace.mark("cleanup.requested")
        defer { replyTrace.mark("cleanup.joined") }
        await gate.release(result: true)
        clock.cancelAll()
        await delegate.finishPendingCleanup()
        // Always release/cancel before joining captured deadlines, including
        // RED where the delegate accidentally lost ownership of the new timer.
        for task in capturedDeadlines { await task.value }
        capturedDeadlines.removeAll()
        replyEvents.continuation.finish()
    }
}

