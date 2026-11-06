import Foundation
import Testing
@testable import Hireva

/// Actual recognition callback entry and the same Service-owned native controls.
/// Synthetic native I/O only; a failed RED worker is released before its join.
@MainActor
struct AppleSpeechRecognitionControlRetirementTests {
    @Test(.timeLimit(.minutes(1)), arguments: RecognitionControlSource.allCases)
    fileprivate func actualRecognitionFailureFinishesOnlyItsBoundControlWorker(
        source: RecognitionControlSource
    ) async throws {
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        @MainActor func cleanup() async { service.stop(); await service.finishStoppingAudioInput() }
        do {
            try await service.start(sessionID: "synthetic-recognition-control", captureMode: .microphoneAndSystem)
            let microphone = try #require(service.microphoneCaptureReceiver as? AppleSpeechNativeReceiver)
            let system = try #require(service.systemAudioCaptureReceiver as? AppleSpeechNativeReceiver)
            let microphoneSession = try #require(service.microphoneSession)
            let systemSession = try #require(service.systemAudioSession)
            let failed = source == .microphone ? microphone : system
            let healthy = source == .microphone ? system : microphone
            let failedSession = source == .microphone ? microphoneSession : systemSession
            let healthySession = source == .microphone ? systemSession : microphoneSession
            let input = try #require(failedSession.nativePCMInput)
            let worker = try #require(service.ownedNativeControlWorkersForTesting.first {
                $0.controls === failed.controls
            })
            #expect(failed.input === input)
            #expect(service.ownedNativeControlWorkersForTesting.count == 2)
            let recognitionID = failedSession.recognitionTaskIDForTesting
            failedSession.receiveRecognitionError(RecognitionControlFailure.current, recognitionTaskID: recognitionID)
            #expect(failedSession.serviceState == .failed)
            #expect((failedSession.lastError as? RecognitionControlFailure) == .current)
            #expect(!input.isAcceptingForTesting)
            #expect(!failed.controls.isAccepting,
                "Recognition error must finish its exact source control signal before whole-capture stop.")
            #expect(healthy.controls.isAccepting)
            #expect(healthySession.isRecognitionActive)
            #expect(service.terminalError == nil)
            // Release the old behavior unconditionally on RED. Await the exact
            // captured worker, never Service.stop from within that same worker.
            failed.controls.close()
            await worker.task.value
            await failedSession.finishStoppingAudioInput()
            #expect(service.ownedNativeControlWorkersForTesting.count == 1)
            #expect(!service.ownedNativeControlWorkersForTesting.contains { $0.controls === failed.controls })
            #expect(service.ownedNativeControlWorkersForTesting.contains { $0.controls === healthy.controls })
            #expect(failedSession.serviceState == .failed)
            #expect((failedSession.lastError as? RecognitionControlFailure) == .current)
            #expect(healthy.controls.isAccepting)
            #expect(healthySession.isRecognitionActive)
            #expect(service.terminalError == nil)
            await cleanup()
            #expect(service.ownedNativeControlWorkersForTesting.isEmpty)
            #expect(!service.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }
}

private enum RecognitionControlSource: CaseIterable, Equatable, Sendable { case microphone, systemAudio }
private enum RecognitionControlFailure: Error, Equatable { case current }
