import AVFoundation
import Combine
import CoreMedia
import Foundation
import Testing
@testable import Hireva

/// Safe owned float PCM enters the real CMSampleBuffer conversion/callback and
/// display path. It never opens SCStream, permission, audio device or ASR.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioMetricsPCMStrideTests {
    @Test(arguments: SystemMetricsFloatLayout.allCases)
    func lastFrameImpulseHasTheSamePhysicalLevelAcrossSupportedFloatLayouts(layout: SystemMetricsFloatLayout) async throws {
        let stream = SystemMetricsControlledStream()
        let native = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream })
        let published = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // The first buffer count is always published, including legacy RED's
        // mistaken zero level. Never wait on the expected nonzero metric.
        let observation = native.totalBuffersReceivedUpdates.dropFirst().sink { count in
            guard count == 1 else { return }
            published.continuation.yield(())
            published.continuation.finish()
        }
        let owned = native.beginSystemAudioCapture()
        @MainActor func cleanup() async throws {
            observation.cancel()
            published.continuation.finish()
            native.stopSystemAudioCapture(capturedReceipt: owned.receipt, retryFailed: false)
            try await native.finishStoppingSystemAudioCapture(capturedReceipt: owned.receipt)
        }
        do {
            try await native.finishStartingSystemAudioCapture(capturedStart: owned.startup,
                capturedReceipt: owned.receipt)
            let sample = try makeSystemMetricsImpulse(layout: layout)
            try await withTaskCancellationHandler {
                // The actual nonisolated callback is called synchronously with
                // the owned SDK value. This test does not claim a native thread
                // or realtime performance measurement.
                native.receiveAudioSampleBuffer(sample, from: stream)
                var notifications = published.stream.makeAsyncIterator()
                try #require(await notifications.next() != nil)
                let rawRMS = sqrt(layout.channels == 1 ? 1.0 / 3 : 1.0 / 6)
                let rawDB = 20 * log10(rawRMS)
                #expect(abs(native.rmsLevel - 0.3 * rawRMS) < 0.000_001,
                    "The last frame must contribute its physical energy for either planar or interleaved layout")
                #expect(abs(native.decibels - (0.3 * rawDB + 0.7 * -90)) < 0.000_01)
                #expect(native.totalBuffersReceived == 1)
                #expect(native.channelCount == layout.channels)
                #expect(native.lastBufferFrameCapacity == 3)
                #expect(native.lastError == nil)
            } onCancel: { published.continuation.finish() }
            try await cleanup()
            #expect(!native.hasOwnedCaptureRuntime && !stream.running)
        } catch {
            do { try await cleanup() }
            catch { Issue.record("The owned synthetic native stream could not be joined: \(error)") }
            throw error
        }
    }
}

enum SystemMetricsFloatLayout: CaseIterable, Sendable {
    case mono, planarLeft, planarRight, interleavedLeft, interleavedRight
    var channels: Int { self == .mono ? 1 : 2 }
    var interleaved: Bool { self == .interleavedLeft || self == .interleavedRight }
    var impulseChannel: Int { self == .planarRight || self == .interleavedRight ? 1 : 0 }
}

@MainActor
private final class SystemMetricsControlledStream: SystemAudioCaptureStream {
    private(set) var running = false
    func startCapture() async throws { running = true }
    func stopCapture() async throws { running = false }
}

private func makeSystemMetricsImpulse(layout: SystemMetricsFloatLayout) throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000, channels: AVAudioChannelCount(layout.channels), interleaved: layout.interleaved))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
    pcm.frameLength = 3
    try #require(pcm.stride == (layout.interleaved ? 2 : 1))
    if layout.interleaved {
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        try #require(buffers.count == 1 && buffers[0].mNumberChannels == 2)
        try #require(Int(buffers[0].mDataByteSize) >= 6 * MemoryLayout<Float>.size)
        let raw = try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)
        // Raw allocation is exactly six initialized scalars. RED's contiguous
        // reads remain within it but miss the impulse in the final frame.
        for index in 0..<6 { raw[index] = 0 }
        raw[layout.impulseChannel == 0 ? 4 : 5] = 1
    } else {
        let channels = try #require(pcm.floatChannelData)
        for channel in 0..<layout.channels {
            for frame in 0..<3 { channels[channel][frame] = 0 }
        }
        channels[layout.impulseChannel][2] = 1
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try #require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: 3,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let created = try #require(sample)
    try #require(CMSampleBufferSetDataBufferFromAudioBufferList(created,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: pcm.audioBufferList) == noErr)
    try #require(CMSampleBufferSetDataReady(created) == noErr)
    return created
}
