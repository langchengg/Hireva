import AVFoundation
import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct LocalModelsSetupTests {
    @Test
    func defaultLocalModelDescriptorsUseQwen35AndParakeet() {
        #expect(LocalModelDescriptor.defaultQwenLocalLLM.id == "qwen3.5:4b")
        #expect(LocalModelDescriptor.defaultQwenLocalLLM.displayName == "Qwen3.5 4B")
        #expect(LocalModelDescriptor.defaultQwenLocalLLM.downloadURL == nil)
        #expect(LocalModelDescriptor.defaultQwenLocalLLM.storageRelativePath == "ollama/qwen3.5-4b")

        #expect(LocalModelDescriptor.defaultParakeetASR.id == "parakeet-tdt-0.6b-v3-int8")
        #expect(LocalModelDescriptor.defaultParakeetASR.displayName == "Parakeet TDT 0.6B")
        #expect(LocalModelDescriptor.defaultParakeetASR.downloadURL?.absoluteString.contains("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2") == true)
        #expect(LocalModelDescriptor.defaultParakeetASR.requiredFiles.map(\.relativePath).contains("encoder.int8.onnx"))
        #expect(LocalModelDescriptor.defaultParakeetASR.requiredFiles.map(\.relativePath).contains("decoder.int8.onnx"))
        #expect(LocalModelDescriptor.defaultParakeetASR.requiredFiles.map(\.relativePath).contains("joiner.int8.onnx"))
        #expect(LocalModelDescriptor.defaultParakeetASR.requiredFiles.map(\.relativePath).contains("tokens.txt"))
        #expect(LocalModelDescriptor.ollamaQwen == .defaultQwenLocalLLM)
    }

    @Test @MainActor
    func runtimeDefaultsUseLocalQwenAndAppleSpeechSelection() throws {
        let previousASR = UserDefaults.standard.object(forKey: "InterviewCopilot.selectedASRProvider")
        let previousActiveASR = UserDefaults.standard.object(forKey: "InterviewCopilot.activeASRProvider")
        let previousMode = UserDefaults.standard.object(forKey: "InterviewCopilot.answerProviderMode")
        let previousQwen = UserDefaults.standard.object(forKey: "InterviewCopilot.selectedQwenModel")
        defer {
            restoreUserDefault(previousASR, forKey: "InterviewCopilot.selectedASRProvider")
            restoreUserDefault(previousActiveASR, forKey: "InterviewCopilot.activeASRProvider")
            restoreUserDefault(previousMode, forKey: "InterviewCopilot.answerProviderMode")
            restoreUserDefault(previousQwen, forKey: "InterviewCopilot.selectedQwenModel")
        }
        UserDefaults.standard.removeObject(forKey: "InterviewCopilot.selectedASRProvider")
        UserDefaults.standard.set(ASRProviderID.appleSpeech.rawValue, forKey: "InterviewCopilot.activeASRProvider")
        UserDefaults.standard.removeObject(forKey: "InterviewCopilot.answerProviderMode")
        UserDefaults.standard.removeObject(forKey: "InterviewCopilot.selectedQwenModel")
        let appState = try AppState(database: AppDatabase(inMemory: true))

        #expect(appState.selectedASRProviderID == .appleSpeech)
        #expect(appState.selectedASRProviderID.source == .appleASR)
        #expect(appState.activeASRProviderID == nil)
        #expect(appState.selectedAnswerProviderMode == .localQwenPrimary)
        #expect(appState.selectedQwenModelName == "qwen3.5:4b")
    }

    @Test @MainActor
    func localQwenPrimaryDoesNotUseTemplateFallbackWatchdogs() throws {
        let appState = try AppState(database: AppDatabase(inMemory: true))

        appState.answerProviderModeOverride = .localQwenPrimary
        #expect(appState.shouldUseFirstAnswerFallbackWatchdogsForCurrentProvider == false)

        appState.answerProviderModeOverride = .deepSeekPrimary
        #expect(appState.shouldUseFirstAnswerFallbackWatchdogsForCurrentProvider == true)

        appState.answerProviderModeOverride = .deepSeekWithLocalQwenFallback
        #expect(appState.shouldUseFirstAnswerFallbackWatchdogsForCurrentProvider == true)
    }

    @Test @MainActor
    func legacyDeepSeekPreferenceMigratesOnlyWhenQwenReady() throws {
        let previousMode = UserDefaults.standard.object(forKey: "InterviewCopilot.answerProviderMode")
        defer {
            restoreUserDefault(previousMode, forKey: "InterviewCopilot.answerProviderMode")
        }

        UserDefaults.standard.set("deepSeek", forKey: "InterviewCopilot.answerProviderMode")
        let appState = try AppState(database: AppDatabase(inMemory: true))

        appState.migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: false)
        #expect(appState.selectedAnswerProviderMode == .deepSeekPrimary)

        appState.migrateStoredAnswerProviderToLocalQwenIfReady(qwenReady: true)
        #expect(appState.selectedAnswerProviderMode == .localQwenPrimary)
    }

    @Test @MainActor
    func legacyLocalParakeetASRSelectionMigratesToAppleSpeechDefaultOnce() throws {
        let selectedKey = "InterviewCopilot.selectedASRProvider"
        let migrationKey = "InterviewCopilot.asrDefaultMigration.appleSpeech.20260706"
        let previousASR = UserDefaults.standard.object(forKey: selectedKey)
        let previousMigration = UserDefaults.standard.object(forKey: migrationKey)
        defer {
            restoreUserDefault(previousASR, forKey: selectedKey)
            restoreUserDefault(previousMigration, forKey: migrationKey)
        }

        UserDefaults.standard.set(ASRProviderID.localParakeet.rawValue, forKey: selectedKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        let appState = try AppState(database: AppDatabase(inMemory: true))

        appState.migrateStoredASRProviderToAppleSpeechDefaultIfNeeded()

        #expect(appState.selectedASRProviderID == .appleSpeech)
        #expect(UserDefaults.standard.bool(forKey: migrationKey) == true)
    }

    @Test
    func permissionPolicyAllowsFinishOnlyWhenRequiredPermissionsReadyOrSkipped() {
        let blocked = SetupPermissionPolicy(
            microphone: .granted,
            speechRecognition: .granted,
            systemAudio: .notGranted,
            screenRecording: .notRequired,
            permissionsExplicitlySkipped: false
        )
        #expect(blocked.canFinishSetup == false)

        let granted = SetupPermissionPolicy(
            microphone: .granted,
            speechRecognition: .granted,
            systemAudio: .granted,
            screenRecording: .notRequired,
            permissionsExplicitlySkipped: false
        )
        #expect(granted.canFinishSetup == true)

        let skipped = SetupPermissionPolicy(
            microphone: .notGranted,
            speechRecognition: .notGranted,
            systemAudio: .notGranted,
            screenRecording: .notRequired,
            permissionsExplicitlySkipped: true
        )
        #expect(skipped.canFinishSetup == true)
    }

    @Test
    func fileLocalModelManagerDownloadsVerifiesAndDeletesLocalFile() async throws {
        let root = temporaryDirectory().appendingPathComponent("models", isDirectory: true)
        let source = temporaryDirectory().appendingPathComponent("source.bin")
        let payload = Data(repeating: 7, count: 192 * 1024)
        try payload.write(to: source)

        let descriptor = LocalModelDescriptor(
            id: "test-model",
            displayName: "Test Model",
            kind: .transcription,
            sizeBytes: Int64(payload.count),
            downloadURL: source,
            checksum: nil,
            storageRelativePath: "Transcription/test-model.bin"
        )
        let manager = FileLocalModelManager(rootDirectory: root)

        #expect(await manager.modelStatus(descriptor) == .notInstalled)

        var progressEvents: [ModelDownloadProgress] = []
        for try await progress in manager.downloadModel(descriptor) {
            progressEvents.append(progress)
        }

        #expect(progressEvents.isEmpty == false)
        #expect(progressEvents.last?.progress == 1)
        #expect(await manager.modelStatus(descriptor) == .installed)
        #expect(try await manager.verifyModel(descriptor) == true)

        try await manager.deleteModel(descriptor)
        #expect(await manager.modelStatus(descriptor) == .notInstalled)
    }

    @Test
    func fileLocalModelManagerDownloadsExtractsAndVerifiesArchiveDirectoryModel() async throws {
        let root = temporaryDirectory().appendingPathComponent("models", isDirectory: true)
        let sourceRoot = temporaryDirectory()
        let sourceModelDir = sourceRoot.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceModelDir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: sourceModelDir.appendingPathComponent("encoder.int8.onnx"))
        try Data(repeating: 2, count: 16).write(to: sourceModelDir.appendingPathComponent("decoder.int8.onnx"))
        try Data(repeating: 3, count: 12).write(to: sourceModelDir.appendingPathComponent("joiner.int8.onnx"))
        try Data("a 0\nb 1\n".utf8).write(to: sourceModelDir.appendingPathComponent("tokens.txt"))
        let archiveURL = sourceRoot.appendingPathComponent("parakeet-test.tar.bz2")
        try makeTarBz2Archive(sourceDirectoryName: sourceModelDir.lastPathComponent, parentDirectory: sourceRoot, archiveURL: archiveURL)

        let descriptor = LocalModelDescriptor(
            id: "parakeet-archive-test",
            displayName: "Parakeet Archive Test",
            kind: .transcription,
            sizeBytes: nil,
            downloadURL: archiveURL,
            checksum: nil,
            storageRelativePath: "asr/parakeet-archive-test",
            requiredFiles: [
                LocalModelFileRequirement(relativePath: "encoder.int8.onnx", minimumBytes: 32),
                LocalModelFileRequirement(relativePath: "decoder.int8.onnx", minimumBytes: 16),
                LocalModelFileRequirement(relativePath: "joiner.int8.onnx", minimumBytes: 12),
                LocalModelFileRequirement(relativePath: "tokens.txt", minimumBytes: 4)
            ]
        )
        let manager = FileLocalModelManager(rootDirectory: root)

        var progressEvents: [ModelDownloadProgress] = []
        for try await progress in manager.downloadModel(descriptor) {
            progressEvents.append(progress)
        }

        #expect(progressEvents.isEmpty == false)
        #expect(await manager.modelStatus(descriptor) == .installed)
        #expect(try await manager.verifyModel(descriptor) == true)
        #expect(FileManager.default.fileExists(atPath: manager.fileURL(for: descriptor).appendingPathComponent("encoder.int8.onnx").path))
    }

    @Test
    func fileLocalModelManagerReportsMissingDownloadURL() async {
        let descriptor = LocalModelDescriptor(
            id: "manual-model",
            displayName: "Manual Model",
            kind: .localLLM,
            sizeBytes: nil,
            downloadURL: nil,
            checksum: nil,
            storageRelativePath: "Manual/model.bin"
        )
        let manager = FileLocalModelManager(rootDirectory: temporaryDirectory())

        await #expect(throws: LocalModelManagerError.missingDownloadURL("Manual Model")) {
            for try await _ in manager.downloadModel(descriptor) {}
        }
    }

    @Test
    func ollamaHealthDetectsMissingServerAndInstalledModel() async throws {
        MockURLProtocol.handlers = [
            "http://localhost:11434/api/tags": { request in
                let data = Data(#"{"models":[{"name":"qwen3.5:4b"}]}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
        ]
        defer { MockURLProtocol.handlers = [:] }

        let provider = OllamaQwenProvider(session: makeMockSession())
        let health = await provider.healthCheck(modelName: "qwen3.5:4b")

        #expect(health.ollamaRunning == true)
        #expect(health.modelInstalled == true)
        #expect(health.providerSource == .ollamaQwen)
    }

    @Test
    func ollamaGenerateUsesOllamaQwenSource() async throws {
        MockURLProtocol.handlers = [
            "http://localhost:11434/api/tags": { request in
                let data = Data(#"{"models":[{"name":"qwen3.5:4b"}]}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            },
            "http://localhost:11434/api/chat": { request in
                let body = try requestBodyData(for: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["think"] as? Bool == false)
                #expect(json["stream"] as? Bool == false)
                let data = Data(#"{"message":{"role":"assistant","content":"hello world"},"done":true}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
        ]
        defer { MockURLProtocol.handlers = [:] }

        let provider = OllamaQwenProvider(session: makeMockSession())
        let stream = try await provider.generateAnswer(request: LocalLLMRequest(
            prompt: "Answer this",
            systemPrompt: nil,
            modelName: "qwen3.5:4b",
            temperature: 0.2
        ))

        var tokens: [LLMToken] = []
        for try await token in stream {
            tokens.append(token)
        }

        #expect(tokens.map(\.text).joined() == "hello world")
        #expect(tokens.allSatisfy { $0.source == .ollamaQwen })
        #expect(tokens.allSatisfy { $0.source.rawValue != AnswerSource.deepseekStream.rawValue })
    }

    @Test
    func ollamaChatUsesThinkFalseAndReadsMessageContent() async throws {
        var chatCallCount = 0
        MockURLProtocol.handlers = [
            "http://localhost:11434/api/tags": { request in
                let data = Data(#"{"models":[{"name":"qwen3.5:4b"}]}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            },
            "http://localhost:11434/api/chat": { request in
                chatCallCount += 1
                let body = try requestBodyData(for: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["think"] as? Bool == false)
                #expect(json["stream"] as? Bool == false)
                let messages = try #require(json["messages"] as? [[String: Any]])
                #expect(messages.contains { ($0["role"] as? String) == "system" })
                #expect(messages.contains { ($0["role"] as? String) == "user" && (($0["content"] as? String)?.contains("Answer this") ?? false) })
                let data = Data(#"{"message":{"role":"assistant","content":"I recovered by retreating, re-localizing, checking grasp confidence, and retrying with adjusted pose control."},"done":true,"done_reason":"stop"}"#.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
        ]
        defer { MockURLProtocol.handlers = [:] }

        let provider = OllamaQwenProvider(session: makeMockSession())
        let stream = try await provider.generateAnswer(request: LocalLLMRequest(
            prompt: "Answer this",
            systemPrompt: "System prompt",
            modelName: "qwen3.5:4b",
            temperature: 0.1,
            numPredict: 80
        ))

        var tokens: [LLMToken] = []
        for try await token in stream {
            tokens.append(token)
        }

        #expect(tokens.map(\.text).joined().contains("I recovered by retreating"))
        #expect(tokens.allSatisfy { $0.source == .ollamaQwen })
        #expect(chatCallCount == 1)
    }

    @Test
    func transcriptReconcilerPreservesASRSourceForAppleSpeechNovelSpan() {
        var reconciler = TranscriptReconciler()
        let first = TranscriptSegment(
            id: "apple-1",
            sessionID: "session",
            source: .systemAudio,
            speaker: .interviewer,
            text: "How did the robot estimate pose?",
            asrSource: .appleASR,
            asrFinalizationReason: "partial",
            recognitionTaskID: "task-1",
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: 32,
            recognitionIsFinal: false
        )
        let second = TranscriptSegment(
            id: "apple-1",
            sessionID: "session",
            source: .systemAudio,
            speaker: .interviewer,
            text: "How did the robot estimate pose? What happened when confidence was low?",
            asrSource: .appleASR,
            asrFinalizationReason: "stable_partial",
            recognitionTaskID: "task-1",
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: 69,
            recognitionIsFinal: true
        )

        _ = reconciler.segmentForQuestionExtraction(first)
        let novel = reconciler.segmentForQuestionExtraction(second)

        #expect(novel?.text == "What happened when confidence was low?")
        #expect(novel?.asrSource == .appleASR)
        #expect(novel?.asrFinalizationReason == "stable_partial")
    }

    @Test
    func ollamaPullReportsProgress() async throws {
        MockURLProtocol.handlers = [
            "http://localhost:11434/api/pull": { request in
                let data = Data("""
                {"status":"pulling manifest"}
                {"status":"downloading","completed":50,"total":100}
                {"status":"success","completed":100,"total":100}
                """.utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
        ]
        defer { MockURLProtocol.handlers = [:] }

        let provider = OllamaQwenProvider(session: makeMockSession())
        var progress: [ModelDownloadProgress] = []
        for try await event in provider.pullModel("qwen3.5:4b") {
            progress.append(event)
        }

        #expect(progress.contains { $0.progress == 0.5 })
        #expect(progress.last?.progress == 1)
    }

    @Test
    func localPlaceholderASRReportsModelNotReady() async {
        let provider = LocalPlaceholderASRProvider(
            id: .localWhisper,
            model: .localWhisperTinyEnglish,
            modelManager: StaticLocalModelManager(status: .notInstalled)
        )

        #expect(await provider.isAvailable() == false)
        await #expect(throws: ASRProviderError.modelNotReady(.localWhisper)) {
            _ = try await provider.startTranscription(config: ASRConfig(sessionID: "s1", captureMode: .systemAudioOnly))
        }
    }

    @Test
    func parakeetDirectoryReadinessRequiresAllModelFiles() async throws {
        let root = temporaryDirectory()
        let descriptor = LocalModelDescriptor(
            id: "parakeet-test",
            displayName: "Parakeet Test",
            kind: .transcription,
            sizeBytes: 4,
            downloadURL: nil,
            checksum: nil,
            storageRelativePath: "asr/parakeet-test",
            requiredFiles: [
                LocalModelFileRequirement(relativePath: "encoder.onnx", minimumBytes: 2),
                LocalModelFileRequirement(relativePath: "vocab.txt", minimumBytes: 1)
            ]
        )
        let manager = FileLocalModelManager(rootDirectory: root)
        let modelDir = manager.fileURL(for: descriptor)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: modelDir.appendingPathComponent("encoder.onnx"))

        #expect(await manager.modelStatus(descriptor) == .notInstalled)

        try Data([3]).write(to: modelDir.appendingPathComponent("vocab.txt"))
        #expect(await manager.modelStatus(descriptor) == .installed)
    }

    @Test
    func parakeetModelReadyButRuntimeMissingFailsExplicitly() async {
        let provider = LocalParakeetASRProvider(
            modelManager: StaticLocalModelManager(status: .installed),
            runtimeClient: MockParakeetRuntimeClient(isAvailable: false)
        )

        #expect(await provider.isAvailable() == false)
        await #expect(throws: ASRProviderError.localASRRuntimeNotImplemented(.localParakeet)) {
            _ = try await provider.startTranscription(config: ASRConfig(sessionID: "s1", captureMode: .systemAudioOnly))
        }
    }

    @Test
    func selectingParakeetWhenModelMissingShowsModelNotReady() async {
        let provider = LocalParakeetASRProvider(
            modelManager: StaticLocalModelManager(status: .notInstalled),
            runtimeClient: MockParakeetRuntimeClient(isAvailable: true)
        )

        #expect(await provider.isAvailable() == false)
        await #expect(throws: ASRProviderError.modelNotReady(.localParakeet)) {
            _ = try await provider.startTranscription(config: ASRConfig(sessionID: "s1", captureMode: .systemAudioOnly))
        }
    }

    @Test
    func selectingParakeetWhenModelAndRuntimeReadyChangesActiveProviderEligibility() async {
        let provider = LocalParakeetASRProvider(
            modelManager: StaticLocalModelManager(status: .installed),
            runtimeClient: MockParakeetRuntimeClient(isAvailable: true)
        )

        #expect(await provider.isAvailable() == true)
    }

    @Test
    func parakeetSidecarRuntimeAvailabilityRequiresExecutablePath() async throws {
        let missing = ParakeetSidecarRuntimeClient(executableURLProvider: { nil })
        #expect(await missing.isRuntimeAvailable() == false)

        let executable = temporaryDirectory().appendingPathComponent("fake-sidecar.sh")
        try """
        #!/bin/sh
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let ready = ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        #expect(await ready.isRuntimeAvailable() == true)
    }

    @Test
    func parakeetSidecarRuntimeReadsJSONLEventsFromProcess() async throws {
        let executable = temporaryDirectory().appendingPathComponent("fake-sidecar.sh")
        try """
        #!/bin/sh
        printf '%s\\n' '{"segmentId":"fake-p1","text":"How did the robot decide which object to approach?","isFinal":true,"startTime":0.0,"endTime":2.5,"confidence":null,"source":"local_parakeet_asr"}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        let stream = try await runtime.startTranscription(
            modelDirectory: temporaryDirectory(),
            config: ASRConfig(sessionID: "sidecar-test", captureMode: .systemAudioOnly)
        )
        var events: [ParakeetTranscriptEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 1)
        #expect(events[0].segmentId == "fake-p1")
        #expect(events[0].source == ASRSource.localParakeetASR.rawValue)
        #expect(events[0].isFinal == true)
    }

    @Test @MainActor
    func parakeetMockRuntimeEmitsLocalASRSourceAndCanEnterQuestionDetection() async throws {
        let provider = LocalParakeetASRProvider(
            modelManager: StaticLocalModelManager(status: .installed),
            runtimeClient: MockParakeetRuntimeClient(
                isAvailable: true,
                events: [
                    ParakeetTranscriptEvent(
                        segmentId: "p1",
                        text: "How would you debug a robot perception failure?",
                        isFinal: true,
                        startTime: 1.0,
                        endTime: 2.0
                    )
                ]
            )
        )
        let appState = try AppState(database: AppDatabase(inMemory: true))
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let stream = try await provider.startTranscription(config: ASRConfig(sessionID: session.id, captureMode: .systemAudioOnly))
        var emitted: [TranscriptSegment] = []
        for try await segment in stream {
            emitted.append(segment)
        }

        #expect(emitted.count == 1)
        #expect(emitted[0].source == .systemAudio)
        #expect(emitted[0].speaker == .interviewer)
        #expect(emitted[0].asrSource == .localParakeetASR)
        #expect(emitted[0].recognitionIsFinal == true)

        await appState.handleTranscriptSegment(emitted[0])
        #expect(appState.lastTranscriptQuestionGenerationTrace.asrSource == ASRSource.localParakeetASR.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.source == AudioSourceType.systemAudio.rawValue)
        #expect(appState.lastTranscriptQuestionGenerationTrace.questionCandidate == true)

        try appState.transcriptRepository.saveSegment(emitted[0])
        let persisted = try #require(try appState.transcriptRepository.segmentByID("p1"))
        #expect(persisted.asrSource == .localParakeetASR)
    }

    @Test
    func sourceMetadataKeepsDeepSeekAndLocalQwenSeparate() {
        let deepSeek = ProviderSourceMetadata.deepSeek(modelName: "deepseek-v4-flash")
        let qwen = ProviderSourceMetadata.ollamaQwen(modelName: "qwen3.5:4b", fallbackReason: "provider_error")

        #expect(deepSeek.source == .deepseekStream)
        #expect(deepSeek.isLocal == false)
        #expect(qwen.source == .ollamaQwen)
        #expect(qwen.isLocal == true)
        #expect(qwen.persistedSource != deepSeek.persistedSource)
        #expect(deepSeek.persistedSource == AnswerSource.deepseekStream.rawValue)
        #expect(qwen.persistedSource == AnswerSource.ollamaQwen.rawValue)
    }

    @Test @MainActor
    func localQwenPrimaryRecordsOllamaQwenSource() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = MockLocalLLMProvider(tokens: [
            "I would debug a confident but wrong YOLOv8 prediction on the LeoRover by reproducing the exact frames, inspecting logs, bounding boxes, classes, and confidence, then checking calibration, lighting, occlusion, motion blur, and spatial consistency before deciding whether retraining is needed."
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-primary-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished == true)
        let card = try #require(appState.currentSuggestion)
        #expect(card.providerKind == .ollamaLocal)
        #expect(card.providerName == "Ollama Qwen")
        #expect(card.isLocal == true)
        #expect(card.sayFirstSource == AnswerSource.ollamaQwen.rawValue)
        #expect(card.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(card.softFallbackUsed == false)
        #expect(card.fallbackReason == nil)
        #expect(appState.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(appState.deepseekFirstTokenMS == nil)
        #expect(appState.deepseekFirstVisibleMS == nil)
    }

    @Test @MainActor
    func phdLocalQwenPromptExcludesUnrelatedJobDescriptionEvidence() async throws {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        appState.interviewContextMode = .phdRobotics
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let question = localQwenQuestion(
            id: "phd-publication-question",
            sessionID: session.id,
            text: "What experimental evidence would convince you that your semantic and geometric grasp re-ranking method is strong enough to support a publication?"
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.activateGeneration(
            question: question,
            generationID: "phd-publication-generation",
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )
        let cvChunk = localDocumentChunk(
            id: "phd-grasp-evidence",
            type: .cv,
            content: "Current MSc work compares semantic grounding, geometric feasibility, clearance, collision risk, and grasp re-ranking."
        )
        let jdChunk = localDocumentChunk(
            id: "unrelated-dexory-jd",
            type: .jobDescription,
            content: "Dexory robotics commissioning role in warehouse logistics."
        )
        let provider = MockLocalLLMProvider(tokens: [
            "I think publication would be possible if the dissertation benchmark shows repeatable improvements in semantic and geometric grasp re-ranking, and I would align those results with my supervisor before making a claim."
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [cvChunk], jobDescriptionChunks: [jdChunk]),
            retrievedChunks: [localRetrievedChunk(cvChunk), localRetrievedChunk(jdChunk)],
            cvSummary: cvChunk.content,
            jdSummary: jdChunk.content,
            generationID: "phd-publication-generation",
            cardID: "phd-publication-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished)
        let prompt = try #require(provider.requests.first?.prompt)
        #expect(prompt.localizedCaseInsensitiveContains("semantic grounding"))
        #expect(!prompt.localizedCaseInsensitiveContains("Dexory"))
        #expect(appState.currentSuggestion?.ragChunkIDs.contains(jdChunk.id) == false)
        #expect(appState.currentSuggestion?.evidenceUsed.contains(jdChunk.id) == false)
    }

    @Test @MainActor
    func phdLocalQwenUsesSpecializedRubricForGroundedArchitectureAnswer() async throws {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        appState.interviewContextMode = .phdRobotics
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let question = localQwenQuestion(
            id: "phd-architecture-question",
            sessionID: session.id,
            text: "Describe the control architecture you used on the robot arm, from the perception result through ROS2 to physical motion execution."
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        appState.activateGeneration(
            question: question,
            generationID: "phd-architecture-generation",
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )
        let provider = MockLocalLLMProvider(tokens: [
            "I used a ROS2-based control architecture where perception outputs a target pose, which I passed to planning and arm-control components for execution. Feedback validated the motion and triggered recovery if timing or localization errors occurred."
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robot perception and ROS2 experience.",
            jdSummary: "",
            generationID: "phd-architecture-generation",
            cardID: "phd-architecture-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished)
        #expect(provider.requests.count == 1)
        #expect(appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        try await waitUntil(timeout: 1.0) {
            let rows = (try? appState.suggestionRepository.suggestions(sessionID: session.id)) ?? []
            return rows.contains { $0.id == "phd-architecture-card" }
        }
        let persisted = try #require(
            try appState.suggestionRepository.suggestions(sessionID: session.id)
                .first { $0.id == "phd-architecture-card" }
        )
        #expect(persisted.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(persisted.sayFirstSource == AnswerSource.ollamaQwen.rawValue)
        #expect(persisted.softFallbackUsed == false)
    }

    @Test @MainActor
    func interruptedQwenQuestionPersistsSupersededSnapshotWithoutFallbackContamination() async throws {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let q4A = localQwenQuestion(
            id: "q4a-superseded",
            sessionID: session.id,
            text: "Walk me through one complete robot task from perception to action."
        )
        let q4B = localQwenQuestion(
            id: "q4b-current",
            sessionID: session.id,
            text: "What did real-world testing teach you about debugging robot behavior?"
        )
        try appState.suggestionRepository.saveDetectedQuestion(q4A)
        try appState.suggestionRepository.saveDetectedQuestion(q4B)
        appState.activateGeneration(
            question: q4A,
            generationID: "q4a-generation",
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )
        appState.activateGeneration(
            question: q4B,
            generationID: "q4b-generation",
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )

        let provider = MockLocalLLMProvider(tokens: [
            "Real-world testing taught me to debug the robot as a timed system: correlate camera, localization, navigation, and manipulation logs, reproduce the exact handoff, then validate one recovery behavior at a time on the LeoRover."
        ])
        let finished = try await appState.finishWithLocalQwenAnswer(
            question: q4B,
            session: session,
            transcript: q4B.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: "q4b-generation",
            cardID: "q4b-card",
            requestStart: Date(),
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )
        #expect(finished == true)

        try await waitUntil(timeout: 2.0) {
            let rows = (try? appState.suggestionRepository.suggestions(sessionID: session.id)) ?? []
            return rows.contains { $0.detectedQuestionID == q4A.id }
        }
        let rows = try appState.suggestionRepository.suggestions(sessionID: session.id)
        let q4ARow = try #require(rows.first { $0.detectedQuestionID == q4A.id })
        #expect(q4ARow.stageBStatus == "superseded")
        #expect(q4ARow.stageBCompleted == false)
        #expect(q4ARow.finalVisibleSource == "local_superseded_question_snapshot")
        #expect(q4ARow.softFallbackUsed == false)
        #expect(q4ARow.softFallbackLatencyMS == nil)

        let q4BCard = try #require(appState.currentSuggestion)
        #expect(q4BCard.detectedQuestionID == q4B.id)
        #expect(q4BCard.generationID == "q4b-generation")
        #expect(q4BCard.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(q4BCard.softFallbackUsed == false)
        #expect(appState.activeQuestionID == q4B.id)
    }

    @Test @MainActor
    func localQwenPrimaryRetriesOnceAfterEmptyStream() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = SequencedMockLocalLLMProvider(tokenBatches: [
            [],
            ["I would debug a confident but wrong YOLOv8 prediction on the LeoRover by replaying the camera frames, checking bounding boxes, classes, confidence, calibration, lighting, occlusion, and spatial consistency before retraining or adding recovery behavior."]
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-retry-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished == true)
        #expect(provider.generateCallCount == 2)
        #expect(appState.currentSuggestion?.providerName == "Ollama Qwen")
        #expect(appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(appState.currentSuggestion?.softFallbackUsed == false)
    }

    @Test @MainActor
    func localQwenPrimaryUsesCompactPromptAfterRepeatedEmptyStreams() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = SequencedMockLocalLLMProvider(tokenBatches: [
            [],
            [],
            ["I would debug a confident but wrong YOLOv8 prediction on the LeoRover by replaying the camera frames, checking bounding boxes, labels, confidence, calibration, lighting, occlusion, and the downstream pose handoff before changing the model or adding recovery behavior."]
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-compact-recovery-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished == true)
        #expect(provider.generateCallCount == 3)
        #expect(appState.currentSuggestion?.providerName == "Ollama Qwen")
        #expect(appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(appState.currentSuggestion?.softFallbackUsed == false)
    }

    @Test @MainActor
    func localQwenPrimaryUsesGroundedRecoveryAfterCompactEmptyStream() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = SequencedMockLocalLLMProvider(tokenBatches: [
            [],
            [],
            [],
            ["I would debug a confident but wrong YOLOv8 prediction on the LeoRover by replaying the exact camera frames, checking the predicted class, box, confidence, calibration, lighting, occlusion, and temporal consistency, then adding validation or retraining only after isolating the failure mode."]
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-grounded-recovery-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished == true)
        #expect(provider.generateCallCount == 4)
        #expect(appState.currentSuggestion?.providerName == "Ollama Qwen")
        #expect(appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(appState.currentSuggestion?.softFallbackUsed == false)
    }

    @Test @MainActor
    func localQwenPrimaryRetriesAfterNonAlignedNonEmptyAnswer() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = SequencedMockLocalLLMProvider(tokenBatches: [
            ["I cannot answer because the required context is missing."],
            [],
            [],
            ["I would debug a confident but wrong YOLOv8 prediction on the LeoRover by replaying the exact camera frames, checking classes, boxes, confidence, calibration, lighting, occlusion, and temporal consistency, then adding validation or retraining after isolating the cause."]
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-nonaligned-retry-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: nil
        )

        #expect(finished == true)
        #expect(provider.generateCallCount == 4)
        #expect(appState.currentSuggestion?.providerName == "Ollama Qwen")
        #expect(appState.currentSuggestion?.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(appState.currentSuggestion?.softFallbackUsed == false)
    }

    @Test @MainActor
    func localQwenFallbackPersistsFallbackReasonWithoutDeepSeekSource() async throws {
        let (appState, session, question, generationID, requestStart) = try makeLocalQwenRuntimeState()
        let provider = MockLocalLLMProvider(tokens: [
            "I would debug a confident but wrong YOLOv8 prediction on the LeoRover by replaying the frames, checking logs, bounding boxes, classes, confidence, calibration, lighting, occlusion, and then adding validation or recovery behavior before retraining."
        ])

        let finished = try await appState.finishWithLocalQwenAnswer(
            question: question,
            session: session,
            transcript: question.questionText,
            context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            retrievedChunks: [],
            cvSummary: "Robotics CV",
            jdSummary: "Robotics role",
            generationID: generationID,
            cardID: "qwen-fallback-card",
            requestStart: requestStart,
            triggerPath: .manualGenerate,
            source: .systemAudio,
            speaker: .interviewer,
            localProvider: provider,
            fallbackReason: "deepseek_failed_before_first_token"
        )

        #expect(finished == true)
        let card = try #require(appState.currentSuggestion)
        #expect(card.sayFirstSource == AnswerSource.ollamaQwen.rawValue)
        #expect(card.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(card.finalVisibleSource != AnswerSource.deepseekStream.rawValue)
        #expect(card.softFallbackUsed == true)
        #expect(card.fallbackReason == "deepseek_failed_before_first_token")

        try appState.suggestionRepository.saveSuggestionCard(card)
        let persisted = try #require(try appState.suggestionRepository.suggestions(sessionID: session.id).first { $0.id == card.id })
        #expect(persisted.finalVisibleSource == AnswerSource.ollamaQwen.rawValue)
        #expect(persisted.fallbackReason == "deepseek_failed_before_first_token")
        #expect(persisted.providerKind == .ollamaLocal)
        #expect(persisted.isLocal == true)
    }

    @Test
    func realOllamaQwenProviderSmokeWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["INTERVIEW_COPILOT_REAL_OLLAMA_SMOKE"] == "1" else {
            return
        }
        let provider = OllamaQwenProvider()
        let health = await provider.healthCheck(modelName: "qwen3.5:4b")
        #expect(health.isReady == true)

        let stream = try await provider.generateAnswer(request: LocalLLMRequest(
            prompt: "Answer in one sentence: what is the role of localization in a robot pipeline?",
            systemPrompt: "You are a concise interview answer helper.",
            modelName: "qwen3.5:4b",
            temperature: 0.1,
            numPredict: 48
        ))
        var answer = ""
        for try await token in stream {
            #expect(token.source == .ollamaQwen)
            answer += token.text
        }
        #expect(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            Issue.record("Expected request body for \(request.url?.absoluteString ?? "unknown URL")")
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            } else {
                break
            }
        }
        return data
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTarBz2Archive(sourceDirectoryName: String, parentDirectory: URL, archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cjf", archiveURL.path, "-C", parentDirectory.path, sourceDirectoryName]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @MainActor
    private func makeLocalQwenRuntimeState() throws -> (AppState, InterviewSession, DetectedQuestion, String, Date) {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let question = DetectedQuestion(
            id: "qwen-question-\(UUID().uuidString)",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?",
            intent: .technical,
            answerStrategy: .technicalExplanation,
            confidence: 0.95,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
        try appState.suggestionRepository.saveDetectedQuestion(question)
        let generationID = "qwen-generation-\(UUID().uuidString)"
        let requestStart = Date()
        appState.activateGeneration(
            question: question,
            generationID: generationID,
            triggerPath: .manualGenerate,
            requestStart: requestStart,
            source: .systemAudio,
            speaker: .interviewer
        )
        return (appState, session, question, generationID, requestStart)
    }

    @MainActor
    private func localQwenQuestion(id: String, sessionID: String, text: String) -> DetectedQuestion {
        DetectedQuestion(
            id: id,
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: text,
            intent: .technical,
            answerStrategy: .technicalExplanation,
            confidence: 0.95,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    private func localDocumentChunk(id: String, type: DocumentType, content: String) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "\(type.rawValue)-document",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: TextChunker.tokenize(content),
            sectionTitle: id,
            wordCount: content.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date()
        )
    }

    private func localRetrievedChunk(_ chunk: DocumentChunk) -> RetrievedChunk {
        RetrievedChunk(
            id: chunk.id,
            documentID: chunk.documentID,
            documentType: chunk.documentType,
            chunkIndex: chunk.chunkIndex,
            contentPreview: String(chunk.content.prefix(80)),
            fullContent: chunk.content,
            keywords: chunk.keywords,
            score: 1,
            keywordOverlapCount: 1,
            contentOverlapCount: 1,
            rank: 1,
            isIncludedInPrompt: true,
            sectionTitle: chunk.sectionTitle,
            wordCount: chunk.wordCount
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(
            domain: "LocalModelsSetupTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for local model state."]
        )
    }
}

private final class MockLocalLLMProvider: LocalLLMProvider {
    let id = "mock_ollama_qwen"
    let displayName = "Mock Ollama Qwen"
    let tokens: [String]
    private(set) var requests: [LocalLLMRequest] = []

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        LocalLLMHealth(
            ollamaRunning: true,
            selectedModel: modelName,
            modelInstalled: true,
            providerSource: .ollamaQwen,
            lastError: nil
        )
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(modelID: modelName, totalBytes: nil))
            continuation.finish()
        }
    }

    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        requests.append(request)
        let tokens = tokens
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(LLMToken(text: token, source: .ollamaQwen, modelName: request.modelName))
            }
            continuation.finish()
        }
    }
}

private final class SequencedMockLocalLLMProvider: LocalLLMProvider {
    let id = "mock_ollama_qwen_sequence"
    let displayName = "Mock Ollama Qwen Sequence"
    private let tokenBatches: [[String]]
    private(set) var generateCallCount = 0

    init(tokenBatches: [[String]]) {
        self.tokenBatches = tokenBatches
    }

    func healthCheck(modelName: String) async -> LocalLLMHealth {
        LocalLLMHealth(
            ollamaRunning: true,
            selectedModel: modelName,
            modelInstalled: true,
            providerSource: .ollamaQwen,
            lastError: nil
        )
    }

    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(modelID: modelName, totalBytes: nil))
            continuation.finish()
        }
    }

    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        generateCallCount += 1
        let index = min(generateCallCount - 1, max(tokenBatches.count - 1, 0))
        let tokens = tokenBatches.isEmpty ? [] : tokenBatches[index]
        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(LLMToken(text: token, source: .ollamaQwen, modelName: request.modelName))
            }
            continuation.finish()
        }
    }
}

private final class MockParakeetRuntimeClient: ParakeetRuntimeClient {
    let isAvailable: Bool
    let events: [ParakeetTranscriptEvent]

    init(isAvailable: Bool, events: [ParakeetTranscriptEvent] = []) {
        self.isAvailable = isAvailable
        self.events = events
    }

    func isRuntimeAvailable() async -> Bool {
        isAvailable
    }

    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        guard isAvailable else {
            throw ParakeetSidecarError.executableNotConfigured
        }
        let events = events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}

    func stop() async {}
}

private final class StaticLocalModelManager: LocalModelManager {
    let status: LocalModelStatus

    init(status: LocalModelStatus) {
        self.status = status
    }

    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus {
        status
    }

    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func deleteModel(_ model: LocalModelDescriptor) async throws {}

    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool {
        status.isReady
    }

    func fileURL(for model: LocalModelDescriptor) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(model.storageRelativePath)
    }
}
