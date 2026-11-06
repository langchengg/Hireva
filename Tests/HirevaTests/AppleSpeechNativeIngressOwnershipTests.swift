import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Synthetic native callbacks exercise actual receivers/service workers/App
/// runtime admission. This is not microphone/SCK/Apple model/locality evidence.
@MainActor
struct AppleSpeechNativeIngressOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [64, 128])
    func actualPCMReceiverBatchesPreserveCountsAtTheAppRuntimeBoundary(bufferCount: Int) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        // Initialization starts a legitimate latency refresh. Supersede and join
        // it before observing PCM-only publication, without disabling that path.
        let baselineRefresh = app.refreshLatencyAverages()
        await baselineRefresh?.value
        let service = makeService(), native = ScreenCaptureKitSystemAudioCaptureService()
        let batches = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var publications = 0
        let observer = app.diagnosticsState.objectWillChange.sink { publications += 1 }
        @MainActor func cleanup() async {
            service.stop()
            await service.finishStoppingAudioInput()
            service.onRuntimeEvent = nil
            batches.continuation.finish(); observer.cancel()
            await app.shutdownForTesting()
            try? database.close()
        }
        do {
            service.onRuntimeEvent = { event in
                app.recordTranscriptRuntimeEvent(event)
                if case .audioBufferReceived(_, _, _, let count, _) = event {
                    batches.continuation.yield(count)
                }
            }
            service.startDiagnosticSystemAudioSession(sessionID: "synthetic-native-pcm-batch")
            publications = 0
            let session = try #require(service.systemAudioSession)
            let buffer = try makeBuffer()
            for index in 0..<bufferCount {
                service.systemAudioCaptureReceiver.systemAudioCaptureService(native,
                    didReceive: buffer, at: .init(sampleTime: AVAudioFramePosition(index), atRate: 16000))
            }
            #expect(session.totalBuffersAppended == bufferCount)
            #expect(session.pendingPCMDisplaySnapshotsForTesting == 1)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == 0,
                "Native PCM must not synchronously publish App presentation state.")
            let count = try await TestEventWaitTrace(label: #function).nextEvent(in: batches.stream, event: "actual_numeric_pcm_batch")
            #expect(count == bufferCount)
            #expect(app.transcriptRuntimeDiagnostics.audioBufferCount == bufferCount)
            #expect(app.totalSystemAudioASRBuffersAppended == bufferCount)
            #expect(session.pendingPCMDisplaySnapshotsForTesting == 0)
            #expect(publications == 0)
            #expect(!app.diagnosticsState.recentEvents.contains { $0.name == "audioBufferReceived" })
            await cleanup()
            #expect(!service.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: AppleIngressFixtureSource.allCases)
    fileprivate func repeatedNativeFailuresHaveOneOwnedControlAndPreserveTheOtherSource(source: AppleIngressFixtureSource) async throws {
        let service = makeService(), manager = makeManager()
        let native = ScreenCaptureKitSystemAudioCaptureService()
        let handled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        do {
            try await service.start(sessionID: "synthetic-control-source", captureMode: .microphoneAndSystem)
            service.onNativeControlHandledForTesting = { _, _ in handled.continuation.yield(()) }
            for _ in 0..<100 {
                switch source {
                case .microphone:
                    service.microphoneCaptureReceiver.audioEngineManager(manager, didFailWith: AppleIngressFixtureFailure.source)
                case .systemAudio:
                    service.systemAudioCaptureReceiver.systemAudioCaptureService(native, didFailWithError: AppleIngressFixtureFailure.source)
                }
            }
            #expect(service.pendingNativeControlsForTesting == 1)
            _ = try await TestEventWaitTrace(label: #function).nextEvent(in: handled.stream, event: "actual_source_failure_control")
            switch source {
            case .microphone:
                #expect(service.microphoneSession?.isRecognitionActive == false)
                #expect(service.systemAudioSession?.isRecognitionActive == true)
            case .systemAudio:
                #expect(service.systemAudioSession?.isRecognitionActive == false)
                #expect(service.microphoneSession?.isRecognitionActive == true)
            }
            #expect(service.terminalError == nil)
            service.stop(); await service.finishStoppingAudioInput()
            #expect(!service.hasUnreleasedAudioInput)
            handled.continuation.finish()
        } catch {
            service.stop(); await service.finishStoppingAudioInput()
            handled.continuation.finish(); throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aNativeRouteThenOldFailureCannotFailTheReplacementRequestInTheSameCaptureEpoch() async throws {
        let service = makeService(), manager = makeManager()
        let handled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var route: Task<Void, Never>?
        @MainActor func cleanup() async {
            route?.cancel(); service.stop()
            await route?.value
            await service.finishStoppingAudioInput()
            handled.continuation.finish()
        }
        do {
            try await service.start(sessionID: "synthetic-route-binding", captureMode: .microphoneAndSystem)
            let old = try #require(service.microphoneSession)
            let healthy = try #require(service.systemAudioSession)
            let oldReceiver = service.microphoneCaptureReceiver
            service.onNativeControlHandledForTesting = { _, _ in
                route = service.routeRecoveryTaskForTesting
                handled.continuation.yield(())
            }
            oldReceiver.audioEngineManagerDidRestartAfterRouteChange(manager)
            oldReceiver.audioEngineManager(manager, didFailWith: AppleIngressFixtureFailure.source)
            #expect(service.pendingNativeControlsForTesting == 2)
            _ = try await TestEventWaitTrace(label: #function).nextEvent(in: handled.stream, event: "actual_route_control")
            #expect(route != nil)
            await route?.value
            let current = try #require(service.microphoneSession)
            #expect(current !== old)
            #expect(current.isRecognitionActive)
            #expect(current.lastError == nil)
            #expect(service.systemAudioSession === healthy)
            #expect(service.terminalError == nil)
            #expect(service.routeRecoveryTaskForTesting == nil)
            let buffer = try makeBuffer()
            oldReceiver.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
            #expect(current.totalBuffersAppended == 0)
            service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 1, atRate: 16000))
            #expect(current.totalBuffersAppended == 1)
            await cleanup()
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func aDelayedOldJoinSubmittedAfterReplacementStartupDoesNotWaitForTheOpenNewControlWorker() async throws {
        let service = makeService()
        let joined = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var pendingJoin: Task<Void, Never>?
        @MainActor func cleanup() async {
            service.stop()
            await pendingJoin?.value
            await service.finishStoppingAudioInput()
            joined.continuation.finish()
        }
        do {
            try await service.start(sessionID: "synthetic-join-old", captureMode: .systemAudioOnly)
            service.stop()
            try await service.start(sessionID: "synthetic-join-new", captureMode: .systemAudioOnly)
            let current = try #require(service.systemAudioSession)
            pendingJoin = Task { @MainActor in
                await service.finishStoppingAudioInput()
                joined.continuation.yield(())
            }
            _ = try await TestEventWaitTrace(label: #function).nextEvent(in: joined.stream, event: "closed_old_resources_joined")
            #expect(service.systemAudioSession === current)
            #expect(current.isRecognitionActive)
            #expect(current.request != nil)
            await cleanup()
        } catch { await cleanup(); throw error }
    }

    private func makeService() -> AppleSpeechTranscriptionService {
        .init(stopTestingOperations: .init(unregisterMicrophone: { _ in },
            unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
    }
    private func makeManager() -> AudioEngineManager {
        .init(testingOperations: .init(installAndPrepareTap: {}, start: {}, stop: {},
            removeTap: {}, reset: {}, isRunning: { false }))
    }
    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1; buffer.floatChannelData![0][0] = 0
        return buffer
    }
}

private enum AppleIngressFixtureSource: CaseIterable, Sendable { case microphone, systemAudio }
private enum AppleIngressFixtureFailure: Error { case source }
