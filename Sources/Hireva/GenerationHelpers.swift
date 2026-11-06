import Foundation

/// One Stage B waiter owns its deadline until that operation actually exits.
/// Stream cancellation wakes the waiter without a cross-executor cleanup task.
@MainActor
final class StageBTrigger {
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let delayProvider: DelayProvider
    private var triggered = false
    private var deadlineTask: Task<Void, Never>?

    init(delayProvider: DelayProvider = RealDelayProvider()) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = pair.stream
        continuation = pair.continuation
        self.delayProvider = delayProvider
    }

    func wait(timeoutMs: Int) async {
        guard !triggered, !Task.isCancelled else { return }
        let continuation = continuation
        let delayProvider = delayProvider
        let deadline = Task {
            do {
                try await delayProvider.sleep(nanoseconds: UInt64(max(timeoutMs, 0)) * 1_000_000)
                try Task.checkCancellation()
                continuation.yield(())
                continuation.finish()
            } catch is CancellationError {
                // The waiter cancels and joins this operation before returning.
            } catch {
                // A clock failure releases Stage B just like the old fallback;
                // provider/output validation still decides whether it may publish.
                continuation.finish()
            }
        }
        deadlineTask = deadline
        var iterator = signal.makeAsyncIterator()
        _ = await iterator.next()
        deadline.cancel()
        await deadline.value
        deadlineTask = nil
        triggered = true
        continuation.finish()
    }

    func trigger() {
        guard !triggered else { return }
        triggered = true
        continuation.yield(())
        continuation.finish()
    }

    deinit {
        deadlineTask?.cancel()
        continuation.finish()
    }
}

public protocol DelayProvider: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public final class RealDelayProvider: DelayProvider {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
