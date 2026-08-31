import Darwin
import Foundation
import Testing
@testable import Hireva

@Suite("ASR release-hardening regressions", .serialized, .sharedRuntimeResources)
struct ASRReleaseHardeningRegressionTests {
    @Test
    func permissionPolicyCoversEveryProviderAndCaptureCombination() {
        let cases: [(ASRProviderID, AudioCaptureMode, Bool, Bool, Bool)] = [
            (.appleSpeech, .microphoneOnly, true, true, false),
            (.appleSpeech, .systemAudioOnly, false, true, true),
            (.appleSpeech, .microphoneAndSystem, true, true, true),
            (.localParakeet, .microphoneOnly, true, false, false),
            (.localParakeet, .systemAudioOnly, false, false, true),
            (.localParakeet, .microphoneAndSystem, true, false, true)
        ]

        for (provider, captureMode, microphone, speech, systemAudio) in cases {
            let requirements = ASRPermissionRequirements(
                provider: provider,
                captureMode: captureMode
            )
            #expect(requirements.microphone == microphone)
            #expect(requirements.speechRecognition == speech)
            #expect(requirements.screenAndSystemAudio == systemAudio)
        }
    }

    @Test
    func parakeetCapabilityIsExplicitlyFinalOnly() {
        #expect(ASRProviderCapabilities.forProvider(.appleSpeech).supportsPartialTranscripts)
        #expect(!ASRProviderCapabilities.forProvider(.localParakeet).supportsPartialTranscripts)
    }

    @Test
    func parakeetMapperRejectsDisabledSourceAndPartialEvents() throws {
        let wrongSource = event(audioSource: .systemAudio, speaker: .interviewer)
        #expect(throws: ASRProviderError.self) {
            _ = try ParakeetTranscriptMapper.map(
                wrongSource,
                config: ASRConfig(sessionID: "source-test", captureMode: .microphoneOnly)
            )
        }

        let partial = event(audioSource: .systemAudio, speaker: .interviewer, isFinal: false)
        #expect(throws: ASRProviderError.self) {
            _ = try ParakeetTranscriptMapper.map(
                partial,
                config: ASRConfig(sessionID: "partial-test", captureMode: .systemAudioOnly)
            )
        }
    }

    @Test
    func mixedParakeetMappingKeepsChannelsAndSpeakersSeparate() throws {
        let microphone = try ParakeetTranscriptMapper.map(
            event(audioSource: .microphone, speaker: .candidate),
            config: ASRConfig(sessionID: "mixed-test", captureMode: .microphoneAndSystem)
        )
        let system = try ParakeetTranscriptMapper.map(
            event(audioSource: .systemAudio, speaker: .interviewer),
            config: ASRConfig(sessionID: "mixed-test", captureMode: .microphoneAndSystem)
        )

        #expect(microphone.source == .microphone)
        #expect(microphone.speaker == .candidate)
        #expect(system.source == .systemAudio)
        #expect(system.speaker == .interviewer)
        #expect(microphone.asrSource == .localParakeetASR)
        #expect(system.asrSource == .localParakeetASR)
    }

    @Test
    func stdoutEOFDoesNotWaitForStillRunningHelperProcess() async throws {
        let pidURL = temporaryDirectory().appendingPathComponent("stdout-eof-helper.pid")
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$$" > '\(pidURL.path)'
        printf '%s\n' '{"segmentId":"eof-1","text":"How did you validate it?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        exec 1>&-
        sleep 30
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "stdout-eof", captureMode: .systemAudioOnly)
        )

        var events: [ParakeetTranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.map(\.segmentId) == ["eof-1"])
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        // EOF must complete the stream while the helper is still alive. This
        // proves lifecycle behavior without a wall-clock performance threshold.
        #expect(Darwin.kill(pid, 0) == 0)
        await runtime.stop()

        let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while Darwin.kill(pid, 0) == 0, ContinuousClock.now < terminationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func healthTimeoutReapsHelperThatIgnoresTermination() async throws {
        let pidURL = temporaryDirectory().appendingPathComponent("health-helper.pid")
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$$" > '\(pidURL.path)'
        trap '' TERM
        sleep 30
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.isRuntimeAvailable() == false)
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test @MainActor
    func parakeetFailureClearsActiveRuntimeAndListeningState() throws {
        let appState = AppState(database: try TestSupport.makeTemporaryDatabase(prefix: "ParakeetFailure"))
        appState.activeASRProviderRuntime = HermeticTestASRProvider()
        appState.markActiveASRProvider(.localParakeet)
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        appState.handleParakeetStreamTermination(error: ParakeetSidecarError.exited(9))

        #expect(appState.activeASRProviderRuntime == nil)
        #expect(appState.activeASRProviderID == nil)
        if case .error = appState.liveState {
            // Expected.
        } else {
            Issue.record("Parakeet failure left liveState outside the error state")
        }
        if case .error = appState.currentCaptureRuntimeState {
            // Expected.
        } else {
            Issue.record("Parakeet failure left capture runtime outside the error state")
        }
    }

    private func event(
        audioSource: AudioSourceType,
        speaker: SpeakerRole,
        isFinal: Bool = true
    ) -> ParakeetTranscriptEvent {
        ParakeetTranscriptEvent(
            segmentId: UUID().uuidString,
            text: "How did you validate the result?",
            isFinal: isFinal,
            startTime: 0,
            endTime: 1,
            source: ASRSource.localParakeetASR.rawValue,
            audioSource: audioSource.rawValue,
            speaker: speaker.rawValue
        )
    }

    private func makeExecutable(_ contents: String) throws -> URL {
        let executable = temporaryDirectory().appendingPathComponent("fake-parakeet-helper")
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaASRReleaseTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
