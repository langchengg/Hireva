import Foundation
import Testing
@testable import InterviewCopilotMac

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
            ["I ", "want ", "this ", "role."],
            [
                "SAY_FIRST:\nI want this role because it connects my robotics work to the team goals.\n\n",
                "KEY_POINTS:\n- The role matches my ROS2 and robotics project work",
                "\n- I can contribute production engineering practices",
                "\n\nFOLLOW_UP_READY:\n- How did you evaluate the pipeline?",
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
        let delay = MockDelayProvider()
        delay.sleepDuration = 500_000_000
        appState.delayProvider = delay

        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Latency Test")
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

        let firstKeyPointDeadline = Date().addingTimeInterval(12.0)
        var sawKeyPointBeforeStreamEnd = false
        while Date() < firstKeyPointDeadline {
            if let card = appState.currentSuggestion,
               !card.keyPoints.isEmpty,
               card.fullCardVisibleMS == nil {
                sawKeyPointBeforeStreamEnd = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(sawKeyPointBeforeStreamEnd == true)
        #expect(appState.currentSuggestion?.firstKeyPointVisibleMS != nil)
        #expect(appState.currentSuggestionSetAt != nil)

        let fullCardDeadline = Date().addingTimeInterval(12.0)
        while Date() < fullCardDeadline && appState.currentSuggestion?.fullCardVisibleMS == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        if let firstKeyPoint = appState.currentSuggestion?.firstKeyPointVisibleMS,
           let fullCard = appState.currentSuggestion?.fullCardVisibleMS {
            #expect(firstKeyPoint < fullCard)
        } else {
            #expect(Bool(false), "Expected first key point and full card latency markers")
        }

        let persistenceDeadline = Date().addingTimeInterval(12.0)
        while Date() < persistenceDeadline && appState.streamPersistedAt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(appState.streamPersistedAt != nil)
        if let visibleAt = appState.currentSuggestionSetAt, let persistedAt = appState.streamPersistedAt {
            #expect(visibleAt <= persistedAt)
        }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatencyOptimizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
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
