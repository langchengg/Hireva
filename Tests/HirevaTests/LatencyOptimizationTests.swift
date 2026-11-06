import Foundation
import os
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

        let appState = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(), llmRouter: router)
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delay = MockDelayProvider()
        delay.sleepDuration = 60_000_000_000
        appState.delayProvider = delay
        appState.generationFullCardWatchdogNanoseconds = 30_000_000_000

        let session = try makeContextBoundSession(appState)
        appState.currentSession = session
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
    @Test(.timeLimit(.minutes(1)))
    func transcriptIngestionReturnsWhileProviderStreamsRemainBlocked() async throws {
        let database = try makeTemporaryDatabase()
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let client = LatencyBlockingLLMClient()
        let appState = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        let pipelineClock = ControlledGenerationWatchdogClock(
            trace: TestEventWaitTrace(label: "latency-ingestion.pipeline-clock"))
        let displayClock = ControlledGenerationWatchdogClock(
            trace: TestEventWaitTrace(label: "latency-ingestion.display-clock"))
        appState.generationWatchdogDelayProvider = pipelineClock
        appState.delayProvider = displayClock
        var owned: [Task<Void, Never>] = []
        @MainActor func cleanup() async throws {
            client.releaseStreams()
            pipelineClock.cancelAll(); displayClock.cancelAll()
            owned.forEach { $0.cancel() }
            appState.cancelActiveGenerationForContextChange()
            for task in owned { await task.value }
            await appState.shutdownForTesting()
            await client.joinWorkers()
            try database.close()
        }
        do {
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
                id: "latency-ingestion-question", sessionID: session.id,
                source: .systemAudio, speaker: .interviewer, text: "Why do you want this role?",
                confidence: 1, asrFinalizationReason: "final_accepted", recognitionIsFinal: true))
            // The actual public ingestion returned while its first provider
            // remains gated. This is causality, not a visible-latency sample.
            try await client.waitForStartedStreams(atLeast: 1)
            let root = try #require(appState.activeAITask)
            owned.append(root)
            try await pipelineClock.waitUntilPending(nanoseconds: 500_000_000)
            // Advance only the existing 500ms Stage B trigger. The 1.5s UI
            // fallback uses the other clock, and 6s/60s remain unexpired.
            pipelineClock.advance(by: 500_000_000)
            try await client.waitForStartedStreams(atLeast: 2)
            let expansion = try #require(appState.stageBTask)
            owned.append(expansion)
            #expect(client.finishedStreamCount == 0)
            #expect(appState.lastTranscriptSnippet == "Why do you want this role?")

            client.releaseStreams()
            try await client.waitForFinishedStreams(atLeast: 2)
            await withTaskCancellationHandler { await root.value } onCancel: { root.cancel() }
            await withTaskCancellationHandler { await expansion.value } onCancel: { expansion.cancel() }
            await appState.generationCoordinator.drainRetiredTasks()
            #expect(client.finishedStreamCount >= 2)
            #expect(appState.currentSuggestion?.questionText == "Why do you want this role?")
            #expect(appState.currentSuggestion?.stageBCompleted == true)
            let persisted = try appState.suggestionRepository.suggestions(sessionID: session.id)
            #expect(persisted.count == 1)
            #expect(persisted.first?.questionText == "Why do you want this role?")
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
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

private final class LatencyBlockingLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private struct State: Sendable {
        var started = 0
        var finished = 0
        var workers: [UUID: Task<Void, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = LatencyBroadcastGate()
    private let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
    private let finished = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
    private let trace = TestEventWaitTrace(label: "latency-ingestion.provider")
    var startedStreamCount: Int { state.withLock { $0.started } }
    var finishedStreamCount: Int { state.withLock { $0.finished } }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "fixture", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content: String
        if prompt.contains("Decide whether the interviewer has asked") {
            content = """
            {"should_trigger":true,"question_complete":true,"question_text":"Why do you want this role?","intent":"company_fit","answer_strategy":"direct_answer","confidence":0.99,"reason":"Deterministic system-audio question."}
            """
        } else { content = Self.jsonCard }
        return LLMChatResult(content: content, modelName: "latency-blocking-fixture",
            providerKind: .deepSeek, providerName: "Latency Blocking Fixture",
            baseURL: "fixture://latency", latencyMS: 0, isLocal: false, rawResponse: content)
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let response = prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.")
            ? Self.sectionCard : Self.sayFirst
        return AsyncThrowingStream { continuation in
            let id = UUID()
            let worker = Task {
                let count = self.state.withLock { $0.started += 1; return $0.started }
                self.trace.mark("producer.stream-started.\(count)")
                self.started.continuation.yield(count)
                do {
                    try await self.gate.wait()
                    try Task.checkCancellation()
                    continuation.yield(response)
                    continuation.finish()
                    let count = self.state.withLock { $0.finished += 1; return $0.finished }
                    self.trace.mark("producer.stream-finished.\(count)")
                    self.finished.continuation.yield(count)
                } catch { continuation.finish(throwing: error) }
            }
            self.state.withLock { $0.workers[id] = worker }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
    func releaseStreams() { gate.release() }
    func waitForStartedStreams(atLeast target: Int) async throws {
        while startedStreamCount < target {
            _ = try await trace.nextEvent(in: started.stream, event: "stream-start")
        }
        try Task.checkCancellation()
    }
    func waitForFinishedStreams(atLeast target: Int) async throws {
        while finishedStreamCount < target {
            _ = try await trace.nextEvent(in: finished.stream, event: "stream-finish")
        }
        try Task.checkCancellation()
    }
    func joinWorkers() async {
        // Every caller closes generation admission before final fixture join.
        // Completed workers remain owned until this exact snapshot is joined.
        let captured = state.withLock { $0.workers }
        for worker in captured.values { await worker.value }
        state.withLock { for id in captured.keys { $0.workers.removeValue(forKey: id) } }
        started.continuation.finish(); finished.continuation.finish()
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

private final class LatencyBroadcastGate: Sendable {
    private struct State: Sendable {
        var open = false
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func wait() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let open = state.withLock {
            if $0.open { return true }
            $0.waiters[id] = events.continuation
            return false
        }
        if open { events.continuation.yield(()); events.continuation.finish() }
        defer {
            _ = state.withLock { $0.waiters.removeValue(forKey: id) }
            events.continuation.finish()
        }
        await withTaskCancellationHandler {
            var iterator = events.stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: { events.continuation.finish() }
        try Task.checkCancellation()
    }
    func release() {
        let pending = state.withLock {
            $0.open = true
            let pending = Array($0.waiters.values)
            $0.waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.yield(()); continuation.finish() }
    }
}
