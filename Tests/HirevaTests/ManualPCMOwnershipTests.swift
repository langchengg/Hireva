import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Actual delegate callbacks and recording service, with a separate synthetic
/// SCK instance. No microphone or native stream is started by these tests.
@Suite @MainActor
struct ManualPCMOwnershipTests {
    @Test func frameworkBufferReuseCannotChangeRecordedSamples() async throws {
        try await withService { service, audio in
        try await service.startCapture(source: .systemAudio, onTimeout: {})
        let buffer = try samples()
        service.systemAudioCaptureService(audio, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
        buffer.floatChannelData![1][0] = 0
        let recorded = service.stopCaptureAndReturnBuffers()
        #expect(recorded.count == 1)
        #expect(recorded.first !== buffer, "AVAudioEngine may reuse the original callback allocation")
        #expect(recorded.first?.floatChannelData?[1][0] == 1)
        }
    }

    @Test func lateAndUnselectedSourceCallbacksCannotAppendAfterStop() async throws {
        try await withService { service, audio in
        let buffer = try samples()
        service.systemAudioCaptureService(audio, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
        #expect(service.stopCaptureAndReturnBuffers().isEmpty)
        try await service.startCapture(source: .systemAudio, onTimeout: {})
        // This is a callback invocation, not microphone registration/capture.
        service.audioEngineManager(.shared, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
        #expect(service.stopCaptureAndReturnBuffers().isEmpty)
        service.systemAudioCaptureService(audio, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
        #expect(service.stopCaptureAndReturnBuffers().isEmpty)
        }
    }

    @Test func interleavedMeteringReadsEachFrameUsingItsStride() async throws {
        try await withService { service, audio in
        try await service.startCapture(source: .systemAudio, onTimeout: {})
        let observed = AsyncStream<Int>.makeStream()
        let subscription = service.$capturedBufferCount.sink {
            if $0 > 0 { observed.continuation.yield($0) }
        }
        defer { subscription.cancel(); observed.continuation.finish() }
        let buffer = try samples()
        service.systemAudioCaptureService(audio, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
        try await GenerationCoordinator.withTimeout(seconds: 15) {
            var iterator = observed.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        #expect(abs(service.rmsLevel - sqrt(1.0 / 8.0)) < 0.00001)
        }
    }

    @Test func capacityOverflowIsVisibleAndCannotAccumulateUnlimitedPCM() async throws {
        try await withService(capacity: 16) { service, audio in
        try await service.startCapture(source: .systemAudio, onTimeout: {})
        service.systemAudioCaptureService(audio, didReceive: try samples(), at: .init(sampleTime: 0, atRate: 16000))
        let recorded = service.stopCaptureAndReturnBuffers()
        #expect(recorded.isEmpty, "A 32-byte buffer exceeds this isolated 16-byte capacity")
        #expect(service.captureFailure != nil, "Overflow must be observable, never silently corrupt the answer")
        }
    }

    @Test(arguments: [false, true])
    func copiedOldReceiverCannotWriteOrFailTheNextEpoch(oldCallbackFirst: Bool) async throws {
        try await withService { service, audio in
            for _ in 0..<20 {
                try await service.startCapture(source: .systemAudio, onTimeout: {})
                let old = try #require(service.activeBufferReceiver)
                _ = service.stopCaptureAndReturnBuffers()
                try await service.startCapture(source: .systemAudio, onTimeout: {})
                let current = try #require(service.activeBufferReceiver)
                let buffer = try samples()
                let time = AVAudioTime(sampleTime: 0, atRate: 16000)
                if oldCallbackFirst { old.systemAudioCaptureService(audio, didReceive: buffer, at: time) }
                current.systemAudioCaptureService(audio, didReceive: buffer, at: time)
                if !oldCallbackFirst { old.systemAudioCaptureService(audio, didReceive: buffer, at: time) }
                old.systemAudioCaptureService(audio, didFailWithError: CancellationError())
                #expect(service.stopCaptureAndReturnBuffers().count == 1)
                #expect(service.captureFailure == nil)
            }
        }
    }

    private func withService(capacity: Int = 32 * 1024 * 1024,
        body: @MainActor (ManualQuestionCaptureService, ScreenCaptureKitSystemAudioCaptureService) async throws -> Void) async throws {
        let audio = ScreenCaptureKitSystemAudioCaptureService()
        let service = ManualQuestionCaptureService(systemAudioCaptureService: audio, maximumStoredBytes: capacity)
        do { try await body(service, audio) }
        catch {
            try? await service.shutdown()
            throw error
        }
        try await service.shutdown()
    }

    private func samples() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<4 { data[channel][frame * buffer.stride] = 0 }
        }
        data[1][0] = 1
        return buffer
    }
}
