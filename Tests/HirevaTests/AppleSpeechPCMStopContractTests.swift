import AVFoundation
import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct AppleSpeechPCMStopContractTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func sessionStopCannotEndTheRequestWhileAnAdmittedNativeAppendIsRunning(delayBeforeStop: Bool) async throws {
        let io = SpeechPCMControlledIO()
        let session = AppleSpeechTranscriptionSession(sessionID: .init(source: .microphone),
            parentSessionID: "synthetic-pcm-stop", onEmit: { _ in }, onStateChange: {},
            pcmTestingOperations: io.operations)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0
        let worker = SpeechPCMAppendThread(session: session, buffer: buffer)
        let trace = TestEventWaitTrace(label: #function)
        try await withTaskCancellationHandler {
            do {
                try await session.start()
                worker.start()
                _ = try await trace.nextEvent(in: io.appendEntered.stream, event: "native_append_held")
                trace.mark("admission.test_resumed")
                if delayBeforeStop {
                    trace.mark("queued_before_stop.begin")
                    try await Task.sleep(for: .milliseconds(11000))
                    trace.mark("queued_before_stop.end")
                }
                io.armSafetyEscape()
                #expect(session.inFlightPCMAppendsForTesting == 1)
                trace.mark("stop.enter")
                session.stop()
                trace.mark("stop.return")
                #expect(io.endCount == 0,
                    "stop must close admission first; endAudio cannot race the already admitted native append.")
                #expect(!io.endedDuringAppend)
                session.appendBuffer(buffer)
                #expect(io.appendCount == 1,
                    "PCM arriving after stop must be rejected at the actual input admission boundary.")
                io.releaseAppend()
                await worker.join()
                _ = try await trace.nextEvent(in: io.audioEnded.stream, event: "exact_request_end")
                await session.pcmCloseTaskForTesting?.value
                #expect(io.endCount == 1)
                #expect(!io.fixtureGuardExpired)
                #expect(session.inFlightPCMAppendsForTesting == 0)
                #expect(session.totalBuffersAppended == 1)
                await cleanup(io, session, worker)
            } catch { await cleanup(io, session, worker); throw error }
        } onCancel: { io.releaseAppend(); io.finishEvents() }
    }

    @Test
    func wrongMainThreadAppendCannotBlockFixtureCleanup() throws {
        try #require(Thread.isMainThread)
        let io = SpeechPCMControlledIO()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        io.operations.append(buffer)
        io.operations.endAudio()
        #expect(io.appendCount == 1 && io.endCount == 1)
        #expect(!io.endedDuringAppend && !io.fixtureGuardExpired)
        io.finishEvents()
    }

    private func cleanup(_ io: SpeechPCMControlledIO, _ session: AppleSpeechTranscriptionSession,
        _ worker: SpeechPCMAppendThread) async {
        let cleanup = Task { @MainActor in
            io.releaseAppend()
            session.stop()
            await worker.join()
            await session.pcmCloseTaskForTesting?.value
            await session.finishStoppingAudioInput()
            io.finishEvents()
        }
        await cleanup.value
    }
}

/// Per-instance synchronous native-I/O substitute. Its independent ten-second
/// Thread escape starts at the owned stop check, never a product ASR deadline.
private final class SpeechPCMControlledIO: Sendable {
    private struct State: Sendable {
        var appendCount = 0
        var endCount = 0
        var appendActive = false
        var endedDuringAppend = false
        var fixtureGuardExpired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    private let stopTestEntered = DispatchSemaphore(value: 0)
    private let trace = TestEventWaitTrace(label: "apple_pcm_stop_borrow")
    let appendEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let audioEnded = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var appendCount: Int { state.withLock { $0.appendCount } }
    var endCount: Int { state.withLock { $0.endCount } }
    var endedDuringAppend: Bool { state.withLock { $0.endedDuringAppend } }
    var fixtureGuardExpired: Bool { state.withLock { $0.fixtureGuardExpired } }
    var operations: AppleSpeechPCMTestingOperations {
        .init(append: { [self] _ in
            trace.mark("append.enter.main.\(Thread.isMainThread)")
            state.withLock { $0.appendCount += 1; $0.appendActive = true }
            appendEntered.continuation.yield(())
            // A wrong-executor regression must fail, not strand MainActor cleanup.
            if Thread.isMainThread {
                state.withLock { $0.appendActive = false }
                return
            }
            stopTestEntered.wait()
            let result = gate.wait(timeout: .now() + .seconds(10))
            trace.mark(result == .timedOut ? "escape.release" : "append.released")
            state.withLock { $0.appendActive = false; $0.fixtureGuardExpired = result == .timedOut }
        }, endAudio: { [self] in
            state.withLock { $0.endCount += 1; $0.endedDuringAppend = $0.appendActive }
            audioEnded.continuation.yield(())
        })
    }
    func armSafetyEscape() { stopTestEntered.signal() }
    func releaseAppend() { stopTestEntered.signal(); gate.signal() }
    func finishEvents() { appendEntered.continuation.finish(); audioEnded.continuation.finish() }
}

/// Target/selector retains the exact borrowed Session and PCM buffer. No
/// non-Sendable AVA value is captured by an async or Sendable worker closure.
private final class SpeechPCMAppendThread: NSObject {
    private let session: AppleSpeechTranscriptionSession
    private let buffer: AVAudioPCMBuffer
    private let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    @MainActor private var thread: Thread?
    @MainActor private var started = false
    init(session: AppleSpeechTranscriptionSession, buffer: AVAudioPCMBuffer) {
        self.session = session; self.buffer = buffer
    }
    @MainActor func start() {
        started = true
        thread = Thread(target: self, selector: #selector(run), object: nil)
        thread?.start()
    }
    @objc private func run() {
        session.appendBuffer(buffer)
        completed.continuation.yield(())
        completed.continuation.finish()
    }
    @MainActor func join() async {
        guard started, let thread else { return }
        var iterator = completed.stream.makeAsyncIterator(); _ = await iterator.next()
        for _ in 0..<1000 {
            if thread.isFinished { return }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { Issue.record("Owned PCM Thread join was cancelled."); return }
        }
        Issue.record("Owned synthetic PCM Thread did not exit after work completed.")
    }
}
