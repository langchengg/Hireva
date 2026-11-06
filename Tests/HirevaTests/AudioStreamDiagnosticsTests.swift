import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct AudioStreamDiagnosticsTests {
    @Test(arguments: AudioCaptureMode.allCases)
    func selectedSourcePermissionFailureIsNeverHiddenByDisabledChannel(_ mode: AudioCaptureMode) async throws {
        let environment = try await makeEnvironment(microphone: .denied, system: .denied)
        let app = environment.appState
        app.settings.audioCaptureMode = mode

        let reason = try #require(app.streamNotRunningReason)
        #expect(reason.contains("Permission"))
        #expect(!reason.contains("Capture Mode"))
        if mode == .systemAudioOnly {
            #expect(reason.contains("System audio"))
            #expect(!reason.contains("Microphone"))
        } else {
            #expect(reason.contains("Microphone"))
        }
        try await environment.shutdown()
    }

    @Test
    func selectedSystemSourceReportsStartupInsteadOfDisabledMicrophone() async throws {
        let environment = try await makeEnvironment(microphone: .denied)
        let app = environment.appState
        app.settings.audioCaptureMode = .systemAudioOnly
        app.currentCaptureRuntimeState = .starting

        #expect(app.streamNotRunningReason == "System audio: Starting capture")
        try await environment.shutdown()
    }

    @Test
    func startedSystemSourceWithoutBuffersReportsWaitingForData() async throws {
        let environment = try await makeEnvironment()
        let app = environment.appState
        app.settings.audioCaptureMode = .systemAudioOnly
        app.currentCaptureRuntimeState = .listening
        app.systemAudioCaptureService.isCapturing = true

        #expect(app.streamNotRunningReason == "System audio: Waiting for audio buffer")
        app.systemAudioCaptureService.isCapturing = false
        try await environment.shutdown()
    }

    @Test
    func captureStartupFailureRemainsVisibleWithGrantedPermissions() async throws {
        let environment = try await makeEnvironment()
        let app = environment.appState
        app.settings.audioCaptureMode = .microphoneOnly
        app.currentCaptureRuntimeState = .error(reason: "Synthetic startup failure")

        #expect(app.streamNotRunningReason == "Microphone not running: Synthetic startup failure")
        try await environment.shutdown()
    }

    @Test
    func combinedModeReportsSystemFailureWhileMicrophoneIsStarting() async throws {
        let environment = try await makeEnvironment()
        let app = environment.appState
        app.settings.audioCaptureMode = .microphoneAndSystem
        app.currentCaptureRuntimeState = .starting
        app.systemAudioCaptureService.lastError = "Synthetic system failure"

        #expect(app.streamNotRunningReason?.contains("System audio not running: Synthetic system failure") == true)
        app.systemAudioCaptureService.lastError = nil
        try await environment.shutdown()
    }

    @Test
    func unselectedSystemErrorDoesNotBecomeMicrophoneFailure() async throws {
        let environment = try await makeEnvironment()
        let app = environment.appState
        app.settings.audioCaptureMode = .microphoneOnly
        app.currentCaptureRuntimeState = .starting
        app.systemAudioCaptureService.lastError = "Unselected source failure"

        #expect(app.streamNotRunningReason == "Microphone: Starting capture")
        app.systemAudioCaptureService.lastError = nil
        try await environment.shutdown()
    }

    @Test
    func parakeetCaptureBuffersDoNotPretendAppleSpeechReceivedThem() async throws {
        let environment = try await makeEnvironment(speech: .denied)
        let app = environment.appState
        app.settings.audioCaptureMode = .systemAudioOnly
        app.activeASRProviderRuntime = environment.asrProvider
        app.currentCaptureRuntimeState = .listening
        app.systemAudioCaptureService.isCapturing = true
        app.systemAudioCaptureService.lastBufferReceivedAt = Date()

        #expect(app.audioStreamDiagnostics.first?.state == .notSelected)
        #expect(app.audioStreamDiagnostics.last?.state == .dataReceived)
        #expect(app.streamNotRunningReason == "System audio: Capture buffers received; ASR delivery is not verified")
        #expect(app.systemBufferCount == 0)
        app.systemAudioCaptureService.isCapturing = false
        try await environment.shutdown()
    }

    @Test
    func previousCaptureEpochBufferDoesNotProveCurrentCaptureDelivery() async throws {
        let environment = try await makeEnvironment()
        let app = environment.appState
        app.settings.audioCaptureMode = .systemAudioOnly
        app.currentCaptureRuntimeState = .listening
        app.lastCaptureStartedAt = Date(timeIntervalSince1970: 100)
        app.systemAudioCaptureService.lastBufferReceivedAt = Date(timeIntervalSince1970: 99)
        app.systemAudioCaptureService.isCapturing = true

        #expect(app.audioStreamDiagnostics.last?.state == .waitingForData)
        app.systemAudioCaptureService.isCapturing = false
        try await environment.shutdown()
    }

    @Test
    func speechPermissionIsProviderSpecific() async throws {
        let environment = try await makeEnvironment(speech: .denied)
        let app = environment.appState
        app.settings.audioCaptureMode = .microphoneOnly
        app.currentCaptureRuntimeState = .starting
        app.setSelectedASRProvider(.appleSpeech)

        #expect(app.streamNotRunningReason == "Microphone not running: Speech Recognition permission required for Apple Speech")
        app.setSelectedASRProvider(.localParakeet)
        #expect(app.streamNotRunningReason == "Microphone: Starting capture")
        try await environment.shutdown()
    }

    @Test
    func asrProcessingAndTranscriptStatesRequireTheirOwnEvidence() {
        let capturedAt = Date(timeIntervalSince1970: 100)
        let received = snapshot(capturedAt: capturedAt, asrBufferCount: 0, recognitionActive: true)
        let recognizing = snapshot(capturedAt: capturedAt, asrBufferCount: 1, recognitionActive: true)
        let transcribing = snapshot(capturedAt: capturedAt, asrBufferCount: 1, recognitionActive: true, hasTranscript: true)

        #expect(received.state == .dataReceived)
        #expect(recognizing.state == .recognizing)
        #expect(transcribing.state == .transcribing)
        #expect(AudioStreamDiagnosticSnapshot.streamNotRunningReason([transcribing]) == nil)
    }

    @Test
    func normalChannelCannotHideAnotherChannelsFailure() {
        let microphone = snapshot(capturedAt: Date(), asrBufferCount: 1, recognitionActive: true, hasTranscript: true)
        let system = AudioStreamDiagnosticSnapshot(
            source: .systemAudio, selected: true, permissionFailure: nil,
            runtimeState: .listening, captureRunning: false, lastCapturedBufferAt: nil,
            asrBufferCount: 0, recognitionActive: false, hasTranscript: false,
            sourceError: "Synthetic system failure"
        )

        #expect(AudioStreamDiagnosticSnapshot.streamNotRunningReason([microphone, system]) == "System audio not running: Synthetic system failure")
    }

    @Test
    func stoppedSelectedChannelHasExplicitReason() {
        let stopped = AudioStreamDiagnosticSnapshot(
            source: .microphone, selected: true, permissionFailure: nil,
            runtimeState: .stopped(reason: .userRequested), captureRunning: false,
            lastCapturedBufferAt: Date(), asrBufferCount: 3, recognitionActive: false,
            hasTranscript: true, sourceError: nil
        )

        #expect(stopped.state == .stopped)
        #expect(AudioStreamDiagnosticSnapshot.streamNotRunningReason([stopped]) == "Microphone: Capture stopped")
    }

    private func makeEnvironment(microphone: PermissionState = .granted,
        speech: PermissionState = .granted, system: PermissionState = .granted) async throws -> HirevaTestEnvironment {
        let permissions = AudioDiagnosticPermissionService(snapshot: .init(
            microphone: microphone, speechRecognition: speech,
            screenRecording: system, systemAudioCapture: system))
        return try await HirevaTestEnvironment(prefix: "AudioStreamDiagnostics", permissionService: permissions)
    }

    private func snapshot(
        capturedAt: Date?, asrBufferCount: Int?, recognitionActive: Bool?, hasTranscript: Bool = false
    ) -> AudioStreamDiagnosticSnapshot {
        AudioStreamDiagnosticSnapshot(
            source: .microphone, selected: true, permissionFailure: nil,
            runtimeState: .listening, captureRunning: true, lastCapturedBufferAt: capturedAt,
            asrBufferCount: asrBufferCount, recognitionActive: recognitionActive,
            hasTranscript: hasTranscript, sourceError: nil
        )
    }
}

/// Injects synthetic OS observations into the real permission owner. Diagnostic
/// expectations above continue to exercise AppState's actual derived snapshots.
private final class AudioDiagnosticPermissionService: PermissionService {
    private let observation: PermissionSnapshot
    init(snapshot: PermissionSnapshot) { observation = snapshot; super.init() }
    override func snapshot() -> PermissionSnapshot { observation }
    override func refreshPermissions() -> PermissionSnapshot { observation }
    override func checkMicrophonePermission() -> MicrophonePermissionState {
        observation.microphone == .denied ? .denied : .authorized
    }
    override func speechStatus() -> PermissionState { observation.speechRecognition }
}
