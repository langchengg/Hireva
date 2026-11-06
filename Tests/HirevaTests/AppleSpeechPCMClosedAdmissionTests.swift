import AVFoundation
import Foundation
import Speech
import Testing
import os
@testable import Hireva

@MainActor
struct AppleSpeechPCMClosedAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func closedInputRejectsLatePCMWithoutWaitingForAnAlreadyAdmittedSDKAppend() async throws {
        let io = ClosedPCMAdmissionIO()
        let input = AppleSpeechPCMInput(request: SFSpeechAudioBufferRecognitionRequest(),
            simulated: true, operations: io.operations)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let first = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        let late = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        first.frameLength = 1; late.frameLength = 1
        first.floatChannelData![0][0] = 0; late.floatChannelData![0][0] = 0
        let admitted = ClosedPCMAdmissionThread(input: input, buffer: first)
        let rejected = ClosedPCMAdmissionThread(input: input, buffer: late)
        let trace = TestEventWaitTrace(label: #function)
        var close: Task<Void, Never>?
        @MainActor func cleanup() async {
            let task = Task { @MainActor in
                io.release()
                close = close ?? input.close()
                await admitted.join(); await rejected.join()
                await close?.value
                io.entered.continuation.finish()
            }
            await task.value
        }
        do {
            admitted.start()
            _ = try await trace.nextEvent(in: io.entered.stream, event: "admitted_native_append")
            #expect(input.inFlightAppendCount == 1)
            close = input.close()
            rejected.start()
            _ = try await trace.nextEvent(in: rejected.completed.stream, event: "closed_late_callback_exit")
            #expect(io.isNativeAppendHeld,
                "A closed callback must exit while the prior SDK append is still held, not after its safety escape.")
            #expect(!io.safetyEscapeFired)
            #expect(io.appendCount == 1)
            #expect(io.endCount == 0)
            #expect(input.inFlightAppendCount == 1)
            await cleanup()
            #expect(io.endCount == 1)
            #expect(input.snapshot.bufferCount == 1)
            #expect(!input.hasUnreleasedInput)
        } catch { await cleanup(); throw error }
    }
}

private final class ClosedPCMAdmissionIO: Sendable {
    private struct State: Sendable {
        var held = false
        var appendCount = 0
        var endCount = 0
        var safetyEscapeFired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var isNativeAppendHeld: Bool { state.withLock { $0.held } }
    var appendCount: Int { state.withLock { $0.appendCount } }
    var endCount: Int { state.withLock { $0.endCount } }
    var safetyEscapeFired: Bool { state.withLock { $0.safetyEscapeFired } }
    var operations: AppleSpeechPCMTestingOperations {
        .init(append: { [self] _ in
            state.withLock { $0.held = true; $0.appendCount += 1 }
            entered.continuation.yield(())
            let expired = gate.wait(timeout: .now() + .seconds(45)) == .timedOut
            state.withLock { $0.held = false; $0.safetyEscapeFired = expired }
        }, endAudio: { [self] in state.withLock { $0.endCount += 1 } })
    }
    func release() { gate.signal() }
}

/// Synchronous native callback borrow; no SDK buffer enters an async closure.
private final class ClosedPCMAdmissionThread: NSObject {
    let input: AppleSpeechPCMInput
    let buffer: AVAudioPCMBuffer
    let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    @MainActor private var thread: Thread?
    @MainActor private var started = false
    init(input: AppleSpeechPCMInput, buffer: AVAudioPCMBuffer) {
        self.input = input; self.buffer = buffer
    }
    @MainActor func start() {
        started = true
        thread = Thread(target: self, selector: #selector(run), object: nil)
        thread?.start()
    }
    @objc private func run() {
        _ = input.append(buffer)
        completed.continuation.yield(()); completed.continuation.finish()
    }
    @MainActor func join() async {
        guard started, let thread else { return }
        var iterator = completed.stream.makeAsyncIterator(); _ = await iterator.next()
        for _ in 0..<1000 {
            if thread.isFinished { return }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { Issue.record("Owned closed-admission Thread join was cancelled."); return }
        }
        Issue.record("Owned closed-admission Thread did not exit.")
    }
}
