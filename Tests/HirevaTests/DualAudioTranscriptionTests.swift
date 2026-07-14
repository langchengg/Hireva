import AVFoundation
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct DualAudioTranscriptionTests {
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
            .appendingPathComponent("DualAudioTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeAppState() throws -> AppState {
        let database = try makeTemporaryDatabase()
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
                clients: [.deepSeek: DualAudioLLMClient()]
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
            title: "Dual Audio Candidate",
            content: String(repeating: "Built deterministic Swift audio pipeline tests for robotics interview software. ", count: 8)
        )
        let role = try documents.saveDocument(
            type: .jobDescription,
            title: "Dual Audio Role",
            content: String(repeating: "The role requires reliable Swift audio routing and automated testing. ", count: 8)
        )
        let contexts = InterviewContextRepository(database: database)
        let profile = CandidateProfile(
            id: "dual-audio-profile",
            displayName: "Dual Audio Candidate",
            sourceDocumentIDs: [cv.id],
            education: [],
            experience: [evidence(
                id: "dual-audio-experience",
                statement: "Built deterministic Swift audio pipeline tests for robotics interview software.",
                documentID: cv.id,
                type: .experience
            )],
            projects: [],
            skills: [evidence(
                id: "dual-audio-skill",
                statement: "Uses Swift concurrency and automated tests for reliable audio routing.",
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
            id: "dual-audio-opportunity",
            title: "Swift Audio Engineer",
            organisation: "Test Organisation",
            opportunityType: .job,
            responsibilities: [evidence(
                id: "dual-audio-responsibility",
                statement: "Maintain reliable Swift audio routing.",
                documentID: role.id,
                type: .responsibility
            )],
            requiredSkills: [evidence(
                id: "dual-audio-required-skill",
                statement: "Swift concurrency and automated audio tests.",
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

    private func makeSimulatedService(
        sessionID: String = "dual-audio-session",
        captureMode: AudioCaptureMode
    ) async throws -> AppleSpeechTranscriptionService {
        let service = AppleSpeechTranscriptionService()
        _ = service.segments
        try await service.start(sessionID: sessionID, captureMode: captureMode)
        return service
    }

    private func stopSimulatedSessions(_ service: AppleSpeechTranscriptionService) {
        service.microphoneSession?.stop()
        service.systemAudioSession?.stop()
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
        timeout: Duration = .seconds(2),
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

    @Test
    func emittedSegmentsCarryImmutableRecognitionProvenance() async throws {
        let service = try await makeSimulatedService(captureMode: .systemAudioOnly)
        defer { stopSimulatedSessions(service) }
        let systemSession = try #require(service.systemAudioSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments {
                segments.append(segment)
            }
        }
        defer { collector.cancel() }

        systemSession.simulateEmit(
            text: "Could you explain your LeoRover project from end to end?",
            isFinal: true
        )
        try await waitUntil("one provenance segment") { segments.count == 1 }
        let segment = try #require(segments.first)
        let data = try JSONEncoder().encode(segment)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect((json["recognitionTaskID"] as? String)?.isEmpty == false)
        #expect((json["recognitionEventSequence"] as? Int) == 1)
        #expect((json["sourceTextStartUTF16"] as? Int) == 0)
        #expect((json["sourceTextEndUTF16"] as? Int) == (segment.text as NSString).length)
        #expect((json["recognitionIsFinal"] as? Bool) == true)
    }

    @Test
    func microphoneAndSystemCreatesTwoIndependentSessionInstances() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }

        #expect(service.microphoneSession != nil)
        #expect(service.systemAudioSession != nil)
        #expect(service.microphoneSession !== service.systemAudioSession)
    }

    @Test
    func micAndSystemRecognitionRequestIdentitiesAreDistinct() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }

        let micRequest = try #require(service.microphoneSession?.request)
        let systemRequest = try #require(service.systemAudioSession?.request)
        #expect(micRequest !== systemRequest)
    }

    @Test
    func micBufferAppendIncrementsOnlyMicCount() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024

        micSession.appendBuffer(buffer)

        #expect(micSession.totalBuffersAppended == 1)
        #expect(systemSession.totalBuffersAppended == 0)
    }

    @Test
    func systemBufferAppendIncrementsOnlySystemCount() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024

        systemSession.appendBuffer(buffer)

        #expect(systemSession.totalBuffersAppended == 1)
        #expect(micSession.totalBuffersAppended == 0)
    }

    @Test
    func micFirstThenSystemStillProducesBothTranscripts() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments { segments.append(segment) }
        }
        defer { collector.cancel() }

        micSession.simulateEmit(text: "Hello from Microphone", isFinal: true)
        systemSession.simulateEmit(text: "Hello from System Audio", isFinal: true)
        try await waitUntil("microphone and system transcript segments") { segments.count == 2 }

        #expect(segments[0].source == .microphone)
        #expect(segments[0].speaker == .candidate)
        #expect(segments[0].text == "Hello from Microphone")
        #expect(segments[1].source == .systemAudio)
        #expect(segments[1].speaker == .interviewer)
        #expect(segments[1].text == "Hello from System Audio")
    }

    @Test
    func systemFirstThenMicStillProducesBothTranscripts() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments { segments.append(segment) }
        }
        defer { collector.cancel() }

        systemSession.simulateEmit(text: "Hello from System Audio", isFinal: true)
        micSession.simulateEmit(text: "Hello from Microphone", isFinal: true)
        try await waitUntil("system and microphone transcript segments") { segments.count == 2 }

        #expect(segments[0].source == .systemAudio)
        #expect(segments[0].speaker == .interviewer)
        #expect(segments[0].text == "Hello from System Audio")
        #expect(segments[1].source == .microphone)
        #expect(segments[1].speaker == .candidate)
        #expect(segments[1].text == "Hello from Microphone")
    }

    @Test
    func gatingRulesVerifyMicDoesNotAutoTriggerButSystemDoes() async throws {
        let appState = try makeAppState()
        defer { cancelAsyncWork(appState) }
        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.manualOnlyMode = false
        appState.settings = settings
        appState.detectionDebounceSeconds = 60

        let micSegment = TranscriptSegment(
            id: "mic-gating",
            sessionID: "dual-audio-gating",
            source: .microphone,
            speaker: .candidate,
            text: "Hello this is a microphone test response from candidate."
        )
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(micSegment)
        let micDiagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(!micDiagnostic.eligibleForAutoDetection)
        #expect(micDiagnostic.source == .microphone)
        #expect(micDiagnostic.speaker == .candidate)
        #expect(!micDiagnostic.skipReason.isEmpty)

        let systemSegment = TranscriptSegment(
            id: "system-gating",
            sessionID: "dual-audio-gating",
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you describe your robotics projects?"
        )
        appState.last10SegmentsDiagnostics.removeAll()
        await appState.handleTranscriptSegment(systemSegment)
        let systemDiagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(systemDiagnostic.eligibleForAutoDetection)
        #expect(systemDiagnostic.source == .systemAudio)
        #expect(systemDiagnostic.speaker == .interviewer)
    }

    @Test
    func manualOnlyModeSuppressesSystemTranscriptQuestionDetectionWithoutStartingAudioPipelines() async throws {
        let appState = try makeAppState()
        defer {
            cancelAsyncWork(appState)
        }
        var settings = appState.settings
        settings.manualOnlyMode = true
        settings.automaticQuestionDetectionEnabled = true
        appState.settings = settings
        let session = try appState.createContextBoundSession(mode: .mock, title: "Manual Only")
        appState.currentSession = session

        await appState.handleTranscriptSegment(TranscriptSegment(
            id: "manual-only-system-question",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you describe your robotics projects?",
            recognitionIsFinal: true
        ))

        #expect(appState.isMicPipelineActive == false)
        #expect(appState.isSystemAudioASRActive == false)
        let diagnostic = try #require(appState.last10SegmentsDiagnostics.first)
        #expect(diagnostic.eligibleForAutoDetection == false)
        #expect(diagnostic.skipReason.localizedCaseInsensitiveContains("manual only mode enabled"))
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(appState.currentSuggestion == nil)
    }

    @Test
    func audioDeviceNameFallbackAndRouteFormattingAreDeterministic() {
        #expect(AudioDeviceManager.resolvedDeviceName(nil, fallback: "Unknown Input") == "Unknown Input")
        #expect(AudioDeviceManager.resolvedDeviceName("  \n", fallback: "Unknown Output") == "Unknown Output")
        #expect(AudioDeviceManager.resolvedDeviceName("  Studio Mic  ", fallback: "Unknown Input") == "Studio Mic")
        #expect(AudioDeviceManager.makeRouteDescription(
            inputName: "Studio Mic",
            outputName: "USB Headphones"
        ) == "Input: Studio Mic, Output: USB Headphones")
    }

    @Test
    func longPartialWithShortFinalASRQualityLogic() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneOnly)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments { segments.append(segment) }
        }
        defer { collector.cancel() }

        micSession.simulateEmit(text: "This is my complete candidate answer regarding robotics experience", isFinal: false)
        micSession.simulateEmit(text: "Take", isFinal: true)
        try await waitUntil("partial and truncated final segments") { segments.count == 2 }

        #expect(micSession.lastPartialTranscript == "This is my complete candidate answer regarding robotics experience")
        #expect(micSession.lastFinalTranscript == "Take")
        #expect(micSession.bestTranscriptUsed == "This is my complete candidate answer regarding robotics experience")
        #expect(micSession.finalizationReason == "final much shorter than recent partial")
        #expect(segments.last?.text == "This is my complete candidate answer regarding robotics experience")
    }

    @Test
    func emptyFinalWithMeaningfulPartialQualityLogic() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneOnly)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments { segments.append(segment) }
        }
        defer { collector.cancel() }

        micSession.simulateEmit(text: "Robotics and VLA policies", isFinal: false)
        micSession.simulateEmit(text: "", isFinal: true)
        try await waitUntil("partial and empty final segments") { segments.count == 2 }

        #expect(micSession.lastPartialTranscript == "Robotics and VLA policies")
        #expect(micSession.lastFinalTranscript == "")
        #expect(micSession.bestTranscriptUsed == "Robotics and VLA policies")
        #expect(micSession.finalizationReason == "final empty but partial meaningful")
        #expect(segments.last?.text == "Robotics and VLA policies")
    }

    @Test
    func goodFinalUsesFinalQualityLogic() async throws {
        let service = try await makeSimulatedService(captureMode: .microphoneOnly)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        var segments: [TranscriptSegment] = []
        let collector = Task { @MainActor in
            for await segment in service.segments { segments.append(segment) }
        }
        defer { collector.cancel() }

        micSession.simulateEmit(text: "This is a good candidate", isFinal: false)
        micSession.simulateEmit(text: "This is a good candidate answer.", isFinal: true)
        try await waitUntil("partial and complete final segments") { segments.count == 2 }

        #expect(micSession.lastPartialTranscript == "This is a good candidate")
        #expect(micSession.lastFinalTranscript == "This is a good candidate answer.")
        #expect(micSession.bestTranscriptUsed == "This is a good candidate answer.")
        #expect(micSession.finalizationReason == "final is longer or similar")
        #expect(segments.last?.text == "This is a good candidate answer.")
    }

    @Test
    func simulatedASRQualityPersistsToTemporaryDatabase() async throws {
        let database = try makeTemporaryDatabase()
        let sessionRepository = SessionRepository(database: database)
        let transcriptRepository = TranscriptRepository(database: database)
        let session = try sessionRepository.createSession(mode: .microphone, title: "Simulated ASR quality")
        let service = try await makeSimulatedService(sessionID: session.id, captureMode: .microphoneAndSystem)
        defer { stopSimulatedSessions(service) }
        let micSession = try #require(service.microphoneSession)
        let systemSession = try #require(service.systemAudioSession)
        var segments: [TranscriptSegment] = []
        var persistenceError: Error?
        let collector = Task { @MainActor in
            for await segment in service.segments {
                segments.append(segment)
                do {
                    try transcriptRepository.saveSegment(segment)
                } catch {
                    persistenceError = error
                    break
                }
            }
        }
        defer { collector.cancel() }

        micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: false)
        micSession.simulateEmit(text: "Take", isFinal: true)
        micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: false)
        micSession.simulateEmit(text: "", isFinal: true)
        micSession.simulateEmit(text: "This is my candidate answer", isFinal: false)
        micSession.simulateEmit(text: "This is my candidate answer about my robotics project", isFinal: true)
        systemSession.simulateEmit(text: "Can you tell me about your robotics project?", isFinal: false)
        systemSession.simulateEmit(text: "Can you tell me about your robotics project?", isFinal: true)
        try await waitUntil("eight persisted simulated ASR events") {
            segments.count == 8 || persistenceError != nil
        }
        if let persistenceError { throw persistenceError }

        #expect(micSession.bestTranscriptUsed == "This is my candidate answer about my robotics project")
        #expect(systemSession.bestTranscriptUsed == "Can you tell me about your robotics project?")
        let savedSegments = try transcriptRepository.segments(sessionID: session.id)
        let segmentIDs = savedSegments.map(\.id)
        #expect(segmentIDs.count == Set(segmentIDs).count)
        #expect(savedSegments.filter { $0.source == .microphone }.contains {
            $0.text == "This is my candidate answer about my robotics project"
        })
        #expect(savedSegments.filter { $0.source == .systemAudio }.contains {
            $0.text == "Can you tell me about your robotics project?"
        })
    }
}

private final class DualAudioLLMClient: LLMClientProtocol {
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
          "say_first": "I built deterministic Swift audio pipeline tests for robotics interview software.",
          "key_points": ["Tested microphone and system attribution", "Used finite deterministic synchronization"],
          "follow_up_ready": [],
          "confidence": 0.95,
          "caution": "Keep the answer grounded in the fixture profile."
        }
        """
        return LLMChatResult(
            content: content,
            modelName: "dual-audio-fixture",
            providerKind: .deepSeek,
            providerName: "Dual Audio Fixture",
            baseURL: "fixture://dual-audio",
            latencyMS: 0,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}
