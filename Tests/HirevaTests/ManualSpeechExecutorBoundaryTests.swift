import Foundation
import Testing
@testable import Hireva

// Keep compatibility-hook tests inside the existing serialized suite, rather
// than create a second suite racing the same three legacy hooks. The remaining
// feature tests use per-instance capabilities and do not share these hooks.
extension ManualCaptureTests {
    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func oldManualSpeechStartupCannotReturnSuccessAfterReplacement(order: Int) async throws {
        let service = ManualQuestionTranscriptionService(finalizeDelayProvider: RealDelayProvider())
        let gate = ManualSpeechBoundaryGate()
        var finals: [(String) -> Void] = []
        var received: [String] = []
        var old: Task<Void, Error>?
        resetManualExecutorHooks()
        defer { resetManualExecutorHooks() }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, final, _ in
            finals.append(final)
            if finals.count == 1 { await gate.wait() }
        }
        do {
            old = Task {
                try await service.startTranscription(onPartialResult: { _ in },
                    onFinalResult: { received.append($0) }, onError: { _ in })
            }
            try await manualBoundaryEntered(gate)
            if order.isMultiple(of: 2) { service.cancel() }
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            let first = try #require(finals.first)
            let current = try #require(finals.last)
            first("STALE_MANUAL_START")
            current("CURRENT_MANUAL_START")
            await gate.release()
            let result = await (try #require(old)).result
            switch result {
            case .success: Issue.record("Replaced startup returned success instead of CancellationError")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(received == ["CURRENT_MANUAL_START"])
            service.cancel()
        } catch {
            service.cancel()
            await gate.release()
            old?.cancel()
            _ = await old?.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func cancelledManualMockFinalizerCannotReturnLateTextFromOldRound(order: Int) async throws {
        let service = ManualQuestionTranscriptionService(finalizeDelayProvider: RealDelayProvider())
        let gate = ManualSpeechBoundaryGate()
        var finals: [(String) -> Void] = []
        var received: [String] = []
        var old: Task<String, Error>?
        resetManualExecutorHooks()
        defer { resetManualExecutorHooks() }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, final, _ in finals.append(final) }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            // Deliberately ignores cancellation until the fixture releases it.
            // This is an opaque adapter contract, not a native Speech result.
            await gate.wait()
            return "STALE_MANUAL_FINALIZER"
        }
        do {
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            old = Task { try await service.endAudioAndFinalize() }
            try await manualBoundaryEntered(gate)
            if order.isMultiple(of: 2) { old?.cancel() }
            else { service.cancel() }
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            let staleCallback = try #require(finals.first)
            let currentCallback = try #require(finals.last)
            staleCallback("STALE_MANUAL_CALLBACK")
            currentCallback("CURRENT_MANUAL_FINALIZER")
            await gate.release()
            let result = await (try #require(old)).result
            switch result {
            case .success: Issue.record("Revoked finalizer returned old text as a successful result")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(received == ["CURRENT_MANUAL_FINALIZER"])
            service.cancel()
        } catch {
            service.cancel()
            await gate.release()
            old?.cancel()
            _ = await old?.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationOfRegisteredManualWaiterCannotCleanReplacementSpeech() async throws {
        let clock = ControlledGenerationWatchdogClock(trace: TestEventWaitTrace(label: "manual-speech-executor.waiter-clock"))
        let service = ManualQuestionTranscriptionService(finalizeDelayProvider: clock)
        var finals: [(String) -> Void] = []
        var received: [String] = []
        var old: Task<String, Error>?
        resetManualExecutorHooks()
        defer { resetManualExecutorHooks() }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, final, _ in finals.append(final) }
        do {
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            old = Task { try await service.endAudioAndFinalize(timeoutSeconds: 1) }
            try await clock.waitUntilScheduled()
            #expect(clock.pendingCount == 1)
            // No suspension: replacement must be installed before the old
            // cancelled owner resumes its actor-isolated cleanup.
            old?.cancel()
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            let currentCallback = try #require(finals.last)
            currentCallback("CURRENT_WAIT_REPLACEMENT")
            let result = await (try #require(old)).result
            switch result {
            case .success: Issue.record("Cancelled continuation waiter returned success")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(received == ["CURRENT_WAIT_REPLACEMENT"])
            #expect(clock.pendingCount == 0)
            service.cancel()
        } catch {
            service.cancel()
            clock.cancelAll()
            old?.cancel()
            _ = await old?.result
            throw error
        }
        clock.cancelAll()
    }

    @Test(.timeLimit(.minutes(1)))
    func precancelledManualFinalizeRevokesCurrentNativeAdmission() async throws {
        let clock = ControlledGenerationWatchdogClock(trace: TestEventWaitTrace(label: "manual-speech-executor.precancel-clock"))
        let service = ManualQuestionTranscriptionService(finalizeDelayProvider: clock)
        let gate = ManualSpeechBoundaryGate()
        var final: ((String) -> Void)?
        var received: [String] = []
        var owned: Task<String, Error>?
        resetManualExecutorHooks()
        defer { resetManualExecutorHooks() }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, callback, _ in final = callback }
        do {
            try await service.startTranscription(onPartialResult: { _ in },
                onFinalResult: { received.append($0) }, onError: { _ in })
            owned = Task {
                // The fixture gate intentionally permits a cancelled task to
                // enter finalize before waiter/native-endAudio registration.
                await gate.wait()
                return try await service.endAudioAndFinalize(timeoutSeconds: 1)
            }
            try await manualBoundaryEntered(gate)
            owned?.cancel()
            await gate.release()
            let result = await (try #require(owned)).result
            switch result {
            case .success: Issue.record("Pre-cancelled finalize returned success")
            case .failure(let error): #expect(error is CancellationError)
            }
            let cancelledCallback = try #require(final)
            cancelledCallback("PRECANCELLED_MANUAL_CALLBACK")
            #expect(received.isEmpty,
                "Cancellation before registration must still revoke this round's native callback admission.")
            #expect(clock.requestedNanoseconds.isEmpty)
            service.cancel()
        } catch {
            service.cancel()
            clock.cancelAll()
            await gate.release()
            owned?.cancel()
            _ = await owned?.result
            throw error
        }
        clock.cancelAll()
    }

    private func resetManualExecutorHooks() {
        ManualQuestionTranscriptionService.mockStartTranscription = nil
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = nil
        ManualQuestionTranscriptionService.mockCancel = nil
    }
    private func manualBoundaryEntered(_ gate: ManualSpeechBoundaryGate) async throws {
        let signal = await gate.signal()
        _ = try await TestEventWaitTrace(label: "manual-speech-executor.entered")
            .nextEvent(in: signal, event: "entered")
    }
}

private actor ManualSpeechBoundaryGate {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    func signal() -> AsyncStream<Void> { entered.stream }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            held = continuation
            entered.continuation.yield(())
        }
    }
    func release() {
        released = true
        let continuation = held; held = nil
        continuation?.resume()
        entered.continuation.finish()
    }
}
