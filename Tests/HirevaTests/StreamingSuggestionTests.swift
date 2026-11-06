import Testing
import Foundation
import os
@testable import Hireva

@Suite
struct StreamingSuggestionTests {
    
    // Helper to create an in-memory or temp SQLite database for settings
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaTests-\(UUID().uuidString)", isDirectory: true)
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
    @Test(.enabled(if: TestSupport.realAppDatabaseTestsEnabled &&
        ProcessInfo.processInfo.environment["HIREVA_REAL_CLOUD_TESTS"] == "1",
        "Requires explicit cloud/production-data opt-in; never part of ordinary or local-only validation."))
    func testRealDeepSeekStreamingSuggetionE2E() async throws {
        // Find DeepSeek API Key strictly from Environment (No real Keychain in unit tests)
        let apiKey: String? = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
        
        let finalKey = try #require(apiKey, "Explicitly enabled cloud test needs a test credential.")
        try #require(!finalKey.isEmpty)
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appendingPathComponent("Hireva/hireva.sqlite")
        
        try #require(FileManager.default.fileExists(atPath: dbPath.path),
            "Explicitly enabled legacy integration requires its database prerequisite.")
        
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
        
        let appState = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(), llmRouter: router)
        
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
    private var sleepDurationOverridesStorage: [UInt64: UInt64] = [:]

    var delayCalledWithNanoseconds: [UInt64] {
        lock.withLock { delayCalledWithNanosecondsStorage }
    }

    var sleepDuration: UInt64 {
        get { lock.withLock { sleepDurationStorage } }
        set { lock.withLock { sleepDurationStorage = newValue } }
    }

    func setSleepDuration(_ duration: UInt64, forRequestedNanoseconds requestedNanoseconds: UInt64) {
        lock.withLock {
            sleepDurationOverridesStorage[requestedNanoseconds] = duration
        }
    }

    func sleep(nanoseconds: UInt64) async throws {
        let duration = lock.withLock {
            delayCalledWithNanosecondsStorage.append(nanoseconds)
            return sleepDurationOverridesStorage[nanoseconds] ?? sleepDurationStorage
        }
        if duration > 0 {
            try await Task.sleep(nanoseconds: duration)
        }
    }
}

final class StreamingMockLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    
    private struct State: Sendable {
        var streamTokens: [String] = []
        var streamTokenBatches: [[String]] = []
        var streamDelayNS: UInt64 = 0
        var streamCallCount = 0
        var completedStreamCount = 0
        var chatResultContent: String = "{}"
        var chatResultDelayNS: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var streamTokens: [String] {
        get { state.withLock { $0.streamTokens } }
        set { state.withLock { $0.streamTokens = newValue } }
    }
    var streamTokenBatches: [[String]] {
        get { state.withLock { $0.streamTokenBatches } }
        set { state.withLock { $0.streamTokenBatches = newValue } }
    }
    var streamDelayNS: UInt64 {
        get { state.withLock { $0.streamDelayNS } }
        set { state.withLock { $0.streamDelayNS = newValue } }
    }
    var chatResultContent: String {
        get { state.withLock { $0.chatResultContent } }
        set { state.withLock { $0.chatResultContent = newValue } }
    }
    var chatResultDelayNS: UInt64 {
        get { state.withLock { $0.chatResultDelayNS } }
        set { state.withLock { $0.chatResultDelayNS = newValue } }
    }
    var completedStreamCount: Int { state.withLock { $0.completedStreamCount } }
    
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
                self.state.withLock { $0.completedStreamCount += 1 }
                continuation.finish()
                return
            }

            let producer = Task {
                for token in tokens {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        continuation.finish()
                        return
                    }
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(token)
                }
                self.state.withLock { $0.completedStreamCount += 1 }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    private func selectTokens(for messages: [LLMChatMessage]) -> [String] {
        let prompt = messages.map(\.content).joined(separator: "\n")
        return state.withLock { state in
            defer { state.streamCallCount += 1 }
            let streamTokenBatches = state.streamTokenBatches
            let streamTokens = state.streamTokens

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

            if state.streamCallCount < streamTokenBatches.count {
                return streamTokenBatches[state.streamCallCount]
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
            ["My ", "LeoRover ", "project ", "was ", "an ", "autonomous ", "object ", "retrieval ", "robot ", "using ", "ROS2, ", "YOLOv8, ", "navigation, ", "localisation, ", "and ", "manipulation ", "on ", "a ", "real ", "robot. ", "The ", "result ", "was ", "a ", "complete ", "perception-to-action ", "pipeline, ", "and ", "I ", "learned ", "that ", "localisation ", "and ", "handoff ", "timing ", "determined ", "reliability."],
            []
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultDelayNS = 0
        
        // Detailed Stage B suggestion card returned as JSON
        mockClient.chatResultContent = """
        {
            "strategy": "Detailed Strategy",
            "say_first": "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot. The result was a complete perception-to-action pipeline, and I learned that localisation and handoff timing determined reliability.",
            "key_points": ["ROS2, YOLOv8, navigation and localisation", "Manipulation on a real robot", "Result and learning: handoff timing determined reliability"],
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
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: router,
            contextRetrievalService: SlowStreamingContextRetrievalService(delayNanoseconds: 30_000_000)
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        // Regression: a rebuilt app can stream through the router while the
        // published provider cache is not hydrated yet. Provider success must
        // still overwrite fallback ownership instead of preserving fallback
        // provider/model/isLocal metadata.
        appState.activeRealtimeProvider = nil
        
        // Inject MockDelayProvider which fires the 1.5s timer immediately (5ms sleep)
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 60_000_000_000
        mockDelay.setSleepDuration(5_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = mockDelay
        appState.stageATimeoutSeconds = 60.0
        appState.lateDeepSeekReplacementWindowSeconds = 60.0
        // The production full-card watchdog is not part of this soft-fallback test.
        // Keep it from racing the deterministic mock Stage B completion under suite load.
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000

        let session = try makeContextBoundSession(appState, suffix: "stage-b-success")
        appState.currentSession = session
        defer { appState.cancelActiveGenerationForContextChange() }
        
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
        
        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
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

        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
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
            "a real robot. ",
            "The result was a complete ",
            "perception-to-action pipeline, ",
            "and I learned that localisation ",
            "and handoff timing determined reliability."
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultContent = """
        {
            "strategy": "Project walkthrough",
            "say_first": "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot. The result was a complete perception-to-action pipeline, and I learned that localisation and handoff timing determined reliability.",
            "key_points": ["Autonomous object retrieval robot", "ROS2, YOLOv8, navigation, localisation, and manipulation", "Result and learning: handoff timing determined reliability"],
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
        
        let appState = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(), llmRouter: router)
        appState.answerProviderModeOverride = .deepSeekPrimary
        
        // Keep the fallback timer far outside full-suite scheduler delays so
        // this test verifies the fast DeepSeek stream, not fallback timing.
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 60_000_000_000
        appState.delayProvider = mockDelay
        appState.stageATimeoutSeconds = 60.0
        // The production watchdog is covered elsewhere. Keep this fixture focused
        // on proving that a fast stream prevents the soft fallback path.
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000

        let session = try makeContextBoundSession(appState, suffix: "fast-provider")
        appState.currentSession = session
        defer { appState.cancelActiveGenerationForContextChange() }
        
        let question = DetectedQuestion(
            id: "q-2", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your LeoRover project?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)

        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
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
    @Test(.timeLimit(.minutes(1)))
    func testConservativeLateReplacementPreservesFallbackWhenInteractedOrGeneric() async throws {
        // Each case owns fresh resources. The un-interacted control uses the
        // same eligible answer as the interacted case, proving interaction is
        // what preserves the opener rather than an unrelated alignment reject.
        for scenario in ControlledLateReplacementScenario.allCases {
            try await exerciseControlledLateReplacement(scenario)
        }
    }

    private enum ControlledLateReplacementScenario: CaseIterable {
        case generic, interacted, eligibleControl
    }

    @MainActor
    private func exerciseControlledLateReplacement(_ scenario: ControlledLateReplacementScenario) async throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        let suiteName = "Hireva.StreamingLateReplacement." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = ControlledLateReplacementLLMClient()
        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: router, keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        app.answerProviderModeOverride = .deepSeekPrimary
        let softClock = ControlledGenerationWatchdogClock(trace: TestEventWaitTrace(label: "controlledFallback.softClock"))
        let controlClock = ControlledGenerationWatchdogClock()
        app.delayProvider = softClock
        app.generationWatchdogDelayProvider = controlClock
        let eligibleAnswer = "My LeoRover project used ROS2 and YOLOv8 to connect perception, navigation, localisation, and manipulation for autonomous object retrieval on a real robot. The result was a complete perception-to-action pipeline; I learned that localisation and handoff timing determined reliability."
        let genericAnswer = "Based on my experience as a software engineer."
        var root: Task<Void, Error>?
        var stageA: Task<String, Error>?
        var stageB: Task<Void, Never>?
        do {
            let session = try makeContextBoundSession(app, suffix: "controlled-late-\(scenario)")
            // Creation saves a snapshot; the actual live entry separately selects
            // the current session used by publication admission.
            app.currentSession = session
            let question = DetectedQuestion(id: UUID().uuidString, sessionID: session.id,
                transcriptSegmentID: nil, questionText: "Could you walk me through your LeoRover project?",
                intent: .technical, answerStrategy: .wait, confidence: 0.95, reason: "Synthetic controlled late replacement",
                shouldTrigger: true, questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date())
            try SuggestionRepository(database: database).saveDetectedQuestion(question)
            let generation = Task { @MainActor in
                try await app.generateSuggestion(for: question, session: session,
                    transcript: question.questionText, autoGenerated: false)
            }
            root = generation
            try await client.waitForFirstStream()
            let requiredFirstAnswerWorker: Task<String, Error> = try #require(app.generationCoordinator.stageATask)
            stageA = requiredFirstAnswerWorker
            let requiredExpansionWorker: Task<Void, Never> = try #require(app.generationCoordinator.stageBTask)
            stageB = requiredExpansionWorker
            let softDeadline = try #require(app.generationCoordinator.fallbackWatchdogTask)
            try await softClock.waitUntilPending(nanoseconds: 1_500_000_000)
            #expect(softClock.pendingNanoseconds.contains(1_500_000_000))
            #expect(!softDeadline.isCancelled)
            softClock.advance(by: 1_500_000_000)
            await softDeadline.value
            #expect(!softDeadline.isCancelled)
            #expect(app.softFallbackUsed, "The owned fallback deadline must reach its selected branch")
            let initial = try #require(app.currentSuggestion, "fallback_source=\(app.finalVisibleSource ?? "nil"); decision=\(String(describing: app.lastDetectedQuestion?.taskDescriptor?.decision)); ui=\(app.generationUIState)")
            let acceptedQuestion = try #require(app.lastDetectedQuestion)
            #expect(initial.softFallbackUsed == true)
            #expect(initial.alignmentVerdict == .aligned)
            #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(initial).accepted)
            #expect(initial.questionID == question.id)
            #expect(initial.generationID == app.currentGenerationID)
            #expect(initial.sayFirst != eligibleAnswer)
            #expect(initial.sayFirst != genericAnswer)
            #expect(!app.generationUIState.isTerminal)
            // Eligibility is checked with the real rule and frozen decision;
            // no validation or evidence policy is copied into this fixture.
            let eligibleAlignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: question.questionText, answerText: eligibleAnswer,
                sayFirst: eligibleAnswer, stageBCompleted: true,
                decision: acceptedQuestion.taskDescriptor?.decision)
            #expect(eligibleAlignment.verdict == .aligned)
            #expect(app.isSpecificAnswer(eligibleAnswer))
            #expect(!app.isSpecificAnswer(genericAnswer))

            // Stage B's real 500 ms trigger deadline is advanced explicitly.
            // Both actual provider streams stay held until test release.
            while !controlClock.requestedNanoseconds.contains(500_000_000) {
                try await controlClock.waitUntilScheduled(minimumCount: controlClock.requestedNanoseconds.count + 1)
            }
            controlClock.advance(by: 500_000_000)
            try await client.waitForFullStream()
            if scenario == .interacted { app.userInteractedWithCard = true }
            let providerAnswer = scenario == .generic ? genericAnswer : eligibleAnswer
            client.releaseFirst(answer: providerAnswer)
            try await generation.value
            let afterFirst = try #require(app.currentSuggestion)
            if scenario == .eligibleControl {
                #expect(afterFirst.sayFirst == eligibleAnswer)
                #expect(afterFirst.sayFirstSource == "deepseek_stream")
                #expect(afterFirst.finalVisibleSource == "deepseek_stream")
                #expect(afterFirst.softFallbackUsed == false)
            } else {
                assertPreservedOpener(afterFirst, initial: initial)
            }
            client.releaseFull(answer: providerAnswer)
            await stageB?.value
            let final = try #require(app.currentSuggestion)
            if scenario == .eligibleControl {
                #expect(final.sayFirst == eligibleAnswer)
                #expect(final.sayFirstSource == "deepseek_stream")
                #expect(final.finalVisibleSource == "deepseek_stream")
                #expect(final.softFallbackUsed == false)
            } else {
                assertPreservedOpener(final, initial: initial)
            }
            #expect(final.alignmentVerdict == .aligned)
            #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(final).accepted)
            client.finishAll()
            softClock.cancelAll(); controlClock.cancelAll()
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            #expect(client.pendingStreamCount == 0)
            try database.close()
        } catch {
            // Open all stream/clock gates before any joins, including failures.
            client.finishAll()
            softClock.cancelAll(); controlClock.cancelAll()
            root?.cancel()
            app.cancelActiveGenerationForContextChange()
            _ = await root?.result
            _ = await stageA?.result
            await stageB?.value
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @MainActor
    private func assertPreservedOpener(_ card: SuggestionCard, initial: SuggestionCard) {
        #expect(card.id == initial.id)
        #expect(card.sessionID == initial.sessionID)
        #expect(card.questionID == initial.questionID)
        #expect(card.generationID == initial.generationID)
        #expect(card.contextSnapshotID == initial.contextSnapshotID)
        #expect(card.candidateProfileVersion == initial.candidateProfileVersion)
        #expect(card.sayFirst == initial.sayFirst)
        #expect(card.sayFirstSource == initial.sayFirstSource)
        #expect(card.finalVisibleSource == initial.finalVisibleSource)
        #expect(card.softFallbackUsed == true)
    }

    private func waitUntil(
        timeout: TimeInterval,
        appState: AppState,
        mockClient: StreamingMockLLMClient,
        predicate: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let card = await MainActor.run { appState.currentSuggestion }
        let diagnostic = await MainActor.run {
            [
                "source=\(card?.sayFirstSource ?? "nil")",
                "finalSource=\(card?.finalVisibleSource ?? "nil")",
                "stageB=\(card?.stageBStatus ?? "nil")/\(card?.stageBCompleted == true)",
                "softFallback=\(card?.softFallbackUsed == true)",
                "keyPoints=\(card?.keyPoints.count ?? 0)",
                "uiState=\(appState.generationUIState.displayName)",
                "alignment=\(appState.lastAlignmentError)",
                "tasks=\(appState.activeTaskSummary)",
                "completedStreams=\(mockClient.completedStreamCount)"
            ].joined(separator: " | ")
        }
        throw NSError(
            domain: "StreamingSoftFallbackTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for streaming soft fallback state. \(diagnostic)"]
        )
    }

    @MainActor
    private func makeContextBoundSession(_ appState: AppState, suffix: String) throws -> InterviewSession {
        let profileID = "streaming-profile-\(suffix)"
        let statements = [
            "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.",
            "I used ROS2, YOLOv8, navigation, localisation, and manipulation for autonomous object retrieval.",
            "I developed a highly specific robotics engineering neural network approach for autonomous navigation.",
            "I have software engineering experience supporting robotics integration.",
            "The result was a complete perception-to-action pipeline on a real robot, and I learned that localisation and handoff timing were the main reliability challenges."
        ]
        let evidence = statements.enumerated().map { index, statement in
            ProfileEvidence(
                id: "streaming-\(suffix)-evidence-\(index)",
                statement: statement,
                sourceDocumentID: "streaming-fixture",
                sourceChunkID: "streaming-\(suffix)-chunk-\(index)",
                sourceSpan: statement,
                confidence: 1,
                evidenceType: index == 0 || index == 4 ? .project : .experience,
                explicitness: .explicit
            )
        }
        let profile = CandidateProfile(
            id: profileID,
            displayName: "Synthetic Streaming Candidate",
            sourceDocumentIDs: ["streaming-fixture"],
            education: [],
            experience: Array(evidence[1...3]),
            projects: [evidence[0], evidence[4]],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        appState.refreshAll()
        appState.selectCandidateProfile(profileID)
        appState.selectInterviewDomain(.roboticsResearch)
        return try appState.createContextBoundSession(mode: .microphone, title: "Streaming Soft Fallback")
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

/// Per-test transport latch. It only recognizes the existing service's two
/// prompt formats and holds their continuations; all answer acceptance,
/// replacement policy and lifecycle behavior runs in production functions.
private final class ControlledLateReplacementLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private enum Kind: Hashable, Sendable { case first, full }
    private struct Round: Sendable {
        let id: UUID
        let continuation: AsyncThrowingStream<String, Error>.Continuation
    }
    private struct State: Sendable {
        var rounds: [Kind: Round] = [:]
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let firstStarts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let fullStarts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var pendingStreamCount: Int { state.withLock { $0.rounds.count } }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult { throw CancellationError() }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        Issue.record("Controlled late-replacement streams unexpectedly used JSON fallback")
        throw CancellationError()
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let kind: Kind
        if prompt.contains("Generate the single opening answer now:") { kind = .first }
        else if prompt.contains("Stream the section response now.") { kind = .full }
        else {
            Issue.record("Controlled late-replacement stream had an unexpected service prompt")
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        return AsyncThrowingStream { continuation in
            let id = UUID()
            let oldOrClosed = state.withLock { state -> (Round?, Bool) in
                guard !state.closed else { return (nil, true) }
                return (state.rounds.updateValue(.init(id: id, continuation: continuation), forKey: kind), false)
            }
            oldOrClosed.0?.continuation.finish(throwing: CancellationError())
            if oldOrClosed.1 { continuation.finish(throwing: CancellationError()); return }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { state in
                    if state.rounds[kind]?.id == id { state.rounds.removeValue(forKey: kind) }
                }
            }
            (kind == .first ? firstStarts.continuation : fullStarts.continuation).yield(())
        }
    }
    func waitForFirstStream() async throws {
        _ = try await TestEventWaitTrace(label: "lateReplacement.first")
            .nextEvent(in: firstStarts.stream, event: "stream-created")
    }
    func waitForFullStream() async throws {
        _ = try await TestEventWaitTrace(label: "lateReplacement.full")
            .nextEvent(in: fullStarts.stream, event: "stream-created")
    }
    func releaseFirst(answer: String) { release(.first, text: answer) }
    func releaseFull(answer: String) {
        release(.full, text: "STRATEGY: Project walkthrough\nSAY_FIRST: \(answer)\nKEY_POINTS:\nFOLLOW_UP_READY:\nCAUTION:\n")
    }
    private func release(_ kind: Kind, text: String) {
        let round = state.withLock { $0.rounds.removeValue(forKey: kind) }
        round?.continuation.yield(text)
        round?.continuation.finish()
    }
    func finishAll() {
        let rounds = state.withLock { state in
            state.closed = true
            let owned = Array(state.rounds.values)
            state.rounds.removeAll()
            return owned
        }
        rounds.forEach { $0.continuation.finish(throwing: CancellationError()) }
        firstStarts.continuation.finish(); fullStarts.continuation.finish()
    }
}
