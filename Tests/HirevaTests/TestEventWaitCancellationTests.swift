import Foundation
import Testing
@testable import Hireva

struct TestEventWaitCancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationEndsOwnedEventWait(cancelBeforeWait: Bool) async throws {
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let trace = TestEventWaitTrace(label: "test_wait_cancellation_\(cancelBeforeWait)")
        let waiter = Task {
            if cancelBeforeWait { withUnsafeCurrentTask { $0?.cancel() } }
            entered.continuation.yield(())
            _ = try await trace.nextEvent(in: events.stream, event: "blocked")
        }
        do {
            _ = try await trace.nextEvent(in: entered.stream, event: "entered")
            waiter.cancel()
            switch await waiter.result {
            case .success:
                Issue.record("A cancelled readiness waiter reported success without an event.")
            case .failure(let error):
                #expect(error is CancellationError)
            }
        } catch {
            events.continuation.finish()
            entered.continuation.finish()
            waiter.cancel()
            _ = await waiter.result
            throw error
        }
        events.continuation.finish()
        entered.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func finishedStreamCannotMasqueradeAsReadiness() async throws {
        let events = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events.continuation.finish()
        let trace = TestEventWaitTrace(label: "test_wait_ended")
        do {
            _ = try await trace.nextEvent(in: events.stream, event: "ended")
            Issue.record("No event was delivered, but the readiness wait reported success.")
        } catch TestEventWaitFailure.endedBeforeEvent {
            // A producer finishing without its event is a failure, not SKIP/PASS.
        }
    }
}
