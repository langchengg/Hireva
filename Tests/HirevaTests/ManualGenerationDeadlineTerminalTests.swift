import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct ManualGenerationDeadlineTerminalTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func manualDeadlinesCannotChangeTheirSameIdentityAfterTheActualWorkerFailed(order: Int) async throws {
        // Preserve fallback/full-card order for each of ten joined repetitions.
        // This is ownership coverage, not a model or routing quality holdout.
        let role = DeadlineRole.allCases[order % DeadlineRole.allCases.count]
        let repetition = order / DeadlineRole.allCases.count
        try await exercise(role: role, repetition: repetition)
    }

    private func exercise(role: DeadlineRole, repetition: Int) async throws {
        let suite = "ManualDeadlineTerminal-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase(inMemory: true)
        let clock = ManualDeadlineIgnoringCancellationClock()
        let retrieval = ManualDeadlineFailingRetrieval()
        var app: AppState?
        var fallback: Task<Void, Never>?
        var full: Task<Void, Never>?
        var provider: Task<Void, Never>?
        do {
            let settings = SettingsRepository(database: database)
            try settings.ensureDefaultProviderConfigurations()
            let config = try #require(try settings.providerConfigurations().first { $0.kind == .deepSeek })
            try settings.setActiveRealtimeProvider(id: config.id)
            let state = AppState(database: database,
                questionRoutingProvider: HermeticQuestionRoutingProvider(),
                llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: ManualDeadlineNoNetworkClient()]),
                permissionService: HermeticPermissionService(),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                contextRetrievalService: retrieval, dialogueDefaults: defaults)
            app = state
            state.answerProviderModeOverride = .deepSeekPrimary
            if role == .fallback {
                state.delayProvider = clock
                state.generationWatchdogDelayProvider = ManualDeadlineCooperativeClock()
            } else {
                state.delayProvider = ManualDeadlineCooperativeClock()
                state.generationWatchdogDelayProvider = clock
            }
            let session = try makeContextSession(state, suffix: "\(role.rawValue)-\(repetition)")
            state.currentSession = session
            state.manualCaptureState = .transcriptReady
            state.manualCaptureTranscript = "Why do you want this role?"
            let fullPeriod = state.generationFullCardWatchdogNanoseconds
            state.sendManualCaptureToAI()
            let requiredFallbackDeadline: Task<Void, Never> = try #require(state.softFallbackTask)
            fallback = requiredFallbackDeadline
            let requiredFullDeadline: Task<Void, Never> = try #require(state.fullCardWatchdogTask)
            full = requiredFullDeadline
            let requiredProviderWorker: Task<Void, Never> = try #require(state.stageBTask)
            provider = requiredProviderWorker
            let identity = try #require(state.activeGenerationController?.identity)
            try await retrieval.waitUntilStarted()
            try await clock.waitUntilStarted()
            #expect(await clock.requestedNanoseconds() == [role == .fallback ? 1_500_000_000 : fullPeriod])
            try #require(state.lastDetectedQuestion?.taskDescriptor?.decision != nil)
            try #require(state.lastDetectedQuestion?.id == identity.acceptedQuestionID)
            try #require(state.manualCaptureSuggestion == nil)

            // Fail through the actual Manual provider worker's catch. The
            // registered deadline is cancelled by markGenerationFailed.
            await retrieval.releaseFailure()
            await provider?.value
            try #require(state.generationUIState.isTerminal)
            try #require(state.terminalGenerationIDs.contains(identity.generationID))
            try #require(state.manualCaptureState == .suggestionError("Provider returned an invalid response: Synthetic manual retrieval failure"))
            #expect(fallback?.isCancelled == true)
            #expect(full?.isCancelled == true)
            let delayed = role == .fallback ? fallback : full
            let other = role == .fallback ? full : fallback
            await other?.value
            let card = state.currentSuggestion
            let manualCard = state.manualCaptureSuggestion
            let manualState = state.manualCaptureState
            let ui = state.generationUIState
            let telemetry = state.currentGenerationTelemetry
            let source = state.finalVisibleSource
            let feedback = state.activeActionFeedbacks
            let events = state.recentTranscriptRuntimeEvents
            let callbackDiscards = state.staleCallbackDiscardCount
            let answerDiscards = state.staleAnswerDiscardCount
            let stored = try state.suggestionRepository.suggestions(sessionID: session.id)
            #expect(stored.isEmpty)
            // Release the actual cancelled deadline's noncooperative delay and
            // join that task before observing its publication effects.
            await clock.release()
            await delayed?.value
            #expect(state.currentSuggestion == card)
            #expect(state.manualCaptureSuggestion == manualCard)
            #expect(state.manualCaptureState == manualState)
            #expect(state.generationUIState == ui)
            #expect(state.currentGenerationTelemetry == telemetry)
            #expect(state.finalVisibleSource == source)
            #expect(state.activeActionFeedbacks == feedback)
            #expect(state.recentTranscriptRuntimeEvents == events)
            #expect(state.staleCallbackDiscardCount == callbackDiscards)
            #expect(state.staleAnswerDiscardCount == answerDiscards)
            #expect(!state.isActionLoading(ActionID.manualGenerate))
            #expect(try state.suggestionRepository.suggestions(sessionID: session.id) == stored)
            await state.shutdownForTesting()
            #expect(state.generationCoordinator.pendingCleanupTaskCount == 0)
            try database.close()
        } catch {
            fallback?.cancel(); full?.cancel(); provider?.cancel()
            await retrieval.releaseFailure(); await clock.release()
            await fallback?.value; await full?.value; await provider?.value
            await app?.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    enum ManualFallbackPublication: String, CaseIterable, Sendable { case card, timestamp }

    /// Actual reviewed-transcript submission, route, retained deadline and UI
    /// setter. The held retriever prevents an answer/provider from masking it.
    @Test(.timeLimit(.minutes(1)), arguments: ManualFallbackPublication.allCases)
    func actualManualFirstFallbackCannotOverwriteReentrantReplacement(
        point: ManualFallbackPublication
    ) async throws {
        try await exerciseManualDeadlinePublication(point: point, deadline: .fallback)
    }

    /// The eight-second callback publishes its firstVisibleStateSetAt timestamp,
    /// rather than the first-fallback currentSuggestionSetAt field.
    @Test(.timeLimit(.minutes(1)), arguments: ManualFallbackPublication.allCases)
    func actualManualFullDeadlineCannotOverwriteReentrantReplacement(
        point: ManualFallbackPublication
    ) async throws {
        try await exerciseManualDeadlinePublication(point: point, deadline: .fullCard)
    }

    private func exerciseManualDeadlinePublication(
        point: ManualFallbackPublication, deadline: DeadlineRole
    ) async throws {
        let suite = "ManualDeadlinePublication-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let database = try AppDatabase(inMemory: true)
        let clock = ManualDeadlineIgnoringCancellationClock()
        let replacementClock = ManualDeadlineIgnoringCancellationClock()
        let retrieval = ManualDeadlineFailingRetrieval()
        var app: AppState?
        var root: Task<Void, Never>?
        var fallback: Task<Void, Never>?
        var replacementTimer: Task<Void, Never>?
        var otherDeadline: Task<Void, Never>?
        var observation: AnyCancellable?
        @MainActor func cleanup() async {
            observation?.cancel()
            root?.cancel(); fallback?.cancel(); replacementTimer?.cancel(); otherDeadline?.cancel()
            await clock.release(); await replacementClock.release(); await retrieval.releaseFailure()
            await root?.value; await fallback?.value; await replacementTimer?.value; await otherDeadline?.value
            await app?.shutdownForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
        }
        do {
            let settings = SettingsRepository(database: database)
            try settings.ensureDefaultProviderConfigurations()
            let config = try #require(try settings.providerConfigurations().first { $0.kind == .deepSeek })
            try settings.setActiveRealtimeProvider(id: config.id)
            let state = AppState(database: database,
                questionRoutingProvider: HermeticQuestionRoutingProvider(),
                llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: ManualDeadlineNoNetworkClient()]),
                permissionService: HermeticPermissionService(),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                contextRetrievalService: retrieval, dialogueDefaults: defaults)
            app = state
            state.answerProviderModeOverride = .deepSeekPrimary
            state.delayProvider = deadline == .fallback ? clock : ManualDeadlineCooperativeClock()
            state.generationWatchdogDelayProvider = deadline == .fullCard ? clock : ManualDeadlineCooperativeClock()
            let session = try makeContextSession(state, suffix: deadline.rawValue + "-" + point.rawValue)
            state.currentSession = session
            state.manualCaptureState = .transcriptReady
            state.manualCaptureTranscript = "Why do you want this role?"
            state.sendManualCaptureToAI()
            let workflow = try #require(state.stageBTask)
            root = workflow
            let originalFallback = try #require(deadline == .fallback ? state.softFallbackTask : state.fullCardWatchdogTask)
            fallback = originalFallback
            otherDeadline = deadline == .fallback ? state.fullCardWatchdogTask : state.softFallbackTask
            let owner = state.generationCoordinator
            let original = try #require(owner.activeGeneration?.identity)
            try await retrieval.waitUntilStarted()
            try await clock.waitUntilStarted()
            try #require(state.lastDetectedQuestion?.taskDescriptor?.decision != nil)
            try #require(owner.activeGeneration?.questionSnapshot?.taskDescriptor?.decision != nil)
            #expect(await clock.requestedNanoseconds() == [deadline == .fallback ? 1_500_000_000 : state.generationFullCardWatchdogNanoseconds])
            let replacement = GenerationIdentity(acceptedQuestionID: original.acceptedQuestionID,
                generationID: original.generationID, sessionID: original.sessionID,
                questionText: original.questionText, normalizedQuestionText: original.normalizedQuestionText,
                questionIntent: original.questionIntent, promptPrimaryQuestion: original.promptPrimaryQuestion,
                ingressIdentity: original.ingressIdentity,
                contextSnapshotID: "synthetic-manual-deadline-replacement-" + deadline.rawValue + "-" + point.rawValue)
            let marker = "Synthetic replacement at manual " + deadline.rawValue + ": " + point.rawValue
            let time = Date(timeIntervalSince1970: 818)
            let feedback = ActionFeedback(actionID: ActionID.manualGenerate, title: marker,
                message: "Replacement-owned manual feedback.", kind: .loading)
            var replaced = false
            @MainActor func replace() {
                guard !replaced else { return }
                replaced = true
                owner.activate(identity: replacement, persistenceTicket: 2,
                    triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                let timer = Task<Void, Never> {
                    _ = try? await replacementClock.sleep(nanoseconds: 2_500_000_000)
                }
                replacementTimer = timer
                state.registerFallbackWatchdogTask(timer, generationID: replacement.generationID)
                state.generationUIState = .idle
                state.currentSuggestion = nil
                state.manualCaptureSuggestion = nil
                state.manualCaptureState = .generatingSuggestion
                state.currentSuggestionSetAt = time
                state.softFallbackUsed = false
                state.softFallbackLatencyMS = 828
                state.softFallbackShownAt = time
                state.finalVisibleSource = marker
                state.firstVisibleStateSetAt = time
                state.actionLoadingStates[ActionID.manualGenerate] = true
                state.activeActionFeedbacks = [feedback]
                state.actionFeedbackDismissTasks[ActionID.manualGenerate]?.cancel()
                state.actionFeedbackDismissTasks[ActionID.manualGenerate] = nil
            }
            switch point {
            case .card:
                observation = state.liveInterview.suggestionUpdates.dropFirst().sink { value in
                    if value?.generationID == original.generationID { replace() }
                }
            case .timestamp:
                let timestamp = deadline == .fallback
                    ? state.currentSuggestionSetAtUpdates : state.firstVisibleStateSetAtUpdates
                observation = timestamp.dropFirst().sink { value in
                    if value != nil { replace() }
                }
            }
            await clock.release()
            await originalFallback.value
            observation?.cancel(); observation = nil
            let retained = try #require(replacementTimer)
            #expect(replaced && originalFallback.isCancelled)
            #expect(owner.canPublish(replacement) && owner.fallbackWatchdogTask == retained && !retained.isCancelled)
            #expect(state.generationUIState == .idle && state.currentSuggestion == nil)
            #expect(state.manualCaptureState == .generatingSuggestion && state.manualCaptureSuggestion == nil)
            #expect(state.currentSuggestionSetAt == time && state.softFallbackShownAt == time)
            #expect(!state.softFallbackUsed && state.softFallbackLatencyMS == 828 && state.finalVisibleSource == marker)
            #expect(state.firstVisibleStateSetAt == time)
            #expect(state.isActionLoading(ActionID.manualGenerate) && state.activeActionFeedbacks == [feedback])
            #expect(state.actionFeedbackDismissTasks[ActionID.manualGenerate] == nil)
            #expect(try state.suggestionRepository.suggestions(sessionID: session.id).isEmpty)
            await cleanup()
            #expect(owner.pendingCleanupTaskCount == 0)
        } catch {
            await cleanup()
            throw error
        }
    }

    private func makeContextSession(_ app: AppState, suffix: String) throws -> InterviewSession {
        let source = "manual-deadline-synthetic-source"
        // Same declared synthetic profile facts as the established fallback
        // tests. No real recordings, candidate documents or external calls.
        let rows: [(String, String, EvidenceType)] = [
            ("project", "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.", .project),
            ("role", "I want this role because it connects my robotics, AI, perception, and real-world deployment experience with the team's product direction.", .goal),
            ("integration", "I integrated robot perception, localisation, navigation, and manipulation through ROS2.", .experience),
            ("result", "The LeoRover project result was a complete perception-to-action pipeline on a real robot, and I learned that localisation and timing made integration the main reliability challenge.", .project)
        ]
        let evidence = rows.map { id, statement, type in ProfileEvidence(
            id: suffix + "-" + id, statement: statement, sourceDocumentID: source,
            sourceChunkID: id, sourceSpan: statement, confidence: 1,
            evidenceType: type, explicitness: .explicit) }
        let profileID = "manual-deadline-profile-" + suffix
        try app.interviewContextRepository.saveCandidateProfile(.init(id: profileID,
            displayName: "Synthetic Manual Deadline Candidate", sourceDocumentIDs: [source],
            education: [], experience: [evidence[2]], projects: [evidence[0], evidence[3]],
            skills: [], publications: [], achievements: [], declaredGaps: [], goals: [evidence[1]],
            generatedSummary: nil, version: 1, updatedAt: Date(timeIntervalSince1970: 1)))
        app.refreshAll(); app.selectCandidateProfile(profileID); app.selectInterviewDomain(.roboticsResearch)
        return try app.createContextBoundSession(mode: .mock, title: "Synthetic manual deadline")
    }

    private enum DeadlineRole: String, CaseIterable { case fallback, fullCard }
}

private actor ManualDeadlineFailingRetrieval: ContextRetrievalService {
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async throws {
        _ = try await TestEventWaitTrace(label: "manual_deadline.retrieval").nextEvent(in: started.stream, event: "registered")
    }
    func releaseFailure() { released = true; waiter?.resume(); waiter = nil }
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        started.continuation.yield(()); started.continuation.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
        throw LLMProviderError.invalidResponse("Synthetic manual retrieval failure")
    }
}

private actor ManualDeadlineIgnoringCancellationClock: DelayProvider {
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var calls: [UInt64] = []
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func sleep(nanoseconds: UInt64) async throws {
        calls.append(nanoseconds); started.continuation.yield(()); started.continuation.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilStarted() async throws {
        _ = try await TestEventWaitTrace(label: "manual_deadline.clock").nextEvent(in: started.stream, event: "registered")
    }
    func requestedNanoseconds() -> [UInt64] { calls }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private struct ManualDeadlineCooperativeClock: DelayProvider {
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

private final class ManualDeadlineNoNetworkClient: LLMClientProtocol, Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        Issue.record("Manual retrieval failure fixture unexpectedly attempted a connection"); throw CancellationError()
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        Issue.record("Manual retrieval failure fixture unexpectedly requested remote models"); throw CancellationError()
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        Issue.record("Manual retrieval failure fixture unexpectedly requested a remote answer"); throw CancellationError()
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        Issue.record("Manual retrieval failure fixture unexpectedly requested a remote stream")
        return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
