import Foundation
import Testing
@testable import Hireva

@Suite
struct LatencyOptimizationTests {
    @Test
    func stageBSectionParserEmitsKeyPointBeforeFullCardCompletes() {
        var parser = StreamingSuggestionSectionParser()
        var snapshot = parser.append("SAY_FIRST:\nI want this role because it connects my robotics work to the team goals.\n\n")
        #expect(snapshot.sayFirst.contains("I want this role"))
        #expect(snapshot.keyPoints.isEmpty)

        snapshot = parser.append("KEY_POINTS:\n- The role matches my ROS2 and robotics project work")
        #expect(snapshot.keyPoints == ["The role matches my ROS2 and robotics project work"])
        #expect(snapshot.followUpReady.isEmpty)

        snapshot = parser.append("\n- I can contribute to production engineering practices\n\nFOLLOW_UP_READY:\n- How did you evaluate the robotics pipeline?\n\nCAUTION:\nKeep the answer concise.")
        #expect(snapshot.keyPoints.count == 2)
        #expect(snapshot.followUpReady == ["How did you evaluate the robotics pipeline?"])
        #expect(snapshot.caution == "Keep the answer concise.")
    }

    @Test
    func strictJSONIsNotRequiredBeforeDisplay() {
        var parser = StreamingSuggestionSectionParser()
        let snapshot = parser.append("""
        SAY_FIRST:
        I would answer this by connecting my project experience to the role.

        KEY_POINTS:
        - Project evidence appears before any JSON exists
        """)

        #expect(snapshot.sayFirst.hasPrefix("I would answer"))
        #expect(snapshot.keyPoints.first == "Project evidence appears before any JSON exists")
    }

    @Test
    func realtimePromptBudgeterLimitsChunksAndWordsByIntent() {
        let context = RetrievedContext(
            cvChunks: [
                makeChunk(id: "cv-1", type: .cv, words: 160),
                makeChunk(id: "cv-2", type: .cv, words: 140),
                makeChunk(id: "cv-3", type: .cv, words: 130)
            ],
            jobDescriptionChunks: [
                makeChunk(id: "jd-1", type: .jobDescription, words: 150),
                makeChunk(id: "jd-2", type: .jobDescription, words: 130)
            ]
        )

        let whyRole = RealtimePromptBudgeter.trim(
            context,
            question: "Why do you want this role?",
            intent: .companyFit,
            strategy: .directAnswer
        )
        #expect(whyRole.cvChunks.count == 1)
        #expect(whyRole.jobDescriptionChunks.count == 1)
        #expect((whyRole.cvChunks.first?.wordCount ?? 0) <= 120)
        #expect((whyRole.jobDescriptionChunks.first?.wordCount ?? 0) <= 120)

        let project = RealtimePromptBudgeter.trim(
            context,
            question: "Walk me through your robotics project",
            intent: .projectDeepDive,
            strategy: .projectWalkthrough
        )
        #expect(project.cvChunks.count == 2)
        #expect(project.jobDescriptionChunks.count == 1)
        #expect(project.cvChunks.allSatisfy { ($0.wordCount ?? 0) <= 120 })
    }

    @Test
    func streamingUpdateThrottleLimitsHighFrequencyPublishes() {
        var throttle = StreamingUpdateThrottle(minimumInterval: 0.1, minimumCharacterDelta: 10)
        let start = Date()

        #expect(throttle.shouldPublish(characterCount: 3, now: start) == true)
        #expect(throttle.shouldPublish(characterCount: 5, now: start.addingTimeInterval(0.02)) == false)
        #expect(throttle.shouldPublish(characterCount: 16, now: start.addingTimeInterval(0.03)) == true)
        #expect(throttle.shouldPublish(characterCount: 17, now: start.addingTimeInterval(0.06)) == false)
        #expect(throttle.shouldPublish(characterCount: 18, now: start.addingTimeInterval(0.18)) == true)
    }

    @MainActor
    @Test
    func appStateDisplaysFirstKeyPointBeforeStageBStreamEndsAndPersistsLater() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()

        let mockClient = StreamingMockLLMClient()
        mockClient.streamTokenBatches = [
            ["I ", "want ", "this ", "role ", "because ", "it ", "connects ", "robotics ", "AI ", "perception ", "and ", "real-world ", "deployment."],
            [
                "SAY_FIRST:\nI want this role because it connects my robotics, AI, perception, and real-world deployment experience with the team's product direction, and I can contribute while growing as an engineer.\n\n",
                "KEY_POINTS:\n- The role matches my robotics, AI, and perception project work",
                "\n- I can contribute to deployed real-world robotics and production engineering practices",
                "\n\nFOLLOW_UP_READY:\n- How does the team evaluate deployment success?",
                "\n- What tradeoffs did you make?",
                "\n\nCAUTION:\nKeep it concise."
            ]
        ]
        mockClient.streamDelayNS = 80_000_000

        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: mockClient])
        if let deepseek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settings.setActiveRealtimeProvider(id: deepseek.id)
        }

        let appState = AppState(database: database, llmRouter: router)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delay = MockDelayProvider()
        delay.sleepDuration = 60_000_000_000
        appState.delayProvider = delay
        appState.generationFullCardWatchdogNanoseconds = 30_000_000_000

        let session = try makeContextBoundSession(appState)
        defer { appState.cancelActiveGenerationForContextChange() }
        let question = DetectedQuestion(
            id: "latency-q",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "Why do you want this role?",
            intent: .companyFit,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "mock",
            promptVersion: "test",
            createdAt: Date()
        )
        try SuggestionRepository(database: database).saveDetectedQuestion(question)

        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)

        try await waitUntil(timeout: 12.0) {
            guard let persisted = try? appState.suggestionRepository
                .suggestions(sessionID: session.id)
                .first(where: { $0.detectedQuestionID == question.id }) else {
                return false
            }
            return appState.currentSuggestion?.firstKeyPointVisibleMS != nil &&
                appState.currentSuggestion?.fullCardVisibleMS != nil &&
                persisted.dbPersistedMS != nil
        }

        #expect(appState.currentSuggestionSetAt != nil)
        let persisted = try #require(
            try appState.suggestionRepository
                .suggestions(sessionID: session.id)
                .first(where: { $0.detectedQuestionID == question.id })
        )
        if let firstKeyPoint = persisted.firstKeyPointVisibleMS,
           let fullCard = persisted.fullCardVisibleMS,
           let dbPersisted = persisted.dbPersistedMS {
            #expect(firstKeyPoint < fullCard)
            #expect(fullCard <= dbPersisted)
        } else {
            #expect(Bool(false), "Expected first key point, full card, and database persistence latency markers")
        }
    }

    @MainActor
    @Test
    func transcriptIngestionReturnsWhileProviderStreamsRemainBlocked() async throws {
        let database = try makeTemporaryDatabase()
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = LatencyBlockingLLMClient()
        let appState = AppState(
            database: database,
            llmRouter: LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        defer {
            client.releaseStreams()
            appState.cancelActiveGenerationForContextChange()
        }

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.manualOnlyMode = false
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)

        let session = try makeContextBoundSession(appState, mode: .mock)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        await appState.handleTranscriptSegment(TranscriptSegment(
            id: "latency-ingestion-question",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Why do you want this role?",
            confidence: 1,
            asrFinalizationReason: "final_accepted",
            recognitionIsFinal: true
        ))

        try await waitUntil(timeout: 12.0) { client.startedStreamCount >= 2 }
        #expect(client.finishedStreamCount == 0)
        #expect(appState.lastTranscriptSnippet == "Why do you want this role?")

        client.releaseStreams()
        try await waitUntil(timeout: 12.0) {
            client.finishedStreamCount >= 2 &&
                appState.currentSuggestion?.questionText == "Why do you want this role?" &&
                appState.currentSuggestion?.stageBCompleted == true &&
                ((try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == 1)
        }
        let persisted = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(persisted.count == 1)
        #expect(persisted.first?.questionText == "Why do you want this role?")
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatencyOptimizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    @MainActor
    private func makeContextBoundSession(
        _ appState: AppState,
        mode: InterviewMode = .mock
    ) throws -> InterviewSession {
        let profileID = "latency-stream-profile"
        let statements: [(String, EvidenceType)] = [
            ("I want this role because it connects my robotics, AI, perception, and real-world deployment experience with the team's product direction, and I can contribute while growing as an engineer.", .goal),
            ("The role matches my robotics, AI, and perception project work.", .project),
            ("I can contribute to deployed real-world robotics and production engineering practices.", .experience)
        ]
        let evidence = statements.enumerated().map { index, item in
            ProfileEvidence(
                id: "latency-evidence-\(index)",
                statement: item.0,
                sourceDocumentID: "latency-stream-fixture",
                sourceChunkID: "latency-chunk-\(index)",
                sourceSpan: item.0,
                confidence: 1,
                evidenceType: item.1,
                explicitness: .explicit
            )
        }
        let profile = CandidateProfile(
            id: profileID,
            displayName: "Synthetic Latency Candidate",
            sourceDocumentIDs: ["latency-stream-fixture"],
            education: [],
            experience: [evidence[2]],
            projects: [evidence[1]],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [evidence[0]],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        appState.refreshAll()
        appState.selectCandidateProfile(profileID)
        appState.selectInterviewDomain(.roboticsResearch)
        return try appState.createContextBoundSession(mode: mode, title: "Latency Test")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        predicate: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(
            domain: "LatencyOptimizationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the controlled streaming state."]
        )
    }

    private func makeChunk(id: String, type: DocumentType, words: Int) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "doc-\(id)",
            documentType: type,
            chunkIndex: 0,
            content: (0..<words).map { "word\($0)" }.joined(separator: " "),
            keywords: ["robotics", "role"],
            sectionTitle: "Section \(id)",
            wordCount: words,
            metadataJSON: nil,
            createdAt: Date()
        )
    }
}

private final class LatencyBlockingLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private let gate = LatencyBroadcastGate()
    private var startedStreams = 0
    private var finishedStreams = 0

    var startedStreamCount: Int { lock.withLock { startedStreams } }
    var finishedStreamCount: Int { lock.withLock { finishedStreams } }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "fixture", latencyMS: 0, models: [])
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content: String
        if prompt.contains("Decide whether the interviewer has asked") {
            content = """
            {"should_trigger":true,"question_complete":true,"question_text":"Why do you want this role?","intent":"company_fit","answer_strategy":"direct_answer","confidence":0.99,"reason":"Deterministic system-audio question."}
            """
        } else {
            content = Self.jsonCard
        }
        return LLMChatResult(
            content: content,
            modelName: "latency-blocking-fixture",
            providerKind: .deepSeek,
            providerName: "Latency Blocking Fixture",
            baseURL: "fixture://latency",
            latencyMS: 0,
            isLocal: false,
            rawResponse: content
        )
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let response = prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.")
            ? Self.sectionCard
            : Self.sayFirst
        return AsyncThrowingStream { continuation in
            Task {
                self.lock.withLock { self.startedStreams += 1 }
                await self.gate.wait()
                continuation.yield(response)
                continuation.finish()
                self.lock.withLock { self.finishedStreams += 1 }
            }
        }
    }

    func releaseStreams() {
        gate.release()
    }

    private static let sayFirst = "I want this role because it matches my robotics, AI, perception, and real-world deployment experience and lets me contribute reliable engineering work."

    private static let sectionCard = """
    STRATEGY:
    Direct answer
    SAY_FIRST:
    \(sayFirst)
    KEY_POINTS:
    - The role matches my robotics, AI, and perception project work.
    - I can contribute reliable real-world deployment and production engineering practices.
    FOLLOW_UP_READY:
    - I can explain the deployment validation work.
    CAUTION:
    Keep the answer grounded in the synthetic profile.
    """

    private static let jsonCard = """
    {"strategy":"Direct answer","say_first":"\(sayFirst)","key_points":["The role matches my robotics project work."],"follow_up_ready":[],"confidence":0.95,"caution":"Use the synthetic profile.","evidence_used":[],"risk_level":"low"}
    """
}

private final class LatencyBroadcastGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuations = lock.withLock {
            guard isOpen == false else { return [CheckedContinuation<Void, Never>]() }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        continuations.forEach { $0.resume() }
    }
}
