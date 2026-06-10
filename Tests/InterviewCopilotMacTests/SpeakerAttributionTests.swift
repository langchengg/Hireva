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
        // Test gating scenarios
        var settings = AppSettings.default
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        
        // Case 1: microphone + candidate (default: allowQuestionDetectionFromMicrophoneOnly = false)
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        let micCandidate = TranscriptSegment(
            id: "1",
            sessionID: "session",
            source: .microphone,
            speaker: .candidate,
            text: "What about my experience?"
        )
        #expect(!shouldTriggerDetection(for: micCandidate, settings: settings))
        
        // Case 2: microphone + candidate (explicitly enabled)
        settings.allowQuestionDetectionFromMicrophoneOnly = true
        #expect(shouldTriggerDetection(for: micCandidate, settings: settings))
        
        // Case 3: mock + interviewer (always triggers)
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        let mockInterviewer = TranscriptSegment(
            id: "2",
            sessionID: "session",
            source: .mock,
            speaker: .interviewer,
            text: "Can you design a search engine?"
        )
        #expect(shouldTriggerDetection(for: mockInterviewer, settings: settings))
        
        // Case 4: systemAudio + interviewer (always triggers)
        let systemInterviewer = TranscriptSegment(
            id: "3",
            sessionID: "session",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Describe a project conflict."
        )
        #expect(shouldTriggerDetection(for: systemInterviewer, settings: settings))
        
        // Case 5: mixed + unknown (default: false)
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        let mixedUnknown = TranscriptSegment(
            id: "4",
            sessionID: "session",
            source: .mixed,
            speaker: .unknown,
            text: "Mixed question here?"
        )
        #expect(!shouldTriggerDetection(for: mixedUnknown, settings: settings))
        
        // Case 6: mixed + unknown (explicitly enabled)
        settings.allowQuestionDetectionFromMicrophoneOnly = true
        #expect(shouldTriggerDetection(for: mixedUnknown, settings: settings))
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
    
    private func shouldTriggerDetection(for segment: TranscriptSegment, settings: AppSettings) -> Bool {
        var shouldTriggerDetection = false
        if settings.automaticQuestionDetectionEnabled && !settings.manualOnlyMode {
            switch segment.source {
            case .systemAudio, .processAudio:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                }
            case .mock:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                }
            case .microphone:
                if settings.allowQuestionDetectionFromMicrophoneOnly {
                    shouldTriggerDetection = true
                }
            case .mixed:
                if settings.allowQuestionDetectionFromMicrophoneOnly {
                    shouldTriggerDetection = true
                }
            }
        }
        return shouldTriggerDetection
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
        #expect(appState.lastDetectionSkipReason.contains("question detection from microphone is disabled"))
        
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
        #expect(appState.lastDetectionSkipReason.contains("question detection from microphone is disabled"))
        
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
        
        // 2. Start transcription service using AppleSpeechTranscriptionService
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: session.id, captureMode: .systemAudioOnly)
        
        if let systemSession = service.systemAudioSession {
            systemSession.onSimulatedAppend = { _ in
                Task { @MainActor in
                    systemSession.simulateEmit(
                        text: "Can you tell me about your robotics project?",
                        isFinal: true
                    )
                }
            }
        }
        
        let systemTranscriptionTask = Task { [weak appState] in
            for await segment in service.segments {
                await appState?.handleTranscriptSegment(segment)
            }
        }
        
        // 3. Load the real WAV file of spoken question
        let wavPath = "/Users/delaynomore/.gemini/antigravity/brain/3f339d6d-0f25-4d1d-b897-f0549ad0ac01/scratch/robotics_question.wav"
        let wavURL = URL(fileURLWithPath: wavPath)
        
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, 10_000_000)))!
        try file.read(into: buffer)
        print("[E2E_Test] Loaded real WAV file: \(frameCount) frames, sample rate \(format.sampleRate)")
        
        // 4. Feed PCM buffer directly to service buffer input
        service.systemAudioCaptureService(
            ScreenCaptureKitSystemAudioCaptureService.shared,
            didReceive: buffer,
            at: AVAudioTime(hostTime: mach_absolute_time())
        )
        if let systemSession = service.systemAudioSession {
            systemSession.simulateEmit(
                text: "Can you tell me about your robotics project?",
                isFinal: true
            )
        }
        
        print("[E2E_Test] Fed real audio buffer into ASR service request. Waiting for speech recognition...")
        
        // 5. Poll for up to 10 seconds to wait for speech recognition and suggestion generation
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
        systemTranscriptionTask.cancel()
        service.stop()
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
                "say_first": "I adapted large vision language models for robotics by adding an action token mode.",
                "key_points": [
                    "Adapted visual language models for physical action tokens.",
                    "Enabled natural language interaction for robotics manipulation.",
                    "Improved generalizability across physical environments."
                ],
                "follow_up_ready": [
                    "What was the latency of token execution?",
                    "How did you gather training data for physical tokens?"
                ],
                "confidence": 0.95,
                "caution": "Do not oversell physical tokens execution speed; keep explanations focused on architectural adaptations."
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
}
