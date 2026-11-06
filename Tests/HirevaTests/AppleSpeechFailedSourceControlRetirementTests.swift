import AVFoundation
import Foundation
import Testing
@testable import Hireva

/// Actual source receivers and Service workers; synthetic native I/O only.
/// This tests source control retirement, not App system-error policy or native
/// device/recognition resource exit. Every owned waiter is released on red.
@MainActor
struct AppleSpeechFailedSourceControlRetirementTests {
    @Test(.timeLimit(.minutes(1)), arguments: AppleControlRetirementSource.allCases)
    fileprivate func aFailedSourceClosesAndJoinsItsOwnControlWorkerWhileTheHealthySourceContinues(
        source: AppleControlRetirementSource
    ) async throws {
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        let manager = AudioEngineManager(testingOperations: .init(installAndPrepareTap: {},
            start: {}, stop: {}, removeTap: {}, reset: {}, isRunning: { false }))
        let native = ScreenCaptureKitSystemAudioCaptureService()
        let handled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        @MainActor func cleanup() async {
            service.stop(); await service.finishStoppingAudioInput()
            handled.continuation.finish()
        }
        do {
            try await service.start(sessionID: "synthetic-failed-control-retirement", captureMode: .microphoneAndSystem)
            let microphone = try #require(service.microphoneCaptureReceiver as? AppleSpeechNativeReceiver)
            let system = try #require(service.systemAudioCaptureReceiver as? AppleSpeechNativeReceiver)
            let failed = source == .microphone ? microphone : system
            let healthy = source == .microphone ? system : microphone
            let worker = try #require(service.ownedNativeControlWorkersForTesting.first {
                $0.controls === failed.controls
            })
            service.onNativeControlHandledForTesting = { _, _ in handled.continuation.yield(()) }
            switch source {
            case .microphone: failed.audioEngineManager(manager, didFailWith: AppleControlRetirementFailure.source)
            case .systemAudio: failed.systemAudioCaptureService(native, didFailWithError: AppleControlRetirementFailure.source)
            }
            _ = try await TestEventWaitTrace(label: #function).nextEvent(in: handled.stream, event: "actual_failed_source_handled")
            #expect(!failed.controls.isAccepting,
                "A failed receiver must finish its exact owned control signal instead of waiting until whole-capture stop.")
            #expect(healthy.controls.isAccepting)
            #expect(service.terminalError == nil)
            // Release the defect on red before joining. The worker's original
            // captured handle is used; a replacement source is never stopped.
            failed.controls.close()
            await worker.task.value
            #expect(!service.ownedNativeControlWorkersForTesting.contains { $0.controls === failed.controls })
            #expect(service.ownedNativeControlWorkersForTesting.contains { $0.controls === healthy.controls })
            switch source {
            case .microphone:
                #expect(service.microphoneSession?.isRecognitionActive == false)
                #expect(service.systemAudioSession?.isRecognitionActive == true)
            case .systemAudio:
                #expect(service.systemAudioSession?.isRecognitionActive == false)
                #expect(service.microphoneSession?.isRecognitionActive == true)
            }
            #expect(healthy.controls.isAccepting)
            #expect(service.terminalError == nil)
            await cleanup()
            #expect(!service.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }
}

private enum AppleControlRetirementSource: CaseIterable, Equatable, Sendable { case microphone, systemAudio }
private enum AppleControlRetirementFailure: Error { case source }
