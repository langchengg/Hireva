import AVFoundation
import Foundation
import Testing
@testable import Hireva

/// Error handling is called through the actual native callback boundary and
/// existing recognition ID. Only native I/O is substituted; no model or audio.
@MainActor
struct AppleSpeechRecognitionErrorRetirementTests {
    @Test(.timeLimit(.minutes(1)), arguments: AppleRecognitionFailureSource.allCases)
    fileprivate func actualRecognitionFailureClosesOnlyTheFailedRequestAndPreservesHealthyUnknownSpeaker(
        source: AppleRecognitionFailureSource
    ) async throws {
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        let native = ScreenCaptureKitSystemAudioCaptureService()
        let manager = AudioEngineManager(testingOperations: .init(installAndPrepareTap: {}, start: {},
            stop: {}, removeTap: {}, reset: {}, isRunning: { false }))
        @MainActor func cleanup() async { service.stop(); await service.finishStoppingAudioInput() }
        do {
            try await service.start(sessionID: "synthetic-recognition-failure", captureMode: .microphoneAndSystem)
            let stream = service.segments
            let microphone = try #require(service.microphoneSession)
            let system = try #require(service.systemAudioSession)
            let failed = source == .microphone ? microphone : system
            let healthy = source == .microphone ? system : microphone
            let failedInput = try #require(failed.nativePCMInput)
            let oldID = failed.recognitionTaskIDForTesting
            let buffer = try makeBuffer()
            failed.receiveRecognitionError(AppleRecognitionFixtureFailure.current, recognitionTaskID: oldID)
            #expect(failed.serviceState == .failed)
            #expect((failed.lastError as? AppleRecognitionFixtureFailure) == .current)
            #expect(!failed.isRecognitionActive)
            #expect(failed.request == nil)
            #expect(!failedInput.isAcceptingForTesting,
                "Actual recognition error must close the failed request admission, even when Combined has a healthy source.")
            switch source {
            case .microphone:
                service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
                service.systemAudioCaptureReceiver.systemAudioCaptureService(native, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
            case .systemAudio:
                service.systemAudioCaptureReceiver.systemAudioCaptureService(native, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
                service.microphoneCaptureReceiver.audioEngineManager(manager, didReceive: buffer, at: .init(sampleTime: 0, atRate: 16000))
            }
            #expect(failed.totalBuffersAppended == 0)
            #expect(healthy.totalBuffersAppended == 1)
            #expect(healthy.isRecognitionActive)
            #expect(healthy.request != nil)
            #expect(service.terminalError == nil)
            healthy.simulateEmit(text: "Synthetic remaining question?", isFinal: true)
            await cleanup()
            var segments: [TranscriptSegment] = []
            for await segment in stream { segments.append(segment) }
            #expect(segments.count == 1)
            #expect(segments.first?.speaker == .unknown)
            #expect(segments.first?.source == healthy.sessionID.source)
            #expect(segments.first?.sessionID == "synthetic-recognition-failure")
            #expect(!service.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStateObserverCanStartReplacementWithoutOldFailureNotifyingOrClosingIt() async throws {
        weak var observed: AppleSpeechTranscriptionSession?
        var failureNotifications = 0
        let session = AppleSpeechTranscriptionSession(sessionID: .init(source: .microphone),
            parentSessionID: "synthetic-failure-reentrant-replacement", onEmit: { _ in },
            onStateChange: {
                guard let observed, observed.serviceState == .failed else { return }
                observed.startSimulatedRecognitionForDiagnostic()
            }, onFailure: { _ in failureNotifications += 1 },
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        observed = session
        @MainActor func cleanup() async { session.stop(); await session.finishStoppingAudioInput() }
        do {
            session.startSimulatedRecognitionForDiagnostic()
            let old = try #require(session.nativePCMInput)
            let oldID = session.recognitionTaskIDForTesting
            session.receiveRecognitionError(AppleRecognitionFixtureFailure.current, recognitionTaskID: oldID)
            let replacement = try #require(session.nativePCMInput)
            #expect(replacement !== old)
            #expect(session.recognitionTaskIDForTesting != oldID)
            #expect(session.serviceState == .running)
            #expect(session.isRecognitionActive)
            #expect(replacement.isAcceptingForTesting)
            #expect(session.lastError == nil)
            #expect(failureNotifications == 0,
                "The failed-state publisher replaced the request; the old callback cannot notify an owner for that replacement.")
            session.receiveRecognitionError(AppleRecognitionFixtureFailure.late, recognitionTaskID: oldID)
            #expect(session.nativePCMInput === replacement)
            #expect(session.isRecognitionActive)
            #expect(session.lastError == nil)
            #expect(failureNotifications == 0)
            session.appendBuffer(try makeBuffer())
            #expect(session.totalBuffersAppended == 1)
            await cleanup()
            #expect(!session.hasUnreleasedAudioInput)
        } catch { await cleanup(); throw error }
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1; buffer.floatChannelData![0][0] = 0
        return buffer
    }
}

private enum AppleRecognitionFailureSource: CaseIterable, Equatable, Sendable { case microphone, systemAudio }
private enum AppleRecognitionFixtureFailure: Error, Equatable { case current, late }
