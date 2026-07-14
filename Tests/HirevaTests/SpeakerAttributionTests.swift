import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct SpeakerAttributionTests {
    private struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    private final class MockPermissionService: PermissionService {
        override func checkMicrophonePermission() -> MicrophonePermissionState { .authorized }

        override func snapshot() -> PermissionSnapshot {
            PermissionSnapshot(
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                systemAudioCapture: .granted
            )
        }

        override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerAttributionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeAppState(database: AppDatabase) throws -> AppState {
        try prepareReadyContext(in: database)
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        if let deepSeek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settings.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let appState = AppState(
            database: database,
            llmRouter: LLMRouter(
                settingsRepository: settings,
                clients: [.deepSeek: SpeakerAttributionLLMClient()]
            ),
            permissionService: MockPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
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
            title: "Speaker Attribution Candidate",
            content: String(repeating: "Built a LeoRover object retrieval system using ROS2, YOLOv8, localization, navigation, and manipulation. ", count: 8)
        )
        let role = try documents.saveDocument(
            type: .jobDescription,
            title: "Robotics Software Role",
            content: String(repeating: "The role requires ROS2 robotics integration, perception, localization, navigation, manipulation, and reliable testing. ", count: 8)
        )
        let contexts = InterviewContextRepository(database: database)
        let profile = CandidateProfile(
            id: "speaker-attribution-profile",
            displayName: "Speaker Attribution Candidate",
            sourceDocumentIDs: [cv.id],
            education: [],
            experience: [],
            projects: [evidence(
                id: "speaker-attribution-project",
                statement: "Built a LeoRover autonomous object retrieval system connecting ROS2, YOLOv8 perception, localization, navigation, and manipulation.",
                documentID: cv.id,
                type: .project
            )],
            skills: [evidence(
                id: "speaker-attribution-skill",
                statement: "Tests reliable handoffs between perception, localization, navigation, and manipulation on real robots.",
                documentID: cv.id,
                type: .skill
            )],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let opportunity = OpportunityContext(
            id: "speaker-attribution-opportunity",
            title: "Robotics Software Engineer",
            organisation: "Test Organisation",
            opportunityType: .job,
            responsibilities: [evidence(
                id: "speaker-attribution-responsibility",
                statement: "Integrate and test perception-to-action robotics pipelines.",
                documentID: role.id,
                type: .responsibility
            )],
            requiredSkills: [evidence(
                id: "speaker-attribution-required-skill",
                statement: "ROS2, perception, localization, navigation, manipulation, and reliable testing.",
                documentID: role.id,
                type: .requiredSkill
            )],
            preferredSkills: [],
            researchTopics: [],
            evaluationCriteria: [],
            sourceDocumentIDs: [role.id],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try contexts.saveCandidateProfile(profile)
        try contexts.saveOpportunityContext(opportunity)
        try contexts.saveSelection(InterviewContextSelection(
            candidateProfileID: profile.id,
            opportunityContextID: opportunity.id,
            domainProfileID: .roboticsResearch
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

    private func cancelAsyncWork(_ appState: AppState) {
        appState.precomputeDebounceTask?.cancel()
        appState.activeDetectionTask?.cancel()
        appState.activeAITask?.cancel()
        appState.detectionDebounceTask?.cancel()
        appState.transcriptionTask?.cancel()
        appState.cancelActiveGenerationForStop()
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
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
    func databaseAttributionPersistenceAndLegacyFallback() throws {
        let database = try makeTemporaryDatabase()
        let repository = TranscriptRepository(database: database)
        let legacyID = UUID().uuidString
        let sessionID = UUID().uuidString

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO interview_sessions (id, title, started_at, mode, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [sessionID, "Legacy Session", "2026-05-26T00:00:00Z", "microphone", "2026-05-26T00:00:00Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, session_id, speaker, text, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [legacyID, sessionID, "audio_input", "Hello legacy speaker", "2026-05-26T12:00:00Z"]
            )
        }

        let legacySegment = try #require(repository.segments(sessionID: sessionID).first)
        #expect(legacySegment.id == legacyID)
        #expect(legacySegment.speaker == .unknown)
        #expect(legacySegment.source == .microphone)
        #expect(legacySegment.confidence == 1.0)

        let newID = UUID().uuidString
        try repository.saveSegment(TranscriptSegment(
            id: newID,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: "This is the interviewer speaking over system loopback",
            startTime: 10.5,
            endTime: 15,
            createdAt: Date(timeIntervalSince1970: 2),
            inputDeviceName: "Virtual Cable Input",
            outputDeviceName: "Test Output",
            deviceID: "virtual_loopback_uid",
            confidence: 0.95
        ))

        let updatedSegments = try repository.segments(sessionID: sessionID)
        #expect(updatedSegments.count == 2)
        let loaded = try #require(updatedSegments.first { $0.id == newID })
        #expect(loaded.source == .systemAudio)
        #expect(loaded.speaker == .interviewer)
        #expect(loaded.inputDeviceName == "Virtual Cable Input")
        #expect(loaded.outputDeviceName == "Test Output")
        #expect(loaded.deviceID == "virtual_loopback_uid")
        #expect(loaded.confidence == 0.95)
    }

    @Test
    func questionDetectionGatingRules() {
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
    func audioDeviceInfoFixtureRoundTripsWithoutHardwareAccess() throws {
        let fixture = AudioDeviceInfo(
            id: "fixture-input",
            name: "Virtual Interview Input",
            transportType: "virtual",
            isDefaultInput: true,
            isDefaultOutput: false,
            isInput: true,
            isOutput: false
        )
        let decoded = try JSONDecoder().decode(
            AudioDeviceInfo.self,
            from: JSONEncoder().encode(fixture)
        )

        #expect(decoded == fixture)
        #expect(decoded.name == "Virtual Interview Input")
        #expect(decoded.isInput)
        #expect(!decoded.isOutput)
    }

    @Test
    func interviewerCandidateAudioSeparationVerification() async throws {
        let database = try makeTemporaryDatabase()
        let appState = try makeAppState(database: database)
        defer { cancelAsyncWork(appState) }
        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)
        appState.detectionDebounceSeconds = 60
        let session = try appState.createContextBoundSession(mode: .microphone, title: "Speaker attribution")
        appState.currentSession = session

        let systemSegment = TranscriptSegment(
            id: "sys-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you describe a challenge you overcame?"
        )
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(systemSegment)
        let systemDiagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(systemDiagnostic.eligibleForAutoDetection)
        #expect(systemDiagnostic.source == .systemAudio)
        #expect(systemDiagnostic.speaker == .interviewer)
        #expect(appState.lastSystemAudioTranscript == systemSegment.text)

        let microphoneSegment = TranscriptSegment(
            id: "mic-1",
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "Can you tell me about your project?"
        )
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(microphoneSegment)
        let microphoneDiagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(!microphoneDiagnostic.eligibleForAutoDetection)
        #expect(microphoneDiagnostic.source == .microphone)
        #expect(microphoneDiagnostic.speaker == .candidate)
        #expect(!microphoneDiagnostic.skipReason.isEmpty)

        let interviewerQuestion = TranscriptSegment(
            id: "sys-q",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you tell me about your robotics project?"
        )
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(interviewerQuestion)
        let interviewerDiagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(interviewerDiagnostic.eligibleForAutoDetection)
        #expect(appState.lastSystemAudioTranscript == interviewerQuestion.text)
    }

    @Test
    func systemAudioTranscriptGeneratesGroundedSuggestion() async throws {
        let database = try makeTemporaryDatabase()
        let appState = try makeAppState(database: database)
        defer { cancelAsyncWork(appState) }
        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)
        appState.detectionDebounceSeconds = 0.01
        let session = try appState.createContextBoundSession(mode: .microphone, title: "Speaker suggestion")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let question = TranscriptSegment(
            id: "system-audio-question",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you tell me about your robotics project?",
            createdAt: Date(timeIntervalSince1970: 3),
            confidence: 1
        )
        await appState.handleTranscriptSegment(question)
        try await waitUntil("grounded system-audio suggestion") {
            appState.currentSuggestion != nil
        }

        let suggestion = try #require(appState.currentSuggestion)
        #expect(appState.lastSystemAudioTranscript == question.text)
        #expect(appState.last10SegmentsDiagnostics.contains {
            $0.source == .systemAudio && $0.speaker == .interviewer
        })
        #expect(appState.lastDetectionShouldTrigger)
        #expect(suggestion.sayFirst.contains("LeoRover"))
        #expect(suggestion.sayFirst.contains("ROS2"))
    }
}

private final class SpeakerAttributionLLMClient: LLMClientProtocol {
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
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content: String
        if prompt.contains("question_complete") || prompt.contains("should_trigger") {
            content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": "Can you tell me about your robotics project?",
              "intent": "project_deep_dive",
              "answer_strategy": "project_walkthrough",
              "confidence": 0.98,
              "reason": "The interviewer requested a project walkthrough."
            }
            """
        } else {
            content = Self.suggestionJSON
        }
        return LLMChatResult(
            content: content,
            modelName: "speaker-attribution-fixture",
            providerKind: .deepSeek,
            providerName: "Speaker Attribution Fixture",
            baseURL: "fixture://speaker-attribution",
            latencyMS: 0,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let isStructuredStage = prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.")
        let content = isStructuredStage ? Self.structuredSuggestion : Self.sayFirst
        return AsyncThrowingStream { continuation in
            continuation.yield(content)
            continuation.finish()
        }
    }

    private static let sayFirst = "My robotics project was a LeoRover autonomous object retrieval system where I connected ROS2, YOLOv8 perception, localization, navigation, and manipulation."

    private static let suggestionJSON = """
    {
      "strategy": "Project Walkthrough",
      "say_first": "\(sayFirst)",
      "key_points": ["Built a ROS2 LeoRover retrieval pipeline", "Connected perception to navigation and manipulation", "Tested reliable handoffs"],
      "follow_up_ready": ["I can explain how I validated each handoff."],
      "confidence": 0.95,
      "caution": "Keep the answer grounded in the LeoRover project."
    }
    """

    private static let structuredSuggestion = """
    STRATEGY:
    Project Walkthrough
    SAY_FIRST:
    \(sayFirst)
    KEY_POINTS:
    - Built a ROS2 LeoRover retrieval pipeline.
    - Connected perception to navigation and manipulation.
    - Tested reliable handoffs.
    FOLLOW_UP_READY:
    - I can explain how I validated each handoff.
    CAUTION:
    Keep the answer grounded in the LeoRover project.
    """
}
