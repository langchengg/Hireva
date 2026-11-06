import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationFailureTerminalIdentityTests {
    enum InitialTerminal: CaseIterable, Equatable, Sendable { case completed, failed, timeout, cancelled }

    @Test(.timeLimit(.minutes(1)), arguments: InitialTerminal.allCases)
    func sameIdentityFailureCannotReplaceAnAlreadyPublishedTerminal(initial: InitialTerminal) async throws {
        let database = try AppDatabase(inMemory: true)
        var ownedApp: AppState?
        do {
            let app = AppState(database: database,
                questionRoutingProvider: HermeticQuestionRoutingProvider(),
                permissionService: HermeticPermissionService(),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                dialogueDefaults: nil)
            ownedApp = app
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let suffix = String(describing: initial)
            let question = DetectedQuestion(id: "terminal-failure-question-" + suffix,
                sessionID: session.id, transcriptSegmentID: nil,
                questionText: "Explain database transactions and atomicity.",
                intent: .technical, answerStrategy: .directAnswer, confidence: 1,
                reason: "Synthetic repeated terminal publication fixture",
                shouldTrigger: true, questionComplete: true,
                modelName: "fixture", promptVersion: "fixture", createdAt: Date())
            try app.suggestionRepository.saveDetectedQuestion(question)
            let generationID = "terminal-failure-generation-" + suffix
            let requestStart = Date()
            app.activateGeneration(question: question, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: requestStart, source: nil, speaker: nil)
            let identity = try #require(app.activeGenerationController?.identity)
            switch initial {
            case .completed:
                // Exercise the real accepted-card application and atomic DB
                // admission before declaring the successful terminal state.
                let plan = StageBApplicationPlan(generationID: generationID,
                    detectedQuestionID: question.id, action: .applyFullCard,
                    fallbackReason: nil, shouldPersist: true, shouldUpdateVisibleCard: true,
                    safeDiagnostics: ["providerStatus": GenerationProviderStatus.completed.rawValue],
                    identity: identity)
                try await app.applyStageBApplicationPlan(plan,
                    sections: .init(strategy: "Explanation", sayFirst: Self.retainedAnswer,
                        keyPoints: ["All operations commit together or roll back together.",
                            "Isolation controls which concurrent changes are visible."],
                        followUpReady: [], caution: ""),
                    cardID: "terminal-failure-card", generationID: generationID,
                    question: question, session: session, requestStart: requestStart,
                    stageBStreamStartedMS: nil, retrievedChunks: [], triggerPath: .manualGenerate,
                    source: nil, speaker: nil, preserveFallbackSayFirst: false)
                try #require(app.suggestionPersistenceClaims.values.contains { $0.cardID == "terminal-failure-card" })
                // This joins the actual retained persistence worker. It creates
                // no private safety timer and does not race an unowned task.
                await app.generationCoordinator.drainRetiredTasks()
                let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
                try #require(saved.count == 1)
                #expect(saved.first?.stageBStatus == "completed")
                #expect(app.currentSuggestion?.sayFirst == Self.retainedAnswer)
                #expect(app.generationUIState == .answerReady(questionID: question.id,
                    generationID: generationID, triggerPath: .manualGenerate))
            case .failed, .timeout, .cancelled:
                app.markGenerationFailed(generationID: generationID,
                    reason: "Synthetic original terminal outcome",
                    providerError: "Synthetic original provider diagnostic",
                    timeout: initial == .timeout, cancelled: initial == .cancelled)
                #expect(try app.suggestionRepository.suggestions(sessionID: session.id).isEmpty)
            }
            try #require(app.currentGenerationID == generationID)
            try #require(app.terminalGenerationIDs.contains(generationID))
            try #require(app.generationUIState.isTerminal)
            #expect(!app.generationCoordinator.canPublish(identity))
            let state = app.generationUIState
            let card = app.currentSuggestion
            let telemetry = app.currentGenerationTelemetry
            let stateChangedAt = app.lastGenerationStateChangeAt
            let source = app.finalVisibleSource
            let feedback = app.activeActionFeedbacks
            let events = app.recentTranscriptRuntimeEvents
            let callbackDiscards = app.staleCallbackDiscardCount
            let answerDiscards = app.staleAnswerDiscardCount
            let stored = try app.suggestionRepository.suggestions(sessionID: session.id)
            let claims = app.suggestionPersistenceClaims.mapValues { $0.cardID }
            let claimIdentities = app.suggestionPersistenceClaims.mapValues { $0.identity }
            let successfulWrites = app.successfulSuggestionPersistenceOwners
            let taskSummary = app.activeTaskSummary

            // No await between the frozen observations and these real helper
            // calls: the contract concerns this same-ID terminal boundary,
            // rather than unrelated background actor scheduling or rendering.
            app.markGenerationFailed(generationID: generationID,
                reason: "Synthetic late timeout", providerError: "Synthetic late provider diagnostic",
                jsonParseError: "Synthetic late parse diagnostic", timeout: true)
            app.markGenerationFailed(generationID: generationID,
                reason: "Synthetic late cancellation", cancelled: true)
            app.markGenerationFailed(generationID: generationID,
                reason: "Synthetic late failure")

            #expect(app.generationUIState == state)
            #expect(app.currentSuggestion == card)
            #expect(app.currentGenerationTelemetry == telemetry)
            #expect(app.lastGenerationStateChangeAt == stateChangedAt)
            #expect(app.finalVisibleSource == source)
            #expect(app.activeActionFeedbacks == feedback)
            #expect(app.recentTranscriptRuntimeEvents == events)
            #expect(app.staleCallbackDiscardCount == callbackDiscards)
            #expect(app.staleAnswerDiscardCount == answerDiscards)
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id) == stored)
            #expect(app.suggestionPersistenceClaims.mapValues { $0.cardID } == claims)
            #expect(app.suggestionPersistenceClaims.mapValues { $0.identity } == claimIdentities)
            #expect(app.successfulSuggestionPersistenceOwners == successfulWrites)
            #expect(app.activeTaskSummary == taskSummary)
            #expect(app.currentGenerationID == generationID)
            #expect(app.terminalGenerationIDs.contains(generationID))
            #expect(!app.isStreamingSayFirst)
            #expect(!app.isExpandingSuggestionCard)
            #expect(!app.isActionLoading(ActionID.generateAnswer))
            #expect(!app.isActionLoading(ActionID.manualGenerate))
            #expect(app.stageBTask == nil)
            #expect(app.softFallbackTask == nil)
            #expect(app.fullCardWatchdogTask == nil)
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            try database.close()
        } catch {
            // App shutdown joins every task created by the actual application;
            // the isolated DB closes only after those owned workers have exited.
            await ownedApp?.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private static let retainedAnswer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."
}
