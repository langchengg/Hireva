import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Hireva

/// Uses the production service/permission driver and synthetic streams. No TCC,
/// SCShareableContent, native stream, microphone or model is started.
@Suite
@MainActor
struct SystemAudioLifecycleOwnershipTests {
    @Test
    func restartWaitsForTheExactOldStreamStop() async throws {
        let oldStop = LifecycleGate()
        let old = ControlledCaptureStream(stopGate: oldStop)
        let current = ControlledCaptureStream()
        let starts = AsyncStream<Void>.makeStream()
        var iterator = starts.stream.makeAsyncIterator()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : current
        }, onStartEntered: { starts.continuation.yield(()) })
        var owned: [Task<Void, Error>] = []
        @MainActor func cleanup() async {
            await oldStop.open()
            owned.forEach { $0.cancel() }
            for task in owned { _ = await task.result }
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await current.stopCapture()
            starts.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            _ = await iterator.next()
            service.stopSystemAudioCapture()
            await old.stopEntered.wait()
            let restart = Task { try await service.startSystemAudioCapture() }
            owned.append(restart)
            _ = await iterator.next()
            #expect(creations == 1, "A new native stream must not be created while the old stop is pending")
            await oldStop.open()
            try await restart.value
            #expect(old.stopCalls == 1)
            #expect(current.startCalls == 1)
            #expect(service.isCapturing)
            service.stopSystemAudioCapture()
            await current.stopFinished.wait()
            starts.continuation.finish()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func stoppedPendingStartupIsDrainedBeforeReplacementStreamCreation() async throws {
        let oldStart = LifecycleGate()
        let old = ControlledCaptureStream(startGate: oldStart)
        let current = ControlledCaptureStream()
        let starts = AsyncStream<Void>.makeStream()
        var iterator = starts.stream.makeAsyncIterator()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : current
        }, onStartEntered: { starts.continuation.yield(()) })
        var owned: [Task<Void, Error>] = []
        @MainActor func cleanup() async {
            await oldStart.open()
            owned.forEach { $0.cancel() }
            for task in owned { _ = await task.result }
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await current.stopCapture()
            starts.continuation.finish()
        }
        do {
            let startup = Task { try await service.startSystemAudioCapture() }
            owned.append(startup)
            await old.startEntered.wait()
            _ = await iterator.next()
            service.stopSystemAudioCapture()
            let replacement = Task { try await service.startSystemAudioCapture() }
            owned.append(replacement)
            _ = await iterator.next()
            #expect(creations == 1, "An ignored-cancellation startup still owns native resources")
            await oldStart.open()
            switch await startup.result {
            case .success: Issue.record("Invalidated startup must not publish capture success")
            case .failure(let error): #expect(error is CancellationError)
            }
            try await replacement.value
            #expect(old.stopCalls == 1)
            #expect(!old.running)
            #expect(current.running)
            service.stopSystemAudioCapture()
            await current.stopFinished.wait()
            starts.continuation.finish()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func oldStreamBuffersDoNotReachCurrentDelegatesAfterStopOrRestart() async throws {
        let sample = try makeSampleBuffer()
        let old = ControlledCaptureStream()
        let current = ControlledCaptureStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : current
        })
        let receiver = BufferReceiver()
        service.register(receiver)
        @MainActor func cleanup() async {
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await current.stopCapture()
        }
        do {
            try await service.startSystemAudioCapture()
            service.stopSystemAudioCapture()
            await old.stopFinished.wait()
            service.receiveAudioSampleBuffer(sample, from: old)
            #expect(receiver.buffers == 0, "Stop closes admission before late native callbacks")
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(sample, from: old)
            service.receiveAudioSampleBuffer(sample, from: current)
            #expect(receiver.buffers == 1, "Only the current stream may deliver PCM")
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            await current.stopFinished.wait()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func stopFailureIsVisibleAndBlocksUnsafeReplacement() async throws {
        let old = ControlledCaptureStream(stopError: SyntheticCaptureError.stop)
        let replacement = ControlledCaptureStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        @MainActor func cleanup() async {
            old.clearStopError()
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await replacement.stopCapture()
        }
        do {
            try await service.startSystemAudioCapture()
            service.stopSystemAudioCapture()
            await old.stopFinished.wait()
            var rejected = false
            do { try await service.startSystemAudioCapture() } catch { rejected = true }
            #expect(rejected, "A failed stop must not be presented as safely released capture")
            #expect(service.lastError?.isEmpty == false)
            #expect(creations == 1)
            // The fixture deliberately keeps a failed-stop stream live. Release the
            // exact synthetic stream explicitly; no unowned process/audio exists.
            old.clearStopError()
            try await old.stopCapture()
            service.stopSystemAudioCapture()
            if replacement.startCalls > 0 { await replacement.stopFinished.wait() }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func burstKeepsDiagnosticPublicationsBoundedWithoutDroppingPCM() async throws {
        let sample = try makeSampleBuffer()
        let stream = ControlledCaptureStream()
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream })
        let receiver = BufferReceiver()
        service.register(receiver)
        @MainActor func cleanup() async {
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await stream.stopCapture()
        }
        do {
            try await service.startSystemAudioCapture()
            // MainActor cannot consume its queued display work while this bounded
            // synchronous burst runs. PCM still goes through the real converter and
            // production delegate delivery. The diagnostic queue must merge snapshots.
            for _ in 0..<128 { service.receiveAudioSampleBuffer(sample, from: stream) }
            #expect(receiver.buffers == 128)
            #expect(service.pendingDiagnosticUpdates <= 1)
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            await stream.stopFinished.wait()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func permissionAudioCallbackCannotFinishPendingNativeStartup() async {
        let startGate = LifecycleGate()
        let stream = ControlledCaptureStream(startGate: startGate)
        let helper = StreamAudioProbeHelper()
        let probe = Task { await helper.runProbe(makeStream: { stream }) }
        await stream.startEntered.wait()
        helper.receiveAudio(from: stream)
        #expect(helper.hasPendingProbeResult, "An early buffer does not prove completed startup and teardown")
        await startGate.open()
        #expect(await probe.value)
        await stream.startFinished.wait()
        await stream.stopFinished.wait()
        #expect(!stream.running)
    }

    @Test
    func cancelledPermissionProbeDrainsStartupAndReportsFailure() async {
        let startGate = LifecycleGate()
        let stream = ControlledCaptureStream(startGate: startGate)
        let helper = StreamAudioProbeHelper()
        let probe = Task { await helper.runProbe(makeStream: { stream }) }
        await stream.startEntered.wait()
        probe.cancel()
        await startGate.open()
        #expect(!(await probe.value), "Cancelled probe must not report native permission/startup success")
        await stream.stopFinished.wait()
        #expect(!stream.running)
    }

    @Test
    func permissionStopFailureCannotReportSuccessfulProbe() async {
        let stream = ControlledCaptureStream(stopError: SyntheticCaptureError.stop)
        let helper = StreamAudioProbeHelper()
        let result = await helper.runProbe(makeStream: { stream })
        #expect(!result, "SCStream stop failure must remain visible to the permission result")
        stream.clearStopError()
        try? await helper.stop()
        #expect(!stream.running)
        #expect(!helper.hasUnreleasedStream)
    }

    @Test
    func normalPermissionProbeStopsTheExactStreamBeforeReturning() async {
        let stream = ControlledCaptureStream()
        let helper = StreamAudioProbeHelper()
        #expect(await helper.runProbe(makeStream: { stream }))
        #expect(stream.startCalls == 1)
        #expect(stream.stopCalls == 1)
        #expect(!stream.running)
        #expect(!helper.hasPendingProbeResult)
    }

    @Test
    func failedResolutionAttemptsStopExactHandlesBeforeFallbackOrFinalError() async {
        var created: [(stream: ControlledCaptureStream, native: Bool)] = []
        var events: [String] = []
        var failed = false
        do {
            _ = try await ScreenCaptureKitSystemAudioCaptureService.startFilteredCapture(
                verification: nil, applications: [], filterFactory: { $0 },
                streamFactory: { _, native in
                    events.append(native ? "create-native" : "create-tiny")
                    let stream = ControlledCaptureStream(startError: SyntheticCaptureError.start)
                    created.append((stream, native))
                    return stream
                }, startStream: { stream in
                    events.append(created.last?.native == true ? "start-native" : "start-tiny")
                    try await stream.startCapture()
                }, stopStream: { stream in
                    let native = created.first(where: { $0.stream === stream })?.native == true
                    events.append(native ? "stop-native" : "stop-tiny")
                    try await stream.stopCapture()
                }, allowFallback: { _ in }
            )
        } catch { failed = true }
        #expect(failed)
        #expect(events == ["create-tiny", "start-tiny", "stop-tiny", "create-native", "start-native", "stop-native"])
        // Reclaim exact fixture handles even after assertion failure; no
        // SCStream/native capture is constructed.
        for entry in created { try? await entry.stream.stopCapture() }
        #expect(created.allSatisfy { !$0.stream.running })
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        pcm.frameLength = 16
        for index in 0..<16 { pcm.floatChannelData?[0][index] = 0.1 }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: 16,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let created = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(created,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList) == noErr)
        #expect(CMSampleBufferSetDataReady(created) == noErr)
        return created
    }
}

private enum SyntheticCaptureError: Error { case start, stop }

private final class ControlledCaptureStream: SystemAudioCaptureStream {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = false
    private var stopError: Error?
    private let startError: Error?
    private let startGate: LifecycleGate?
    private let stopGate: LifecycleGate?
    let startEntered = LifecycleGate()
    let startFinished = LifecycleGate()
    let stopEntered = LifecycleGate()
    let stopFinished = LifecycleGate()
    var startCalls: Int { lock.withLock { starts } }
    var stopCalls: Int { lock.withLock { stops } }
    var running: Bool { lock.withLock { active } }

    init(startGate: LifecycleGate? = nil, stopGate: LifecycleGate? = nil, stopError: Error? = nil, startError: Error? = nil) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.stopError = stopError
        self.startError = startError
    }

    func startCapture() async throws {
        lock.withLock { starts += 1 }
        await startEntered.open()
        await startGate?.wait()
        lock.withLock { active = true }
        await startFinished.open()
        if let startError { throw startError }
    }

    func stopCapture() async throws {
        let error = lock.withLock { stops += 1; return stopError }
        await stopEntered.open()
        await stopGate?.wait()
        if error == nil { lock.withLock { active = false } }
        await stopFinished.open()
        if let error { throw error }
    }

    func clearStopError() { lock.withLock { stopError = nil } }
}

private actor LifecycleGate {
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

private final class BufferReceiver: SystemAudioBufferDelegate {
    private(set) var buffers = 0
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) { buffers += 1 }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {}
}
