import Foundation
import Testing
import AVFoundation
@testable import Hireva

@Suite(.serialized)
@MainActor
struct ManualCaptureTests {

    private struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaManualCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func setupOnboardingData(database: AppDatabase) async throws {
        let documents = DocumentRepository(database: database)
        let cv = try documents.saveDocument(
            type: .cv,
            title: "Manual Capture CV",
            content: String(repeating: "Built Swift Package tests and robotics software using Python, C++, ROS2, AI perception, Core Audio, and ScreenCaptureKit. ", count: 8)
        )
        let opportunityDocument = try documents.saveDocument(
            type: .jobDescription,
            title: "Manual Capture Role",
            content: String(repeating: "The principal Swift macOS role values automated testing, practical robotics systems, reliable audio capture, and engineering growth. ", count: 8)
        )
        let contexts = InterviewContextRepository(database: database)
        let profile = CandidateProfile(
            id: "manual-capture-profile",
            displayName: "Manual Capture Candidate",
            sourceDocumentIDs: [cv.id],
            education: [],
            experience: [evidence(
                id: "manual-capture-experience",
                statement: "Built Swift Package tests and macOS audio capture software using Core Audio and ScreenCaptureKit.",
                documentID: cv.id,
                type: .experience
            )],
            projects: [evidence(
                id: "manual-capture-project",
                statement: "Built robotics and AI perception projects using Python, C++, and ROS2 for practical robot deployment.",
                documentID: cv.id,
                type: .project
            )],
            skills: [evidence(
                id: "manual-capture-skills",
                statement: "Comfortable with Python and ROS2 and actively improving C++ for performance-critical robotics systems.",
                documentID: cv.id,
                type: .skill
            )],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [evidence(
                id: "manual-capture-goal",
                statement: "Wants a Swift robotics role that combines real robot deployment with engineering growth.",
                documentID: cv.id,
                type: .goal
            )],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let opportunity = OpportunityContext(
            id: "manual-capture-opportunity",
            title: "Principal Swift macOS Engineer",
            organisation: "Test Organisation",
            opportunityType: .job,
            responsibilities: [evidence(
                id: "manual-capture-responsibility",
                statement: "Build reliable audio capture and practical robotics software.",
                documentID: opportunityDocument.id,
                type: .responsibility
            )],
            requiredSkills: [evidence(
                id: "manual-capture-required-skill",
                statement: "Swift Package testing, Core Audio, ScreenCaptureKit, Python, C++, and ROS2.",
                documentID: opportunityDocument.id,
                type: .requiredSkill
            )],
            preferredSkills: [],
            researchTopics: [],
            evaluationCriteria: [],
            sourceDocumentIDs: [opportunityDocument.id],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try contexts.saveCandidateProfile(profile)
        try contexts.saveOpportunityContext(opportunity)
        try contexts.saveSelection(InterviewContextSelection(
            candidateProfileID: profile.id,
            opportunityContextID: opportunity.id,
            domainProfileID: .softwareEngineering
        ))
        try contexts.saveConfigurationOrigin(.automaticDocuments)
    }

    private func evidence(
        id: String,
        statement: String,
        documentID: String,
        type: EvidenceType
    ) -> ProfileEvidence {
        ProfileEvidence(
            id: id,
            statement: statement,
            sourceDocumentID: documentID,
            sourceChunkID: "\(id)-chunk",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: type,
            explicitness: .explicit
        )
    }

    private final class MockPermissionService: PermissionService {
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

    private func makeAppState(
        database: AppDatabase,
        client: any LLMClientProtocol,
        permissionService: MockPermissionService
    ) throws -> AppState {
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        if let deepSeek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settings.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.automaticContextReadiness = .ready
        ManualQuestionCaptureService.mockCancelCapture = {}
        ManualQuestionTranscriptionService.mockCancel = {}
        return appState
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw WaitTimeout(description: "Timed out waiting for \(description)")
            }
            try await clock.sleep(for: .milliseconds(5))
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
                "say_first": "I am comfortable with Python and ROS2 and actively improving C++, and I also write Swift Package tests for reliable macOS capture workflows.",
                "key_points": ["Python, ROS2, and C++ robotics work", "Swift Package tests for macOS capture workflows"],
                "follow_up_ready": ["I can describe where I used each tool and how I tested the workflow."],
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
                isLocal: false,
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

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
        try await waitUntil("system-audio manual recording to start") {
            appState.manualCaptureState == .recording && captureStarted && transcriptionStarted
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
            return "How comfortable are you with Python, C++, and ROS2?"
        }

        appState.stopAndTranscribeManualCapture()
        try await waitUntil("manual suggestion and transcript persistence") {
            appState.manualCaptureState == .suggestionReady && appState.transcriptSegments.last != nil
        }

        // Assert Constraint 4: Manual captured systemAudio question maps to .interviewer speaker
        let lastSegment = try #require(appState.transcriptSegments.last)
        #expect(lastSegment.source == .systemAudio)
        #expect(lastSegment.speaker == .interviewer)
        #expect(lastSegment.text == "How comfortable are you with Python, C++, and ROS2?")

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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        // 1. Force microphone manual capture source
        var settings = appState.settings
        settings.manualCaptureSource = .microphone
        appState.saveSettings(settings)

        // Mock audio capture start
        var captureStarted = false
        var transcriptionStarted = false
        ManualQuestionCaptureService.mockStartCapture = { source, maxSecs, timeoutBlock in
            #expect(source == .microphone)
            captureStarted = true
        }
        ManualQuestionCaptureService.mockCancelCapture = {}
        ManualQuestionTranscriptionService.mockStartTranscription = { _, _, _ in
            transcriptionStarted = true
        }
        ManualQuestionTranscriptionService.mockCancel = {}

        // Act
        appState.startManualCapture()
        try await waitUntil("microphone manual recording to start") {
            appState.manualCaptureState == .recording && captureStarted && transcriptionStarted
        }

        // Assert Constraint 2: microphone manual capture requests microphone/speech permissions
        #expect(mockPermission.micRequestedCount == 1)
        #expect(mockPermission.speechRequestedCount == 1)
        #expect(appState.manualCaptureState == .recording)
        #expect(captureStarted)
        #expect(transcriptionStarted)
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

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
        try await waitUntil("review-mode manual recording to start") {
            appState.manualCaptureState == .recording
        }

        // Stop capture
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "A question to review"
        }

        appState.stopAndTranscribeManualCapture()
        try await waitUntil("manual transcript review state") {
            appState.manualCaptureState == .transcriptReady
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

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
        try await waitUntil("direct-generation manual recording to start") {
            appState.manualCaptureState == .recording
        }

        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "Can we write swift package tests?"
        }

        appState.stopAndTranscribeManualCapture()
        try await waitUntil("manual generation to finish") {
            appState.manualCaptureState == .suggestionReady
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

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
        try await waitUntil("empty-transcript manual recording to start") {
            appState.manualCaptureState == .recording
        }

        ManualQuestionCaptureService.mockStopCapture = { return [] }
        // Return empty string as transcript result
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "   "
        }

        appState.stopAndTranscribeManualCapture()
        try await waitUntil("empty transcript error") {
            if case .error = appState.manualCaptureState { return true }
            return false
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

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
        try await waitUntil("manual timeout callback installation") {
            appState.manualCaptureState == .recording && capturedTimeoutBlock != nil
        }

        #expect(appState.manualCaptureState == .recording)
        let timeoutBlock = try #require(capturedTimeoutBlock)

        // Mock stopping and returning buffers
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in
            return "How do you test Swift packages?"
        }

        // Trigger timeout block manually
        timeoutBlock()
        try await waitUntil("max-duration manual generation to finish") {
            appState.manualCaptureState == .suggestionReady
        }

        // Assert Constraint 7: Max duration reached triggers automatic stop
        // The AppState should have handled the timeout, finalized, and turned state to suggestionReady or error
        #expect(appState.manualCaptureState == .suggestionReady)
        #expect(appState.manualCaptureTranscript == "How do you test Swift packages?")
    }

    @Test
    func testManualCaptureBufferDiagnosticsRemainNonzero() async throws {
        resetMockHooks()
        defer { resetMockHooks() }

        let database = try makeTemporaryDatabase()
        try await setupOnboardingData(database: database)

        let mockPermission = MockPermissionService()
        let trackingLLM = TrackingLLMClient()
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        let captureService = ManualQuestionCaptureService.shared
        let originalBufferCount = captureService.capturedBufferCount
        let originalDuration = captureService.recordingDuration
        let originalTimestamp = captureService.lastBufferTimestamp
        defer {
            captureService.capturedBufferCount = originalBufferCount
            captureService.recordingDuration = originalDuration
            captureService.lastBufferTimestamp = originalTimestamp
        }

        appState.manualCaptureState = .recording
        captureService.capturedBufferCount = 42
        captureService.recordingDuration = 10.5
        let testTimestamp = Date()
        captureService.lastBufferTimestamp = testTimestamp

        // Stop capture
        ManualQuestionCaptureService.mockStopCapture = { return [] }
        ManualQuestionTranscriptionService.mockEndAudioAndFinalize = { _ in return "What do you offer?" }

        appState.stopAndTranscribeManualCapture()
        try await waitUntil("manual buffer diagnostics transcription") {
            appState.manualCaptureTranscript == "What do you offer?"
        }

        #expect(appState.manualCaptureBufferCount == 42)
        #expect(abs(appState.manualCaptureDuration - 10.5) <= 0.30)
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
        let appState = try makeAppState(database: database, client: failingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "What do you offer"
        appState.manualCaptureBufferCount = 15

        appState.sendManualCaptureToAI()
        try await waitUntil("manual provider failure") {
            if case .suggestionError = appState.manualCaptureState { return true }
            return false
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
        let appState = try makeAppState(database: database, client: trackingLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        appState.manualCaptureState = .suggestionError("Previous failure")
        appState.manualCaptureTranscript = "How comfortable are you with Python, C++, and ROS2?"
        appState.manualCaptureBufferCount = 12

        appState.sendManualCaptureToAI()
        try await waitUntil("manual retry generation") {
            appState.manualCaptureState == .suggestionReady
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        #expect(appState.manualCaptureTranscript == "How comfortable are you with Python, C++, and ROS2?")
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
                    "say_first": "I want this role because it connects with my robotics, AI, and perception experience, real robot deployment interests, and engineering growth.",
                    "key_points": ["Role connects with robotics and AI", "Real-world deployment and engineering growth"],
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
        let appState = try makeAppState(database: database, client: malformedLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "Why do you want to join our team?"

        appState.sendManualCaptureToAI()
        try await waitUntil("malformed JSON repair") {
            appState.manualCaptureState == .suggestionReady
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        let suggestion = try #require(appState.manualCaptureSuggestion)
        #expect(suggestion.strategy == "Direct Answer")
        #expect(suggestion.sayFirst == "I want this role because it connects with my robotics, AI, and perception experience, real robot deployment interests, and engineering growth.")
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
                let rawContent = "I want this role because it connects with my robotics, AI, and perception experience and my interest in real robot deployment.\n- Engineering growth\n- Contribute to practical robotics systems"
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
        let appState = try makeAppState(database: database, client: plainLLM, permissionService: mockPermission)
        defer { appState.cancelManualCapture() }

        appState.manualCaptureState = .transcriptReady
        appState.manualCaptureTranscript = "Why do you want to join our team?"

        appState.sendManualCaptureToAI()
        try await waitUntil("plain-text suggestion conversion") {
            appState.manualCaptureState == .suggestionReady
        }

        #expect(appState.manualCaptureState == .suggestionReady)
        let suggestion = try #require(appState.manualCaptureSuggestion)
        #expect(suggestion.strategy == "Direct Answer")
        #expect(suggestion.sayFirst.contains("I want this role"))
        #expect(suggestion.keyPoints.count >= 2)
        #expect(suggestion.keyPoints.contains("Engineering growth"))
    }
}
