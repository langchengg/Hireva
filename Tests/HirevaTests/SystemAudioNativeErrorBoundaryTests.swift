import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Hireva

/// Drives the actual SCStreamDelegate boundary with controlled protocol streams.
/// It does not instantiate SCStream or access TCC, displays, microphones or models.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioNativeErrorBoundaryTests {
    @Test
    func currentNativeErrorClosesPCMImmediatelyAndJoinsTheExactStop() async throws {
        let stopGate = NativeErrorGate()
        let stream = NativeErrorStream(stopGate: stopGate)
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream })
        let receiver = NativeErrorReceiver()
        service.register(receiver)
        let sample = try nativeErrorSample()
        var stop: Task<Void, Error>?
        let finishEntered = AsyncStream<Void>.makeStream()
        var stopped = false
        @MainActor func cleanup() async {
            await stopGate.open()
            stop?.cancel()
            _ = await stop?.result
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await stream.stopCapture()
            receiver.events.continuation.finish()
            stream.events.continuation.finish()
            finishEntered.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            #expect(try await nativeErrorNext(stream.events.stream, trace: stream.trace) == .startEntered)
            service.receiveStreamFailure(nativeError("current failure"), from: stream)
            service.receiveStreamFailure(nativeError("duplicate failure"), from: stream)
            service.receiveAudioSampleBuffer(sample, from: stream)
            #expect(receiver.bufferCount == 0, "Native failure closes PCM before the MainActor handles diagnostics")
            #expect(service.totalBuffersReceived == 0, "A native error is not an audio buffer")
            #expect(try await nativeErrorNext(receiver.events.stream, trace: receiver.trace) == "current failure")
            #expect(try await nativeErrorNext(stream.events.stream, trace: stream.trace) == .stopEntered)
            stop = Task {
                finishEntered.continuation.yield(())
                try await service.finishStoppingSystemAudioCapture()
                stopped = true
            }
            _ = try await nativeErrorNext(finishEntered.stream)
            #expect(!stopped)
            #expect(!service.isCapturing)
            #expect(receiver.failureCount == 1)
            await stopGate.open()
            try await stop?.value
            #expect(stopped)
            #expect(!stream.running)
            #expect(stream.stopCalls == 1)
            #expect(service.lastError?.contains("current failure") == true)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func oldStreamNativeErrorCannotStopOrContaminateReplacement() async throws {
        let old = NativeErrorStream()
        let replacement = NativeErrorStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        let receiver = NativeErrorReceiver()
        let sample = try nativeErrorSample()
        service.register(receiver)
        @MainActor func cleanup() async {
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await replacement.stopCapture()
            receiver.events.continuation.finish()
            old.events.continuation.finish()
            replacement.events.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            service.stopSystemAudioCapture()
            try await service.finishStoppingSystemAudioCapture()
            try await service.startSystemAudioCapture()
            #expect(try await nativeErrorNext(replacement.events.stream, trace: replacement.trace) == .startEntered)
            service.receiveStreamFailure(nativeError("old failure"), from: old)
            service.receiveAudioSampleBuffer(sample, from: replacement)
            #expect(receiver.bufferCount == 1)
            #expect(service.isCapturing)
            service.receiveStreamFailure(nativeError("replacement failure"), from: replacement)
            #expect(try await nativeErrorNext(receiver.events.stream, trace: receiver.trace) == "replacement failure")
            #expect(receiver.failureCount == 1)
            #expect(try await nativeErrorNext(replacement.events.stream, trace: replacement.trace) == .stopEntered)
            try await service.finishStoppingSystemAudioCapture()
            #expect(old.stopCalls == 1)
            #expect(replacement.stopCalls == 1)
            #expect(service.lastError?.contains("old failure") == false)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test(arguments: [false, true])
    func pendingStartupErrorCannotPublishSuccessOrLoseItsControlEvent(startThrows: Bool) async throws {
        let startGate = NativeErrorGate()
        let stream = NativeErrorStream(startGate: startGate,
            startError: startThrows ? nativeError("SDK startup rejected") : nil)
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream })
        let receiver = NativeErrorReceiver()
        service.register(receiver)
        var startup: Task<Void, Error>?
        @MainActor func cleanup() async {
            await startGate.open()
            startup?.cancel()
            _ = await startup?.result
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await stream.stopCapture()
            receiver.events.continuation.finish()
            stream.events.continuation.finish()
        }
        do {
            startup = Task { try await service.startSystemAudioCapture() }
            #expect(try await nativeErrorNext(stream.events.stream, trace: stream.trace) == .startEntered)
            service.receiveStreamFailure(nativeError("pending native failure"), from: stream)
            await startGate.open()
            switch await startup?.result {
            case .some(.success): Issue.record("Failed native startup published capture success")
            case .some(.failure): break
            case .none: Issue.record("The fixture lost its owned startup")
            }
            #expect(try await nativeErrorNext(receiver.events.stream, trace: receiver.trace) == "pending native failure")
            service.stopSystemAudioCapture()
            try await service.finishStoppingSystemAudioCapture()
            #expect(receiver.failureCount == 1)
            #expect(!service.isCapturing)
            #expect(!stream.running)
            #expect(service.lastError?.contains("pending native failure") == true)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func queuedOldErrorCannotPublishAfterExplicitStopAndRestart() async throws {
        let old = NativeErrorStream()
        let replacement = NativeErrorStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : replacement
        })
        let receiver = NativeErrorReceiver()
        service.register(receiver)
        @MainActor func cleanup() async {
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await old.stopCapture()
            try? await replacement.stopCapture()
            receiver.events.continuation.finish()
            old.events.continuation.finish()
            replacement.events.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            // There is no await between callback admission and explicit stop:
            // the queued MainActor publication must see the invalidated epoch.
            service.receiveStreamFailure(nativeError("queued old failure"), from: old)
            service.stopSystemAudioCapture()
            try await service.finishStoppingSystemAudioCapture()
            try await service.startSystemAudioCapture()
            #expect(service.isCapturing)
            #expect(service.lastError == nil)
            #expect(receiver.failureCount == 0)
            #expect(old.stopCalls == 1)
            #expect(replacement.stopCalls == 0)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func nativeFailureStopErrorRemainsVisibleAndRejectsReplacement() async throws {
        let failed = NativeErrorStream(stopError: nativeError("SDK stop rejected"))
        let replacement = NativeErrorStream()
        var creations = 0
        let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? failed : replacement
        })
        let receiver = NativeErrorReceiver()
        service.register(receiver)
        @MainActor func cleanup() async {
            failed.clearStopError()
            service.unregister(receiver)
            service.stopSystemAudioCapture()
            try? await service.finishStoppingSystemAudioCapture()
            try? await failed.stopCapture()
            try? await replacement.stopCapture()
            receiver.events.continuation.finish()
            failed.events.continuation.finish()
            replacement.events.continuation.finish()
        }
        do {
            try await service.startSystemAudioCapture()
            #expect(try await nativeErrorNext(failed.events.stream, trace: failed.trace) == .startEntered)
            service.receiveStreamFailure(nativeError("native runtime failed"), from: failed)
            #expect(try await nativeErrorNext(receiver.events.stream, trace: receiver.trace) == "native runtime failed")
            #expect(try await nativeErrorNext(failed.events.stream, trace: failed.trace) == .stopEntered)
            var stopRejected = false
            do { try await service.finishStoppingSystemAudioCapture() }
            catch { stopRejected = true }
            #expect(stopRejected)
            #expect(failed.running, "Rejected stop is not resource exit")
            var replacementRejected = false
            do { try await service.startSystemAudioCapture() }
            catch { replacementRejected = true }
            #expect(replacementRejected)
            #expect(creations == 1)
            #expect(service.lastError?.contains("SDK stop rejected") == true)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

private enum NativeErrorStreamEvent: Sendable, Equatable { case startEntered, stopEntered }

private actor NativeErrorGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class NativeErrorStream: SystemAudioCaptureStream {
    let trace = TestEventWaitTrace(label: "native_error_stream")
    private let lock = NSLock()
    private let startGate: NativeErrorGate?
    private let stopGate: NativeErrorGate?
    private let startError: Error?
    private var stopError: Error?
    private var active = false
    private var stops = 0
    let events = AsyncStream<NativeErrorStreamEvent>.makeStream()
    var running: Bool { lock.withLock { active } }
    var stopCalls: Int { lock.withLock { stops } }
    init(startGate: NativeErrorGate? = nil, stopGate: NativeErrorGate? = nil,
        startError: Error? = nil, stopError: Error? = nil) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.startError = startError
        self.stopError = stopError
    }
    func startCapture() async throws {
        trace.mark("producer.start.yield.before")
        let yielded = events.continuation.yield(.startEntered)
        trace.mark("producer.start.yield.\(yielded)")
        await startGate?.wait()
        lock.withLock { active = true }
        if let startError { throw startError }
    }
    func stopCapture() async throws {
        let failure = lock.withLock { stops += 1; return stopError }
        trace.mark("producer.stop.yield.before")
        let yielded = events.continuation.yield(.stopEntered)
        trace.mark("producer.stop.yield.\(yielded)")
        await stopGate?.wait()
        if let failure { throw failure }
        lock.withLock { active = false }
    }
    func clearStopError() { lock.withLock { stopError = nil } }
}

private final class NativeErrorReceiver: SystemAudioBufferDelegate {
    let trace = TestEventWaitTrace(label: "native_error_receiver")
    private let lock = NSLock()
    private var buffers = 0
    private var failures = 0
    let events = AsyncStream<String>.makeStream()
    var bufferCount: Int { lock.withLock { buffers } }
    var failureCount: Int { lock.withLock { failures } }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.withLock { buffers += 1 }
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {
        lock.withLock { failures += 1 }
        trace.mark("producer.error.yield.before")
        let yielded = events.continuation.yield(error.localizedDescription)
        trace.mark("producer.error.yield.\(yielded)")
    }
}

private func nativeError(_ text: String) -> NSError {
    NSError(domain: "Hireva.SyntheticNativeStream", code: 1,
        userInfo: [NSLocalizedDescriptionKey: text])
}

private func nativeErrorNext<Value: Sendable>(_ stream: AsyncStream<Value>,
    trace: TestEventWaitTrace = .init(label: "native_error_control")) async throws -> Value {
    try await trace.nextEvent(in: stream, event: "control")
}

private func nativeErrorSample() throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
    pcm.frameLength = 16
    for index in 0..<16 { pcm.floatChannelData?[0][index] = 0.1 }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: 16,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    #expect(status == noErr)
    let created = try #require(sample)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(created,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: pcm.audioBufferList) == noErr)
    #expect(CMSampleBufferSetDataReady(created) == noErr)
    return created
}
