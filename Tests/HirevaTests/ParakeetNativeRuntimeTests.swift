import AVFoundation
import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet native runtime", .serialized)
struct ParakeetNativeRuntimeTests {
    @Test
    func contextualTermsUseOnlyReviewedShortOpportunitySkills() {
        func evidence(_ statement: String, type: EvidenceType = .requiredSkill,
                      explicitness: EvidenceExplicitness = .explicit) -> ProfileEvidence {
            .init(id: UUID().uuidString, statement: statement, confidence: 1,
                evidenceType: type, explicitness: explicitness)
        }
        let opportunity = OpportunityContext(id: "synthetic-vocabulary", opportunityType: .job,
            responsibilities: [evidence("private responsibility", type: .responsibility)],
            requiredSkills: [evidence("deduplication"), evidence("Deduplication"),
                evidence("not reviewed", explicitness: .inferred), evidence("word:99"), evidence("#comment"),
                evidence("hidden\nterm"), evidence("one two three four five")],
            preferredSkills: [evidence("data replication", type: .preferredSkill)],
            researchTopics: [], evaluationCriteria: [], sourceDocumentIDs: [], version: 1, updatedAt: .now)
        #expect(ASRConfig.opportunityTerms(opportunity) == ["deduplication", "data replication"])
        #expect(ASRConfig.opportunityTerms(nil).isEmpty)
        #expect(ASRConfig(sessionID: "ordinary", captureMode: .systemAudioOnly).contextualStrings.isEmpty)
    }

    @Test
    func contextualVocabularyIsPassedToExactHelperAndRemovedAfterDrain() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("arguments.txt")
        let escapedReceipt = receipt.path.replacingOccurrences(of: "'", with: "'\\''")
        let helper = root.appendingPathComponent("helper")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(escapedReceipt)'\nexec /bin/cat > /dev/null\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper }, vocabularyRoot: root)
        let stream = try await runtime.startTranscription(modelDirectory: root,
            config: .init(sessionID: "context-vocabulary", captureMode: .systemAudioOnly,
                contextualStrings: ["idempotency", "deduplication"]))
        await runtime.stop()
        withExtendedLifetime(stream) {}
        let arguments = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
        let index = try #require(arguments.firstIndex(of: "--hotwords-file"))
        let directory = URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent()
        #expect(arguments.contains("modified_beam_search"))
        #expect(arguments.contains("--approximate-bpe-vocab"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
    }

    @Test
    func invalidContextVocabularyFailsBeforeLaunchingHelper() async throws {
        let helper = try makeExecutable("#!/bin/sh\nexit 99\n")
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
        do {
            _ = try await runtime.startTranscription(modelDirectory: helper.deletingLastPathComponent(),
                config: .init(sessionID: "invalid-vocabulary", captureMode: .systemAudioOnly,
                    contextualStrings: ["deduplication:99"]))
            Issue.record("Hotword weight injection must fail before Process.run.")
        } catch let error as ParakeetSidecarError {
            #expect(error.localizedDescription.contains("Invalid contextual vocabulary"))
        }
        await runtime.stop()
    }

    @Test
    func failedVocabularyRemovalRetainsAnObservableOwnerAndExplicitRetry() async throws {
        let root = temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let helper = root.appendingPathComponent("helper")
        let escapedRoot = root.path.replacingOccurrences(of: "'", with: "'\\''")
        try "#!/bin/sh\nchmod 500 '\(escapedRoot)'\nexec /bin/cat > /dev/null\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper }, vocabularyRoot: root)
        let stream = try await runtime.startTranscription(modelDirectory: root,
            config: .init(sessionID: "retained-vocabulary", captureMode: .systemAudioOnly,
                contextualStrings: ["idempotency"]))
        await runtime.stop()
        #expect(await runtime.cleanupFailure != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        await runtime.stop()
        #expect(await runtime.cleanupFailure == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["helper"])
        withExtendedLifetime(stream) {}
    }

    @Test
    func healthRequiresStructuredNativeResponse() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        exit 0
        """)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.isRuntimeAvailable() == false)
        let diagnostics = await runtime.runtimeDiagnostics()
        #expect(diagnostics.healthStatus == "failed")
        #expect(diagnostics.lastHealthError == "Invalid helper health response")
    }

    @Test
    func healthReportsPinnedNativeRuntimeMetadata() async throws {
        let helper = try makeHealthExecutable(architecture: currentArchitecture)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

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
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

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
            allowDevelopmentOverrides: false,
            verificationConfiguration: nil
        )
        let debugResult = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: bundle,
            environment: ["PARAKEET_ASR_HELPER_PATH": external.path],
            storedDevelopmentPath: nil,
            currentDirectory: root,
            allowDevelopmentOverrides: true,
            verificationConfiguration: nil
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
            allowDevelopmentOverrides: true,
            verificationConfiguration: nil
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
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })

        #expect(await runtime.probeModel(at: temporaryDirectory()) == true)
    }

    @Test
    func transcriptEventPreservesMixedChannelMetadata() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"segmentId":"mixed-1","text":"Can you explain the tradeoff?","isFinal":true,"startTime":1.0,"endTime":2.0,"confidence":null,"source":"local_parakeet_asr","audioSource":"microphone","speaker":"candidate"}'
        """)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
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
    func transcriptReaderPreservesDelayedJSONLLines() async throws {
        let helper = try makeExecutable("""
        #!/bin/sh
        printf '%s\n' '{"segmentId":"line-1","text":"First question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        sleep 1
        printf '%s\n' '{"segmentId":"line-2","text":"Second question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        sleep 1
        printf '%s\n' '{"segmentId":"line-3","text":"Third question?","isFinal":true,"source":"local_parakeet_asr","audioSource":"systemAudio","speaker":"interviewer"}'
        """)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
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
    func immediateStopDrainsAcceptedAudioBeforeStopCommand() async throws {
        let inputLog = temporaryDirectory().appendingPathComponent("helper-input.jsonl")
        let escapedInputLog = inputLog.path.replacingOccurrences(of: "'", with: "'\\''")
        let helper = try makeExecutable("""
        #!/bin/sh
        cat > '\(escapedInputLog)'
        """)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
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
        exec /bin/sleep 30
        """)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { helper })
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_REAL_PARAKEET_STREAM_TEST"] == "1"))
    func realRuntimePreservesMultipleUtterancesInOneStream() async throws {
        let environment = ProcessInfo.processInfo.environment
        let helperPath = try #require(environment["HIREVA_PARAKEET_HELPER_PATH"])
        let modelPath = try #require(environment["HIREVA_PARAKEET_MODEL_PATH"])
        let audioPath = try #require(environment["HIREVA_PARAKEET_TEST_AUDIO"])
        let contextualStrings: [String]
        if let vocabularyPath = environment["HIREVA_PARAKEET_CONTEXT_TERMS_PATH"] {
            contextualStrings = try String(contentsOf: URL(fileURLWithPath: vocabularyPath), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        } else { contextualStrings = [] }
        let runtime = await ParakeetSidecarRuntimeClient(
            executableURLProvider: { URL(fileURLWithPath: helperPath) }
        )
        let stream = try await runtime.startTranscription(
            modelDirectory: URL(fileURLWithPath: modelPath),
            config: ASRConfig(sessionID: "real-multi-utterance", captureMode: .systemAudioOnly,
                contextualStrings: contextualStrings)
        )
        let collector = Task { () throws -> [ParakeetTranscriptEvent] in
            var events: [ParakeetTranscriptEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        do {
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
            if let expectedPath = environment["HIREVA_PARAKEET_EXPECTED_TEXTS_PATH"] {
                let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: expectedPath)))
                #expect(events.map(\.text) == expected)
            }
            #expect(events.allSatisfy { $0.source == ASRSource.localParakeetASR.rawValue })
            #expect(runtime.audioWriterDiagnostics().droppedChunks == 0)
            #expect(await runtime.cleanupFailure == nil)
        } catch {
            collector.cancel()
            await runtime.stop()
            _ = await collector.result
            throw error
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
