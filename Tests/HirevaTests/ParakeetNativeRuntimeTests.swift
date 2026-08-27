import AVFoundation
import CryptoKit
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

    @Test
    func structuredHelperFailureDoesNotSurfaceDiagnosticDetails() async throws {
        let privateDiagnosticToken = "fixture-private-\(UUID().uuidString)"
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"type":"error","code":"model_file_unavailable","message":"\(privateDiagnosticToken)"}'
        exit 1
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "structured-error", captureMode: .systemAudioOnly)
        )

        var receivedError: Error?
        do {
            for try await _ in stream {}
        } catch {
            receivedError = error
        }

        let sidecarError = try #require(receivedError as? ParakeetSidecarError)
        #expect(sidecarError == .helperFailure(.modelFileUnavailable))
        #expect(sidecarError.localizedDescription == "Parakeet native helper failed (model_file_unavailable).")
        #expect(sidecarError.localizedDescription.contains(privateDiagnosticToken) == false)
    }

    @Test
    func nativeHelperPublishesStableStructuredFailureCodes() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("native/parakeet_asr_helper.mm"),
            encoding: .utf8
        )

        #expect(source.contains("@\"code\""))
        #expect(source.contains("model_file_unavailable"))
        #expect(source.contains("model_lock_unavailable"))
        #expect(source.contains("recognizer_initialization_failed"))
        #expect(source.contains("input_protocol_failure"))
        #expect(source.contains("queue_limit_exceeded"))
        #expect(source.contains("audio_file_unavailable"))
        #expect(source.contains("runtime_conflict"))
        #expect(!source.contains("@\"message\""))
        #expect(!source.contains("fatal: %s"))
    }

    @Test
    func healthFailureUsesStructuredCodeWithoutStderrOrHelperPath() async throws {
        let privateDiagnosticToken = "fixture-private-\(UUID().uuidString)"
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"type":"error","code":"model_file_unavailable"}'
        printf '%s\n' '\(privateDiagnosticToken)' >&2
        exit 1
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        let diagnostics = await runtime.runtimeDiagnostics()

        #expect(diagnostics.healthStatus == "failed")
        #expect(diagnostics.helperPath == "Development helper")
        #expect(diagnostics.lastHealthError == "Helper failed (model_file_unavailable)")
        #expect(diagnostics.lastHealthError?.contains(privateDiagnosticToken) == false)
        #expect(diagnostics.lastHealthError?.contains(helper.path) == false)
    }

    @Test
    func transcriptReaderPreservesDelayedJSONLLines() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"segmentId":"line-1","text":"First question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        sleep 1
        printf '%s\n' '{"segmentId":"line-2","text":"Second question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        sleep 1
        printf '%s\n' '{"segmentId":"line-3","text":"Third question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "delayed-lines", captureMode: .systemAudioOnly)
        )

        var events: [ParakeetTranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.map(\.segmentId) == ["line-1", "line-2", "line-3"])
    }

    @Test
    func nonzeroProcessTerminationBeforeStdoutEOFIsPreserved() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        # The background child inherits stdout, keeping the pipe open after
        # the helper process itself has exited with the status under test.
        sleep 1 &
        exit 7
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "exit-before-eof", captureMode: .systemAudioOnly)
        )

        var receivedError: Error?
        do {
            for try await _ in stream {}
        } catch {
            receivedError = error
        }

        #expect(receivedError as? ParakeetSidecarError == .exited(7))
    }

    @Test
    func immediateStopDrainsAcceptedAudioBeforeStopCommand() async throws {
        let inputLog = temporaryDirectory().appendingPathComponent("helper-input.jsonl")
        let escapedInputLog = inputLog.path.replacingOccurrences(of: "'", with: "'\\''")
        let helper = try makeExecutable("""
        #!/bin/sh
        cat > '\(escapedInputLog)'
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "immediate-stop", captureMode: .systemAudioOnly)
        )
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960

        runtime.appendAudioBuffer(
            buffer,
            at: AVAudioTime(sampleTime: 0, atRate: 48_000),
            source: .systemAudio
        )
        await runtime.stop()

        let helperInput = try String(contentsOf: inputLog, encoding: .utf8)
        #expect(helperInput.contains("\"type\":\"audio\""))
        #expect(helperInput.contains("\"type\":\"stop\""))
        #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
        withExtendedLifetime(stream) {}
    }

    @Test
    func audioWriterIsBoundedAndStopCannotWaitBehindBlockedPipeWrites() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        sleep 30
        """)
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "blocked-writer", captureMode: .systemAudioOnly)
        )
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000

        for sequence in 0..<200 {
            runtime.appendAudioBuffer(
                buffer,
                at: AVAudioTime(sampleTime: AVAudioFramePosition(sequence * 48_000), atRate: 48_000),
                source: .systemAudio
            )
        }

        let diagnostics = runtime.audioWriterDiagnostics()
        #expect(diagnostics.pendingChunks <= diagnostics.maximumPendingChunks)
        #expect(diagnostics.maximumPendingChunks == 2_048)
        #expect(diagnostics.pendingBytes <= diagnostics.maximumPendingBytes)
        #expect(diagnostics.maximumPendingBytes == 8 * 1_024 * 1_024)
        #expect(diagnostics.droppedChunks > 0)

        let clock = ContinuousClock()
        let start = clock.now
        await runtime.stop()
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(5))
        withExtendedLifetime(stream) {}
    }

    @Test
    func realRuntimePreservesMultipleUtterancesInOneStream() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(
            environment["HIREVA_REAL_PARAKEET_STREAM_TEST"] == "1",
            "The reconciled release run must execute the real Parakeet stream lane"
        )
        let helperPath = try #require(environment["HIREVA_PARAKEET_HELPER_PATH"])
        let modelPath = try #require(environment["HIREVA_PARAKEET_MODEL_PATH"])
        let audioPath = try #require(environment["HIREVA_PARAKEET_TEST_AUDIO"])
        let provenancePath = try #require(environment["HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE"])
        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let provenanceData = try Data(contentsOf: URL(fileURLWithPath: provenancePath))
        let provenance = try JSONDecoder().decode(SyntheticAudioProvenance.self, from: provenanceData)
        let audioSHA256 = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()
        #expect(provenance.schemaVersion == 1)
        #expect(provenance.synthetic)
        #expect(provenance.containsRealPersonalData == false)
        #expect(provenance.generator == "macos_say")
        #expect(provenance.audio.filename == URL(fileURLWithPath: audioPath).lastPathComponent)
        #expect(provenance.audio.sha256 == audioSHA256)
        #expect(provenance.audio.sizeBytes == audioData.count)
        #expect(provenance.utterances.count == 3)
        let runtime = ParakeetSidecarRuntimeClient(
            executableURLProvider: { URL(fileURLWithPath: helperPath) }
        )
        let stream = try await runtime.startTranscription(
            modelDirectory: URL(fileURLWithPath: modelPath),
            config: ASRConfig(sessionID: "real-multi-utterance", captureMode: .systemAudioOnly)
        )
        let collector = Task { () throws -> [ParakeetTranscriptEvent] in
            var events: [ParakeetTranscriptEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let format = audioFile.processingFormat
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate / 50)))
        var sampleTime: AVAudioFramePosition = 0
        while audioFile.framePosition < audioFile.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames))
            try audioFile.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            runtime.appendAudioBuffer(
                buffer,
                at: AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate),
                source: .systemAudio
            )
            sampleTime += AVAudioFramePosition(buffer.frameLength)
            try await Task.sleep(for: .milliseconds(20))
        }

        try await Task.sleep(for: .seconds(15))
        await runtime.stop()
        let events = try await collector.value
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.isFinal })
        #expect(events.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(events.allSatisfy { !$0.segmentId.isEmpty })
        #expect(Set(events.map(\.segmentId)).count == 3)
        #expect(events.allSatisfy { $0.source == ASRSource.localParakeetASR.rawValue })
        #expect(events.allSatisfy { $0.audioSource == AudioSourceType.systemAudio.rawValue })
        #expect(events.allSatisfy { $0.speaker == SpeakerRole.interviewer.rawValue })
        for (event, expected) in zip(events, provenance.utterances) {
            let normalized = event.text.lowercased()
            #expect(expected.expectedTranscriptTerms.count >= 2)
            #expect(
                expected.expectedTranscriptTerms.allSatisfy { normalized.contains($0.lowercased()) },
                "ASR event \(event.segmentId) did not preserve synthetic utterance \(expected.id): \(event.text)"
            )
        }
        #expect(runtime.audioWriterDiagnostics().droppedChunks == 0)
    }

    private struct SyntheticAudioProvenance: Decodable {
        struct Audio: Decodable {
            let filename: String
            let sha256: String
            let sizeBytes: Int

            enum CodingKeys: String, CodingKey {
                case filename
                case sha256
                case sizeBytes = "size_bytes"
            }
        }

        struct Utterance: Decodable {
            let id: String
            let text: String
            let expectedTranscriptTerms: [String]

            enum CodingKeys: String, CodingKey {
                case id
                case text
                case expectedTranscriptTerms = "expected_transcript_terms"
            }
        }

        let schemaVersion: Int
        let synthetic: Bool
        let containsRealPersonalData: Bool
        let generator: String
        let audio: Audio
        let utterances: [Utterance]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case synthetic
            case containsRealPersonalData = "contains_real_personal_data"
            case generator
            case audio
            case utterances
        }
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

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
