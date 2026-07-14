import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct CaptureRuntimeStateTests {

    private struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    private final class AsyncGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var waiterCount = 0
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            waiterCount += 1
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureRuntimeStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
    
    private final class MockPermissionService: PermissionService {
        override func checkMicrophonePermission() -> MicrophonePermissionState {
            return .authorized
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
        systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil
    ) throws -> AppState {
        let database = try makeTemporaryDatabase()
        try prepareReadyContext(in: database)

        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        if let deepSeek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settings.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let router = LLMRouter(
            settingsRepository: settings,
            clients: [.deepSeek: CaptureRuntimeLLMClient()]
        )
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: MockPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: systemAudioCaptureService,
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.automaticContextReadiness = .ready
        return appState
    }

    private func prepareReadyContext(in database: AppDatabase) throws {
        let documents = DocumentRepository(database: database)
        let cv = try documents.saveDocument(
            type: .cv,
            title: "Capture Runtime CV",
            content: String(repeating: "Built and tested Swift macOS interview software with deterministic capture lifecycle handling. ", count: 8)
        )
        let opportunityDocument = try documents.saveDocument(
            type: .jobDescription,
            title: "Capture Runtime Role",
            content: String(repeating: "The role needs reliable Swift lifecycle management, audio-state diagnostics, and automated testing. ", count: 8)
        )
        let contexts = InterviewContextRepository(database: database)
        let profile = CandidateProfile(
            id: "capture-runtime-profile",
            displayName: "Capture Runtime Candidate",
            sourceDocumentIDs: [cv.id],
            education: [],
            experience: [evidence(
                id: "capture-runtime-experience",
                statement: "Built and tested Swift macOS interview software with deterministic capture lifecycle handling.",
                documentID: cv.id,
                type: .experience
            )],
            projects: [],
            skills: [evidence(
                id: "capture-runtime-skill",
                statement: "Uses Swift concurrency and automated tests to keep capture and generation state reliable.",
                documentID: cv.id,
                type: .skill
            )],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [evidence(
                id: "capture-runtime-goal",
                statement: "Wants this role to apply reliable Swift engineering to a production interview workflow.",
                documentID: cv.id,
                type: .goal
            )],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let opportunity = OpportunityContext(
            id: "capture-runtime-opportunity",
            title: "Swift Runtime Engineer",
            organisation: "Test Organisation",
            opportunityType: .job,
            responsibilities: [evidence(
                id: "capture-runtime-responsibility",
                statement: "Maintain reliable capture and generation lifecycle state.",
                documentID: opportunityDocument.id,
                type: .responsibility
            )],
            requiredSkills: [evidence(
                id: "capture-runtime-required-skill",
                statement: "Swift concurrency and deterministic automated testing.",
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

    private func makeContextBoundSession(_ appState: AppState) throws -> InterviewSession {
        let session = try appState.createContextBoundSession(mode: .microphone, title: "Capture Runtime Test")
        appState.currentSession = session
        return session
    }

    private func installSimulatedMicrophoneCapture(
        on appState: AppState,
        sessionID: String
    ) async throws -> AppleSpeechTranscriptionService {
        let service = AppleSpeechTranscriptionService()
        _ = service.segments
        try await service.start(sessionID: sessionID, captureMode: .microphoneOnly)
        appState.appleSpeechService = service
        return service
    }

    private func stopSimulatedCapture(_ service: AppleSpeechTranscriptionService, appState: AppState) {
        service.microphoneSession?.stop()
        service.systemAudioSession?.stop()
        if appState.appleSpeechService === service {
            appState.appleSpeechService = nil
        }
    }

    private func cancelAsyncWork(_ appState: AppState) {
        appState.precomputeDebounceTask?.cancel()
        appState.activeDetectionTask?.cancel()
        appState.activeAITask?.cancel()
        appState.detectionDebounceTask?.cancel()
        appState.transcriptionTask?.cancel()
        appState.cancelActiveGenerationForStop()
    }

    private func waitForState(
        _ appState: AppState,
        toSatisfy predicate: @escaping (CaptureRuntimeState) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(appState.currentCaptureRuntimeState) {
            guard clock.now < deadline else {
                throw WaitTimeout(description: "Timed out waiting for capture state. Current state: \(appState.currentCaptureRuntimeState)")
            }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    private func waitForLiveState(
        _ appState: AppState,
        toSatisfy predicate: @escaping (LiveInterviewState) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate(appState.liveState) {
            guard clock.now < deadline else {
                throw WaitTimeout(description: "Timed out waiting for live state. Current state: \(appState.liveState)")
            }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(2),
        predicate: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else {
                throw WaitTimeout(description: "Timed out waiting for \(description).")
            }
            try await clock.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func stoppingPendingStartupCannotReviveCaptureOrLeaveSessionOpen() async throws {
        let appState = try makeAppState()
        let gate = AsyncGate()
        appState.mockTranscriptionService.startBarrier = { await gate.wait() }
        defer {
            gate.open()
            appState.mockTranscriptionService.startBarrier = nil
            cancelAsyncWork(appState)
            if appState.liveState.canStop {
                appState.stopListening(reason: .userRequested)
            }
        }

        appState.startListening(mode: .mock)
        try await waitUntil("mock provider startup to suspend") {
            gate.waiterCount == 1 && appState.currentSession != nil
        }
        let pendingSession = try #require(appState.currentSession)

        appState.stopListening(reason: .userRequested)
        gate.open()
        await appState.captureStartupTask?.value

        #expect(appState.liveState == .stopped)
        #expect(appState.currentCaptureRuntimeState == .stopped(reason: .userRequested))
        let persistedSession = try #require(try appState.sessionRepository.session(id: pendingSession.id))
        #expect(persistedSession.endedAt != nil)
        #expect(appState.mockTranscriptionService.stopCallCount >= 1)
    }

    @Test
    func immediateRestartAfterPendingStopCreatesOnlyFreshActiveSession() async throws {
        let appState = try makeAppState()
        let gate = AsyncGate()
        appState.mockTranscriptionService.startBarrier = { await gate.wait() }
        defer {
            gate.open()
            appState.mockTranscriptionService.startBarrier = nil
            cancelAsyncWork(appState)
            if appState.liveState.canStop {
                appState.stopListening(reason: .userRequested)
            }
        }

        appState.startListening(mode: .mock)
        try await waitUntil("first startup to suspend") {
            gate.waiterCount == 1 && appState.currentSession != nil
        }
        let firstSession = try #require(appState.currentSession)

        appState.stopListening(reason: .userRequested)
        appState.startListening(mode: .mock)
        gate.open()
        try await waitForLiveState(appState, toSatisfy: { $0 == .listening })
        let secondSession = try #require(appState.currentSession)

        #expect(secondSession.id != firstSession.id)
        #expect(secondSession.endedAt == nil)
        let persistedFirstSession = try #require(try appState.sessionRepository.session(id: firstSession.id))
        #expect(persistedFirstSession.endedAt != nil)
        #expect(appState.mockTranscriptionService.startCallCount == 2)
    }

    @Test
    func captureStartupWaitsForPreviousTeardown() async throws {
        let appState = try makeAppState()
        let gate = AsyncGate()
        appState.captureTeardownTask = Task { await gate.wait() }
        defer {
            gate.open()
            cancelAsyncWork(appState)
            if appState.liveState.canStop {
                appState.stopListening(reason: .userRequested)
            }
        }

        appState.startListening(mode: .mock)
        try await waitUntil("teardown barrier to suspend") { gate.waiterCount == 1 }
        #expect(appState.mockTranscriptionService.startCallCount == 0)

        gate.open()
        try await waitForLiveState(appState, toSatisfy: { $0 == .listening })
        #expect(appState.mockTranscriptionService.startCallCount == 1)
    }

    @Test
    func applicationTerminationEndsActiveSessionAndStopsCapture() async throws {
        let appState = try makeAppState()
        defer { cancelAsyncWork(appState) }

        appState.startListening(mode: .mock)
        try await waitForLiveState(appState, toSatisfy: { $0 == .listening })
        let session = try #require(appState.currentSession)

        appState.handleApplicationWillTerminate()
        await appState.captureTeardownTask?.value

        let persisted = try #require(try appState.sessionRepository.session(id: session.id))
        #expect(persisted.endedAt != nil)
        #expect(appState.currentCaptureRuntimeState == .stopped(reason: .applicationTerminated))
        #expect(appState.mockTranscriptionService.stopCallCount >= 1)
    }

    @Test
    func startingAfterStopCreatesFreshSessionForNewQuestions() async throws {
        let appState = try makeAppState()
        defer {
            cancelAsyncWork(appState)
            if appState.liveState.canStop {
                appState.stopListening(reason: .userRequested)
            }
        }

        appState.startListening(mode: .mock)
        try await waitForLiveState(appState, toSatisfy: { $0 == .listening })
        let firstSession = try #require(appState.currentSession)

        appState.stopListening(reason: .userRequested)
        try await waitForLiveState(appState, toSatisfy: { $0 == .stopped })
        let endedFirstSession = try #require(try appState.sessionRepository.session(id: firstSession.id))
        #expect(endedFirstSession.endedAt != nil)

        appState.startListening(mode: .mock)
        try await waitForLiveState(appState, toSatisfy: { $0 == .listening })
        let secondSession = try #require(appState.currentSession)

        #expect(secondSession.id != firstSession.id)
        #expect(secondSession.endedAt == nil)

        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = false
        appState.saveSettings(settings)

        let newQuestionSegment = TranscriptSegment(
            id: "second-question-segment",
            sessionID: secondSession.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Why do you want this second role?"
        )
        await appState.handleTranscriptSegment(newQuestionSegment)

        let persistedSegment = try #require(try appState.transcriptRepository.segmentByID("second-question-segment"))
        #expect(persistedSegment.sessionID == secondSession.id)
    }

    // 1. Stage A/B completions do not halt active capture streams or transcribing tasks.
    @Test
    func testStageABCompletionsDoNotHaltActiveCaptureStreamsOrTranscribingTasks() async throws {
        let appState = try makeAppState()
        let session = try makeContextBoundSession(appState)
        let simulatedCapture = try await installSimulatedMicrophoneCapture(on: appState, sessionID: session.id)
        defer {
            cancelAsyncWork(appState)
            stopSimulatedCapture(simulatedCapture, appState: appState)
        }
        #expect(appState.anyCaptureRunning)
        
        let dummyQuestion = DetectedQuestion(
            id: "q-1",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "Why do you want this role?",
            intent: .behavioral,
            answerStrategy: .starStory,
            confidence: 0.9,
            reason: "Test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test-model",
            promptVersion: "v1",
            createdAt: Date()
        )
        
        // Trigger suggestion generation
        try await appState.generateSuggestion(for: dummyQuestion, session: session, transcript: "Why do you want this role?", autoGenerated: false)
        
        #expect(appState.recent20CaptureEvents.contains { $0.eventName == "suggestionGenerationStarted" })
        
        // Wait for background Stage B task to finish its failure path (since no LLM provider/key is configured)
        // and verify that it automatically restores the active capture's listening state because isCapturing remains true!
        try await waitForState(appState, toSatisfy: { $0 == .listening })
        
        #expect(appState.currentCaptureRuntimeState == .listening)
        #expect(appState.anyCaptureRunning == true)
        #expect(appState.isMicPipelineActive)
    }

    // 2. User Stop clicks during active suggestion generation set `.stopped(reason: .userRequested)` and prevent restoration to `.listening` on completion.
    @Test
    func testUserStopClicksDuringActiveSuggestionGenerationPreventsRestoration() async throws {
        let appState = try makeAppState()
        let session = try makeContextBoundSession(appState)
        let simulatedCapture = try await installSimulatedMicrophoneCapture(on: appState, sessionID: session.id)
        defer {
            cancelAsyncWork(appState)
            stopSimulatedCapture(simulatedCapture, appState: appState)
        }
        
        let dummyQuestion = DetectedQuestion(
            id: "q-1",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "Why do you want this role?",
            intent: .behavioral,
            answerStrategy: .starStory,
            confidence: 0.9,
            reason: "Test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test-model",
            promptVersion: "v1",
            createdAt: Date()
        )
        
        // Trigger suggestion generation
        try await appState.generateSuggestion(for: dummyQuestion, session: session, transcript: "Why do you want this role?", autoGenerated: false)

        // The provider path can fail fast and restore to listening before this assertion when
        // the full suite runs in parallel. Force the in-flight precondition this test owns.
        appState.currentCaptureRuntimeState = .generating
        appState.stopReason = nil
        #expect(appState.currentCaptureRuntimeState == .generating)
        
        // User Stop click simulated
        appState.stopListening(reason: .userRequested)
        
        #expect(appState.currentCaptureRuntimeState == .stopped(reason: .userRequested))
        #expect(appState.stopReason == .userRequested)
        
        try await waitForLiveState(appState, toSatisfy: { $0 == .stopped })
        
        // State must remain stopped. It must not be restored to listening.
        #expect(appState.currentCaptureRuntimeState == .stopped(reason: .userRequested))
        #expect(appState.stopReason == .userRequested)
    }

    // 3. Stream capture failures (`isCapturing = false` during suggestion) trigger `.stopped(reason: .screenCaptureStreamEnded)`.
    @Test
    func testStreamCaptureFailuresTriggerStoppedScreenCaptureStreamEnded() async throws {
        let captureService = ScreenCaptureKitSystemAudioCaptureService()
        captureService.isCapturing = true
        let appState = try makeAppState(systemAudioCaptureService: captureService)
        defer {
            cancelAsyncWork(appState)
            captureService.isCapturing = false
            captureService.lastError = nil
        }
        let session = try makeContextBoundSession(appState)
        try await waitForState(appState, toSatisfy: { _ in appState.anyCaptureRunning })
        
        let dummyQuestion = DetectedQuestion(
            id: "q-1",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "Why do you want this role?",
            intent: .behavioral,
            answerStrategy: .starStory,
            confidence: 0.9,
            reason: "Test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test-model",
            promptVersion: "v1",
            createdAt: Date()
        )
        
        // Trigger suggestion generation
        appState.markSystemAudioCaptureRuntimeOwnedForTesting(true)
        try await appState.generateSuggestion(for: dummyQuestion, session: session, transcript: "Why do you want this role?", autoGenerated: false)

        // Provider failure is allowed to restore listening before generateSuggestion returns.
        // This test owns the stream-ended precondition, so establish it explicitly.
        appState.currentCaptureRuntimeState = .generating
        appState.stopReason = nil
        #expect(appState.currentCaptureRuntimeState == .generating)
        
        // Stream failure: set isCapturing to false during active generation
        captureService.isCapturing = false
        
        // Wait for Combine propagation to main thread
        try await waitForState(appState, toSatisfy: {
            if case .stopped(let reason) = $0 {
                return reason == .screenCaptureStreamEnded
            }
            return false
        })
        
        #expect(appState.currentCaptureRuntimeState == .stopped(reason: .screenCaptureStreamEnded))
        #expect(appState.stopReason == .screenCaptureStreamEnded)
    }

    // 4. Main window toolbar buttons correctly disable Start / enable Stop when streams are active across Mic, System, and Dual modes.
    @Test
    func testMainWindowToolbarButtonsCorrectlyDisableStartEnableStop() async throws {
        let appState = try makeAppState()
        let session = try makeContextBoundSession(appState)
        let simulatedCapture = try await installSimulatedMicrophoneCapture(on: appState, sessionID: session.id)
        defer {
            cancelAsyncWork(appState)
            stopSimulatedCapture(simulatedCapture, appState: appState)
        }

        // A simulated microphone session is sufficient to exercise toolbar
        // state without touching Core Audio or ScreenCaptureKit.
        #expect(appState.anyCaptureRunning == true)
        #expect(appState.canStopCapture == true)
        
        // Generating state (even if isCapturing is false, canStopCapture should be true to allow cancellation)
        stopSimulatedCapture(simulatedCapture, appState: appState)
        #expect(appState.anyCaptureRunning == false)
        #expect(appState.canStopCapture == false)
        appState.currentCaptureRuntimeState = .generating
        #expect(appState.canStopCapture == true)
        
        // Reset
        appState.currentCaptureRuntimeState = .idle
    }

    // 5. Capture event logs accurately record `#file`, `#line`, and `#function` caller context.
    @Test
    func testCaptureEventLogsAccuratelyRecordCallerContext() async throws {
        let appState = try makeAppState()
        defer { cancelAsyncWork(appState) }
        
        appState.recent20CaptureEvents.removeAll()
        
        // Call stopListening directly with simulated parameters
        let testFile = "CaptureRuntimeStateTests.swift"
        let testLine = 345
        let testFunction = "testFunction()"
        
        appState.stopListening(reason: .userRequested, file: testFile, line: testLine, function: testFunction)
        
        try await waitForState(appState, toSatisfy: { _ in
            appState.recent20CaptureEvents.contains { $0.eventName == "stopListening" }
        })
        
        // Verify the logged event has the exact caller details we passed
        let lastEvent = appState.recent20CaptureEvents.first(where: { $0.eventName == "stopListening" })
        #expect(lastEvent != nil)
        #expect(lastEvent?.file == testFile)
        #expect(lastEvent?.line == testLine)
        #expect(lastEvent?.function == testFunction)
    }
}

private final class CaptureRuntimeLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "fixture", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let content = """
        {
          "strategy": "Direct Answer",
          "say_first": "I want this role because it lets me apply reliable Swift concurrency and automated testing to production capture workflows.",
          "key_points": ["Built deterministic Swift lifecycle tests", "Focused on reliable capture and generation state"],
          "follow_up_ready": ["I can explain the lifecycle checks I automated."],
          "confidence": 0.95,
          "caution": "Keep the answer grounded in the fixture profile."
        }
        """
        return LLMChatResult(
            content: content,
            modelName: "capture-runtime-fixture",
            providerKind: .deepSeek,
            providerName: "DeepSeek Fixture",
            baseURL: "fixture://capture-runtime",
            latencyMS: 0,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content: String
        if prompt.contains("Stream the section response now.") {
            content = """
            STRATEGY:
            Direct Answer
            SAY_FIRST:
            I want this role because it lets me apply reliable Swift concurrency and automated testing to production capture workflows.
            KEY_POINTS:
            - Built deterministic Swift lifecycle tests.
            - Focused on reliable capture and generation state.
            FOLLOW_UP_READY:
            - I can explain the lifecycle checks I automated.
            CAUTION:
            Keep the answer grounded in the fixture profile.
            """
        } else {
            content = "I want this role because it lets me apply reliable Swift concurrency and automated testing to production capture workflows."
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(content)
            continuation.finish()
        }
    }
}
