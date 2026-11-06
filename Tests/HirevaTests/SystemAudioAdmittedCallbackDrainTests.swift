import AVFoundation
import CoreMedia
import Foundation
import os
import Testing
@testable import Hireva

/// Synthetic PCM enters the production callback on this test's owned queue.
/// There is no SCStream, TCC, microphone, audio playback or model invocation.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct SystemAudioAdmittedCallbackDrainTests {
    @Test
    func stopClosesAdmissionWithoutWaitingForAdmittedNativeAppend() async throws {
        try await exercise(order: .nativeStopFirst, verifyReplacement: false)
    }

    @Test(arguments: [false, true])
    func rejectedNativeStopStillDrainsTheAdmittedBorrowAndRetainsNativeOwnership(delayBeforeStop: Bool) async throws {
        let nativeError = NSError(domain: "Hireva.SyntheticRejectedStop", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "controlled rejected native stop"])
        let old = CallbackDrainStream(stopError: nativeError)
        let replacement = CallbackDrainStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        let receiver = HeldNativeAppendReceiver()
        service.register(receiver)
        let callback = OwnedSyntheticCallback()
        let admissionEscape = OwnedCallbackReleaseGuard(receiver: receiver)
        let failureRelease = OwnedFailedStopBorrowReleaseGuard(receiver: receiver)
        let trace = TestEventWaitTrace(label: "sck_rejected_stop_admission")
        var finish: Task<Void, Never>?
        var rejected = false
        @MainActor func cleanup() async {
            receiver.releaseAppend()
            admissionEscape.signalStopReturned()
            failureRelease.signalStopReturned()
            finish?.cancel()
            _ = await finish?.result
            await callback.join()
            await admissionEscape.join()
            await failureRelease.join()
            service.unregister(receiver)
            let stop = service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture(capturedStop: stop)
            // The failed native handle deliberately remains owned. Release the
            // exact fixture after clearing its injected error; no SDK exists.
            old.clearStopError()
            try? await old.stopCapture()
            try? await replacement.stopCapture()
        }
        do {
            try await service.startSystemAudioCapture()
            callback.start(service: service, source: old)
            _ = try await callbackDrainNext(receiver.entered.stream)
            trace.mark("receiver_entered.test_resumed")
            if delayBeforeStop {
                trace.mark("queued_before_stop.begin")
                try await Task.sleep(for: .milliseconds(2100))
                trace.mark("queued_before_stop.end")
            }
            admissionEscape.start()
            trace.mark("stop.enter")
            let capturedStop = service.stopSystemAudioCapture()
            trace.mark("stop.return")
            admissionEscape.signalStopReturned()
            #expect(!receiver.appendReleased)
            failureRelease.start()
            finish = Task {
                do { try await service.finishStoppingSystemAudioCapture(capturedStop: capturedStop) }
                catch { rejected = true }
                failureRelease.signalStopReturned()
            }
            _ = try await callbackDrainNext(old.stopEntered.stream)
            await failureRelease.join()
            await callback.join()
            await finish?.value
            #expect(!failureRelease.returnedBeforeReleasingAppend,
                "Rejected native stop still owns the admitted PCM borrow until its callback returns")
            #expect(rejected, "Native rejection must remain an error after draining PCM")
            #expect(service.lastError?.contains("controlled rejected native stop") == true)
            var restartRejected = false
            do { try await service.startSystemAudioCapture() }
            catch { restartRejected = true }
            #expect(restartRejected)
            #expect(creations == 1, "A drained borrow does not mean a rejected SDK stream was released")
            #expect(replacement.stopCalls == 0)
            #expect(!(await admissionEscape.didNeedEscape()))
            #expect(callback.failure == nil)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func aMainThreadAppendCannotStrandTheFixtureHost() throws {
        try #require(Thread.isMainThread)
        let stream = CallbackDrainStream()
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream })
        let receiver = HeldNativeAppendReceiver()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        receiver.systemAudioCaptureService(service, didReceive: buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
        #expect(receiver.buffers == 1 && receiver.appendReleased)
    }

    @Test(arguments: CallbackDrainOrder.allCases)
    func restartAndOldStopJoinRetainTheExactAdmittedCallback(order: CallbackDrainOrder) async throws {
        // Two explicitly ordered release schedules, ten executions each. This
        // is twenty controlled executions, not twenty distinct interleavings.
        for _ in 0..<10 { try await exercise(order: order, verifyReplacement: true) }
    }

    private func exercise(order: CallbackDrainOrder, verifyReplacement: Bool) async throws {
        let nativeStop = CallbackDrainGate()
        let old = CallbackDrainStream(stopGate: nativeStop)
        let replacement = CallbackDrainStream()
        let entered = AsyncStream<Void>.makeStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : replacement
        }, onStartEntered: { entered.continuation.yield(()) })
        let receiver = HeldNativeAppendReceiver()
        service.register(receiver)
        let callback = OwnedSyntheticCallback()
        let releaseGuard = OwnedCallbackReleaseGuard(receiver: receiver)
        var tasks: [Task<Void, Error>] = []
        @MainActor func cleanup() async {
            // Every failing assertion/throw opens the native append and stop
            // gates before joining owned jobs. The RED cannot strand the host.
            receiver.releaseAppend()
            releaseGuard.signalStopReturned()
            await nativeStop.open()
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
            await callback.join()
            await releaseGuard.join()
            service.unregister(receiver)
            let stop = service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture(capturedStop: stop)
            try? await old.stopCapture()
            try? await replacement.stopCapture()
            entered.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            _ = try await callbackDrainNext(entered.stream)
            callback.start(service: service, source: old)
            _ = try await callbackDrainNext(receiver.entered.stream)

            // The native append is already entered. In RED, close blocks on its
            // admission lock; an owned worker releases that append after a
            // bounded two-second escape. In GREEN, stop returns first and the
            // append stays held until the test explicitly releases it.
            releaseGuard.start()
            let capturedStop = service.stopSystemAudioCapture()
            releaseGuard.signalStopReturned()
            #expect(!receiver.appendReleased,
                "Stop must close admission before a previously admitted native append returns")
            #expect(!service.isCapturing)
            let lateSample = try callbackDrainSample()
            service.receiveAudioSampleBuffer(lateSample, from: old)
            #expect(receiver.buffers == 1, "No second PCM callback is admitted after stop")

            let joined = CallbackDrainCompletion()
            let finish = Task {
                try await service.finishStoppingSystemAudioCapture(capturedStop: capturedStop)
                joined.finish()
            }
            tasks.append(finish)
            _ = try await callbackDrainNext(old.stopEntered.stream)
            var restart: Task<Void, Error>?
            if verifyReplacement {
                restart = Task { try await service.startSystemAudioCapture() }
                tasks.append(try #require(restart))
                _ = try await callbackDrainNext(entered.stream)
                #expect(creations == 1)
            }
            switch order {
            case .nativeStopFirst:
                await nativeStop.open()
                _ = try await callbackDrainNext(old.stopExited.stream)
                // The native stop has finished, but the append is still held.
                // Joining stop/restarting cannot discard that resource owner.
                #expect(!joined.finished)
                #expect(creations == 1)
                receiver.releaseAppend()
                await callback.join()
            case .callbackFirst:
                receiver.releaseAppend()
                await callback.join()
                #expect(!joined.finished)
                #expect(creations == 1)
                await nativeStop.open()
            }
            try await finish.value
            #expect(joined.finished)
            #expect(callback.failure == nil)
            #expect(!(await releaseGuard.didNeedEscape()))
            if let restart {
                try await restart.value
                #expect(creations == 2)
                #expect(service.isCapturing)
                // Joining an immutable old stop a second time must not adopt
                // or tear down the replacement capture's resources.
                try await service.finishStoppingSystemAudioCapture(capturedStop: capturedStop)
                service.receiveStreamFailure(NSError(domain: "Hireva.ControlledOldEpoch", code: 1), from: old)
                service.receiveAudioSampleBuffer(lateSample, from: old)
                #expect(receiver.buffers == 1)
                service.receiveAudioSampleBuffer(lateSample, from: replacement)
                #expect(receiver.buffers == 2)
                #expect(replacement.stopCalls == 0)
                #expect(service.isCapturing)
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

enum CallbackDrainOrder: String, CaseIterable, Sendable { case nativeStopFirst, callbackFirst }

private actor CallbackDrainGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let owned = waiters
        waiters.removeAll()
        owned.forEach { $0.resume() }
    }
}

private final class CallbackDrainStream: SystemAudioCaptureStream, Sendable {
    private struct State { var stops = 0; var error: Error? }
    private let state: OSAllocatedUnfairLock<State>
    private let stopGate: CallbackDrainGate?
    let stopEntered = AsyncStream<Void>.makeStream()
    let stopExited = AsyncStream<Void>.makeStream()
    var stopCalls: Int { state.withLock { $0.stops } }
    init(stopGate: CallbackDrainGate? = nil, stopError: Error? = nil) {
        self.stopGate = stopGate
        state = OSAllocatedUnfairLock(initialState: State(error: stopError))
    }
    func startCapture() async throws {}
    func stopCapture() async throws {
        let error = state.withLock { state in state.stops += 1; return state.error }
        stopEntered.continuation.yield(())
        await stopGate?.wait()
        stopExited.continuation.yield(())
        if let error { throw error }
    }
    func clearStopError() { state.withLock { $0.error = nil } }
}

private final class HeldNativeAppendReceiver: SystemAudioBufferDelegate, Sendable {
    private struct State { var buffers = 0; var released = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let appendGate = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream()
    var appendReleased: Bool { state.withLock { $0.released } }
    var buffers: Int { state.withLock { $0.buffers } }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let held = state.withLock { state in state.buffers += 1; return !state.released }
        guard held else { return }
        entered.continuation.yield(())
        // A wrong-executor regression must fail the borrow assertion, not block MainActor cleanup.
        if Thread.isMainThread { releaseAppend(); return }
        // This wait is confined to the explicitly owned synthetic callback
        // queue. The test never blocks MainActor waiting for this semaphore.
        appendGate.wait()
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {}
    func releaseAppend() {
        let first = state.withLock { state in
            guard !state.released else { return false }
            state.released = true
            return true
        }
        if first { appendGate.signal() }
    }
}

private final class OwnedSyntheticCallback: Sendable {
    private let queue = DispatchQueue(label: "Hireva.Tests.OwnedSyntheticCallback")
    private let state = OSAllocatedUnfairLock(initialState: (started: false, failure: Optional<String>.none))
    private let completed = AsyncStream<Void>.makeStream()
    var failure: String? { state.withLock { $0.failure } }
    func start(service: ScreenCaptureKitSystemAudioCaptureService, source: CallbackDrainStream) {
        state.withLock { $0.started = true }
        queue.async {
            // SDK buffers are created and borrowed on this queue, never
            // captured by an actor-hopping Task or asserted Sendable.
            do { service.receiveAudioSampleBuffer(try callbackDrainSample(), from: source) }
            catch { self.state.withLock { $0.failure = error.localizedDescription } }
            self.completed.continuation.finish()
        }
    }
    func join() async {
        guard state.withLock({ $0.started }) else { return }
        for await _ in completed.stream {}
    }
}

private final class OwnedCallbackReleaseGuard: Sendable {
    private let queue = DispatchQueue(label: "Hireva.Tests.OwnedCallbackReleaseGuard")
    private let stopReturned = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: (started: false, neededEscape: false))
    private let receiver: HeldNativeAppendReceiver
    private let completed = AsyncStream<Void>.makeStream()
    private let trace = TestEventWaitTrace(label: "sck_callback_release_guard")
    init(receiver: HeldNativeAppendReceiver) { self.receiver = receiver }
    func start() {
        state.withLock { $0.started = true }
        queue.async {
            self.trace.mark("worker.started")
            let escaped = self.stopReturned.wait(timeout: .now() + 2) == .timedOut
            self.state.withLock { $0.neededEscape = escaped }
            if escaped { self.trace.mark("escape.release"); self.receiver.releaseAppend() }
            self.completed.continuation.finish()
        }
    }
    func signalStopReturned() { stopReturned.signal() }
    func didNeedEscape() async -> Bool {
        await join()
        return state.withLock { $0.neededEscape }
    }
    func join() async {
        guard state.withLock({ $0.started }) else { return }
        for await _ in completed.stream {}
    }
}

/// The two-second release is a test-host escape, not a product deadline. V1
/// reports its rejected native stop first and triggers release; V2 retains the
/// borrow and cannot return until this worker releases it. All paths join it.
private final class OwnedFailedStopBorrowReleaseGuard: Sendable {
    private let queue = DispatchQueue(label: "Hireva.Tests.OwnedFailedStopBorrowReleaseGuard")
    private let stopReturned = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: (started: false, returnedBeforeRelease: false))
    private let receiver: HeldNativeAppendReceiver
    private let completed = AsyncStream<Void>.makeStream()
    var returnedBeforeReleasingAppend: Bool { state.withLock { $0.returnedBeforeRelease } }
    init(receiver: HeldNativeAppendReceiver) { self.receiver = receiver }
    func start() {
        state.withLock { $0.started = true }
        queue.async {
            let returned = self.stopReturned.wait(timeout: .now() + 2) == .success
            self.state.withLock { $0.returnedBeforeRelease = returned }
            self.receiver.releaseAppend()
            self.completed.continuation.finish()
        }
    }
    func signalStopReturned() { stopReturned.signal() }
    func join() async {
        guard state.withLock({ $0.started }) else { return }
        for await _ in completed.stream {}
    }
}

private final class CallbackDrainCompletion: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var finished: Bool { state.withLock { $0 } }
    func finish() { state.withLock { $0 = true } }
}

private func callbackDrainNext<Value: Sendable>(_ stream: AsyncStream<Value>) async throws -> Value {
    try await TestEventWaitTrace(label: "system_audio_admitted_callback").nextEvent(in: stream, event: "control")
}

private func callbackDrainSample() throws -> CMSampleBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16) else {
        throw NSError(domain: "Hireva.SyntheticSample", code: 1)
    }
    pcm.frameLength = 16
    for index in 0..<16 { pcm.floatChannelData?[0][index] = 0.1 }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: 16,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    guard created == noErr, let sample,
          CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
              blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr,
          CMSampleBufferSetDataReady(sample) == noErr else {
        throw NSError(domain: "Hireva.SyntheticSample", code: 2)
    }
    return sample
}
