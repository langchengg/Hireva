import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationDeadlineClockTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func providerDeadlineUsesOwnedClockAndReleasesOperation(parentCancels: Bool) async throws {
        let app = AppState(database: try TestSupport.makeTemporaryDatabase(prefix: "GenerationDeadlineClock"),
            questionRoutingProvider: HermeticQuestionRoutingProvider(), permissionService: HermeticPermissionService())
        let trace = TestEventWaitTrace(label: "generationDeadline.parentCancels.\(parentCancels)")
        let clock = ControlledGenerationWatchdogClock(trace: trace)
        app.generationWatchdogDelayProvider = clock
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let request = Task {
            trace.mark("producer.request.entered")
            defer { trace.mark("producer.request.return") }
            try await app.withTimeout(seconds: 1) {
                trace.mark("producer.operation.entered")
                defer { trace.mark("producer.operation.return") }
                for await _ in events {}
                try Task.checkCancellation()
            }
        }
        do {
            // The test's timeLimit bounds readiness and cleanup. Only the owned
            // clock determines the provider's one-second business deadline.
            trace.mark("consumer.registration.requested")
            try await clock.waitUntilScheduled()
            trace.mark("consumer.registration.event_consumed")
            trace.mark("consumer.registration.return")
            #expect(clock.requestedNanoseconds == [1_000_000_000])
            clock.advance(by: 999_999_999)
            #expect(clock.pendingCount == 1)
            if parentCancels { request.cancel() }
            else { clock.advance(by: 1) }
            switch await request.result {
            case .success: Issue.record("An expired or cancelled provider operation must not succeed.")
            case .failure(let error):
                if parentCancels { #expect(error is CancellationError) }
                else { #expect((error as NSError).domain == "TimeoutDomain") }
            }
            #expect(clock.pendingCount == 0)
        } catch {
            trace.mark("cleanup.error.requested")
            request.cancel()
            clock.cancelAll()
            continuation.finish()
            _ = await request.result
            await app.shutdownForTesting()
            trace.mark("cleanup.error.joined")
            throw error
        }
        trace.mark("cleanup.normal.requested")
        request.cancel()
        clock.cancelAll()
        continuation.finish()
        _ = await request.result
        await app.shutdownForTesting()
        trace.mark("cleanup.normal.joined")
    }
}

