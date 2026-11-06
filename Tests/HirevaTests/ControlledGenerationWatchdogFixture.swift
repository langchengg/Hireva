import Foundation
@testable import Hireva

/// Advances only when a test chooses a deadline ordering. Cancellation resumes
/// each owned continuation, including cancellation before registration.
final class ControlledGenerationWatchdogClock: DelayProvider, @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let requestedNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeRegistration = Set<UUID>()
    private var completed = Set<UUID>()
    private var stopped = false
    private var requestedStorage: [UInt64] = []
    private let registrations: AsyncStream<Void>
    private let registrationContinuation: AsyncStream<Void>.Continuation
    private let trace: TestEventWaitTrace?
    private let onRegistrationWaitEntered: (@Sendable () -> Void)?

    init(trace: TestEventWaitTrace? = nil,
        onRegistrationWaitEntered: (@Sendable () -> Void)? = nil) {
        self.trace = trace
        self.onRegistrationWaitEntered = onRegistrationWaitEntered
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        registrations = pair.stream
        registrationContinuation = pair.continuation
    }

    var requestedNanoseconds: [UInt64] { lock.withLock { requestedStorage } }
    var pendingCount: Int { lock.withLock { sleepers.count } }
    var pendingNanoseconds: [UInt64] { lock.withLock { sleepers.values.map(\.requestedNanoseconds) } }

    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        trace?.mark("clock.sleep.requested.\(nanoseconds).id.\(id.uuidString)")
        defer { trace?.mark("clock.sleep.return.id.\(id.uuidString)") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    if stopped || cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                        completed.insert(id)
                        return true
                    }
                    requestedStorage.append(nanoseconds)
                    let addition = now.addingReportingOverflow(nanoseconds)
                    sleepers[id] = Sleeper(deadline: addition.overflow ? .max : addition.partialValue,
                        requestedNanoseconds: nanoseconds, continuation: continuation)
                    return false
                }
                if cancelled {
                    trace?.mark("clock.sleep.registration_cancelled.id.\(id.uuidString)")
                    continuation.resume(throwing: CancellationError())
                } else {
                    trace?.mark("clock.sleep.registered.\(nanoseconds).id.\(id.uuidString)")
                    let result = registrationContinuation.yield(())
                    trace?.mark("producer.clock_registration.yield.\(result)")
                }
            }
        } onCancel: {
            self.trace?.mark("clock.sleep.cancel_requested.id.\(id.uuidString)")
            let continuation = self.lock.withLock {
                guard !self.completed.contains(id) else { return nil as CheckedContinuation<Void, Error>? }
                if let sleeper = self.sleepers.removeValue(forKey: id) {
                    self.completed.insert(id)
                    return sleeper.continuation
                }
                self.cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilScheduled(minimumCount: Int = 1) async throws {
        precondition(minimumCount > 0)
        try Task.checkCancellation()
        trace?.mark("consumer.clock_registration.requested.minimum.\(minimumCount)")
        defer { trace?.mark("consumer.clock_registration.return") }
        if requestedNanoseconds.count >= minimumCount {
            try Task.checkCancellation()
            trace?.mark("consumer.clock_registration.already_ready")
            return
        }
        onRegistrationWaitEntered?()
        for await _ in registrations {
            trace?.mark("consumer.clock_registration.event_consumed")
            try Task.checkCancellation()
            if requestedNanoseconds.count >= minimumCount {
                try Task.checkCancellation()
                return
            }
        }
        throw CancellationError()
    }

    /// Historical requests include cancelled timers. A controlled advance must
    /// wait for the currently owned sleeper, rather than that history count.
    func waitUntilPending(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if pendingNanoseconds.contains(nanoseconds) { trace?.mark("clock.pending.ready.\(nanoseconds)"); return }
        for await _ in registrations {
            try Task.checkCancellation()
            if pendingNanoseconds.contains(nanoseconds) { trace?.mark("clock.pending.ready.\(nanoseconds)"); return }
        }
        throw CancellationError()
    }

    func advance(by nanoseconds: UInt64) {
        trace?.mark("clock.advance.requested.\(nanoseconds)")
        let ready = lock.withLock {
            let addition = now.addingReportingOverflow(nanoseconds)
            now = addition.overflow ? .max : addition.partialValue
            let ids = sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { id -> CheckedContinuation<Void, Error>? in
                completed.insert(id)
                return sleepers.removeValue(forKey: id)?.continuation
            }
        }
        trace?.mark("clock.advance.resume_count.\(ready.count)")
        ready.forEach { $0.resume() }
    }

    func cancelAll() {
        trace?.mark("clock.cancel_all.requested")
        let pending = lock.withLock {
            stopped = true
            let pending = sleepers.values.map(\.continuation)
            completed.formUnion(sleepers.keys)
            sleepers.removeAll()
            return pending
        }
        trace?.mark("clock.cancel_all.resume_count.\(pending.count)")
        pending.forEach { $0.resume(throwing: CancellationError()) }
        registrationContinuation.finish()
    }
}

/// No unstructured cleanup from defer/deinit. The fixture captures generation
/// handles, asks the app to cancel, then joins the captured tasks explicitly.
@MainActor
struct ControlledGenerationWatchdogFixture {
    let app: AppState
    let clock: ControlledGenerationWatchdogClock

    init(app: AppState) {
        self.app = app
        clock = ControlledGenerationWatchdogClock()
        app.generationWatchdogDelayProvider = clock
    }

    func run<Result>(_ body: @MainActor () async throws -> Result) async throws -> Result {
        do {
            let result = try await body()
            await shutdown()
            return result
        } catch {
            await shutdown()
            throw error
        }
    }

    private func shutdown() async {
        let request = app.generationCoordinator.requestTask
        let stageA = app.generationCoordinator.stageATask
        let stageB = app.generationCoordinator.stageBTask
        let watchdog = app.generationCoordinator.fullCardWatchdogTask
        let fallback = app.generationCoordinator.fallbackWatchdogTask
        // Release the test latch before awaiting joins, including cleanup after
        // an assertion/throw; a broken cancellation path cannot strand this clock.
        clock.cancelAll()
        await app.shutdownForTesting()
        await request?.value
        _ = try? await stageA?.value
        await stageB?.value
        await watchdog?.value
        await fallback?.value
    }
}
