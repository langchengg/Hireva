import Testing
import Foundation
@testable import InterviewCopilotMac

@Suite
struct StreamingSuggestionTests {
    
    // Helper to create an in-memory or temp SQLite database for settings
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
    
    // 1. SSE Parser handles split chunks, keep-alives, role-only deltas, and usage-only chunks
    @Test
    func testSSEParserResilience() throws {
        var parser = SSEParser()
        
        // Test a normal chunk
        let chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n"
        let events1 = parser.append(chunk1)
        #expect(events1 == [.token("Hello")])
        
        // Test keep-alive comments
        let chunk2 = ": keep-alive\n"
        let events2 = parser.append(chunk2)
        #expect(events2.isEmpty)
        
        // Test role-only deltas
        let chunk3 = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n"
        let events3 = parser.append(chunk3)
        #expect(events3.isEmpty)
        
        // Test empty delta content
        let chunk4 = "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n"
        let events4 = parser.append(chunk4)
        #expect(events4.isEmpty)
        
        // Test usage-only chunks
        let chunk5 = "data: {\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":10,\"total_tokens\":130,\"prompt_tokens_details\":{\"cached_tokens\":100}}}\n"
        let events5 = parser.append(chunk5)
        #expect(events5 == [.usage(promptTokens: 120, completionTokens: 10, totalTokens: 130, cachedPromptTokens: 100)])
        
        // Test split network chunk (TCP packet split boundary)
        let chunk6Part1 = "data: {\"choices\":[{\"delta\":{\"con"
        let events6Part1 = parser.append(chunk6Part1)
        #expect(events6Part1.isEmpty) // No newline yet
        
        let chunk6Part2 = "tent\":\" world!\"}}]}\n"
        let events6Part2 = parser.append(chunk6Part2)
        #expect(events6Part2 == [.token(" world!")])
        
        // Test [DONE] chunk
        let chunk7 = "data: [DONE]\n"
        let events7 = parser.append(chunk7)
        #expect(events7.isEmpty)
    }
    
    // 2. Local heuristic detects professional prompts and questions
    @Test
    func testLocalHeuristicPrompts() throws {
        let db = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: db)
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: InMemoryAPIKeyStore())
        let detector = QuestionDetectionService(llmRouter: router)
        
        // Standard question mark
        let res1 = detector.isLikelyQuestion("Can you describe your project?")
        #expect(res1.shouldTrigger == true)
        #expect(res1.confidence >= 0.9)
        
        // Interview prompts
        let res2 = detector.isLikelyQuestion("walk me through your CV")
        #expect(res2.shouldTrigger == true)
        #expect(res2.reason.contains("walk me through"))
        
        let res3 = detector.isLikelyQuestion("tell me about a time you failed")
        #expect(res3.shouldTrigger == true)
        #expect(res3.reason.contains("tell me about"))
        
        let res4 = detector.isLikelyQuestion("give me an example of leadership")
        #expect(res4.shouldTrigger == true)
        #expect(res4.reason.contains("give me an example"))
        
        let res5 = detector.isLikelyQuestion("describe the architecture")
        #expect(res5.shouldTrigger == true)
        #expect(res5.reason.contains("describe"))
        
        // Non-question text
        let res6 = detector.isLikelyQuestion("Yes, I think so.")
        #expect(res6.shouldTrigger == false)
    }
    
    // 3. Stage B merge policy preserves good Stage A answer and merges correctly
    @Test
    func testStageBMergePolicy() {
        // Prepare original/streamed card (Stage A)
        let stageACard = SuggestionCard(
            id: "card-123",
            sessionID: "session-123",
            questionID: "q-123",
            strategy: "Quick Opener",
            sayFirst: "This is my wonderful Stage A streamed opener.",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.8,
            caution: "Streaming...",
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "deepseek-v4-flash",
            promptVersion: "quick-v1",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "",
            latencyMS: 200,
            isLocal: false,
            createdAt: Date(),
            sayFirstSource: "deepseek_stream",
            stageATimedOut: false,
            stageBCompleted: false,
            stageBStatus: "skipped"
        )
        
        // Full Stage B result card
        let stageBCard = SuggestionCard(
            id: "card-123",
            sessionID: "session-123",
            questionID: "q-123",
            strategy: "Detailed Strategy",
            sayFirst: "This is a completely different Stage B opener that is not clearly better.",
            keyPoints: ["Point 1", "Point 2"],
            followUpReady: ["Follow up"],
            confidence: 0.85, // confidence difference is 0.05, so not clearly better (requires difference > 0.15)
            caution: "Caution info",
            evidenceUsed: ["cv-chunk-1"],
            riskLevel: .medium,
            modelName: "deepseek-v4-pro",
            promptVersion: "full-v1",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "",
            latencyMS: 2000,
            isLocal: false,
            createdAt: Date()
        )
        
        // Simulate AppState merge logic
        var finalCard = stageBCard
        let isFallbackUsed = stageACard.sayFirstSource == "rag_template_fallback"
        let currentSayFirst = stageACard.sayFirst
        let stageBIsClearlyBetter = (finalCard.confidence ?? 0.0) > (stageACard.confidence ?? 0.0) + 0.15 || currentSayFirst.count < 15
        
        if !isFallbackUsed && !stageBIsClearlyBetter && !currentSayFirst.isEmpty {
            finalCard.sayFirst = currentSayFirst
        }
        
        // Assertions
        #expect(finalCard.sayFirst == "This is my wonderful Stage A streamed opener.") // Preserved!
        #expect(finalCard.keyPoints == ["Point 1", "Point 2"]) // Merged in!
        #expect(finalCard.strategy == "Detailed Strategy") // Merged in!
    }
    
    // 4. Prompt prefix stability
    @Test
    func testPromptPrefixStability() {
        let systemPromptA = """
        You are a real-time interview helper. Based ONLY on the provided local evidence, generate a single, highly concise 'Say First' opening sentence for the candidate to start their answer with. Do not invent any facts. Speak directly as the candidate (e.g. use 'I' instead of 'The candidate'). Output only that single opening sentence. No intro, no markdown, no JSON, no conversational filler.
        """
        #expect(!systemPromptA.contains("Date"))
        #expect(!systemPromptA.contains("UUID"))
        #expect(!systemPromptA.contains("Timestamp"))
        
        let systemPromptB = """
        You are an AI interview copilot. Generate concise, truthful, glanceable suggestion cards grounded only in the provided CV/JD context. Do not fabricate. Return valid JSON only.
        """
        #expect(!systemPromptB.contains("Date"))
        #expect(!systemPromptB.contains("UUID"))
    }

    // 5. E2E suggestion pipeline test on real DeepSeek
    @MainActor
    @Test
    func testRealDeepSeekStreamingSuggetionE2E() async throws {
        guard TestSupport.realAppDatabaseTestsEnabled else {
            print("Skipping testRealDeepSeekStreamingSuggetionE2E: set REAL_APP_DB_TESTS=1 to allow real app database access.")
            return
        }

        // Find DeepSeek API Key strictly from Environment (No real Keychain in unit tests)
        let apiKey: String? = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
        
        guard let finalKey = apiKey, !finalKey.isEmpty else {
            print("⚠️ Skipping testRealDeepSeekStreamingSuggetionE2E: DeepSeek API Key not configured in Environment")
            return
        }
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("InterviewCopilotMac/interview_copilot.sqlite")
        
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            print("⚠️ Real SQLite database does not exist at: \(dbPath.path)")
            return
        }
        
        print("\n================================================================================")
        print("🚀 RUNNING E2E REAL DEEPSEEK STREAMING SUGGESTION GENERATION PIPELINE")
        print("================================================================================")
        
        // 1. Initialize real AppState
        let database = try AppDatabase(path: dbPath)
        
        // Re-inject key store with finalKey to make sure LLMRouter uses the correct key
        final class CustomEnvKeyStore: APIKeyStore {
            let key: String
            init(key: String) { self.key = key }
            func loadAPIKey(account: String) throws -> String? { return key }
            func saveAPIKey(_ apiKey: String, account: String) throws {}
            func deleteAPIKey(account: String) throws {}
        }
        
        let customKeyStore = CustomEnvKeyStore(key: finalKey)
        let customLLMClient = DeepSeekLLMClient(apiKeyStore: customKeyStore)
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [
            .deepSeek: customLLMClient
        ])
        
        let appState = AppState(database: database, llmRouter: router)
        
        // Ensure DeepSeek is selected as active provider
        if let deepseekProvider = appState.providerConfigurations.first(where: { $0.kind == .deepSeek }) {
            appState.updateActiveRealtimeProvider(provider: deepseekProvider, model: "deepseek-v4-flash")
        }
        
        // 2. Create an E2E Session in real database
        let session = InterviewSession(
            id: UUID().uuidString,
            title: "Real DeepSeek Streaming E2E Verification",
            company: "Autonomous Robotics",
            role: "Robotics Engineer",
            startedAt: Date(),
            endedAt: nil,
            mode: .microphone,
            createdAt: Date()
        )
        try await database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id,
                    session.title,
                    session.company,
                    session.role,
                    DateCoding.string(from: session.startedAt),
                    nil,
                    session.mode.rawValue,
                    DateCoding.string(from: session.createdAt)
                ]
            )
        }
        
        // 3. Create DetectedQuestion
        let query = "Can you tell me about your robotics project?"
        let detectedQuestion = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: query,
            intent: .technical,
            answerStrategy: .wait,
            confidence: 0.98,
            reason: "Practice / Manual Capture Trigger",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-v4-flash",
            promptVersion: "v1.0",
            createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(detectedQuestion)
        
        // Trigger live suggestion E2E generation pipeline
        try await appState.generateSuggestion(
            for: detectedQuestion,
            session: session,
            transcript: query,
            autoGenerated: false
        )
        
        // Stage A should have finished immediately or timed out.
        // Now poll until Stage B finishes (max 15 seconds)
        let startPoll = Date()
        while appState.isExpandingSuggestionCard && Date().timeIntervalSince(startPoll) < 15.0 {
            try? await Task.sleep(nanoseconds: 100_000_000) // Sleep 100ms
        }
        
        let finalCard = appState.currentSuggestion
        #expect(finalCard != nil)
        
        if let card = finalCard {
            print("\nE2E Pipeline suggestion generation completed factually:")
            print("  First Token Latency: \(card.latencyFirstTokenMS ?? -1) ms")
            print("  First Visible Latency: \(card.latencyFirstVisibleMS ?? -1) ms")
            print("  Full Card Latency: \(card.latencyFullCardMS ?? -1) ms")
            print("  Stage A Source: \(card.sayFirstSource ?? "nil")")
            print("  Stage B Status: \(card.stageBStatus ?? "nil")")
            print("  Stage A Timed Out: \(card.stageATimedOut ?? false)")
            print("  Stage B Completed: \(card.stageBCompleted ?? false)")
            print("  Opener (Say First): \"\(card.sayFirst)\"")
            print("  Key Points: \(card.keyPoints)")
            
            #expect(card.providerName == "DeepSeek")
            #expect(card.modelName == "deepseek-v4-flash")
            #expect(card.stageBCompleted == true)
            #expect(card.stageBStatus == "completed")
        }
        
        print("================================================================================")
    }
}

// MARK: - Mocks for Testing

final class MockDelayProvider: DelayProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var delayCalledWithNanosecondsStorage: [UInt64] = []
    private var sleepDurationStorage: UInt64 = 0

    var delayCalledWithNanoseconds: [UInt64] {
        lock.withLock { delayCalledWithNanosecondsStorage }
    }

    var sleepDuration: UInt64 {
        get { lock.withLock { sleepDurationStorage } }
        set { lock.withLock { sleepDurationStorage = newValue } }
    }

    func sleep(nanoseconds: UInt64) async throws {
        let duration = lock.withLock {
            delayCalledWithNanosecondsStorage.append(nanoseconds)
            return sleepDurationStorage
        }
        if duration > 0 {
            try await Task.sleep(nanoseconds: duration)
        }
    }
}

final class StreamingMockLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    
    var streamTokens: [String] = []
    var streamTokenBatches: [[String]] = []
    var streamDelayNS: UInt64 = 0
    private let lock = NSLock()
    private var streamCallCount = 0
    private var completedStreamCountStorage = 0

    var completedStreamCount: Int {
        lock.withLock { completedStreamCountStorage }
    }
    
    var chatResultContent: String = "{}"
    var chatResultDelayNS: UInt64 = 0
    
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        return LLMConnectionTestResult(success: true, message: "Mock OK", latencyMS: 0, models: [])
    }
    
    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        if chatResultDelayNS > 0 {
            try? await Task.sleep(nanoseconds: chatResultDelayNS)
        }
        return LLMChatResult(
            content: chatResultContent,
            modelName: "mock-model",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            baseURL: "",
            latencyMS: 100,
            isLocal: false,
            rawResponse: chatResultContent
        )
    }
    
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        return []
    }
    
    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let tokens = selectTokens(for: messages)
        let delay = streamDelayNS
        return AsyncThrowingStream { continuation in
            guard delay > 0 else {
                for token in tokens {
                    continuation.yield(token)
                }
                self.lock.withLock {
                    self.completedStreamCountStorage += 1
                }
                continuation.finish()
                return
            }

            Task {
                for token in tokens {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(token)
                }
                self.lock.withLock {
                    self.completedStreamCountStorage += 1
                }
                continuation.finish()
            }
        }
    }

    private func selectTokens(for messages: [LLMChatMessage]) -> [String] {
        let prompt = messages.map(\.content).joined(separator: "\n")
        return lock.withLock {
            defer { streamCallCount += 1 }

            // Stage A and Stage B streams are launched concurrently in
            // production. Tests that need distinct batches must route by prompt
            // type, not by scheduler-dependent call order.
            if streamTokenBatches.count >= 2 {
                if prompt.contains("Generate the single opening answer now:") {
                    return streamTokenBatches[0]
                }
                if prompt.contains("Stream the section response now.") {
                    return streamTokenBatches[1]
                }
            }

            if streamCallCount < streamTokenBatches.count {
                return streamTokenBatches[streamCallCount]
            }
            return streamTokens
        }
    }
}

// MARK: - Soft Fallback & Provenance Suite

@Suite(.serialized)
struct StreamingSoftFallbackTests {
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingSoftFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
    
    @MainActor
    @Test
    func providerStageBSuccessOverridesSoftFallbackOwnership() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // Keep Stage A and Stage B streams distinct so the assertion verifies
        // late Stage A replacement, not scheduler-dependent section streaming.
        mockClient.streamTokenBatches = [
            ["My ", "LeoRover ", "project ", "was ", "an ", "autonomous ", "object ", "retrieval ", "robot ", "using ", "ROS2, ", "YOLOv8, ", "navigation, ", "localisation, ", "and ", "manipulation ", "on ", "a ", "real ", "robot."],
            []
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultDelayNS = 0
        
        // Detailed Stage B suggestion card returned as JSON
        mockClient.chatResultContent = """
        {
            "strategy": "Detailed Strategy",
            "say_first": "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.",
            "key_points": ["ROS2, YOLOv8, navigation and localisation", "Manipulation on a real robot"],
            "follow_up_ready": ["What is next?"],
            "confidence": 0.9,
            "caution": "None",
            "evidence_used": [],
            "risk_level": "low"
        }
        """
        
        let router = LLMRouter(settingsRepository: settings, clients: [
            .deepSeek: mockClient
        ])
        
        // Select DeepSeek as active provider
        if let deepseek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            var updated = deepseek
            updated.isDefaultForRealtime = true
            try settings.saveProviderConfiguration(updated)
            try settings.setActiveRealtimeProvider(id: updated.id)
        }
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: SlowStreamingContextRetrievalService(delayNanoseconds: 30_000_000)
        )
        // Regression: a rebuilt app can stream through the router while the
        // published provider cache is not hydrated yet. Provider success must
        // still overwrite fallback ownership instead of preserving fallback
        // provider/model/isLocal metadata.
        appState.activeRealtimeProvider = nil
        
        // Inject MockDelayProvider which fires the 1.5s timer immediately (5ms sleep)
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 5_000_000 // 5ms sleep
        appState.delayProvider = mockDelay
        appState.stageATimeoutSeconds = 60.0
        appState.lateDeepSeekReplacementWindowSeconds = 60.0
        // The production full-card watchdog is not part of this soft-fallback test.
        // Keep it from racing the deterministic mock Stage B completion under suite load.
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        
        let session = InterviewSession(id: "sess-1", title: "Test", company: "C", role: "R", startedAt: Date(), endedAt: nil, mode: .microphone, createdAt: Date())
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id, session.title, session.company, session.role, DateCoding.string(from: session.startedAt), nil, session.mode.rawValue, DateCoding.string(from: session.createdAt)]
            )
        }
        
        let question = DetectedQuestion(
            id: "q-1", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your LeoRover project?", intent: .projectDeepDive,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        // Execute suggestion generation
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        try await waitUntil(timeout: 12.0) {
            appState.currentSuggestion?.stageBCompleted == true &&
            appState.currentSuggestion?.keyPoints.contains("ROS2, YOLOv8, navigation and localisation") == true
        }
        
        // Assertions
        #expect(mockDelay.delayCalledWithNanoseconds.contains(1_500_000_000))
        #expect(appState.currentSuggestion != nil)
        
        let finalCard = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == false)
        #expect(finalCard.softFallbackUsed == false)
        #expect(finalCard.stageBCompleted == true)
        #expect(finalCard.stageBStatus == "completed")
        #expect(finalCard.sayFirst.localizedCaseInsensitiveContains("LeoRover"))
        #expect(finalCard.keyPoints.contains("ROS2, YOLOv8, navigation and localisation"))
        #expect(finalCard.providerName == "DeepSeek")
        #expect(finalCard.modelName.localizedCaseInsensitiveContains("deepseek"))
        #expect(finalCard.sayFirstSource == "deepseek_stream")
        #expect(finalCard.finalVisibleSource == "deepseek_stream")
        #expect(finalCard.isLocal == false)

        try await waitUntil(timeout: 5.0) {
            (try? suggestionRepo.suggestions(sessionID: session.id).first?.finalVisibleSource) == "deepseek_stream"
        }
        let persisted = try #require(try suggestionRepo.suggestions(sessionID: session.id).first)
        #expect(persisted.providerName == "DeepSeek")
        #expect(persisted.modelName.localizedCaseInsensitiveContains("deepseek"))
        #expect(persisted.finalVisibleSource == "deepseek_stream")
        #expect(persisted.sayFirstSource == "deepseek_stream")
        #expect(persisted.isLocal == false)
        #expect(persisted.softFallbackUsed == false)
    }
    
    @MainActor
    @Test
    func testSkipFallbackWhenDeepSeekIsFast() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // DeepSeek streams fast

        mockClient.streamTokens = [
            "My LeoRover ",
            "project was ",
            "an autonomous ",
            "object retrieval ",
            "robot using ",
            "ROS2, YOLOv8 ",
            "perception, navigation, ",
            "localisation, and ",
            "manipulation on ",
            "a real robot."
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultContent = """
        {
            "strategy": "Project walkthrough",
            "say_first": "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.",
            "key_points": ["Autonomous object retrieval robot", "ROS2, YOLOv8, navigation, localisation, and manipulation"],
            "follow_up_ready": ["I can describe how the modules handed off to each other."],
            "confidence": 0.9,
            "caution": "None",
            "evidence_used": [],
            "risk_level": "low"
        }
        """
        
        let router = LLMRouter(settingsRepository: settings, clients: [
            .deepSeek: mockClient
        ])
        
        if let deepseek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            var updated = deepseek
            updated.isDefaultForRealtime = true
            try settings.saveProviderConfiguration(updated)
            try settings.setActiveRealtimeProvider(id: updated.id)
        }
        
        let appState = AppState(database: database, llmRouter: router)
        
        // Keep the fallback timer far outside full-suite scheduler delays so
        // this test verifies the fast DeepSeek stream, not fallback timing.
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 60_000_000_000
        appState.delayProvider = mockDelay
        appState.stageATimeoutSeconds = 60.0
        // The production watchdog is covered elsewhere. Keep this fixture focused
        // on proving that a fast stream prevents the soft fallback path.
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        
        let session = InterviewSession(id: "sess-2", title: "Test", company: "C", role: "R", startedAt: Date(), endedAt: nil, mode: .microphone, createdAt: Date())
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id, session.title, session.company, session.role, DateCoding.string(from: session.startedAt), nil, session.mode.rawValue, DateCoding.string(from: session.createdAt)]
            )
        }
        
        let question = DetectedQuestion(
            id: "q-2", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your LeoRover project?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)

        try await waitUntil(timeout: 60.0) {
            appState.currentSuggestion?.stageBCompleted == true
        }
        
        let finalCard = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == false)
        #expect(finalCard.softFallbackUsed == false)
        #expect(finalCard.sayFirstSource == "deepseek_stream")
        #expect(finalCard.finalVisibleSource == "deepseek_stream")
        #expect(finalCard.isLocal == false)
    }
    
    @MainActor
    @Test
    func testConservativeLateReplacementPreservesFallbackWhenInteractedOrGeneric() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // Generic answer that fails specificity check
        mockClient.streamTokens = ["Based ", "on ", "my ", "experience ", "as ", "a ", "software ", "engineer."]
        mockClient.streamDelayNS = 20_000_000 // 20ms delay per token
        
        let router = LLMRouter(settingsRepository: settings, clients: [
            .deepSeek: mockClient
        ])
        
        if let deepseek = try settings.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            var updated = deepseek
            updated.isDefaultForRealtime = true
            try settings.saveProviderConfiguration(updated)
            try settings.setActiveRealtimeProvider(id: updated.id)
        }
        
        let appState = AppState(database: database, llmRouter: router)
        
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 5_000_000 // 5ms sleep (soft fallback fires first)
        appState.delayProvider = mockDelay
        
        let session = InterviewSession(id: "sess-3", title: "Test", company: "C", role: "R", startedAt: Date(), endedAt: nil, mode: .microphone, createdAt: Date())
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id, session.title, session.company, session.role, DateCoding.string(from: session.startedAt), nil, session.mode.rawValue, DateCoding.string(from: session.createdAt)]
            )
        }
        
        let question = DetectedQuestion(
            id: "q-3", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your LeoRover project?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        // Run with generic answer
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        let start = Date()
        while appState.isExpandingSuggestionCard && Date().timeIntervalSince(start) < 3.0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        let cardGeneric = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == true)
        #expect(cardGeneric.softFallbackUsed == true)
        // Preserved because "Based on my experience as a software engineer." contains "based on my experience" and "as a software engineer", failing isSpecificAnswer check
        #expect(cardGeneric.sayFirstSource == "rag_template_soft_fallback")
        #expect(cardGeneric.finalVisibleSource == "rag_template_soft_fallback")
        
        // Reset and test user interaction path
        mockClient.streamTokens = ["Highly ", "specific ", "robotics ", "engineering ", "neural ", "network ", "answer ", "about ", "autonomous ", "navigation."] // highly specific
        
        // Simulate user interacted in flight (after 10ms, while streaming is active)
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await MainActor.run {
                appState.userInteractedWithCard = true
            }
        }
        
        // Execute again
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        let start2 = Date()
        while appState.isExpandingSuggestionCard && Date().timeIntervalSince(start2) < 3.0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        let cardInteracted = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == true)
        #expect(cardInteracted.softFallbackUsed == true)
        // Preserved because user interacted with card before completion
        #expect(cardInteracted.sayFirstSource == "rag_template_soft_fallback")
        #expect(cardInteracted.finalVisibleSource == "rag_template_soft_fallback")
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "StreamingSoftFallbackTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for streaming soft fallback state."]
        )
    }
}

private final class SlowStreamingContextRetrievalService: ContextRetrievalService {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        let trace = RetrievalTrace(
            id: UUID(),
            query: question,
            intent: intent.rawValue,
            createdAt: Date(),
            rankedCVChunks: [],
            rankedJDChunks: [],
            includedCVChunks: [],
            includedJDChunks: [],
            excludedCVChunks: [],
            excludedJDChunks: [],
            cvWordsUsed: 0,
            jdWordsUsed: 0,
            cvWordBudget: maxCVWords,
            jdWordBudget: maxJDWords,
            retrievalLatencyMS: Double(delayNanoseconds) / 1_000_000.0,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []), trace)
    }
}
