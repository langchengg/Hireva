import Foundation
import Testing
import AVFoundation
import GRDB
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct ManualCaptureTests {

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacManualCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func setupOnboardingData(database: AppDatabase) async throws {
        try await database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('1', 'CV', 'This is my comprehensive resume detailing all of my professional experience in software engineering and artificial intelligence.', 'cv', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('2', 'JD', 'This is a job description for a principal swift macos developer requiring years of experience in Core Audio and ScreenCaptureKit.', 'job_description', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
        }
    }

    class MockPermissionService: PermissionService {
        var micRequestedCount = 0
        var speechRequestedCount = 0

        override func checkMicrophonePermission() -> MicrophonePermissionState {
            return .authorized
        }

        override func requestMicrophonePermission() async -> MicrophonePermissionState {
            micRequestedCount += 1
            return .authorized
        }

        override func requestSpeechRecognition() async -> PermissionState {
            speechRequestedCount += 1
            return .granted
        }

        override func speechStatus() -> PermissionState {
            return .granted
        }

        override func snapshot() -> PermissionSnapshot {
            return PermissionSnapshot(
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                systemAudioCapture: .granted
            )
        }

        override func refreshPermissions() -> PermissionSnapshot {
            return snapshot()
        }
    }

    final class TrackingLLMClient: LLMClientProtocol {
        let providerKind: LLMProviderKind = .deepSeek
        var chatCallsCount = 0
        var lastMessages: [LLMChatMessage] = []

        func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
            return LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
        }

        func chatCompletion(
            configuration: LLMProviderConfiguration,
            messages: [LLMChatMessage],
            responseFormat: LLMResponseFormat?,
            options: LLMRequestOptions
        ) async throws -> LLMChatResult {
            chatCallsCount += 1
            lastMessages = messages

            let content = """
            {
                "strategy": "Technical Deep Dive",
                "say_first": "I adapts large vision language models for robotics by adding physical tokens.",
                "key_points": ["First point", "Second point"],
                "follow_up_ready": ["What was the latency?"],
                "confidence": 0.95,
                "caution": "None"
            }
            """
            return LLMChatResult(
                content: content,
                modelName: configuration.model,
                providerKind: configuration.kind,
                providerName: configuration.name,
                baseURL: configuration.baseURL,
                latencyMS: 100,
                isLocal: true,
                rawResponse: nil
            )
        }

        func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
            return []
        }
    }

    // Reset all mock hooks before/after tests
    private func resetMockHooks() {
        ScreenSystemAudioPermissionProbe.mockProbe = nil
        ManualQuestionCaptureService.mockStartCapture = nil
        ManualQuestionCaptureService.mockStopCapture = nil
        ManualQuestionCaptureService.mockCancelCapture = nil
        ManualQuestionTranscriptionService.mockStartTranscription = nil
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = nil
        ManualQuestionTranscriptionService.mockCancel = nil
    }

    // Helper to create a dummy PCM audio buffer
    private func makeDummyAudioBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        return buffer
    }

    // MARK: - Requirement 1 & 4 Tests
    @Test
    func testSystemAudioManualCapturePermissionsAndSpeakerMapping() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }
        appState.refreshAll()

        // 1. Force systemAudio manual capture source
        var settings = appState.settings
        settings.manualCaptureSource = .systemAudio
        settings.showTranscriptBeforeSending = false
        settings.autoSendAfterTranscription = true
        appState.saveSettings(settings)

        // Mock preflight screen recording to succeed
        ScreenSystemAudioPermissionProbe.mockProbe = {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }

        // Mock audio capture start
        var captureStarted = false
        ManualQuestionCaptureService.mockStartCapture = { source, maxSecs, timeoutBlock in
            captureStarted = true
            #expect(source == .systemAudio)
        }

        // Mock transcription start
        var transcriptionStarted = false
        ManualQuestionTranscriptionService.mockStartTranscription = { onPartial, onFinal, onError in
            transcriptionStarted = true
        }

        // Create an active session so database persistence triggers
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session

        // Act
        appState.startManualCapture()
        var elapsedStart = 0
        while (appState.manualCaptureState != .recording || !captureStarted || !transcriptionStarted) && elapsedStart < 150 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        // Assert Constraint 1: systemAudio manual capture does not request microphone/speech permission
        #expect(mockPermission.micRequestedCount == 0)
        #expect(mockPermission.speechRequestedCount == 0)
        #expect(captureStarted)
        #expect(transcriptionStarted)
        #expect(appState.manualCaptureState == .recording)

        // Mock stopping and transcribing
        ManualQuestionCaptureService.mockStopCapture = {
            return [self.makeDummyAudioBuffer()]
        }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { timeout in
            return "What is your experience in ScreenCaptureKit?"
        }

        appState.stopAndTranscribeManualCapture()
        
        var elapsed = 0
        while appState.manualCaptureState != .suggestionReady && elapsed < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            elapsed += 1
        }

        // Assert Constraint 4: Manual captured systemAudio question maps to .interviewer speaker
        let lastSegment = try #require(appState.transcriptSegments.last)
        #expect(lastSegment.source == .systemAudio)
        #expect(lastSegment.speaker == .interviewer)
        #expect(lastSegment.text == "What is your experience in ScreenCaptureKit?")

        // Validate final state is suggestionReady
        #expect(appState.manualCaptureState == .suggestionReady)
        let suggestion = try #require(appState.manualCaptureSuggestion)
        #expect(suggestion.strategy == "Technical Deep Dive")
    }

    // MARK: - Requirement 2 Test
    @Test
    func testMicrophoneManualCapturePermissions() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        // 1. Force microphone manual capture source
        var settings = appState.settings
        settings.manualCaptureSource = .microphone
        appState.saveSettings(settings)

        // Mock audio capture start
        ManualQuestionCaptureService.mockStartCapture = { source, maxSecs, timeoutBlock in
            #expect(source == .microphone)
        }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in }

        // Act
        appState.startManualCapture()
        var elapsedStart = 0
        while appState.manualCaptureState != .recording && elapsedStart < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        // Assert Constraint 2: microphone manual capture requests microphone/speech permissions
        #expect(mockPermission.micRequestedCount == 1)
        #expect(mockPermission.speechRequestedCount == 1)
        #expect(appState.manualCaptureState == .recording)
    }

    // MARK: - Requirement 3 Test
    @Test
    func testShowTranscriptBeforeSendingOverridesAutoSend() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        // Force both parameters to true
        var settings = appState.settings
        settings.manualCaptureSource = .systemAudio
        settings.showTranscriptBeforeSending = true
        settings.autoSendAfterTranscription = true
        appState.saveSettings(settings)

        // Mock preflight screen recording to succeed
        ScreenSystemAudioPermissionProbe.mockProbe = {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }
        ManualQuestionCaptureService.mockStartCapture = { _, _, _ in }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in }

        appState.startManualCapture()
        var elapsedStart = 0
        while appState.manualCaptureState != .recording && elapsedStart < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        // Stop capture
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "A question to review"
        }

        appState.stopAndTranscribeManualCapture()
        
        var elapsed = 0
        while appState.manualCaptureState != .transcriptReady && elapsed < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            elapsed += 1
        }

        // Assert Constraint 3: showTranscriptBeforeSending overrides autoSendAfterTranscription
        // State should be .transcriptReady and NOT auto-sent to AI (calls count should be 0)
        #expect(appState.manualCaptureState == .transcriptReady)
        #expect(appState.manualCaptureTranscript == "A question to review")
        #expect(trackingLLM.chatCallsCount == 0)
    }

    // MARK: - Requirement 5 Test
    @Test
    func testManualCapturedQuestionBypassesQuestionDetection() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        var settings = appState.settings
        settings.manualCaptureSource = .systemAudio
        settings.showTranscriptBeforeSending = false
        settings.autoSendAfterTranscription = true
        appState.saveSettings(settings)

        ScreenSystemAudioPermissionProbe.mockProbe = {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }
        ManualQuestionCaptureService.mockStartCapture = { _, _, _ in }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in }

        appState.startManualCapture()
        var elapsedStart = 0
        while appState.manualCaptureState != .recording && elapsedStart < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "Can we write swift package tests?"
        }

        appState.stopAndTranscribeManualCapture()
        
        var elapsed = 0
        while appState.manualCaptureState != .suggestionReady && elapsed < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            elapsed += 1
        }

        // Assert Constraint 5: Bypasses QuestionDetectionService and goes directly to SuggestionGenerationService.
        // There should be exactly 1 call to LLM (the suggestion prompt), and the system prompt must NOT contain
        // question detection rules.
        #expect(trackingLLM.chatCallsCount == 1)
        let lastMsg = try #require(trackingLLM.lastMessages.first?.content)
        #expect(lastMsg.contains("expert interviewer") || lastMsg.contains("Direct Answer") || lastMsg.contains("suggest"))
        #expect(!lastMsg.contains("determine if the interviewer is asking a complete question"))
    }

    // MARK: - Requirement 6 Test
    @Test
    func testEmptyTranscriptShowsCleanErrorState() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        var settings = appState.settings
        settings.manualCaptureSource = .systemAudio
        settings.showTranscriptBeforeSending = false
        settings.autoSendAfterTranscription = true
        appState.saveSettings(settings)

        ScreenSystemAudioPermissionProbe.mockProbe = {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }
        ManualQuestionCaptureService.mockStartCapture = { _, _, _ in }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in }

        appState.startManualCapture()
        var elapsedStart = 0
        while appState.manualCaptureState != .recording && elapsedStart < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        ManualQuestionCaptureService.mockStopCapture = { return [] }
        // Return empty string as transcript result
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "   "
        }

        appState.stopAndTranscribeManualCapture()
        
        var elapsed = 0
        while true {
            if case .error = appState.manualCaptureState { break }
            if elapsed >= 200 { break }
            try? await Task.sleep(for: .milliseconds(50))
            elapsed += 1
        }

        // Assert Constraint 6: Empty transcript results show a clean error state
        if case .error(let message) = appState.manualCaptureState {
            #expect(message.contains("No speech detected"))
        } else {
            #expect(Bool(false), "Expected manualCaptureState to be .error but was \(appState.manualCaptureState)")
        }
    }

    // MARK: - Requirement 7 Test
    @Test
    func testMaxDurationReachedTriggersAutomaticStop() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        var settings = appState.settings
        settings.manualCaptureSource = .systemAudio
        settings.maxManualCaptureSeconds = 2
        settings.showTranscriptBeforeSending = false
        settings.autoSendAfterTranscription = true
        appState.saveSettings(settings)

        ScreenSystemAudioPermissionProbe.mockProbe = {
            return ScreenSystemAudioPermissionProbeResult(
                preflightGranted: true,
                shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true,
                errorDescription: nil,
                likelyIdentityMismatch: false
            )
        }

        var capturedTimeoutBlock: (() -> Void)?
        ManualQuestionCaptureService.mockStartCapture = { source, maxSec, onTimeout in
            capturedTimeoutBlock = onTimeout
        }
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in }

        appState.startManualCapture()
        var elapsedStart = 0
        while (appState.manualCaptureState != .recording || capturedTimeoutBlock == nil) && elapsedStart < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            elapsedStart += 1
        }

        #expect(appState.manualCaptureState == .recording)
        let timeoutBlock = try #require(capturedTimeoutBlock)

        // Mock stopping and returning buffers
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "Timeout test question"
        }

        // Trigger timeout block manually
        timeoutBlock()
        
        var elapsed = 0
        while appState.manualCaptureState != .suggestionReady && elapsed < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            elapsed += 1
        }

        // Assert Constraint 7: Max duration reached triggers automatic stop
        // The AppState should have handled the timeout, finalized, and turned state to suggestionReady or error
        #expect(appState.manualCaptureState == .suggestionReady)
        #expect(appState.manualCaptureTranscript == "Timeout test question")
    }

    @Test
    func testManualCaptureBufferDiagnosticsRemainNonzero() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        appState.manualCaptureState = .recording
        ManualQuestionCaptureService.shared.capturedBufferCount = 42
        ManualQuestionCaptureService.shared.recordingDuration = 10.5
        let testTimestamp = Date()
        ManualQuestionCaptureService.shared.lastBufferTimestamp = testTimestamp

        // Stop capture
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in return "What do you offer?" }

        appState.stopAndTranscribeManualCapture()
        
        // Wait for transcription to complete
        var elapsed = 0
        while appState.manualCaptureState == .transcribing && elapsed < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 1
        }

        #expect(appState.manualCaptureBufferCount == 42)
        #expect(abs(appState.manualCaptureDuration - 10.5) <= 0.15)
        #expect(appState.manualCaptureTranscript == "What do you offer?")
    }

    @Test
    func testLLMFailureKillsNotState() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        final class FailingLLMClient: LLMClientProtocol {
            let providerKind: LLMProviderKind = .deepSeek
            func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
                return LLMConnectionTestResult(success: false, message: "fail", latencyMS: 1, models: [])
            }
            func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage], responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
                throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "API provider timeout error domain"])
            }
            func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
                return []
            }
        }

        let mockPermission = MockPermissionService()
        let failingLLM = FailingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: failingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "What do you offer"
        appState.manualCaptureBufferCount = 15

        appState.sendManualCaptureToAI()

        var elapsed = 0
        while appState.manualCaptureState == .generatingSuggestion && elapsed < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 1
        }

        // Verify state is suggestionError, and transcript is retained!
        if case .suggestionError(let msg) = appState.manualCaptureState {
            #expect(msg.contains("API provider timeout error domain"))
        } else {
            Issue.record("Expected state to be suggestionError but was \(appState.manualCaptureState)")
        }
        #expect(appState.manualCaptureTranscript == "What do you offer")
        #expect(appState.manualCaptureBufferCount == 15)
    }

    @Test
    func testRetryLLMReusesTranscript() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: trackingLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        appState.manualCaptureState = .suggestionError("Previous failure")
        appState.manualCaptureTranscript = "Edited question text"
        appState.manualCaptureBufferCount = 12

        appState.sendManualCaptureToAI()

        var elapsed = 0
        while appState.manualCaptureState == .generatingSuggestion && elapsed < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 1
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        #expect(appState.manualCaptureTranscript == "Edited question text")
        #expect(appState.manualCaptureSuggestion != nil)
    }

    @Test
    func testMalformedJSONRepair() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        final class MalformedJSONLLMClient: LLMClientProtocol {
            let providerKind: LLMProviderKind = .deepSeek
            func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
                return LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
            }
            func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage], responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
                let rawContent = """
                ```json
                {
                    "strategy": "Direct Answer",
                    "say_first": "Corrected text",
                    "key_points": ["First point", "Second point"],
                    "follow_up_ready": [],
                    "confidence": 0.85,
                    "caution": "None",
                    "evidence_used": [],
                    "risk_level": "low",
                }
                ```
                """
                return LLMChatResult(
                    content: rawContent,
                    modelName: "test-model",
                    providerKind: .deepSeek,
                    providerName: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    latencyMS: 100,
                    isLocal: true,
                    rawResponse: nil
                )
            }
            func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
                return []
            }
        }

        let mockPermission = MockPermissionService()
        let malformedLLM = MalformedJSONLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: malformedLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "What do you offer"

        appState.sendManualCaptureToAI()

        var elapsed = 0
        while appState.manualCaptureState == .generatingSuggestion && elapsed < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 1
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        let suggestion = try #require(appState.manualCaptureSuggestion)
        #expect(suggestion.strategy == "Direct Answer")
        #expect(suggestion.sayFirst == "Corrected text")
        #expect(suggestion.keyPoints.count == 2)
    }

    @Test
    func testRawTextFallbackSuggestion() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        final class PlainTextLLMClient: LLMClientProtocol {
            let providerKind: LLMProviderKind = .deepSeek
            func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
                return LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
            }
            func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage], responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
                let rawContent = "This is a plain text answer from the model. It contains sentences. It also has: \n- Bullet point 1\n- Bullet point 2"
                return LLMChatResult(
                    content: rawContent,
                    modelName: "test-model",
                    providerKind: .deepSeek,
                    providerName: "DeepSeek",
                    baseURL: "https://api.deepseek.com",
                    latencyMS: 100,
                    isLocal: true,
                    rawResponse: nil
                )
            }
            func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
                return []
            }
        }

        let mockPermission = MockPermissionService()
        let plainLLM = PlainTextLLMClient()
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: plainLLM])
        let appState = AppState(database: database, llmRouter: router, permissionService: mockPermission)
        appState.refreshAll()

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "What do you offer"

        appState.sendManualCaptureToAI()

        var elapsed = 0
        while appState.manualCaptureState == .generatingSuggestion && elapsed < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 1
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        let suggestion = try #require(appState.manualCaptureSuggestion)
        #expect(suggestion.strategy == "Direct Answer")
        #expect(suggestion.sayFirst.contains("This is a plain text answer"))
        #expect(suggestion.keyPoints.count >= 2)
        #expect(suggestion.keyPoints.contains("Bullet point 1"))
    }
}
