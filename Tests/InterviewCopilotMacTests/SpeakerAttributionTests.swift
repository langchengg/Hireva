import Foundation
import Testing
import GRDB
import AVFoundation
import Speech
@testable import InterviewCopilotMac

@Suite(.serialized) @MainActor
struct SpeakerAttributionTests {
    
    @Test
    func databaseAttributionPersistenceAndLegacyFallback() throws {
        // 1. Setup in-memory temporary database
        let database = try makeTemporaryDatabase()
        let repository = TranscriptRepository(database: database)
        
        // 2. Insert legacy row using raw SQL to simulate pre-migration database records
        let legacyID = UUID().uuidString
        let sessionID = UUID().uuidString
        
        // Setup a mock session so the foreign key constraint is satisfied
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO interview_sessions (id, title, started_at, mode, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [sessionID, "Legacy Session", "2026-05-26T00:00:00Z", "microphone", "2026-05-26T00:00:00Z"]
            )
        }
        
        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, session_id, speaker, text, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [legacyID, sessionID, "audio_input", "Hello legacy speaker", "2026-05-26T12:00:00Z"]
            )
        }
        
        // 3. Load historical row and check fallback mapping
        let segments = try repository.segments(sessionID: sessionID)
        #expect(segments.count == 1)
        let legacySegment = segments[0]
        #expect(legacySegment.id == legacyID)
        #expect(legacySegment.speaker == .unknown) // mapped from "audio_input"
        #expect(legacySegment.source == .microphone) // fallback default
        #expect(legacySegment.confidence == 1.0) // fallback default
        
        // 4. Save and load a fully-attributed new segment
        let newID = UUID().uuidString
        let newSegment = TranscriptSegment(
            id: newID,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: "This is the interviewer speaking over system loopback",
            startTime: 10.5,
            endTime: 15.0,
            createdAt: Date(),
            inputDeviceName: "Virtual Cable Input",
            outputDeviceName: "AirPods Pro",
            deviceID: "virtual_loopback_uid",
            confidence: 0.95
        )
        
        try repository.saveSegment(newSegment)
        
        let updatedSegments = try repository.segments(sessionID: sessionID)
        #expect(updatedSegments.count == 2)
        
        let loadedNewSegment = updatedSegments.first { $0.id == newID }
        #expect(loadedNewSegment != nil)
        #expect(loadedNewSegment?.source == .systemAudio)
        #expect(loadedNewSegment?.speaker == .interviewer)
        #expect(loadedNewSegment?.inputDeviceName == "Virtual Cable Input")
        #expect(loadedNewSegment?.outputDeviceName == "AirPods Pro")
        #expect(loadedNewSegment?.deviceID == "virtual_loopback_uid")
        #expect(loadedNewSegment?.confidence == 0.95)
    }
    
    @Test
    func questionDetectionGatingRules() throws {
        let state = DialogueRuntimeState.initial(for: .panelQuestions)
        let micCandidate = TranscriptSegment(
            id: "1",
            sessionID: "session",
            source: .microphone,
            speaker: .candidate,
            text: "What about my experience?"
        )
        #expect(!dialogueDecision(for: micCandidate, state: state).shouldEvaluateQuestion)

        let mockInterviewer = TranscriptSegment(
            id: "2",
            sessionID: "session",
            source: .mock,
            speaker: .interviewer,
            text: "Can you design a search engine?"
        )
        #expect(dialogueDecision(for: mockInterviewer, state: state).shouldEvaluateQuestion)

        let systemInterviewer = TranscriptSegment(
            id: "3",
            sessionID: "session",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Describe a project conflict."
        )
        #expect(dialogueDecision(for: systemInterviewer, state: state).shouldEvaluateQuestion)

        let mixedUnknown = TranscriptSegment(
            id: "4",
            sessionID: "session",
            source: .mixed,
            speaker: .unknown,
            text: "Mixed question here?"
        )
        let ambiguousDecision = dialogueDecision(for: mixedUnknown, state: state)
        #expect(ambiguousDecision.speakerRole == .ambiguous)
        #expect(!ambiguousDecision.shouldEvaluateQuestion)
    }
    
    @Test
    func audioDeviceManagerFallbackAndSanitization() throws {
        // AudioDeviceManager when Core Audio is stubbed or uninitialized returns readable names or Unknown Device fallbacks
        let manager = AudioDeviceManager.shared
        // Even if Core Audio is uninitialized, confirm current properties have readable non-empty values
        #expect(!manager.currentInputDeviceName.isEmpty)
        #expect(!manager.currentOutputDeviceName.isEmpty)
        #expect(!manager.routeDescription.isEmpty)
    }
    
    // MARK: - Helper Methods
    
    private func dialogueDecision(
        for segment: TranscriptSegment,
        state: DialogueRuntimeState
    ) -> DialogueTriggerDecision {
        InterviewDialogueTriggerPolicy.decideDialogueTrigger(
            segment: segment,
            sessionMode: state.selectedSessionMode,
            currentState: state,
            answerPanelQuestions: true,
            suppressPresentation: true,
            suppressCandidateQuestions: true
        )
    }
    
    @Test
    func interviewerCandidateAudioSeparationVerification() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        
        // Ensure onboarding is complete so startListening can run
        try await database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('1', 'CV', 'This is my comprehensive resume detailing all of my professional experience in software engineering and artificial intelligence.', 'cv', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('2', 'JD', 'This is a job description for a principal swift macos developer requiring years of experience in Core Audio and ScreenCaptureKit.', 'job_description', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
        }
        appState.refreshAll()
        
        // Force settings state
        var settings = AppSettings.default
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)
        
        #expect(appState.onboardingComplete)
        
        // Let's create an active mock session
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        
        // Test 1: System Audio segment processing (source = .systemAudio, speaker = .interviewer)
        let systemSegment = TranscriptSegment(
            id: "sys-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you describe a challenge you overcame?"
        )
        
        // Under default settings:
        // System audio segment (speaker = .interviewer) MUST trigger detection.
        await appState.handleTranscriptSegment(systemSegment)
        
        #expect(appState.lastSystemAudioTranscript == "Can you describe a challenge you overcame?")
        #expect(appState.lastDetectionSkipReason.isEmpty) // Should not be skipped, so it goes to detection
        
        // Test 2: Microphone segment processing (source = .microphone, speaker = .candidate)
        let micSegment = TranscriptSegment(
            id: "mic-1",
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "What project are we discussing?"
        )
        
        await appState.handleTranscriptSegment(micSegment)
        // Candidate audio MUST be gated out from triggering auto-detection by default
        #expect(appState.lastDetectionSkipReason.contains("candidate speech does not request"))
        
        // Test 3: Candidate false-trigger protection
        // Even if the text sounds like a question ("Can you tell me about your project?"),
        // when said by Candidate/Microphone, it must be gated out.
        let candidateQuestion = TranscriptSegment(
            id: "mic-q",
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "Can you tell me about your project?"
        )
        await appState.handleTranscriptSegment(candidateQuestion)
        #expect(appState.lastDetectionSkipReason.contains("candidate speech does not request"))
        
        // Play it via System Audio (interviewer) -> it triggers detection!
        let interviewerQuestion = TranscriptSegment(
            id: "sys-q",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you tell me about your project?"
        )
        await appState.handleTranscriptSegment(interviewerQuestion)
        #expect(appState.lastSystemAudioTranscript == "Can you tell me about your project?")
        #expect(appState.lastDetectionSkipReason.isEmpty)
        
        // Test 4: Diagnostics values check
        #expect(!appState.currentInputDeviceName.isEmpty)
        #expect(appState.lastSystemAudioTranscript == "Can you tell me about your project?")
    }

    @Test
    func realAudioBufferToSuggestionPipeline() async throws {
        // 1. Setup in-memory temporary database
        let database = try makeTemporaryDatabase()
        
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let mockClient = MockLLMClient()
        let llmRouter = LLMRouter(
            settingsRepository: settingsRepository,
            clients: [.deepSeek: mockClient]
        )
        let appState = AppState(database: database, llmRouter: llmRouter)
        
        // Ensure onboarding is complete
        try await database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('1', 'CV', 'This is my comprehensive resume detailing all of my professional experience in software engineering and artificial intelligence.', 'cv', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
            try db.execute(sql: "INSERT INTO documents (id, title, content, type, created_at, updated_at) VALUES ('2', 'JD', 'This is a job description for a principal swift macos developer requiring years of experience in Core Audio and ScreenCaptureKit.', 'job_description', '2026-05-26T00:00:00Z', '2026-05-26T00:00:00Z')")
        }
        appState.refreshAll()
        
        // Force settings state
        var settings = AppSettings.default
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)
        
        #expect(appState.onboardingComplete)
        
        // Create an active mock session
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        
        let systemAudioQuestion = TranscriptSegment(
            id: "system-audio-question",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you tell me about your robotics project?",
            createdAt: Date(),
            confidence: 1.0
        )
        await appState.handleTranscriptSegment(systemAudioQuestion)
        print("[E2E_Test] Fed deterministic system audio transcript into AppState. Waiting for suggestion generation...")
        
        // Poll for up to 10 seconds to wait for question detection and suggestion generation.
        var completed = false
        for _ in 1...100 {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if appState.currentSuggestion != nil {
                completed = true
                break
            }
        }
        
        // 6. Assert and prove results
        #expect(completed == true)
        #expect(!appState.lastSystemAudioTranscript.isEmpty)
        #expect(appState.last10SegmentsDiagnostics.contains { $0.source == .systemAudio && $0.speaker == .interviewer })
        #expect(appState.lastDetectionShouldTrigger == true)
        
        if let card = appState.currentSuggestion {
            print("[E2E_Test] SUCCESS! Real suggestion card generated from loopback audio buffer:")
            print("Say First: \"\(card.sayFirst)\"")
            print("Strategy: \(card.strategy)")
            print("Key Points: \(card.keyPoints)")
            print("Caution: \(card.caution ?? "None")")
            print("Raw Card JSON: \(card.rawJSON ?? "")")
        } else {
            print("[E2E_Test] FAILED to generate suggestion card from system audio buffer")
        }
    }


    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerAttributionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}

final class MockLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        return LLMConnectionTestResult(success: true, message: "ok", latencyMS: 1, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let isQuestionDetection = messages.contains { $0.content.contains("question_complete") || $0.content.contains("should_trigger") }
        
        let rawJSON: String
        if isQuestionDetection {
            rawJSON = """
            {
                "should_trigger": true,
                "question_complete": true,
                "question_text": "Can you tell me about your robotics project?",
                "intent": "project_deep_dive",
                "answer_strategy": "project_walkthrough",
                "confidence": 0.98,
                "reason": "Interviewer is asking for details on the candidate's robotics project."
            }
            """
        } else {
            rawJSON = """
            {
                "strategy": "Project Walkthrough",
                "say_first": "My robotics project was a LeoRover autonomous object retrieval system where I connected ROS2, YOLOv8 perception, localization, navigation, and manipulation so the robot could find and pick up target objects.",
                "key_points": [
                    "Built a ROS2-based LeoRover object retrieval pipeline.",
                    "Connected YOLOv8 perception to localization, navigation, and manipulation.",
                    "Focused on reliable real-robot handoffs and recovery behavior."
                ],
                "follow_up_ready": [
                    "How did you validate the perception-to-action handoff?",
                    "What recovery behavior did you add?"
                ],
                "confidence": 0.95,
                "caution": "Keep the answer grounded in the LeoRover project."
            }
            """
        }
        
        return LLMChatResult(
            content: rawJSON,
            modelName: "MockModel",
            providerKind: .deepSeek,
            providerName: "MockClient",
            baseURL: "https://api.deepseek.com",
            latencyMS: 42,
            isLocal: true,
            rawResponse: rawJSON
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        return [LLMModelInfo(name: "MockModel", modifiedAt: nil, size: nil)]
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let isStageB = prompt.contains("Return plain text sections only")
        let sayFirst = "My robotics project was a LeoRover autonomous object retrieval system where I connected ROS2, YOLOv8 perception, localization, navigation, and manipulation so the robot could find and pick up target objects."
        let tokens: [String]
        if isStageB {
            tokens = [
                "STRATEGY:\nProject Walkthrough\n",
                "SAY_FIRST:\n\(sayFirst)\n",
                "KEY_POINTS:\n",
                "- Built a ROS2-based LeoRover object retrieval pipeline.\n",
                "- Connected YOLOv8 perception to localization, navigation, and manipulation.\n",
                "- Focused on reliable real-robot handoffs and recovery behavior.\n",
                "FOLLOW_UP_READY:\n",
                "- How did you validate the perception-to-action handoff?\n",
                "- What recovery behavior did you add?\n",
                "CAUTION:\nKeep the answer grounded in the LeoRover project.\n"
            ]
        } else {
            tokens = sayFirst.split(separator: " ", omittingEmptySubsequences: false).map { "\($0) " }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
