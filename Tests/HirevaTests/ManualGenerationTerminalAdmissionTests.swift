import Combine
import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct ManualGenerationTerminalAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: ManualTerminalOutcome.allCases, [false, true])
    fileprivate func actualManualJSONTerminalCannotFinishSubscriberReplacement(outcome: ManualTerminalOutcome,
                                                                             replaceAtTerminal: Bool) async throws {
        try await withApplication(outcome: outcome) { app, session, client, clock in
            let text = "Explain database transactions and atomicity."
            app.manualCaptureState = .transcriptReady
            app.manualCaptureTranscript = text
            app.sendManualCaptureToAI(forceDeepSeek: true)
            let caller = try #require(app.stageBTask)
            let originalID = try #require(app.currentGenerationID)
            let originalQuestionID = try #require(app.activeQuestionID)
            let replacementID = UUID().uuidString
            let replacement = DetectedQuestion(id: UUID().uuidString, sessionID: session.id,
                transcriptSegmentID: nil, questionText: "Explain transaction isolation and visibility.",
                intent: .technical, answerStrategy: .technicalExplanation, confidence: 0.99,
                reason: "Synthetic manual terminal replacement", shouldTrigger: true, questionComplete: true,
                modelName: "synthetic-no-provider", promptVersion: "synthetic-no-provider", createdAt: Date())
            var replaced = false
            var replacementRoot: Task<Void, Never>?
            var replacementAnswer: Task<String, Error>?
            var admittedOriginal: SuggestionCard?
            let observation = app.generationCoordinator.objectWillChange.sink { _ in
                guard replaceAtTerminal, !replaced,
                      app.terminalGenerationIDs.contains(originalID) else { return }
                replaced = true
                admittedOriginal = app.currentSuggestion
                app.startGenerationRequest(triggerPath: .regenerate) { _ in }
                replacementRoot = app.activeAITask
                guard let requestID = app.generationCoordinator.activeRequest?.id else {
                    Issue.record("The terminal subscriber must own its replacement request")
                    return
                }
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                    speaker: .unknown, requestID: requestID)
                let answer = Task<String, Error> { "Finite Q2-owned answer" }
                replacementAnswer = answer
                app.registerStageATask(answer, generationID: replacementID)
                app.lastDetectedQuestion = replacement
                app.manualCaptureState = .generatingSuggestion
                app.manualCaptureSuggestion = nil
                app.beginAction(ActionID.manualGenerate, title: "Synthetic replacement pending", message: "Synthetic Q2 work")
            }
            @MainActor func releaseAndJoin() async {
                observation.cancel()
                clock.cancelAll()
                await caller.value
                await replacementRoot?.value
                _ = await replacementAnswer?.result
                await app.generationCoordinator.drainRetiredTasks()
            }
            do {
                await caller.value
                observation.cancel()
                #expect(client.callCount == 1, "The actual Manual JSON service consumed the submitted fake transport")
                #expect(app.terminalGenerationIDs.contains(originalID))
                if replaceAtTerminal {
                    #expect(replaced)
                    #expect(app.currentGenerationID == replacementID)
                    #expect(app.activeQuestionID == replacement.id)
                    #expect(app.lastDetectedQuestion?.id == replacement.id)
                    #expect(app.manualCaptureState == .generatingSuggestion)
                    #expect(app.manualCaptureSuggestion == nil)
                    #expect(app.currentSuggestion == nil)
                    #expect(app.currentGenerationTelemetry.generationID == replacementID)
                    #expect(app.currentGenerationTelemetry.failureReason == nil)
                    #expect(app.generationUIState == .preparing(questionID: replacement.id,
                        generationID: replacementID, triggerPath: .regenerate))
                    #expect(app.isActionLoading(ActionID.manualGenerate),
                        "A completed Q1 caller cannot clear Q2's actual manual loading fact")
                    #expect(app.generationCoordinator.stageATask == replacementAnswer)
                    #expect(replacementAnswer?.isCancelled == false)
                } else {
                    #expect(!replaced)
                    #expect(!app.isActionLoading(ActionID.manualGenerate))
                    if outcome == .success {
                        #expect(app.manualCaptureState == .suggestionReady)
                        #expect(app.currentSuggestion?.sayFirst == ManualTerminalClient.answer)
                        #expect(app.manualCaptureSuggestion == app.currentSuggestion)
                    } else {
                        guard case .suggestionError = app.manualCaptureState else {
                            Issue.record("The controlled normal provider failure must remain a manual error")
                            await releaseAndJoin()
                            return
                        }
                        #expect(app.currentSuggestion == nil)
                    }
                }
                await releaseAndJoin()
                let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
                if outcome == .success {
                    #expect(saved.count == 1,
                        "The qualified Q1 card remains valid history when terminal publication synchronously admits Q2")
                    #expect(saved.first?.generationID == originalID)
                    #expect(saved.first?.detectedQuestionID == originalQuestionID)
                    #expect(saved.first?.sayFirst == ManualTerminalClient.answer)
                    if replaceAtTerminal {
                        #expect(admittedOriginal?.generationID == originalID)
                        #expect(admittedOriginal?.sayFirst == ManualTerminalClient.answer,
                            "Historical admission must originate from the real validated Q1 card")
                    }
                } else {
                    #expect(saved.isEmpty, "A controlled transport failure is not a successful answer")
                }
                app.generationCoordinator.invalidateAndCancel()
                await app.generationCoordinator.drainRetiredTasks()
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            } catch {
                await releaseAndJoin()
                throw error
            }
        }
    }

    private func withApplication(outcome: ManualTerminalOutcome,
        operation: @MainActor (AppState, InterviewSession, ManualTerminalClient, ControlledGenerationWatchdogClock) async throws -> Void
    ) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.manual-terminal." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(AnswerProviderMode.deepSeekPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        let repository = SettingsRepository(database: database)
        var settings = AppSettings.default
        settings.saveTranscriptsLocally = true
        try repository.saveSettings(settings)
        try repository.ensureDefaultProviderConfigurations()
        let configuration = try #require(repository.providerConfigurations().first { $0.kind == .deepSeek })
        try repository.setActiveRealtimeProvider(id: configuration.id)
        let client = ManualTerminalClient(outcome: outcome)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: repository, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: ManualTerminalRetrieval(), verificationMocksEnabled: false,
            dialogueDefaults: defaults, embeddingProviderResolverOverride: { _ in nil })
        let clock = ControlledGenerationWatchdogClock()
        app.delayProvider = clock
        app.generationWatchdogDelayProvider = clock
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic manual terminal")
            app.currentSession = session
            try await operation(app, session, client, clock)
            clock.cancelAll()
            await app.shutdownForTesting()
            try database.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            clock.cancelAll()
            await app.shutdownForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }
}

fileprivate enum ManualTerminalOutcome: Equatable, CaseIterable, Sendable { case success, providerFailure }

fileprivate final class ManualTerminalClient: LLMClientProtocol {
    let outcome: ManualTerminalOutcome
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { calls.withLock { $0 } }
    var providerKind: LLMProviderKind { .deepSeek }
    static let answer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."
    init(outcome: ManualTerminalOutcome) { self.outcome = outcome }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic transport", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
                        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        try Task.checkCancellation()
        calls.withLock { $0 += 1 }
        if outcome == .providerFailure { throw LLMProviderError.invalidResponse("Controlled manual provider failure") }
        let payload = "{\"strategy\":\"Explanation\",\"say_first\":\"" + Self.answer + "\",\"key_points\":[],\"follow_up_ready\":[],\"confidence\":0.95,\"caution\":null,\"evidence_used\":[],\"risk_level\":\"low\"}"
        return .init(content: payload, modelName: configuration.model, providerKind: configuration.kind,
            providerName: configuration.name, baseURL: configuration.baseURL, latencyMS: 0,
            isLocal: false, rawResponse: nil)
    }
}

fileprivate struct ManualTerminalRetrieval: ContextRetrievalService {
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
                                 maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [], excludedCVChunks: [], excludedJDChunks: [],
                cvWordsUsed: 0, jdWordsUsed: 0, cvWordBudget: maxCVWords, jdWordBudget: maxJDWords,
                retrievalLatencyMS: 0, emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
