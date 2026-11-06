import Foundation
import Testing
@testable import Hireva

@MainActor
struct RejectedStageBFallbackBoundaryTests {
    @Test
    func rejectedLocalStageBFallbackTerminatesAndCancelsItsExpansionWithoutSavingAnAnswer() async throws {
        let fixture = try await RejectedStageBFallbackFixture(prefix: "rejected-stage-b")
        try await fixture.run {
            let app = fixture.app
            let stageB = Task {
                try? await fixture.clock.sleep(nanoseconds: UInt64.max)
                return ()
            }
            fixture.own(stageB)
            app.registerStageBTask(stageB, generationID: fixture.generationID)
            try await fixture.clock.waitUntilScheduled()
            app.setGenerationUIState(.expandingFullAnswer(questionID: fixture.question.id,
                generationID: fixture.generationID, triggerPath: .manualGenerate),
                generationID: fixture.generationID)
            app.isExpandingSuggestionCard = true
            app.suggestionGenerationStarted = true

            // No context snapshot can provide a candidate fallback. The real
            // boundary must reject its empty card and still close this request.
            let fallback = app.makeInitialFirstAnswerFallbackCard(cardID: "rejected-card",
                question: fixture.question, session: fixture.session, requestStart: fixture.started)
            #expect(fallback.isLocal)
            #expect(fallback.sayFirst.isEmpty)
            #expect(!app.displaySuggestionIfAligned(fallback, question: fixture.question,
                generationID: fixture.generationID, triggerPath: .manualGenerate))
            #expect(!app.generationUIState.isTerminal,
                "A preliminary rejected local preview does not finish expansion by itself.")

            try await fixture.applySemanticFallback()
            #expect(app.generationUIState.isTerminal,
                "The completed Stage B plan was handled but left its request nonterminal.")
            #expect(app.currentGenerationErrorText != nil)
            #expect(!app.visibleAnswerExists)
            #expect(app.currentSuggestion == nil)
            #expect(!app.isExpandingSuggestionCard)
            #expect(!app.suggestionGenerationStarted)
            #expect(!app.stageBTaskActive)
            #expect(stageB.isCancelled,
                "Terminal rejection must cancel the exact owned expansion.")
            #expect(app.suggestionPersistenceClaims.isEmpty)
            #expect(try app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
        }
    }

    @Test
    func semanticFallbackPlanKeepsQualifiedProviderFirstAnswerAndDoesNotReviveRevokedConsent() async throws {
        let fixture = try await RejectedStageBFallbackFixture(prefix: "retained-stage-b")
        try await fixture.run {
            let app = fixture.app
            let answer = "A database transaction groups operations into one atomic unit. Atomicity means every operation commits together or all operations roll back together."
            #expect(app.publishStreamingSections(.init(strategy: "Explanation",
                sayFirst: answer, keyPoints: [], followUpReady: [], caution: ""),
                cardID: "qualified-first-answer", generationID: fixture.generationID,
                question: fixture.question, session: fixture.session,
                requestStart: fixture.started, stageBStreamStartedMS: nil))
            let first = try #require(app.currentSuggestion)
            #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(first).accepted)
            let source = first.sayFirstSource
            let ticket = app.activeGenerationController?.persistenceTicket
            app.persistenceConsent.update(enabled: false)
            app.persistenceConsent.update(enabled: true)
            #expect(ticket.map { app.persistenceConsent.isCurrent(ticket: $0) } == false)

            try await fixture.applySemanticFallback()
            #expect(app.generationUIState.isTerminal)
            #expect(app.currentGenerationErrorText == nil)
            #expect(app.currentSuggestion?.id == first.id)
            #expect(app.currentSuggestion?.sayFirst == answer)
            #expect(app.currentSuggestion?.sayFirstSource == source)
            #expect(app.currentSuggestion?.isLocal == false)
            #expect(app.suggestionPersistenceClaims.isEmpty)
            #expect(try app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
        }
    }

    @Test
    func rejectedOldStageBPlanCannotTerminateReplacementGeneration() async throws {
        let fixture = try await RejectedStageBFallbackFixture(prefix: "stale-stage-b")
        try await fixture.run {
            let app = fixture.app
            let next = DetectedQuestion(id: "replacement-question", sessionID: fixture.session.id,
                transcriptSegmentID: nil, questionText: "Explain cache invalidation and consistency.",
                intent: .technical, answerStrategy: .directAnswer, confidence: 1,
                reason: "Synthetic replacement identity", shouldTrigger: true, questionComplete: true,
                modelName: "fixture", promptVersion: "fixture", createdAt: Date())
            app.activateGeneration(question: next, generationID: "replacement-generation",
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            let state = app.generationUIState
            let feedback = app.latestActionFeedback(for: ActionID.generateAnswer)
            try await fixture.applySemanticFallback()
            #expect(app.currentGenerationID == "replacement-generation")
            #expect(app.generationUIState == state)
            #expect(!app.generationUIState.isTerminal)
            #expect(app.latestActionFeedback(for: ActionID.generateAnswer)?.id == feedback?.id)
            #expect(app.currentSuggestion == nil)
            #expect(app.suggestionPersistenceClaims.isEmpty)
        }
    }
}

@MainActor
private final class RejectedStageBFallbackFixture {
    let environment: HirevaTestEnvironment
    let session: InterviewSession
    let question: DetectedQuestion
    let generationID: String
    let identity: GenerationIdentity
    let started: Date
    let clock = ControlledGenerationWatchdogClock()
    var app: AppState { environment.appState }
    private var tasks: [Task<Void, Never>] = []

    init(prefix: String) async throws {
        let environment = try await HirevaTestEnvironment(prefix: prefix)
        let started = Date()
        let app = environment.appState
        let session = try app.sessionRepository.createSession(mode: .mock)
        app.currentSession = session
        let question = DetectedQuestion(id: prefix + "-question", sessionID: session.id,
            transcriptSegmentID: nil, questionText: "Explain database transactions and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1,
            reason: "Synthetic completed Stage B rejection", shouldTrigger: true, questionComplete: true,
            modelName: "fixture", promptVersion: "fixture", createdAt: started)
        let generationID = prefix + "-generation"
        try app.suggestionRepository.saveDetectedQuestion(question)
        app.activateGeneration(question: question, generationID: generationID,
            triggerPath: .manualGenerate, requestStart: started, source: nil, speaker: nil)
        let identity = try #require(app.activeGenerationController?.identity)
        self.environment = environment
        self.started = started
        self.session = session
        self.question = question
        self.generationID = generationID
        self.identity = identity
    }

    func own(_ task: Task<Void, Never>) { tasks.append(task) }

    func applySemanticFallback() async throws {
        let plan = StageBApplicationPlan(generationID: generationID,
            detectedQuestionID: question.id, action: .useSemanticFallback,
            fallbackReason: "Synthetic completed provider expansion rejected by publication checks.",
            shouldPersist: true, shouldUpdateVisibleCard: true,
            safeDiagnostics: ["providerStatus": GenerationProviderStatus.completed.rawValue,
                "stageBClassification": StageBResultClassification.fallbackRequired.rawValue],
            identity: identity)
        try await app.applyStageBApplicationPlan(plan, sections: .init(strategy: "Rejected expansion",
            sayFirst: "A provider placeholder.", keyPoints: [], followUpReady: [], caution: ""),
            cardID: "rejected-card", generationID: generationID, question: question,
            session: session, requestStart: started, stageBStreamStartedMS: nil,
            retrievedChunks: [], triggerPath: .manualGenerate, source: nil, speaker: nil,
            preserveFallbackSayFirst: false)
    }

    func run(_ body: @MainActor () async throws -> Void) async throws {
        do {
            try await body()
            try await shutdown()
        } catch {
            try await shutdown()
            throw error
        }
    }

    private func shutdown() async throws {
        // Explicitly release the synthetic clock even when the baseline fails
        // to cancel Stage B. No background test work survives a failing assert.
        clock.cancelAll()
        tasks.forEach { $0.cancel() }
        try await environment.shutdown()
        for task in tasks { await task.value }
    }
}
