import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet native runtime", .serialized)
struct ParakeetNativeRuntimeTests {
    @Test
    func healthRequiresStructuredNativeResponse() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        exit 0
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.isRuntimeAvailable() == false)
        let diagnostics = await runtime.runtimeDiagnostics()
        #expect(diagnostics.healthStatus == "failed")
        #expect(diagnostics.lastHealthError == "Invalid helper health response")
    }

    @Test
    func healthReportsPinnedNativeRuntimeMetadata() async throws {
        let helper = try makeHealthExecutable(architecture: currentArchitecture)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.isRuntimeAvailable() == true)
        let diagnostics = await runtime.runtimeDiagnostics()
        #expect(diagnostics.runtimeMode == "bundled_native")
        #expect(diagnostics.sherpaVersion == "1.13.4")
        #expect(diagnostics.onnxRuntimeVersion == "1.27.0")
        #expect(diagnostics.helperArchitecture == currentArchitecture)
        #expect(diagnostics.helperExecutable == true)
    }

    @Test
    func wrongArchitectureFailsHealth() async throws {
        let wrongArchitecture = currentArchitecture == "arm64" ? "x86_64" : "arm64"
        let helper = try makeHealthExecutable(architecture: wrongArchitecture)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.isRuntimeAvailable() == false)
        #expect((await runtime.runtimeDiagnostics()).lastHealthError?.contains("does not match") == true)
    }

    @Test
    func releaseDiscoveryRejectsExternalOverride() throws {
        let root = temporaryDirectory()
        let bundle = root.appendingPathComponent("Hireva.app")
        let external = try makeExecutable("#!/bin/sh\nexit 0\n")

        let releaseResult = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: bundle,
            environment: ["PARAKEET_ASR_HELPER_PATH": external.path],
            storedDevelopmentPath: external.path,
            currentDirectory: root,
            allowDevelopmentOverrides: false
        )
        let debugResult = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: bundle,
            environment: ["PARAKEET_ASR_HELPER_PATH": external.path],
            storedDevelopmentPath: nil,
            currentDirectory: root,
            allowDevelopmentOverrides: true
        )

        #expect(releaseResult == nil)
        #expect(debugResult == external)
    }

    @Test
    func bundledHelperWinsOverDevelopmentOverride() throws {
        let root = temporaryDirectory()
        let bundle = root.appendingPathComponent("Hireva.app")
        let bundled = bundle.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        try FileManager.default.createDirectory(
            at: bundled.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: bundled, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let external = try makeExecutable("#!/bin/sh\nexit 0\n")

        let result = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: bundle,
            environment: ["PARAKEET_ASR_HELPER_PATH": external.path],
            storedDevelopmentPath: external.path,
            currentDirectory: root,
            allowDevelopmentOverrides: true
        )

        #expect(result == bundled)
    }

    @Test
    func modelProbeMustReportReady() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        if [ "${2:-}" = "--probe-model" ]; then
          printf '%s\n' '{"status":"ok","runtimeMode":"bundled_native","runtimeVersion":"1","sherpaVersion":"1.13.4","onnxRuntimeVersion":"1.27.0","architecture":"\(currentArchitecture)","source":"local_parakeet_asr","modelStatus":"ready"}'
        else
          printf '%s\n' '{"status":"ok","runtimeMode":"bundled_native","runtimeVersion":"1","sherpaVersion":"1.13.4","onnxRuntimeVersion":"1.27.0","architecture":"\(currentArchitecture)","source":"local_parakeet_asr","modelStatus":"not_probed"}'
        fi
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.probeModel(at: temporaryDirectory()) == true)
    }

    @Test
    func transcriptEventPreservesMixedChannelMetadata() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"segmentId":"mixed-1","text":"Can you explain the tradeoff?","isFinal":true,"startTime":1.0,"endTime":2.0,"confidence":null,"source":"local_parakeet_asr","audioSource":"microphone","speaker":"candidate"}'
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "mixed", captureMode: .microphoneAndSystem)
        )

        var events: [ParakeetTranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].source == ASRSource.localParakeetASR.rawValue)
        #expect(events[0].audioSource == AudioSourceType.microphone.rawValue)
        #expect(events[0].speaker == SpeakerRole.candidate.rawValue)
    }

    private var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private func makeHealthExecutable(architecture: String) throws -> URL {
        try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"status":"ok","runtimeMode":"bundled_native","runtimeVersion":"1","sherpaVersion":"1.13.4","onnxRuntimeVersion":"1.27.0","architecture":"\(architecture)","source":"local_parakeet_asr","modelStatus":"not_probed"}'
        """)
    }

    private func makeExecutable(_ contents: String) throws -> URL {
        let executable = temporaryDirectory().appendingPathComponent("fake-parakeet-helper")
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaParakeetRuntimeTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
