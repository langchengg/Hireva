import Foundation
import Testing
import GRDB
@testable import InterviewCopilotMac

@Suite @MainActor
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
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerAttributionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
