import AVFoundation
import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppleNativeDelegateEpochTests {
    @Test(.timeLimit(.minutes(1)), arguments: AppleNativeCallbackSource.allCases)
    fileprivate func oldNativePCMReceiverCannotAppendToANewSpeechRound(source: AppleNativeCallbackSource) async throws {
        let service = makeService(), manager = makeManager()
        let systemCapture = ScreenCaptureKitSystemAudioCaptureService()
        do {
            try await service.start(sessionID: "synthetic-apple-old", captureMode: .microphoneAndSystem)
            let oldMicrophone = service.microphoneCaptureReceiver
            let oldSystem = service.systemAudioCaptureReceiver
            try await service.start(sessionID: "synthetic-apple-new", captureMode: .microphoneAndSystem)
            let mic = try #require(service.microphoneSession), system = try #require(service.systemAudioSession)
            let buffer = try makeBuffer()
            switch source {
            case .microphone: oldMicrophone.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
            case .systemAudio: oldSystem.systemAudioCaptureService(systemCapture, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
            }
            #expect(mic.totalBuffersAppended == 0)
            #expect(system.totalBuffersAppended == 0,
                "Old capture delegates must close their own epoch, rather than reading a new mutable session slot.")
            switch source {
            case .microphone:
                service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 1, atRate: 16000))
                #expect(mic.totalBuffersAppended == 1)
                #expect(system.totalBuffersAppended == 0)
            case .systemAudio:
                service.systemAudioCaptureReceiver.systemAudioCaptureService(systemCapture, didReceive: buffer, at: .init(sampleTime: 1, atRate: 16000))
                #expect(system.totalBuffersAppended == 1)
                #expect(mic.totalBuffersAppended == 0)
            }
            await cleanup(service)
        } catch { await cleanup(service); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: AppleNativeCallbackSource.allCases)
    fileprivate func oldNativeFailureCannotStopTheNewSource(source: AppleNativeCallbackSource) async throws {
        let service = makeService(), manager = makeManager()
        let systemCapture = ScreenCaptureKitSystemAudioCaptureService()
        do {
            try await service.start(sessionID: "synthetic-apple-old", captureMode: .microphoneAndSystem)
            let oldMicrophone = service.microphoneCaptureReceiver
            let oldSystem = service.systemAudioCaptureReceiver
            try await service.start(sessionID: "synthetic-apple-new", captureMode: .microphoneAndSystem)
            let mic = try #require(service.microphoneSession), system = try #require(service.systemAudioSession)
            switch source {
            case .microphone: oldMicrophone.audioEngineManager(manager, didFailWith: AppleEpochFixtureFailure.oldNativeSource)
            case .systemAudio: oldSystem.systemAudioCaptureService(systemCapture, didFailWithError: AppleEpochFixtureFailure.oldNativeSource)
            }
            #expect(mic.isRecognitionActive)
            #expect(system.isRecognitionActive)
            #expect(service.microphoneSession === mic)
            #expect(service.systemAudioSession === system)
            #expect(service.terminalError == nil)
            await cleanup(service)
        } catch { await cleanup(service); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func oldNativeRouteRestartCannotReplaceTheNewMicrophoneSession() async throws {
        let service = makeService(), manager = makeManager()
        do {
            try await service.start(sessionID: "synthetic-apple-old", captureMode: .microphoneAndSystem)
            let oldReceiver = service.microphoneCaptureReceiver
            try await service.start(sessionID: "synthetic-apple-new", captureMode: .microphoneAndSystem)
            let current = try #require(service.microphoneSession)
            oldReceiver.audioEngineManagerDidRestartAfterRouteChange(manager)
            #expect(service.microphoneSession === current,
                "An old route callback cannot spin up a replacement request inside the new round.")
            #expect(current.isRecognitionActive)
            await cleanup(service)
        } catch { await cleanup(service); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCurrentSourceFailureRetainsTheHealthyChannelAndUnknownSpeaker() async throws {
        let service = makeService(), manager = makeManager()
        do {
            try await service.start(sessionID: "synthetic-apple-current", captureMode: .microphoneAndSystem)
            let stream = service.segments
            let handled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            service.onNativeControlHandledForTesting = { _, _ in handled.continuation.yield(()) }
            defer { handled.continuation.finish() }
            service.microphoneCaptureReceiver.audioEngineManager(manager, didFailWith: AppleEpochFixtureFailure.currentNativeSource)
            _ = try await TestEventWaitTrace(label: #function).nextEvent(in: handled.stream, event: "native_source_failure_handled")
            #expect(service.microphoneSession?.isRecognitionActive == false)
            #expect(service.systemAudioSession?.isRecognitionActive == true)
            service.systemAudioSession?.simulateEmit(text: "Synthetic system question?", isFinal: true)
            await cleanup(service)
            var values: [TranscriptSegment] = []
            for await segment in stream { values.append(segment) }
            #expect(values.count == 1)
            #expect(values.first?.source == .systemAudio)
            #expect(values.first?.speaker == .unknown)
            #expect(values.first?.sessionID == "synthetic-apple-current")
        } catch { await cleanup(service); throw error }
    }

    private func makeService() -> AppleSpeechTranscriptionService {
        AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
    }
    private func makeManager() -> AudioEngineManager {
        AudioEngineManager(testingOperations: .init(installAndPrepareTap: {}, start: {}, stop: {},
            removeTap: {}, reset: {}, isRunning: { false }))
    }
    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0
        return buffer
    }
    private func cleanup(_ service: AppleSpeechTranscriptionService) async {
        // Capture before stop clears the slot. Join only this service's real
        // legacy route worker; mocked stop never touches a global engine/SCK.
        let route = service.routeRecoveryTaskForTesting
        route?.cancel()
        service.stop()
        await route?.value
        await service.finishStoppingAudioInput()
    }
}

private enum AppleNativeCallbackSource: CaseIterable, Sendable { case microphone, systemAudio }
private enum AppleEpochFixtureFailure: Error { case oldNativeSource, currentNativeSource }
