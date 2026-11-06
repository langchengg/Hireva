import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct ManualLocalOnlyRequestTests {
    @Test(.timeLimit(.minutes(1)))
    func answerNowInLocalOnlyModeNeverSendsTranscriptToRemoteDetector() async throws {
        let trace = TestEventWaitTrace(label: "ManualLocalOnly")
        trace.mark("body.enter")
        defer { trace.mark("body.exit") }
        let database = try AppDatabase(inMemory: true)
        let suiteName = "com.langcheng.Hireva.tests.manual-local-only.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AnswerProviderMode.localQwenPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        let settings = SettingsRepository(database: database)
        var preferences = AppSettings.default
        preferences.saveTranscriptsLocally = false
        try settings.saveSettings(preferences)
        try settings.ensureDefaultProviderConfigurations()
        let configuration = try #require(settings.providerConfigurations().first { $0.kind == .deepSeek })
        try settings.setActiveRealtimeProvider(id: configuration.id)
        let remote = ManualPrivacyRemoteClient()
        let local = ManualPrivacyLocalProvider()
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: remote]),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: ManualPrivacyRetrieval(), dialogueDefaults: defaults)
        app.localLLMProviderOverride = local
        let clock = ControlledGenerationWatchdogClock()
        app.generationWatchdogDelayProvider = clock
        var pending: Task<Void, Never>?
        @MainActor func cleanup() async throws {
            clock.cancelAll()
            pending?.cancel()
            await pending?.value
            await app.shutdownForTesting()
            try database.close()
        }
        do {
            let question = "Explain database transactions and atomicity."
            // The existing local candidate cleaner removes a trailing period.
            // Require every word and the same exact accepted question in the
            // provider request and displayed card, while preserving raw input.
            let expectedQuestion = "Explain database transactions and atomicity"
            let candidate = try #require(SystemAudioQuestionExtractor.extract(from: question).last)
            #expect(candidate.text == expectedQuestion)
            let session = try app.createContextBoundSession(mode: .mock)
            app.currentSession = session
            // This is the existing Answer Now transcript input. No capture,
            // microphone permission, network transport, or model is involved.
            app.transcriptSegments = [TranscriptSegment(id: UUID().uuidString,
                sessionID: session.id, source: .mock, speaker: .interviewer, text: question)]
            #expect(app.selectedAnswerProviderMode == .localQwenPrimary)
            #expect(app.onboardingComplete)
            app.manualAnswerNow()
            let request = try #require(app.activeAITask)
            pending = request
            // The owning test bounds this cooperative fixture's completion;
            // cancellation still reaches and joins the actual request root.
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                await request.value
                try Task.checkCancellation()
            } onCancel: {
                request.cancel()
            }
            let requests = await local.requests()
            trace.mark("request.terminal.parser_checked")
            #expect(remote.requests().isEmpty,
                "Local-only Answer Now must not send the transcript to the remote question detector.")
            #expect(requests.count == 1)
            #expect(requests.first?.prompt.contains(expectedQuestion) == true)
            #expect(app.currentSuggestion?.questionText == expectedQuestion)
            #expect(app.currentSuggestion?.promptPrimaryQuestion == expectedQuestion)
            #expect(app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            #expect(app.currentSuggestion?.sayFirst.contains("atomic") == true)
            #expect(!app.isActionLoading(ActionID.generateAnswer))
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }
}

private final class ManualPrivacyRemoteClient: LLMClientProtocol {
    var providerKind: LLMProviderKind { .deepSeek }
    private let captured = OSAllocatedUnfairLock(initialState: [[LLMChatMessage]]())
    func requests() -> [[LLMChatMessage]] {
        captured.withLock { $0 }
    }
    private func record(_ messages: [LLMChatMessage]) {
        captured.withLock { $0.append(messages) }
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic recording transport", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        try Task.checkCancellation()
        record(messages)
        return .init(content: "{\"should_trigger\":true,\"question_complete\":true,\"question_text\":\"Explain database transactions and atomicity.\",\"intent\":\"technical\",\"answer_strategy\":\"direct_answer\",\"confidence\":0.95,\"reason\":\"Synthetic manual privacy fixture\"}",
            modelName: configuration.model, providerKind: configuration.kind,
            providerName: configuration.name, baseURL: configuration.baseURL,
            latencyMS: 0, isLocal: false, rawResponse: nil)
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        record(messages)
        return AsyncThrowingStream { $0.finish(throwing: LLMProviderError.notConfigured("Synthetic remote streaming is prohibited in local-only mode")) }
    }
}

private actor ManualPrivacyLocalProvider: LocalLLMProvider {
    nonisolated var id: String { "manual-privacy-local" }
    nonisolated var displayName: String { id }
    private var captured: [LocalLLMRequest] = []
    func requests() -> [LocalLLMRequest] { captured }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        try Task.checkCancellation()
        captured.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private struct ManualPrivacyRetrieval: ContextRetrievalService {
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
