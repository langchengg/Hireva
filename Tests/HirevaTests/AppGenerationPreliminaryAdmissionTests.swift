import Combine
import Foundation
import Testing
@testable import Hireva

/// Uses committed owner notifications and real App entries. No provider,
/// capture, clock sleep or production instrumentation participates.
@MainActor
struct AppGenerationPreliminaryAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: PreliminaryEntry.allCases)
    fileprivate func subscriberRequestSurvivesTheOlderPreliminaryCancellation(entry: PreliminaryEntry) async throws {
        try await withApplication { app, session in
            let original = question(session: session, suffix: "original", text: "Explain transaction atomicity?")
            let replacement = question(session: session, suffix: "replacement", text: "Explain transaction isolation?")
            let submitted = question(session: session, suffix: "submitted", text: "Explain transaction durability?")
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            let requestID = app.beginGenerationRequest(triggerPath: .manualGenerate)
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio,
                speaker: .unknown, requestID: requestID)
            let originalRoot = Task<Void, Never> {}
            #expect(app.generationCoordinator.registerRequestTask(originalRoot, requestID: requestID))
            let replacementAnswer = Task<String, Error> { "Finite replacement-owned answer" }
            var replacementRequestID: String?
            var replacementRoot: Task<Void, Never>?
            var executions: [String] = []
            var replaced = false
            let subscription = app.generationCoordinator.objectWillChange.sink { _ in
                guard !replaced, app.generationCoordinator.activeGeneration == nil,
                      app.generationCoordinator.activeRequest == nil else { return }
                replaced = true
                app.startGenerationRequest(triggerPath: .regenerate) { _ in executions.append("replacement") }
                replacementRequestID = app.generationCoordinator.activeRequest?.id
                replacementRoot = app.activeAITask
                if let replacementRequestID {
                    app.activateGeneration(question: replacement, generationID: replacementID,
                        triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                        speaker: .unknown, requestID: replacementRequestID)
                    app.registerStageATask(replacementAnswer, generationID: replacementID)
                } else {
                    Issue.record("The actual subscriber launch must register its root before returning")
                }
            }
            var olderReturnedRequestID: String?
            switch entry {
            case .begin:
                olderReturnedRequestID = app.beginGenerationRequest(triggerPath: .manualGenerate)
            case .launch:
                app.startGenerationRequest(triggerPath: .manualGenerate) { _ in executions.append("older") }
            case .activate:
                app.activateGeneration(question: submitted, generationID: UUID().uuidString,
                    triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            }
            subscription.cancel()
            let returnedRoot = app.activeAITask
            #expect(replaced)
            #expect(originalRoot.isCancelled)
            #expect(app.generationCoordinator.activeRequest?.id == replacementRequestID)
            #expect(app.activeAITask == replacementRoot)
            #expect(app.currentGenerationID == replacementID)
            #expect(app.activeQuestionID == replacement.id)
            #expect(app.generationUIState == .preparing(questionID: replacement.id,
                generationID: replacementID, triggerPath: .regenerate))
            #expect(app.currentPromptPrimaryQuestion == replacement.questionText)
            #expect(app.generationCoordinator.stageATask == replacementAnswer)
            #expect(app.providerStreamActive)
            #expect(!replacementAnswer.isCancelled)
            if let olderReturnedRequestID {
                #expect(!app.generationCoordinator.isCurrentRequest(olderReturnedRequestID),
                    "An obsolete synchronous entry must not receive the newer request's admission token")
            }
            await originalRoot.value
            await replacementRoot?.value
            await returnedRoot?.value
            _ = await replacementAnswer.result
            #expect(executions == ["replacement"])
            app.generationCoordinator.invalidateAndCancel()
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalSubscriberKeepsNewUILoadingAndOldAdmittedHistory() async throws {
        try await withApplication { app, session in
            var settings = app.settings
            settings.saveTranscriptsLocally = true
            app.saveSettings(settings)
            let original = question(session: session, suffix: "accepted-original", text: "Explain database transactions and atomicity.")
            let replacement = question(session: session, suffix: "accepted-replacement", text: "Explain transaction isolation?")
            try app.suggestionRepository.saveDetectedQuestion(original)
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            var card = SuggestionCard(id: UUID().uuidString, sessionID: session.id,
                questionID: original.id, strategy: "Explanation",
                sayFirst: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                keyPoints: ["Commit all operations together or roll back the transaction."],
                followUpReady: [], confidence: 0.95, caution: nil, evidenceUsed: [], riskLevel: .low,
                modelName: "synthetic-no-provider", promptVersion: "synthetic-no-provider", rawJSON: nil,
                createdAt: Date())
            card.detectedQuestionID = original.id
            card.generationID = originalID
            card.questionText = original.questionText
            card.promptQuestionText = original.questionText
            card.promptPrimaryQuestion = original.questionText
            card.contextSnapshotID = session.contextSnapshotID
            card.stageBCompleted = true
            card.stageBStatus = "completed"
            #expect(app.displaySuggestionIfAligned(card, question: original,
                generationID: originalID, triggerPath: .manualGenerate), Comment(rawValue: app.lastAlignmentError))
            let admitted = try #require(app.currentSuggestion)
            let persistenceValidation = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(admitted)
            #expect(persistenceValidation.accepted)
            let expectedStored = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
                admitted, result: persistenceValidation)
            let replacementAnswer = Task<String, Error> { "Finite replacement-owned answer" }
            var replacementRoot: Task<Void, Never>?
            var replaced = false
            let subscription = app.generationCoordinator.objectWillChange.sink { _ in
                guard !replaced, app.terminalGenerationIDs.contains(originalID) else { return }
                replaced = true
                app.startGenerationRequest(triggerPath: .regenerate) { _ in }
                replacementRoot = app.activeAITask
                if let requestID = app.generationCoordinator.activeRequest?.id {
                    app.activateGeneration(question: replacement, generationID: replacementID,
                        triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                        speaker: .unknown, requestID: requestID)
                    app.registerStageATask(replacementAnswer, generationID: replacementID)
                    app.beginAction(ActionID.generateAnswer, title: "Synthetic replacement pending", message: "Synthetic pending answer")
                } else {
                    Issue.record("The actual replacement must retain its request admission")
                }
            }
            let accepted = app.finishGenerationWithVisibleCard(admitted, generationID: originalID,
                question: original, session: session, requestStart: Date(), retrievedChunks: [],
                triggerPath: .manualGenerate, timedOut: false)
            subscription.cancel()
            #expect(accepted, "The original validated card was accepted before terminal notification")
            #expect(replaced)
            #expect(app.currentGenerationID == replacementID)
            #expect(app.terminalGenerationIDs.contains(originalID))
            #expect(!app.terminalGenerationIDs.contains(replacementID))
            #expect(app.generationUIState == .preparing(questionID: replacement.id,
                generationID: replacementID, triggerPath: .regenerate))
            #expect(app.currentGenerationTelemetry.generationID == replacementID)
            #expect(app.currentGenerationTelemetry.questionID == replacement.id)
            #expect(app.currentGenerationTelemetry.fullCardAt == nil)
            #expect(app.isActionLoading(ActionID.generateAnswer))
            #expect(app.providerStreamActive)
            #expect(app.currentSuggestion == nil)
            #expect(!replacementAnswer.isCancelled)
            await replacementRoot?.value
            await app.generationCoordinator.drainRetiredTasks()
            // Join even the fixture-owned finite child before the throwing SQL read.
            _ = await replacementAnswer.result
            let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(saved.count == 1)
            #expect(saved.first?.id == admitted.id)
            #expect(saved.first?.detectedQuestionID == original.id)
            #expect(saved.first?.generationID == originalID)
            #expect(saved.first?.sayFirst == admitted.sayFirst)
            #expect(saved.first?.promptPrimaryQuestion == expectedStored.promptPrimaryQuestion)
            #expect(app.liveSuggestionHistory.contains { $0.id == admitted.id })
            #expect(app.currentGenerationID == replacementID)
            #expect(app.currentSuggestion == nil)
            app.generationCoordinator.invalidateAndCancel()
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    private func withApplication(
        _ operation: @MainActor (AppState, InterviewSession) async throws -> Void
    ) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.preliminary-admission." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { _ in nil })
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic preliminary admission")
            app.currentSession = session
            try await operation(app, session)
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            try database.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }

    private func question(session: InterviewSession, suffix: String, text: String) -> DetectedQuestion {
        DetectedQuestion(id: "synthetic-" + suffix + "-" + UUID().uuidString, sessionID: session.id,
            transcriptSegmentID: nil, questionText: text, intent: .technical,
            answerStrategy: .technicalExplanation, confidence: 0.99, reason: "Synthetic App entry",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", createdAt: Date())
    }
}

fileprivate enum PreliminaryEntry: String, CaseIterable, Sendable { case begin, launch, activate }
