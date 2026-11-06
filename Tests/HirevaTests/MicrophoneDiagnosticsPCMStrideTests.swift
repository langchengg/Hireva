import AVFoundation
import Foundation
import Testing
import os
@testable import Hireva

/// Owned synthetic PCM through the actual registered native delegate path.
/// No real microphone, capture permission, ASR, model or shared engine is used.
@MainActor
struct MicrophoneDiagnosticsPCMStrideTests {
    @Test(arguments: DiagnosticsFloatLayout.allCases)
    func aLastFrameImpulseHasTheSamePhysicalLevelAcrossFloatLayouts(layout: DiagnosticsFloatLayout) async throws {
        let buffer = try makeImpulse(layout: layout)
        let io = DiagnosticsStrideEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsStrideJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic PCM Input" }, onCallbackScheduled: { jobs.record($0) })
        do {
            try service.startMeteringForCapture()
            #expect(!service.isRunning, "Metering is attached to a capture owner, not a standalone microphone test.")
            #expect(manager.registeredDelegateCountForTesting == 1)
            manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 48_000))
            let exactWorkers = jobs.snapshot
            #expect(exactWorkers.count == 1)
            for task in exactWorkers { await task.value }

            // One unit impulse among3 mono or6 stereo scalar samples. This
            // analytic physical expectation does not reproduce the reader loop.
            let rawRMS = sqrt(layout.channels == 1 ? 1.0 / 3 : 1.0 / 6)
            let rawDB = 20 * log10(rawRMS)
            let expectedDisplayRMS = 0.3 * rawRMS
            let expectedDisplayDB = 0.3 * rawDB + 0.7 * -90
            #expect(abs(service.rmsLevel - expectedDisplayRMS) < 0.000_001,
                "The final-frame sample must be read for the selected channel, including its interleaved stride.")
            #expect(abs(service.decibels - expectedDisplayDB) < 0.000_01,
                "Retain the existing smoothing while correcting physical sample indexing.")
            #expect(service.lastError == nil)
            await close(service, jobs: jobs)
            #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
            #expect(!manager.isEngineRunning && !io.tapInstalled)
        } catch {
            await close(service, jobs: jobs)
            throw error
        }
    }

    @Test(arguments: [false, true])
    func emptyOrUnsupportedPCMRetainsTheExistingSilentLevelContract(unsupportedFloat64: Bool) async throws {
        let format = try #require(AVAudioFormat(commonFormat: unsupportedFloat64 ? .pcmFormatFloat64 : .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = unsupportedFloat64 ? 3 : 0
        if unsupportedFloat64 { #expect(buffer.floatChannelData == nil) }
        let io = DiagnosticsStrideEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsStrideJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic PCM Input" }, onCallbackScheduled: { jobs.record($0) })
        do {
            try service.startMeteringForCapture()
            manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 48_000))
            for task in jobs.snapshot { await task.value }
            #expect(service.rmsLevel == 0 && service.decibels == -90 && service.lastError == nil)
            await close(service, jobs: jobs)
            #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
            #expect(!manager.isEngineRunning && !io.tapInstalled)
        } catch {
            await close(service, jobs: jobs)
            throw error
        }
    }

    private func makeImpulse(layout: DiagnosticsFloatLayout) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: AVAudioChannelCount(layout.channels), interleaved: layout.interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        #expect(buffer.stride == (layout.interleaved ? layout.channels : 1))
        if layout.interleaved {
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            try #require(buffers.count == 1 && buffers[0].mNumberChannels == 2)
            try #require(Int(buffers[0].mDataByteSize) >= 6 * MemoryLayout<Float>.size)
            let samples = try #require(buffers[0].mData).assumingMemoryBound(to: Float.self)
            // Write the raw interleaved allocation, not the product's channel
            // pointer/stride algorithm. Both earlier frames are complete silence.
            for index in 0..<6 { samples[index] = 0 }
            samples[layout.impulseChannel == 0 ? 4 : 5] = 1
        } else {
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<layout.channels {
                for frame in 0..<3 { channels[channel][frame] = 0 }
            }
            channels[layout.impulseChannel][2] = 1
        }
        return buffer
    }
    private func close(_ service: MicrophoneDiagnosticsService, jobs: DiagnosticsStrideJobs) async {
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
    }
}

enum DiagnosticsFloatLayout: CaseIterable, Sendable {
    case mono, planarLeft, planarRight, interleavedLeft, interleavedRight
    var channels: Int { self == .mono ? 1 : 2 }
    var interleaved: Bool { self == .interleavedLeft || self == .interleavedRight }
    var impulseChannel: Int { self == .planarRight || self == .interleavedRight ? 1 : 0 }
}

private final class DiagnosticsStrideJobs: Sendable {
    private let jobs = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    func record(_ task: Task<Void, Never>) { jobs.withLock { $0.append(task) } }
    var snapshot: [Task<Void, Never>] { jobs.withLock { $0 } }
}
private final class DiagnosticsStrideEngine: Sendable {
    private struct State: Sendable { var running = false; var tap = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var tapInstalled: Bool { state.withLock { $0.tap } }
    var operations: AudioEngineStartupTestingOperations {
        .init(installAndPrepareTap: { [self] in
            state.withLock { $0.tap = true }
        }, start: { [self] in state.withLock { $0.running = true } },
        stop: { [self] in state.withLock { $0.running = false } },
        removeTap: { [self] in state.withLock { $0.tap = false } },
        reset: {}, isRunning: { [self] in state.withLock { $0.running } })
    }
}
