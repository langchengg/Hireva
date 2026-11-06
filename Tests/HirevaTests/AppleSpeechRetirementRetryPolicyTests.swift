import Foundation
import os
import Testing
@testable import Hireva

@Suite("Apple Speech retirement preserves explicit retry authority", .timeLimit(.minutes(1)))
@MainActor
struct AppleSpeechRetirementRetryPolicyTests {
    @Test
    func cancelledHeldStartupDoesNotImplicitlyRetryTheLatchedNativeFailure() async throws {
        try await withRetirementRetryFixture(holdStartup: true) { provider, service, control in
            let start = Task { @MainActor in
                do {
                    _ = try await provider.startTranscription(config: .init(
                        sessionID: "synthetic-held-start", captureMode: .systemAudioOnly))
                    Issue.record("Cancelled held startup unexpectedly returned a stream")
                } catch { #expect(error is CancellationError) }
            }
            control.own(start)
            try await control.waitFor(.startupEntered)
            let stop = Task { @MainActor in await provider.stopTranscription() }
            control.own(stop)
            try await control.waitFor(.stopEntered)
            // The held service deliberately ignores cancellation. A resource
            // failure becomes visible after the initial close, before its join.
            service.latchCaptureFailure()
            control.releaseStartup()
            await start.value
            await stop.value
            #expect(service.explicitRetryCalls == 0)
            #expect(service.captureCleanupFailure != nil)
            #expect(!service.running)
            #expect(provider.hasOwnedTranscriptionWork)
            // Only this subsequent explicit request may retry the failure.
            await provider.stopTranscription()
            #expect(service.explicitRetryCalls == 1)
            #expect(service.captureCleanupFailure == nil)
            #expect(!provider.hasOwnedTranscriptionWork)
        }
    }

    @Test
    func normalSourceFinishDoesNotImplicitlyRetryAnAlreadyLatchedFailure() async throws {
        try await withRetirementRetryFixture(holdStartup: false) { provider, service, control in
            let stream = try await provider.startTranscription(config: .init(
                sessionID: "synthetic-normal-eof", captureMode: .systemAudioOnly))
            service.latchCaptureFailure()
            control.finishSource()
            await provider.waitForCurrentTranscriptionEnd()
            #expect(service.explicitRetryCalls == 0)
            #expect(service.captureCleanupFailure != nil)
            #expect(!service.running)
            #expect(provider.hasOwnedTranscriptionWork)
            await provider.stopTranscription()
            #expect(service.explicitRetryCalls == 1)
            #expect(service.captureCleanupFailure == nil)
            #expect(!provider.hasOwnedTranscriptionWork)
            withExtendedLifetime(stream) {}
        }
    }
}

@MainActor
private func withRetirementRetryFixture(holdStartup: Bool,
    body: @MainActor (AppleSpeechASRProvider, RetirementRetrySpeechService, RetirementRetryControl) async throws -> Void
) async throws {
    let control = RetirementRetryControl(holdStartup: holdStartup)
    let service = RetirementRetrySpeechService(control: control)
    let provider = AppleSpeechASRProvider(service: service)
    @MainActor func cleanup() async {
        // No MainActor hop is required to release the non-cooperative startup.
        // The only budget is the owning test cancellation; no setup sleep/guard.
        control.releaseStartup()
        control.finishSource()
        await provider.stopTranscription()
        for task in control.ownedTasks { await task.value }
        await provider.waitForCurrentTranscriptionEnd()
        #expect(!service.running)
        #expect(service.captureCleanupFailure == nil)
        #expect(!provider.hasOwnedTranscriptionWork)
    }
    try await withTaskCancellationHandler {
        do { try await body(provider, service, control) }
        catch { await cleanup(); throw error }
        await cleanup()
    } onCancel: { control.cancelOwningTest() }
}

@MainActor
private final class RetirementRetrySpeechService: AppleSpeechProviderService {
    private let control: RetirementRetryControl
    var segments: AsyncStream<TranscriptSegment> { control.source }
    var terminalError: Error? { nil }
    private(set) var captureCleanupFailure: Error?
    private(set) var running = false
    private(set) var explicitRetryCalls = 0
    init(control: RetirementRetryControl) { self.control = control }
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws {
        await control.enterStartup()
        running = true
    }
    func stop() { stop(retryFailedResource: true) }
    // This fake already has the future overload while still conforming to the
    // current protocol. RED invokes the real provider's existing stop() sites.
    func stop(retryFailedResource: Bool) {
        running = false
        control.stopped()
        if retryFailedResource, captureCleanupFailure != nil {
            explicitRetryCalls += 1
            captureCleanupFailure = nil
        }
    }
    func finishStoppingAudioInput() async {}
    func latchCaptureFailure() { captureCleanupFailure = RetirementRetryFailure.nativeStopRejected }
}

private enum RetirementRetryFailure: Error, Sendable { case nativeStopRejected }
private enum RetirementRetryEvent: Equatable, Sendable { case startupEntered, stopEntered }

/// This checked value leaf owns only immutable stream handles, Swift tasks and
/// one continuation; it can release every fixture latch from cancellation.
private final class RetirementRetryControl: Sendable {
    private struct State: Sendable {
        let holdStartup: Bool
        var released = false
        var cancelled = false
        var startupWaiters: [CheckedContinuation<Void, Never>] = []
        var tasks: [Task<Void, Never>] = []
    }
    private let state: OSAllocatedUnfairLock<State>
    private let sourcePair = AsyncStream<TranscriptSegment>.makeStream()
    private let eventPair = AsyncStream<RetirementRetryEvent>.makeStream()
    var source: AsyncStream<TranscriptSegment> { sourcePair.stream }
    var ownedTasks: [Task<Void, Never>] { state.withLock { $0.tasks } }
    init(holdStartup: Bool) { state = OSAllocatedUnfairLock(initialState: State(holdStartup: holdStartup)) }
    func own(_ task: Task<Void, Never>) {
        let cancel = state.withLock { value in value.tasks.append(task); return value.cancelled }
        if cancel { task.cancel() }
    }
    func enterStartup() async {
        eventPair.continuation.yield(.startupEntered)
        guard state.withLock({ $0.holdStartup }) else { return }
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                if value.released { return true }
                value.startupWaiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func stopped() { eventPair.continuation.yield(.stopEntered) }
    func finishSource() { sourcePair.continuation.finish() }
    func waitFor(_ expected: RetirementRetryEvent) async throws {
        for await event in eventPair.stream {
            if event == expected { return }
        }
        throw CancellationError()
    }
    func releaseStartup() {
        let waiters = state.withLock { value in
            value.released = true
            let result = value.startupWaiters
            value.startupWaiters.removeAll()
            return result
        }
        for waiter in waiters { waiter.resume() }
    }
    func cancelOwningTest() {
        let action = state.withLock { value in
            value.cancelled = true
            value.released = true
            let waiters = value.startupWaiters
            value.startupWaiters.removeAll()
            return (waiters, value.tasks)
        }
        for waiter in action.0 { waiter.resume() }
        sourcePair.continuation.finish()
        eventPair.continuation.finish()
        for task in action.1 { task.cancel() }
    }
}
