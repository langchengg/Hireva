import AVFoundation
import Foundation
import Testing
@testable import Hireva

/// Real Combined receiver -> numeric Service worker -> AppRuntime diagnostic
/// path, followed by the actual timer callback. No model/device is exercised.
@MainActor
struct AppleSpeechSourceCounterBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func actualCombinedMicrophoneBatchesCannotRaiseSystemASRCountOrLetMonitoringDecreaseIt() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let baselineRefresh = app.refreshLatencyAverages()
        await baselineRefresh?.value
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        let manager = AudioEngineManager(testingOperations: .init(installAndPrepareTap: {}, start: {},
            stop: {}, removeTap: {}, reset: {}, isRunning: { false }))
        let native = ScreenCaptureKitSystemAudioCaptureService()
        let batches = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let trace = TestEventWaitTrace(label: #function)
        @MainActor func cleanup() async {
            service.stop(); await service.finishStoppingAudioInput()
            service.onRuntimeEvent = nil
            app.appleSpeechService = nil
            batches.continuation.finish()
            await app.shutdownForTesting()
            try? database.close()
        }
        do {
            app.appleSpeechService = service
            service.onRuntimeEvent = { event in
                app.recordTranscriptRuntimeEvent(event)
                if case .audioBufferReceived = event { batches.continuation.yield(()) }
            }
            try await service.start(sessionID: "synthetic-combined-counter", captureMode: .microphoneAndSystem)
            let microphone = try #require(service.microphoneSession)
            let system = try #require(service.systemAudioSession)
            let buffer = try makeBuffer()
            for offset in 0..<3 {
                service.systemAudioCaptureReceiver.systemAudioCaptureService(native, didReceive: buffer,
                    at: .init(sampleTime: AVAudioFramePosition(offset), atRate: 16000))
            }
            for offset in 0..<7 {
                service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer,
                    at: .init(sampleTime: AVAudioFramePosition(offset), atRate: 16000))
            }
            _ = try await trace.nextEvent(in: batches.stream, event: "first_actual_source_batch")
            _ = try await trace.nextEvent(in: batches.stream, event: "second_actual_source_batch")
            #expect(microphone.totalBuffersAppended == 7)
            #expect(system.totalBuffersAppended == 3)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 10)
            #expect(app.totalSystemAudioASRBuffersAppended == 3,
                "Only three system buffers reached this request; the seven microphone buffers cannot count as system ASR.")
            let beforeMonitoring = app.totalSystemAudioASRBuffersAppended
            // LiveState is idle: the actual count-monitoring branch executes,
            // then returns before microphone meter/global device inspection.
            app.monitorAudioSignal()
            #expect(app.totalSystemAudioASRBuffersAppended == beforeMonitoring,
                "The periodic monitor must observe the same count authority rather than overwrite accumulated diagnostic state.")
            #expect(app.totalSystemAudioASRBuffersAppended == 3)
            for offset in 7..<9 {
                service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer,
                    at: .init(sampleTime: AVAudioFramePosition(offset), atRate: 16000))
            }
            _ = try await trace.nextEvent(in: batches.stream, event: "additional_actual_microphone_batch")
            #expect(microphone.totalBuffersAppended == 9)
            #expect(system.totalBuffersAppended == 3)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 12)
            #expect(app.totalSystemAudioASRBuffersAppended == 3)
            app.monitorAudioSignal()
            #expect(app.totalSystemAudioASRBuffersAppended == 3)
            await cleanup()
            #expect(!service.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1; buffer.floatChannelData![0][0] = 0
        return buffer
    }
}
