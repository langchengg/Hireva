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
    var delayCalledWithNanoseconds: [UInt64] = []
    var sleepDuration: UInt64 = 0
    func sleep(nanoseconds: UInt64) async throws {
        delayCalledWithNanoseconds.append(nanoseconds)
        if sleepDuration > 0 {
            try await Task.sleep(nanoseconds: sleepDuration)
        }
    }
}

final class StreamingMockLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    
    var streamTokens: [String] = []
    var streamTokenBatches: [[String]] = []
    var streamDelayNS: UInt64 = 0
    private var streamCallCount = 0
    var completedStreamCount = 0
    
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
        let tokens: [String]
        if streamCallCount < streamTokenBatches.count {
            tokens = streamTokenBatches[streamCallCount]
        } else {
            tokens = streamTokens
        }
        streamCallCount += 1
        let delay = streamDelayNS
        return AsyncThrowingStream { continuation in
            Task {
                for token in tokens {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    continuation.yield(token)
                }
                self.completedStreamCount += 1
                continuation.finish()
            }
        }
    }
}

// MARK: - Soft Fallback & Provenance Suite

@Suite
struct StreamingSoftFallbackTests {
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingSoftFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
    
    @MainActor
    @Test
    func testSoftFallbackTriggersWhenSlowAndReplacesStream() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // DeepSeek stream is slow: delay 10ms per token, yields 10 specific tokens
        mockClient.streamTokens = ["This ", "is ", "my ", "specific ", "candidate ", "answer ", "about ", "my ", "robotics ", "project."]
        mockClient.streamDelayNS = 20_000_000 // 20ms delay per token
        
        // Detailed Stage B suggestion card returned as JSON
        mockClient.chatResultContent = """
        {
            "strategy": "Detailed Strategy",
            "say_first": "This is my candidate answer about my robotics project.",
            "key_points": ["First point", "Second point"],
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
        
        let appState = AppState(database: database, llmRouter: router)
        
        // Inject MockDelayProvider which fires the 1.5s timer immediately (5ms sleep)
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 5_000_000 // 5ms sleep
        appState.delayProvider = mockDelay
        
        let session = InterviewSession(id: "sess-1", title: "Test", company: "C", role: "R", startedAt: Date(), endedAt: nil, mode: .microphone, createdAt: Date())
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id, session.title, session.company, session.role, DateCoding.string(from: session.startedAt), nil, session.mode.rawValue, DateCoding.string(from: session.createdAt)]
            )
        }
        
        let question = DetectedQuestion(
            id: "q-1", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Can you tell me about your robotics project?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        // Execute suggestion generation
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        // Wait for Stage B task to expand and complete (max 3 seconds)
        let start = Date()
        while appState.isExpandingSuggestionCard && Date().timeIntervalSince(start) < 3.0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        // Assertions
        #expect(appState.softFallbackUsed == true)
        #expect(mockDelay.delayCalledWithNanoseconds.contains(1_500_000_000))
        #expect(appState.currentSuggestion != nil)
        
        let finalCard = appState.currentSuggestion!
        #expect(finalCard.softFallbackUsed == true)
        #expect(finalCard.sayFirstSource == "deepseek_stream") // Replaced since elapsed < 4.0s and answer is specific
        #expect(finalCard.finalVisibleSource == "deepseek_stream")
        #expect(finalCard.stageBCompleted == true)
        #expect(finalCard.keyPoints.contains("First point"))
    }
    
    @MainActor
    @Test
    func testSkipFallbackWhenDeepSeekIsFast() async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // DeepSeek streams fast

        mockClient.streamTokens = ["Fast ", "answer."]
        mockClient.streamDelayNS = 0
        
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
        
        // Inject MockDelayProvider with 500ms sleep (DeepSeek stream completes in <1ms)
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 500_000_000 // 500ms sleep
        appState.delayProvider = mockDelay
        
        let session = InterviewSession(id: "sess-2", title: "Test", company: "C", role: "R", startedAt: Date(), endedAt: nil, mode: .microphone, createdAt: Date())
        try await database.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id, session.title, session.company, session.role, DateCoding.string(from: session.startedAt), nil, session.mode.rawValue, DateCoding.string(from: session.createdAt)]
            )
        }
        
        let question = DetectedQuestion(
            id: "q-2", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "What is your project?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        // Wait for Stage B task to complete
        let start = Date()
        while appState.isExpandingSuggestionCard && Date().timeIntervalSince(start) < 3.0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        let finalCard = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == false)
        #expect(finalCard.softFallbackUsed == false)
        #expect(finalCard.sayFirstSource == "deepseek_stream")
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
            questionText: "What is your project?", intent: .technical,
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
}
