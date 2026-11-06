import Foundation
import os
import Testing
@testable import Hireva

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualRequestSnapshotTests {
    @Test
    func answerFallbackOfLocallyRejectedManualQuestionNeverCallsRemoteDetection() async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            let incomplete = "Explain database transactions and"
            #expect(SystemAudioQuestionExtractor.extract(from: incomplete, allowContextDependent: true).isEmpty)
            fixture.setTranscript(incomplete)
            fixture.app.manualAnswerNow()
            let original = try #require(fixture.app.activeAITask)
            pending.append(original)
            try await fixture.join(original)
            #expect(fixture.app.latestActionFeedback(for: ActionID.generateAnswer)?.kind == .error)
            #expect(fixture.remote.requests().isEmpty)
            #expect(fixture.app.currentSuggestion == nil)

            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let retry = try #require(fixture.app.activeAITask)
            pending.append(retry)
            try await fixture.join(retry)

            #expect(fixture.remote.requests().isEmpty,
                "Answer Fallback must preserve local-only when the local detector rejected an incomplete prompt.")
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.app.currentSuggestion == nil)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test(arguments: [ManualEntry.answerNow, .capture])
    func entryFreezesLocalProviderModelAndQuestionBeforeRootTaskRuns(entry: ManualEntry) async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            let text = "Explain database transactions and atomicity."
            fixture.setTranscript(text)
            switch entry {
            case .answerNow:
                fixture.app.manualAnswerNow()
                pending.append(try #require(fixture.app.activeAITask))
            case .capture:
                // Use the actual Generate button path with reviewed synthetic
                // text. No recorder or shared transcription mock is started.
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = text
                fixture.app.sendManualCaptureToAI()
                pending.append(try #require(fixture.app.stageBTask))
            }
            // This MainActor test has not suspended since the entry call, so
            // the owned provider/root task cannot have consumed configuration.
            fixture.app.setSelectedQwenModelName("replacement-manual-model")
            fixture.app.localLLMProviderOverride = fixture.replacement
            fixture.setTranscript("Explain database isolation and concurrency.")
            fixture.app.manualCaptureTranscript = "Explain database isolation and concurrency."
            try await fixture.join(try #require(pending.last))

            let originalRequests = await fixture.original.requests()
            #expect(originalRequests.count == 1)
            #expect(originalRequests.first?.modelName == fixture.originalModel)
            #expect(originalRequests.first?.prompt.contains("Explain database transactions and atomicity") == true)
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(fixture.app.currentSuggestion?.questionText == (entry == .answerNow
                ? "Explain database transactions and atomicity" : text))
            #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
            #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            if entry == .capture {
                #expect(fixture.app.manualCaptureState == .suggestionReady)
                #expect(fixture.app.manualCaptureSuggestion == fixture.app.currentSuggestion)
            }
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func answerNowCapturesVisibleParentBeforeAnotherCardArrives() async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            let original = fixture.parent(id: "original-parent", answer: "Use bounded retries for transient transaction failures.")
            fixture.app.currentSuggestion = original
            fixture.app.manualAnswerNow()
            pending.append(try #require(fixture.app.activeAITask))
            fixture.app.currentSuggestion = fixture.parent(id: "later-parent", answer: "A new visible answer must not become the earlier request's parent.")
            try await fixture.join(try #require(pending.last))

            let parent = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContext)
            #expect(parent.questionID == original.questionID)
            #expect(parent.questionText == original.questionText)
            #expect(parent.answerText == original.sayFirst)
            #expect(parent.contextSnapshotID == original.contextSnapshotID)
            #expect(parent.sessionID == fixture.session.id)
            #expect(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContextCaptured == true)
            #expect(fixture.remote.requests().isEmpty)
            #expect(await fixture.original.requests().count == 1)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test(arguments: [Invalidation.mode, .context])
    func userPolicyChangeCancelsQueuedManualRequestWithoutPublishing(change: Invalidation) async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            fixture.app.manualAnswerNow()
            let request = try #require(fixture.app.activeAITask)
            pending.append(request)
            switch change {
            case .mode: fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
            case .context: fixture.app.selectInterviewDomain(.roboticsResearch)
            }
            #expect(request.isCancelled)
            try await fixture.join(request)
            #expect(fixture.remote.requests().isEmpty)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.app.currentSuggestion == nil)
            #expect(fixture.app.currentGenerationID == nil)
            #expect(!fixture.app.isActionLoading(ActionID.generateAnswer))
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    enum ManualEntry: String { case answerNow, capture }
    enum Invalidation: String { case mode, context }
}

@MainActor
final class ManualSnapshotFixture {
    let database: AppDatabase
    let defaults: UserDefaults
    let suiteName = "com.langcheng.Hireva.tests.manual-snapshot.\(UUID().uuidString)"
    let originalModel = "original-manual-model"
    let remote: ManualSnapshotRemoteClient
    let original: ManualSnapshotLocalProvider
    let replacement = ManualSnapshotLocalProvider(id: "replacement-manual-provider")
    let app: AppState
    let clock = ControlledGenerationWatchdogClock()
    let session: InterviewSession
    private struct JoinReceipt {
        let root: Task<Void, Never>
        let observer: Task<Void, Never>
    }
    private var joinReceipts: [JoinReceipt] = []

    init(mode: AnswerProviderMode = .localQwenPrimary,
         useAnswerProviderForRouting: Bool = false,
         retrieval: any ContextRetrievalService = ManualSnapshotRetrieval(),
         configuredManualAnswer: String? = nil, trace: TestEventWaitTrace? = nil) async throws {
        original = ManualSnapshotLocalProvider(id: "original-manual-provider", trace: trace)
        remote = ManualSnapshotRemoteClient(completeQuestion: mode != .localQwenPrimary,
            configuredManualAnswer: configuredManualAnswer, trace: trace)
        // These request/admission tests use an independent real SQLite queue;
        // no caller depends on file durability or a second connection.
        database = try await TestSupport.makeInMemoryDatabase()
        do {
            defaults = try #require(UserDefaults(suiteName: suiteName))
        } catch {
            try? database.close()
            throw error
        }
        var initializedApp: AppState?
        do {
            defaults.set(mode.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
            defaults.set(originalModel, forKey: HirevaPreferenceKeys.selectedQwenModel)
            let repository = SettingsRepository(database: database)
            var settings = AppSettings.default
            settings.saveTranscriptsLocally = false
            try repository.saveSettings(settings)
            try repository.ensureDefaultProviderConfigurations()
            let configuration = try #require(repository.providerConfigurations().first { $0.kind == .deepSeek })
            try repository.setActiveRealtimeProvider(id: configuration.id)
            let instance = AppState(database: database, questionRoutingProvider: useAnswerProviderForRouting ? nil : HermeticQuestionRoutingProvider(),
                llmRouter: LLMRouter(settingsRepository: repository, clients: [.deepSeek: remote]),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                contextRetrievalService: retrieval, dialogueDefaults: defaults)
            initializedApp = instance
            instance.generationWatchdogDelayProvider = clock
            instance.localLLMProviderOverride = original
            session = try instance.createContextBoundSession(mode: .mock)
            instance.currentSession = session
            app = instance
        } catch {
            await initializedApp?.shutdownForTesting()
            defaults.removePersistentDomain(forName: suiteName)
            try? database.close()
            throw error
        }
    }

    func setTranscript(_ text: String) {
        app.transcriptSegments = [.init(id: UUID().uuidString, sessionID: session.id,
            source: .mock, speaker: .interviewer, text: text)]
    }

    func parent(id: String, answer: String) -> SuggestionCard {
        var card = SuggestionCard(id: id + "-card", sessionID: session.id, questionID: id,
            strategy: "Explanation", sayFirst: answer, keyPoints: [], followUpReady: [],
            confidence: 1, caution: nil, evidenceUsed: [], riskLevel: .low,
            modelName: "synthetic-parent", promptVersion: "synthetic-parent", rawJSON: nil, createdAt: Date())
        card.questionText = "Compare retry strategies for transient requests."
        card.contextSnapshotID = session.contextSnapshotID
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        return card
    }

    func join(_ task: Task<Void, Never>, onWaitEntered: (@Sendable () -> Void)? = nil) async throws {
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let trace = TestEventWaitTrace(label: "ManualSnapshotFixture.join")
        let observer = Task {
            await task.value
            trace.mark("producer.root_completed")
            completion.continuation.yield(())
            completion.continuation.finish()
        }
        // Retain ownership before cancellation can throw. A cancelled wait must
        // reach the caller's catch so it can release its noncooperative latch;
        // close still joins the actual root and its completion observer.
        joinReceipts.append(JoinReceipt(root: task, observer: observer))
        try await withTaskCancellationHandler {
            onWaitEntered?()
            _ = try await trace.nextEvent(in: completion.stream, event: "root_completed")
            await observer.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
            completion.continuation.finish()
        }
    }

    func close(_ tasks: [Task<Void, Never>]) async throws {
        clock.cancelAll()
        let roots = tasks + joinReceipts.map(\.root)
        roots.forEach { $0.cancel() }
        for task in roots { await task.value }
        await app.shutdownForTesting()
        for receipt in joinReceipts { await receipt.observer.value }
        joinReceipts.removeAll()
        try database.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

actor ManualSnapshotLocalProvider: LocalLLMProvider {
    nonisolated let id: String
    nonisolated var displayName: String { id }
    private var captured: [LocalLLMRequest] = []
    private let trace: TestEventWaitTrace?
    init(id: String, trace: TestEventWaitTrace? = nil) { self.id = id; self.trace = trace }
    func requests() -> [LocalLLMRequest] { captured }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .ollamaQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        try Task.checkCancellation()
        captured.append(request)
        trace?.mark("provider.answer.started.local")
        let answer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."
        let output = request.responseSchema == LocalQwenAnswerParser.scopedResponseSchema
            ? try TestSupport.scriptedLocalAnswer(answer, request: request)
            : request.responseSchema == nil ? answer
            : "{\"task\":\"generalKnowledge\",\"personalEvidence\":\"notRequired\",\"basis\":\"generalKnowledge\",\"relation\":\"independent\",\"clarification\":\"\"}"
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

final class ManualSnapshotRemoteClient: LLMClientProtocol {
    var providerKind: LLMProviderKind { .deepSeek }
    private let completeQuestion: Bool
    private let configuredManualAnswer: String?
    private let trace: TestEventWaitTrace?
    private struct State: Sendable {
        var captured: [[LLMChatMessage]] = []
        var configurations: [LLMProviderConfiguration] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(completeQuestion: Bool, configuredManualAnswer: String? = nil, trace: TestEventWaitTrace? = nil) {
        self.completeQuestion = completeQuestion
        self.configuredManualAnswer = configuredManualAnswer
        self.trace = trace
    }
    func requests() -> [[LLMChatMessage]] { state.withLock { $0.captured } }
    func providerConfigurations() -> [LLMProviderConfiguration] { state.withLock { $0.configurations } }
    private func record(_ messages: [LLMChatMessage], configuration: LLMProviderConfiguration) {
        state.withLock { state in
            state.captured.append(messages)
            state.configurations.append(configuration)
        }
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage], responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        try Task.checkCancellation()
        record(messages, configuration: configuration)
        let complete = "{\"should_trigger\":true,\"question_complete\":true,\"question_text\":\"Explain database transactions and atomicity.\",\"intent\":\"technical\",\"answer_strategy\":\"direct_answer\",\"confidence\":0.95,\"reason\":\"Synthetic complete prompt\"}"
        let incomplete = "{\"should_trigger\":false,\"question_complete\":false,\"question_text\":\"Explain database transactions and\",\"intent\":\"technical\",\"answer_strategy\":\"wait\",\"confidence\":0.2,\"reason\":\"Synthetic incomplete prompt\"}"
        return .init(content: configuredManualAnswer ?? (completeQuestion ? complete : incomplete),
            modelName: configuration.model, providerKind: configuration.kind, providerName: configuration.name,
            baseURL: configuration.baseURL, latencyMS: 0, isLocal: false, rawResponse: nil)
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage], responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        record(messages, configuration: configuration)
        trace?.mark("provider.answer.started.remote")
        guard completeQuestion else {
            return AsyncThrowingStream { $0.finish(throwing: LLMProviderError.notConfigured("Unexpected remote stream in local-only fixture")) }
        }
        let answer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."
        let output = messages.contains { $0.content.contains("SAY_FIRST") }
            ? "STRATEGY: Explanation\nSAY_FIRST: \(answer)\nKEY_POINTS:\n- Commit or roll back atomically.\nFOLLOW_UP_READY:\n- I can explain isolation levels next.\nCAUTION:\n" : answer
        return AsyncThrowingStream { $0.yield(output); $0.finish() }
    }
}

private struct ManualSnapshotRetrieval: ContextRetrievalService {
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int, maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [], excludedCVChunks: [], excludedJDChunks: [],
                cvWordsUsed: 0, jdWordsUsed: 0, cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
