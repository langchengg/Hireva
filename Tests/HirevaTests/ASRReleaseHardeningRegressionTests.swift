import Darwin
import Foundation
import Testing
@testable import Hireva

@Suite("ASR release-hardening regressions")
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
    func mixedParakeetMappingKeepsChannelsWithoutInventingSpeakers() throws {
        let microphone = try ParakeetTranscriptMapper.map(
            event(audioSource: .microphone, speaker: .candidate),
            config: ASRConfig(sessionID: "mixed-test", captureMode: .microphoneAndSystem)
        )
        let system = try ParakeetTranscriptMapper.map(
            event(audioSource: .systemAudio, speaker: .interviewer),
            config: ASRConfig(sessionID: "mixed-test", captureMode: .microphoneAndSystem)
        )

        #expect(microphone.source == .microphone)
        #expect(microphone.speaker == .unknown)
        #expect(system.source == .systemAudio)
        #expect(system.speaker == .unknown)
        #expect(microphone.asrSource == .localParakeetASR)
        #expect(system.asrSource == .localParakeetASR)
    }

    @Test(.timeLimit(.minutes(1)))
    func stdoutEOFRetiresItsHelperAndPreservesTheActualExitCause() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidURL = directory.appendingPathComponent("stdout-eof-helper.pid")
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$$" > '\(pidURL.path)'
        printf '%s\n' '{"segmentId":"eof-1","text":"How did you validate it?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        exec 1>&-
        exec /bin/sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: directory,
            config: ASRConfig(sessionID: "stdout-eof", captureMode: .systemAudioOnly)
        )

        var events: [ParakeetTranscriptEvent] = []
        do {
            for try await event in stream { events.append(event) }
            Issue.record("Closing stdout while a helper is alive must not manufacture successful completion.")
        } catch ParakeetSidecarError.exited(let status) where status == SIGTERM {
            // This fixture ignores the protocol stop message, but accepts TERM.
            // The output owner retires it at stdout EOF and reports its exit.
        } catch {
            await runtime.stop()
            throw error
        }

        // Join the exact cleanup even if stream termination precedes owner release.
        await runtime.stop()
        #expect(events.map(\.segmentId) == ["eof-1"])
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        let pid = try #require(Int32(pidText))
        // The actual awaitable stop must finish reaping; no scheduler-dependent poll.
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test(.timeLimit(.minutes(1)))
    func healthTimeoutReapsHelperThatIgnoresTermination() async throws {
        try await ParakeetHealthCheckTestFixture.verifyDeadline()
    }

    @Test @MainActor
    func parakeetFailureClearsActiveRuntimeAndListeningState() async throws {
        let appState = AppState(database: try TestSupport.makeTemporaryDatabase(prefix: "ParakeetFailure"))
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        let provider = HermeticTestASRProvider()
        appState.currentSession = session
        appState.activeASRProviderRuntime = provider
        appState.markActiveASRProvider(.localParakeet)
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        appState.handleParakeetStreamTermination(error: ParakeetSidecarError.exited(9), provider: provider, sessionID: session.id, startupID: UUID())

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
        await appState.captureTeardownTask?.value
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
