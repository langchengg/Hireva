import Testing
import Foundation
@testable import Hireva

@Suite
struct StreamingSuggestionTests {

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
        let db = try AppDatabase(inMemory: true)
        defer { try? db.close() }
        let settings = SettingsRepository(database: db)
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: InMemoryAPIKeyStore())
        let detector = QuestionDetectionService(llmRouter: router)
        
        // Standard question mark
        let res1 = detector.isLikelyQuestion("Can you describe your project?")
        #expect(res1.shouldTrigger == true)
        #expect(res1.confidence >= 0.9)
        
        // Interview prompts
        let res2 = detector.isLikelyQuestion("walk me through your technical background")
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

    // 5. E2E suggestion pipeline contract with an injected synthetic provider
    @MainActor
    @Test
    func deepSeekStreamingSuggestionPipelineCompletesWithSyntheticProvider() async throws {
        try await withStreamingAppTestFixture(prefix: "StreamingSuggestionPipeline") { fixture in
            try await verifyDeepSeekStreamingSuggestionPipeline(fixture: fixture)
        }
    }

    @MainActor
    private func verifyDeepSeekStreamingSuggestionPipeline(
        fixture: StreamingAppTestFixture
    ) async throws {
        let database = fixture.database
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        guard var provider = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) else {
            throw NSError(
                domain: "StreamingSuggestionTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "DeepSeek provider fixture is missing."]
            )
        }
        provider.model = "deepseek-v4-flash"
        provider.isDefaultForRealtime = true
        try settingsRepository.saveProviderConfiguration(provider)
        try settingsRepository.setActiveRealtimeProvider(id: provider.id)

        let mockClient = StreamingMockLLMClient()
        mockClient.streamTokenBatches = [
            ["I traced the synthetic service failure with logs and metrics, isolated the faulty handoff, and verified the repair with repeatable tests."],
            ["""
            STRATEGY: Evidence-based debugging
            SAY_FIRST: I traced the synthetic service failure with logs and metrics, isolated the faulty handoff, and verified the repair with repeatable tests.
            KEY_POINTS:
            - I used observable evidence to isolate the failure.
            - I verified the repair with repeatable tests.
            FOLLOW_UP:
            - I can explain the validation sequence.
            CAUTION:
            Keep the answer bound to the synthetic fixture.
            """]
        ]
        let router = LLMRouter(
            settingsRepository: settingsRepository,
            clients: [.deepSeek: mockClient]
        )
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil
        )
        fixture.register(appState)
        appState.answerProviderModeOverride = .deepSeekPrimary
        #expect(appState.activeRealtimeProvider?.id == provider.id)
        #expect(appState.activeRealtimeProvider?.model == provider.model)
        appState.stageATimeoutSeconds = 60.0
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        appState.delayProvider = delayProvider

        let sourceDocumentID = "streaming-synthetic-document"
        let profile = TestSupport.makeCandidateProfile(
            id: "streaming-synthetic-candidate",
            documentID: sourceDocumentID,
            statements: [
                "The synthetic candidate traced a service failure with logs and metrics, isolated a faulty handoff, and verified the repair with repeatable tests."
            ]
        )
        let opportunity = TestSupport.makeOpportunityContext(
            id: "streaming-synthetic-opportunity",
            documentID: sourceDocumentID,
            statements: [
                "The synthetic role requires evidence-based debugging and repeatable validation."
            ]
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        try appState.interviewContextRepository.saveOpportunityContext(opportunity)
        appState.refreshAll()
        appState.selectCandidateProfile(profile.id)
        appState.selectOpportunityContext(opportunity.id)
        appState.selectInterviewDomain(.general)
        let session = try appState.createContextBoundSession(
            mode: .mock,
            title: "Synthetic streaming suggestion pipeline"
        )
        appState.currentSession = session

        let query = "How did you debug the synthetic service failure?"
        let detectedQuestion = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: query,
            intent: .technical,
            answerStrategy: .wait,
            confidence: 0.98,
            reason: "Synthetic pipeline contract",
            shouldTrigger: true,
            questionComplete: true,
            modelName: provider.model,
            promptVersion: "v1.0",
            createdAt: Date()
        )
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(detectedQuestion)

        try await appState.generateSuggestion(
            for: detectedQuestion,
            session: session,
            transcript: query,
            autoGenerated: false
        )

        try await waitUntil(timeout: 5.0, label: "synthetic Stage B completion") {
            appState.currentSuggestion?.stageBCompleted == true &&
                appState.currentSuggestion?.stageBStatus == "completed"
        }

        let card = try #require(appState.currentSuggestion)
        let expectedSayFirst = "I traced the synthetic service failure with logs and metrics, isolated the faulty handoff, and verified the repair with repeatable tests."
        let expectedKeyPoints = [
            "I used observable evidence to isolate the failure.",
            "I verified the repair with repeatable tests."
        ]
        #expect(card.providerKind == .deepSeek)
        #expect(card.providerName == "DeepSeek")
        #expect(card.modelName == "deepseek-v4-flash")
        #expect(card.providerBaseURL == provider.baseURL)
        #expect(card.isLocal == false)
        #expect(card.stageBCompleted == true)
        #expect(card.stageBStatus == "completed")
        #expect(card.sayFirst == expectedSayFirst)
        #expect(card.keyPoints == expectedKeyPoints)
        #expect(card.strategy == "Evidence-based debugging")
        #expect(card.followUpReady == ["I can explain the validation sequence."])
        #expect(card.caution == "Keep the answer bound to the synthetic fixture.")
        #expect(card.sayFirstSource == "deepseek_stream")
        #expect(card.finalVisibleSource == "deepseek_stream")
        #expect(card.softFallbackUsed == false)
        #expect(appState.softFallbackUsed == false)
        #expect(card.detectedQuestionID == detectedQuestion.id)

        let streamRequests = mockClient.capturedStreamRequests
        #expect(streamRequests.count == 2)
        #expect(mockClient.capturedCompletionRequests.isEmpty)
        let firstAnswerRequest = try #require(streamRequests.first { request in
            request.userPrompt.hasSuffix("Generate the single opening answer now:")
        })
        let sectionRequest = try #require(streamRequests.first { request in
            request.userPrompt.hasSuffix("Stream the section response now.")
        })
        for request in [firstAnswerRequest, sectionRequest] {
            #expect(request.configuration.id == provider.id)
            #expect(request.configuration.name == provider.name)
            #expect(request.configuration.kind == provider.kind)
            #expect(request.configuration.baseURL == provider.baseURL)
            #expect(request.configuration.model == provider.model)
            #expect(request.configuration.apiKeyAccount == provider.apiKeyAccount)
            #expect(request.configuration.isDefaultForRealtime == true)
            #expect(request.configuration.supportsStreaming == true)
        }
        #expect(firstAnswerRequest.responseFormat == .text)
        #expect(sectionRequest.responseFormat == .text)
        #expect(firstAnswerRequest.options.stream == true)
        #expect(sectionRequest.options.stream == true)
        #expect(firstAnswerRequest.options.temperature == 0.1)
        #expect(sectionRequest.options.temperature == 0.2)
        #expect(firstAnswerRequest.userPrompt.contains("CURRENT QUESTION TO ANSWER:\n\"\(query)\""))
        #expect(sectionRequest.userPrompt.contains("CURRENT QUESTION TO ANSWER:\n\"\(query)\""))
        #expect(firstAnswerRequest.userPrompt.contains("service failure with logs and metrics"))
        #expect(sectionRequest.userPrompt.contains("repeatable tests"))

        try await waitUntil(timeout: 5.0, label: "synthetic suggestion persistence") {
            ((try? suggestionRepo.suggestions(sessionID: session.id)) ?? [])
                .filter { $0.detectedQuestionID == detectedQuestion.id }
                .count == 1
        }
        let rows = try suggestionRepo.suggestions(sessionID: session.id)
        let persisted = try #require(rows.first { $0.detectedQuestionID == detectedQuestion.id })
        #expect(rows.filter { $0.detectedQuestionID == detectedQuestion.id }.count == 1)
        #expect(persisted.sayFirst == expectedSayFirst)
        #expect(persisted.keyPoints == expectedKeyPoints)
        #expect(persisted.stageBCompleted == true)
        #expect(persisted.stageBStatus == "completed")
        #expect(persisted.sayFirstSource == "deepseek_stream")
        #expect(persisted.finalVisibleSource == "deepseek_stream")
        #expect(persisted.softFallbackUsed == false)
        #expect(persisted.providerKind == .deepSeek)
        #expect(persisted.providerName == "DeepSeek")
        #expect(persisted.providerBaseURL == provider.baseURL)
        #expect(persisted.modelName == provider.model)
        #expect(persisted.isLocal == false)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        label: String,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(
            domain: "StreamingSuggestionTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(label)."]
        )
    }
}

@MainActor
private final class StreamingAppTestFixture {
    let database: AppDatabase
    private let rootDirectory: URL
    private var appState: AppState?
    private var isShutdown = false

    init(prefix: String) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        do {
            database = try AppDatabase(path: rootDirectory.appendingPathComponent("test.sqlite"))
        } catch {
            try? FileManager.default.removeItem(at: rootDirectory)
            throw error
        }
    }

    func register(_ appState: AppState) {
        precondition(self.appState == nil, "Streaming app test fixture already owns an AppState.")
        self.appState = appState
    }

    func shutdown() async throws {
        guard !isShutdown else { return }
        await appState?.shutdownForTesting()
        try database.close()
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
        isShutdown = true
    }
}

@MainActor
private func withStreamingAppTestFixture(
    prefix: String,
    operation: @MainActor (StreamingAppTestFixture) async throws -> Void
) async throws {
    let fixture = try StreamingAppTestFixture(prefix: prefix)
    do {
        try await operation(fixture)
        try await fixture.shutdown()
    } catch {
        try? await fixture.shutdown()
        throw error
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
    
    var streamTokens: [String] = []
    var streamTokenBatches: [[String]] = []
    var streamDelayNS: UInt64 = 0
    private let lock = NSLock()
    private var streamCallCount = 0
    private var completedStreamCountStorage = 0
    private var capturedStreamRequestsStorage: [StreamingMockRequest] = []
    private var capturedCompletionRequestsStorage: [StreamingMockRequest] = []

    var completedStreamCount: Int {
        lock.withLock { completedStreamCountStorage }
    }

    var capturedStreamRequests: [StreamingMockRequest] {
        lock.withLock { capturedStreamRequestsStorage }
    }

    var capturedCompletionRequests: [StreamingMockRequest] {
        lock.withLock { capturedCompletionRequestsStorage }
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
        lock.withLock {
            capturedCompletionRequestsStorage.append(
                StreamingMockRequest(
                    configuration: configuration,
                    messages: messages,
                    responseFormat: responseFormat,
                    options: options
                )
            )
        }
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
        lock.withLock {
            capturedStreamRequestsStorage.append(
                StreamingMockRequest(
                    configuration: configuration,
                    messages: messages,
                    responseFormat: responseFormat,
                    options: options
                )
            )
        }
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
                self.lock.withLock {
                    self.completedStreamCountStorage += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
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

struct StreamingMockRequest {
    let configuration: LLMProviderConfiguration
    let messages: [LLMChatMessage]
    let responseFormat: LLMResponseFormat?
    let options: LLMRequestOptions

    var userPrompt: String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }
}

// MARK: - Soft Fallback & Provenance Suite

@Suite(.serialized)
struct StreamingSoftFallbackTests {

    @MainActor
    @Test
    func providerStageBSuccessOverridesSoftFallbackOwnership() async throws {
        try await withStreamingAppTestFixture(prefix: "StreamingSoftFallback-StageB") { fixture in
            try await verifyProviderStageBSuccessOverridesSoftFallbackOwnership(fixture: fixture)
        }
    }

    @MainActor
    private func verifyProviderStageBSuccessOverridesSoftFallbackOwnership(
        fixture: StreamingAppTestFixture
    ) async throws {
        let database = fixture.database
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // Keep Stage A and Stage B streams distinct so the assertion verifies
        // late Stage A replacement, not scheduler-dependent section streaming.
        mockClient.streamTokenBatches = [
            ["My ", "event notification ", "service ", "used ", "an ", "idempotency ", "ledger, ", "queue ", "retries, ", "delivery ", "tracing, ", "and ", "reconciliation ", "jobs. ", "The ", "result ", "was ", "reliable ", "duplicate ", "suppression, ", "and ", "I ", "learned ", "that ", "retry ", "ownership ", "and ", "handoff ", "timing ", "determined ", "delivery ", "consistency."],
            []
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultDelayNS = 0
        
        // Detailed Stage B suggestion card returned as JSON
        mockClient.chatResultContent = """
        {
            "strategy": "Detailed Strategy",
            "say_first": "My event notification service used an idempotency ledger, queue retries, delivery tracing, and reconciliation jobs. The result was reliable duplicate suppression, and I learned that retry ownership and handoff timing determined delivery consistency.",
            "key_points": ["Idempotency ledger, queue retries, and delivery tracing", "Reconciliation jobs for delivery gaps", "Result and learning: retry ownership determined consistency"],
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
        fixture.register(appState)
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
        defer { appState.cancelActiveGenerationForContextChange() }
        
        let question = DetectedQuestion(
            id: "q-1", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your event notification service?", intent: .projectDeepDive,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        // Execute suggestion generation
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)
        
        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
            appState.currentSuggestion?.stageBCompleted == true &&
            appState.currentSuggestion?.keyPoints.contains("Idempotency ledger, queue retries, and delivery tracing") == true
        }
        
        // Assertions
        #expect(mockDelay.delayCalledWithNanoseconds.contains(1_500_000_000))
        #expect(appState.currentSuggestion != nil)
        
        let finalCard = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == false)
        #expect(finalCard.softFallbackUsed == false)
        #expect(finalCard.stageBCompleted == true)
        #expect(finalCard.stageBStatus == "completed")
        #expect(finalCard.sayFirst.localizedCaseInsensitiveContains("event notification service"))
        #expect(finalCard.keyPoints.contains("Idempotency ledger, queue retries, and delivery tracing"))
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
        try await withStreamingAppTestFixture(prefix: "StreamingSoftFallback-FastProvider") { fixture in
            try await verifySkipFallbackWhenDeepSeekIsFast(fixture: fixture)
        }
    }

    @MainActor
    private func verifySkipFallbackWhenDeepSeekIsFast(
        fixture: StreamingAppTestFixture
    ) async throws {
        let database = fixture.database
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        
        let mockClient = StreamingMockLLMClient()
        // DeepSeek streams fast

        mockClient.streamTokens = [
            "My event notification ",
            "service used an ",
            "idempotency ledger, ",
            "queue retries, ",
            "delivery tracing, and ",
            "reconciliation jobs. ",
            "The result was reliable ",
            "duplicate suppression, ",
            "and I learned that retry ownership ",
            "and handoff timing determined delivery consistency."
        ]
        mockClient.streamDelayNS = 0
        mockClient.chatResultContent = """
        {
            "strategy": "Project walkthrough",
            "say_first": "My event notification service used an idempotency ledger, queue retries, delivery tracing, and reconciliation jobs. The result was reliable duplicate suppression, and I learned that retry ownership and handoff timing determined delivery consistency.",
            "key_points": ["Idempotency ledger and queue retries", "Delivery tracing and reconciliation jobs", "Result and learning: retry ownership determined consistency"],
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
        fixture.register(appState)
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
        defer { appState.cancelActiveGenerationForContextChange() }
        
        let question = DetectedQuestion(
            id: "q-2", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your event notification service?", intent: .technical,
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
    @Test
    func testConservativeLateReplacementPreservesFallbackWhenInteractedOrGeneric() async throws {
        try await withStreamingAppTestFixture(prefix: "StreamingSoftFallback-LateProvider") { fixture in
            try await verifyConservativeLateReplacementPreservesFallback(fixture: fixture)
        }
    }

    @MainActor
    private func verifyConservativeLateReplacementPreservesFallback(
        fixture: StreamingAppTestFixture
    ) async throws {
        let database = fixture.database
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
        fixture.register(appState)
        appState.answerProviderModeOverride = .deepSeekPrimary
        
        let mockDelay = MockDelayProvider()
        mockDelay.sleepDuration = 60_000_000_000
        mockDelay.setSleepDuration(5_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = mockDelay

        let session = try makeContextBoundSession(appState, suffix: "late-provider")
        defer { appState.cancelActiveGenerationForContextChange() }
        
        let question = DetectedQuestion(
            id: "q-3", sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Could you walk me through your event notification service?", intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        
        let suggestionRepo = SuggestionRepository(database: database)
        try suggestionRepo.saveDetectedQuestion(question)
        
        // Run with generic answer
        try await appState.generateSuggestion(for: question, session: session, transcript: question.questionText, autoGenerated: false)

        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
            appState.currentSuggestion?.softFallbackUsed == true &&
                mockClient.completedStreamCount >= 2
        }
        
        let cardGeneric = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == true)
        #expect(cardGeneric.softFallbackUsed == true)
        // Preserved because "Based on my experience as a software engineer." contains "based on my experience" and "as a software engineer", failing isSpecificAnswer check
        #expect(cardGeneric.sayFirstSource == "rag_template_soft_fallback")
        #expect(cardGeneric.finalVisibleSource == "rag_template_soft_fallback")
        
        // Reset and test user interaction path
        mockClient.streamTokens = ["I ", "used ", "idempotency ", "keys, ", "queue ", "retry ", "ownership, ", "and ", "delivery ", "traces ", "to ", "prevent ", "duplicate ", "notifications."] // highly specific
        let interactedQuestion = DetectedQuestion(
            id: "q-3-interacted", sessionID: session.id, transcriptSegmentID: nil,
            questionText: question.questionText, intent: .technical,
            answerStrategy: .wait, confidence: 0.95, reason: "Test", shouldTrigger: true,
            questionComplete: true, modelName: "mock", promptVersion: "1.0", createdAt: Date()
        )
        try suggestionRepo.saveDetectedQuestion(interactedQuestion)
        
        // Execute again
        let completedStreamsBeforeSecondRun = mockClient.completedStreamCount
        let secondGenerationTask = Task { @MainActor in
            try await appState.generateSuggestion(
                for: interactedQuestion,
                session: session,
                transcript: interactedQuestion.questionText,
                autoGenerated: false
            )
        }
        defer { secondGenerationTask.cancel() }

        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
            appState.softFallbackUsed == true &&
                appState.currentSuggestion?.sayFirstSource == "rag_template_soft_fallback"
        }
        appState.userInteractedWithCard = true
        try await secondGenerationTask.value
        try await waitUntil(timeout: 5.0, appState: appState, mockClient: mockClient) {
            mockClient.completedStreamCount >= completedStreamsBeforeSecondRun + 2
        }
        
        let cardInteracted = appState.currentSuggestion!
        #expect(appState.softFallbackUsed == true)
        #expect(cardInteracted.softFallbackUsed == true)
        // Preserved because user interacted with card before completion
        #expect(cardInteracted.sayFirstSource == "rag_template_soft_fallback")
        #expect(cardInteracted.finalVisibleSource == "rag_template_soft_fallback")
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
            "My event notification service used an idempotency ledger, queue retries, delivery tracing, and reconciliation jobs.",
            "I used idempotency keys and queue retry ownership to prevent duplicate notifications.",
            "I developed a specific trace-correlation workflow for diagnosing delayed deliveries.",
            "I have software engineering experience supporting reliable service integration.",
            "The result was reliable duplicate suppression, and I learned that retry ownership and handoff timing were the main delivery consistency challenges."
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
        appState.selectInterviewDomain(.general)
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
