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
    func runtimeDefaultsUseLocalQwenAndLocalParakeetSelection() throws {
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

        #expect(appState.selectedASRProviderID == .localParakeet)
        #expect(appState.selectedASRProviderID.source == .localParakeetASR)
        #expect(appState.activeASRProviderID == nil)
        #expect(appState.selectedAnswerProviderMode == .localQwenPrimary)
        #expect(appState.selectedQwenModelName == "qwen3.5:4b")
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
            "http://localhost:11434/api/generate": { request in
                let data = Data("""
                {"response":"hello","done":false}
                {"response":" world","done":false}
                {"response":"","done":true}
                """.utf8)
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
}

private final class MockLocalLLMProvider: LocalLLMProvider {
    let id = "mock_ollama_qwen"
    let displayName = "Mock Ollama Qwen"
    let tokens: [String]

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
        let tokens = tokens
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
