import Foundation
import Testing
import AVFoundation
@testable import InterviewCopilotMac

@Suite
struct DualAudioTranscriptionTests {
    
    @Test
    func microphoneAndSystemCreatesTwoIndependentSessionInstances() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        #expect(service.microphoneSession != nil)
        #expect(service.systemAudioSession != nil)
        #expect(service.microphoneSession !== service.systemAudioSession)
        
        service.stop()
    }
    
    @Test
    func micAndSystemRecognitionRequestIdentitiesAreDistinct() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        let micRequest = try #require(service.microphoneSession?.request)
        let systemRequest = try #require(service.systemAudioSession?.request)
        
        #expect(micRequest !== systemRequest)
        
        service.stop()
    }
    
    @Test
    func micBufferAppendIncrementsOnlyMicCount() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        service.audioEngineManager(AudioEngineManager.shared, didReceive: buffer, at: AVAudioTime(hostTime: 0))
        
        #expect(service.microphoneSession?.totalBuffersAppended == 1)
        #expect(service.systemAudioSession?.totalBuffersAppended == 0)
        
        service.stop()
    }
    
    @Test
    func systemBufferAppendIncrementsOnlySystemCount() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        service.systemAudioCaptureService(ScreenCaptureKitSystemAudioCaptureService.shared, didReceive: buffer, at: AVAudioTime(hostTime: 0))
        
        #expect(service.systemAudioSession?.totalBuffersAppended == 1)
        #expect(service.microphoneSession?.totalBuffersAppended == 0)
        
        service.stop()
    }
    
    @Test
    func micFirstThenSystemStillProducesBothTranscripts() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        
        var segmentsCollected: [TranscriptSegment] = []
        
        let collectorTask = Task {
            for await segment in service.segments {
                segmentsCollected.append(segment)
                if segmentsCollected.count >= 2 {
                    break
                }
            }
        }
        
        // Speak mic first
        await micSession.simulateEmit(text: "Hello from Microphone", isFinal: true)
        // Speak system second
        await systemSession.simulateEmit(text: "Hello from System Audio", isFinal: true)
        
        _ = await collectorTask.result
        
        #expect(segmentsCollected.count == 2)
        #expect(segmentsCollected[0].source == .microphone)
        #expect(segmentsCollected[0].speaker == .candidate)
        #expect(segmentsCollected[0].text == "Hello from Microphone")
        
        #expect(segmentsCollected[1].source == .systemAudio)
        #expect(segmentsCollected[1].speaker == .interviewer)
        #expect(segmentsCollected[1].text == "Hello from System Audio")
        
        service.stop()
    }
    
    @Test
    func systemFirstThenMicStillProducesBothTranscripts() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneAndSystem)
        
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        
        var segmentsCollected: [TranscriptSegment] = []
        
        let collectorTask = Task {
            for await segment in service.segments {
                segmentsCollected.append(segment)
                if segmentsCollected.count >= 2 {
                    break
                }
            }
        }
        
        // Speak system first
        await systemSession.simulateEmit(text: "Hello from System Audio", isFinal: true)
        // Speak mic second
        await micSession.simulateEmit(text: "Hello from Microphone", isFinal: true)
        
        _ = await collectorTask.result
        
        #expect(segmentsCollected.count == 2)
        #expect(segmentsCollected[0].source == .systemAudio)
        #expect(segmentsCollected[0].speaker == .interviewer)
        #expect(segmentsCollected[0].text == "Hello from System Audio")
        
        #expect(segmentsCollected[1].source == .microphone)
        #expect(segmentsCollected[1].speaker == .candidate)
        #expect(segmentsCollected[1].text == "Hello from Microphone")
        
        service.stop()
    }
    
    @Test
    @MainActor
    func gatingRulesVerifyMicDoesNotAutoTriggerButSystemDoes() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        
        // Enable auto question detection in settings
        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.manualOnlyMode = false
        appState.settings = settings
        
        // 1. Microphone Candidate Segment
        let micSegment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: "test_session_id",
            source: .microphone,
            speaker: .candidate,
            text: "Hello this is a microphone test response from candidate."
        )
        
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(micSegment)
        
        let micDiag = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(!micDiag.eligibleForAutoDetection)
        #expect(micDiag.skipReason.contains("allowQuestionDetectionFromMicrophoneOnly = false") || micDiag.skipReason.contains("speaker is candidate"))
        
        // 2. System Audio Interviewer Segment
        let sysSegment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: "test_session_id",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you describe your robotics projects?"
        )
        
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(sysSegment)
        
        let sysDiag = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(sysDiag.eligibleForAutoDetection)
    }
    
    @Test
    @MainActor
    func manualCaptureStillWorksAfterRefactor() async throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        
        // Verify default status of ASR continuous manager is nil
        #expect(appState.isMicPipelineActive == false)
        #expect(appState.isSystemAudioASRActive == false)
        
        // Set manual capture mode
        var settings = appState.settings
        settings.manualOnlyMode = true
        appState.settings = settings
        
        // Start listening
        appState.startListening(mode: .microphone)
        
        // Continuous session manager should NOT be active in manual capture
        #expect(appState.isMicPipelineActive == false)
        #expect(appState.isSystemAudioASRActive == false)
        
        appState.stopListening()
    }
    
    @Test
    func longPartialWithShortFinalASRQualityLogic() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneOnly)
        
        let micSession = try #require(service.microphoneSession)
        
        var segmentsCollected: [TranscriptSegment] = []
        let collectorTask = Task {
            for await segment in service.segments {
                segmentsCollected.append(segment)
                if segmentsCollected.count >= 2 {
                    break
                }
            }
        }
        
        // 1. Emit a long, complete partial
        await micSession.simulateEmit(text: "This is my complete candidate answer regarding robotics experience", isFinal: false)
        
        // 2. Emit a short final pass (less than 50% words)
        await micSession.simulateEmit(text: "Take", isFinal: true)
        
        // Stop service to complete AsyncStream
        service.stop()
        _ = await collectorTask.result
        
        #expect(micSession.lastPartialTranscript == "This is my complete candidate answer regarding robotics experience")
        #expect(micSession.lastFinalTranscript == "Take")
        #expect(micSession.bestTranscriptUsed == "This is my complete candidate answer regarding robotics experience")
        #expect(micSession.finalizationReason == "final much shorter than recent partial")
        
        // Assert that the final segment was finalized using the partial transcript
        #expect(segmentsCollected.last?.text == "This is my complete candidate answer regarding robotics experience")
    }
    
    @Test
    func emptyFinalWithMeaningfulPartialQualityLogic() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneOnly)
        
        let micSession = try #require(service.microphoneSession)
        
        var segmentsCollected: [TranscriptSegment] = []
        let collectorTask = Task {
            for await segment in service.segments {
                segmentsCollected.append(segment)
                if segmentsCollected.count >= 2 {
                    break
                }
            }
        }
        
        // 1. Emit a meaningful partial
        await micSession.simulateEmit(text: "Robotics and VLA policies", isFinal: false)
        
        // 2. Emit an empty final pass
        await micSession.simulateEmit(text: "", isFinal: true)
        
        service.stop()
        _ = await collectorTask.result
        
        #expect(micSession.lastPartialTranscript == "Robotics and VLA policies")
        #expect(micSession.lastFinalTranscript == "")
        #expect(micSession.bestTranscriptUsed == "Robotics and VLA policies")
        #expect(micSession.finalizationReason == "final empty but partial meaningful")
        
        #expect(segmentsCollected.last?.text == "Robotics and VLA policies")
    }
    
    @Test
    func goodFinalUsesFinalQualityLogic() async throws {
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: "test_session_id", captureMode: .microphoneOnly)
        
        let micSession = try #require(service.microphoneSession)
        
        var segmentsCollected: [TranscriptSegment] = []
        let collectorTask = Task {
            for await segment in service.segments {
                segmentsCollected.append(segment)
                if segmentsCollected.count >= 2 {
                    break
                }
            }
        }
        
        // 1. Emit partial
        await micSession.simulateEmit(text: "This is a good candidate", isFinal: false)
        
        // 2. Emit a good final (similar or longer)
        await micSession.simulateEmit(text: "This is a good candidate answer.", isFinal: true)
        
        service.stop()
        _ = await collectorTask.result
        
        #expect(micSession.lastPartialTranscript == "This is a good candidate")
        #expect(micSession.lastFinalTranscript == "This is a good candidate answer.")
        #expect(micSession.bestTranscriptUsed == "This is a good candidate answer.")
        #expect(micSession.finalizationReason == "final is longer or similar")
        
        #expect(segmentsCollected.last?.text == "This is a good candidate answer.")
    }
    
    @Test
    func realRuntimeASRQualityAndDatabaseVerification() async throws {
        guard TestSupport.realAppDatabaseTestsEnabled else {
            print("Skipping realRuntimeASRQualityAndDatabaseVerification: set REAL_APP_DB_TESTS=1 to allow real app database access.")
            return
        }

        print("=== STARTING REAL RUNTIME ASR QUALITY VERIFICATION ===")
        
        // 1. Initialize real AppDatabase and repositories using AppPaths.databaseURL
        let db = try AppDatabase(path: AppPaths.databaseURL)
        let sessionRepo = SessionRepository(database: db)
        let transcriptRepo = TranscriptRepository(database: db)
        
        // 2. Create a clean test interview session (mode: .microphone)
        let testSession = try sessionRepo.createSession(mode: .microphone, title: "ASR Quality Real Runtime verification")
        print("Created real test session in database: \(testSession.id)")
        
        // 3. Set up the unified AppleSpeechTranscriptionService
        let service = AppleSpeechTranscriptionService()
        try await service.start(sessionID: testSession.id, captureMode: AudioCaptureMode.microphoneAndSystem)
        
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        
        // Enable simulation hooks
        micSession.simulatedTaskActive = true
        systemSession.simulatedTaskActive = true
        
        var segmentsCollected: [TranscriptSegment] = []
        let collectorTask = Task {
            for await segment in service.segments {
                print("[VerificationStream] Yielded segment: id = \(segment.id) | source = \(segment.source.rawValue) | speaker = \(segment.speaker.rawValue) | text = \"\(segment.text)\"")
                segmentsCollected.append(segment)
                try? transcriptRepo.saveSegment(segment)
            }
        }
        
        // Test 1: Truncated final on Microphone (e.g. "Take")
        print("\n--- Test A: Truncated Final (Mic speaks first) ---")
        await micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: false)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay
        await micSession.simulateEmit(text: "Take", isFinal: true)
        
        print("Mic Diagnostics (Truncated Final):")
        print(" - Quality Last Partial: \"\(micSession.lastPartialTranscript)\"")
        print(" - Quality Last Final:   \"\(micSession.lastFinalTranscript)\"")
        print(" - Best Transcript Used: \"\(micSession.bestTranscriptUsed)\"")
        print(" - Finalization Reason:  \"\(micSession.finalizationReason)\"")
        
        #expect(micSession.bestTranscriptUsed == "This is my candidate answer about my robotics project")
        #expect(micSession.finalizationReason == "final much shorter than recent partial")
        
        // Test 2: Empty final with meaningful partial on Microphone
        print("\n--- Test B: Empty Final (Mic) ---")
        await micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await micSession.simulateEmit(text: "", isFinal: true)
        
        print("Mic Diagnostics (Empty Final):")
        print(" - Quality Last Partial: \"\(micSession.lastPartialTranscript)\"")
        print(" - Quality Last Final:   \"\(micSession.lastFinalTranscript)\"")
        print(" - Best Transcript Used: \"\(micSession.bestTranscriptUsed)\"")
        print(" - Finalization Reason:  \"\(micSession.finalizationReason)\"")
        
        #expect(micSession.bestTranscriptUsed == "This is my candidate answer about my robotics project")
        #expect(micSession.finalizationReason == "final empty but partial meaningful")

        // Test 3: Good final on Microphone
        print("\n--- Test C: Good Final (Mic) ---")
        await micSession.simulateEmit(text: "This is my candidate answer", isFinal: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: true)
        
        print("Mic Diagnostics (Good Final):")
        print(" - Quality Last Partial: \"\(micSession.lastPartialTranscript)\"")
        print(" - Quality Last Final:   \"\(micSession.lastFinalTranscript)\"")
        print(" - Best Transcript Used: \"\(micSession.bestTranscriptUsed)\"")
        print(" - Finalization Reason:  \"\(micSession.finalizationReason)\"")
        
        #expect(micSession.bestTranscriptUsed == "This is my candidate answer about my robotics project")
        #expect(micSession.finalizationReason == "final is longer or similar")
        
        // Test 4: Concurrent System Audio stream segment (proves no shared state)
        print("\n--- Test D: Concurrent System Audio Stream (System speaks first) ---")
        await systemSession.simulateEmit(text: "Can you tell me about your robotics project?", isFinal: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        await systemSession.simulateEmit(text: "Can you tell me about your robotics project?", isFinal: true)
        
        print("System Diagnostics:")
        print(" - Quality Last Partial: \"\(systemSession.lastPartialTranscript)\"")
        print(" - Quality Last Final:   \"\(systemSession.lastFinalTranscript)\"")
        print(" - Best Transcript Used: \"\(systemSession.bestTranscriptUsed)\"")
        print(" - Finalization Reason:  \"\(systemSession.finalizationReason)\"")
        
        #expect(systemSession.bestTranscriptUsed == "Can you tell me about your robotics project?")
        
        // Stop service to finish
        service.stop()
        collectorTask.cancel()
        
        // Verify database segments
        let savedSegments = try transcriptRepo.segments(sessionID: testSession.id)
        print("\n--- DB Verification: Stored transcript segments for session \(testSession.id) ---")
        for segment in savedSegments {
            print("DB Row -> id: \(segment.id) | speaker: \(segment.speaker.rawValue) | source: \(segment.source.rawValue) | text: \"\(segment.text)\"")
        }
        
        // Assertions for DB properties:
        // 1. Assert no duplicate rows for the same segment ID (utteranceID)
        let segmentIDs = savedSegments.map { $0.id }
        #expect(segmentIDs.count == Set(segmentIDs).count, "Database contains duplicate transcript segment rows for the same utterance ID!")
        
        // 2. Assert microphone/candidate transcript is complete (uses best transcript)
        let micFinals = savedSegments.filter { $0.source == AudioSourceType.microphone }
        #expect(micFinals.contains { $0.text == "This is my candidate answer about my robotics project" })
        
        // 3. Assert systemAudio/interviewer transcript is complete
        let systemFinals = savedSegments.filter { $0.source == AudioSourceType.systemAudio }
        #expect(systemFinals.contains { $0.text == "Can you tell me about your robotics project?" })
        
        print("\n=== REAL RUNTIME VERIFICATION SUCCEEDED ===")
    }

    // Helper to create a temp in-memory SQLite DB for tests
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
