import Combine
import Foundation
import Testing
@testable import Hireva

/// Calls current App APIs with a committed GenerationCoordinator publisher.
/// These synthetic cases do not call a provider or open an audio device.
@MainActor
struct AppGenerationOwnerCallbackAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func activateCannotResetTheNewerSubscriberGenerationPresentation() async throws {
        try await withApplication { app, session in
            let submitted = question(session: session, suffix: "submitted", text: "Explain transaction atomicity?")
            let replacement = question(session: session, suffix: "replacement", text: "Explain transaction isolation?")
            let submittedID = UUID().uuidString, replacementID = UUID().uuidString
            var replaced = false
            var observedSubmittedIdentity: GenerationIdentity?
            var replacementIdentity: GenerationIdentity?
            let subscription = app.generationCoordinator.objectWillChange.sink { _ in
                guard !replaced, app.currentGenerationID == submittedID else { return }
                replaced = true
                observedSubmittedIdentity = app.activeGenerationController?.identity
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                replacementIdentity = app.activeGenerationController?.identity
            }
            app.activateGeneration(question: submitted, generationID: submittedID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            subscription.cancel()
            #expect(replaced)
            #expect(observedSubmittedIdentity?.generationID == submittedID,
                "The subscriber enters after the owner committed the submitted record.")
            #expect(app.activeGenerationController?.identity == replacementIdentity)
            #expect(app.currentGenerationID == replacementID)
            #expect(app.currentPromptQuestionText == replacement.questionText)
            #expect(app.currentPromptPrimaryQuestion == replacement.questionText)
            #expect(app.generationUIState == .preparing(questionID: replacement.id,
                generationID: replacementID, triggerPath: .regenerate))
            #expect(app.currentGenerationTelemetry.generationID == replacementID)
            #expect(app.currentGenerationTelemetry.questionID == replacement.id)
            #expect(app.currentGenerationTelemetry.generationState == GenerationUIState.preparing(
                questionID: replacement.id, generationID: replacementID, triggerPath: .regenerate).displayName)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func terminalPublicationCannotWriteTheReplacementTelemetry(failed: Bool) async throws {
        try await withApplication { app, session in
            let original = question(session: session, suffix: "terminal-original", text: "Explain transaction atomicity?")
            let replacement = question(session: session, suffix: "terminal-replacement", text: "Explain transaction isolation?")
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            var replaced = false
            var observedTerminalFence = false
            let subscription = app.generationCoordinator.objectWillChange.sink { _ in
                guard !replaced, app.terminalGenerationIDs.contains(originalID) else { return }
                replaced = true
                observedTerminalFence = app.generationCoordinator.activeGeneration?.generationID == originalID
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            }
            let terminal: GenerationUIState = failed
                ? .failed(questionID: original.id, generationID: originalID,
                    triggerPath: .manualGenerate, reason: "Synthetic original-generation failure")
                : .answerReady(questionID: original.id, generationID: originalID, triggerPath: .manualGenerate)
            app.setGenerationUIState(terminal, generationID: originalID)
            subscription.cancel()
            #expect(replaced && observedTerminalFence)
            #expect(app.currentGenerationID == replacementID)
            #expect(app.terminalGenerationIDs.contains(originalID), "Legal old terminal history remains immutable.")
            #expect(!app.terminalGenerationIDs.contains(replacementID))
            #expect(app.generationUIState == .preparing(questionID: replacement.id,
                generationID: replacementID, triggerPath: .regenerate))
            #expect(app.currentGenerationTelemetry.generationID == replacementID)
            #expect(app.currentGenerationTelemetry.questionID == replacement.id)
            #expect(app.currentGenerationTelemetry.generationState == GenerationUIState.preparing(
                questionID: replacement.id, generationID: replacementID, triggerPath: .regenerate).displayName)
            #expect(app.currentGenerationTelemetry.failureReason == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: AppGenerationClearRole.allCases, [false, true])
    fileprivate func clearCannotDeactivateTheSubscriberOwnedChild(
        role: AppGenerationClearRole, sameGeneration: Bool
    ) async throws {
        try await withApplication { app, session in
            let original = question(session: session, suffix: "clear-original", text: "Explain transaction atomicity?")
            let replacement = sameGeneration ? original : question(session: session,
                suffix: "clear-replacement", text: "Explain transaction isolation?")
            let originalID = UUID().uuidString
            let replacementID = sameGeneration ? originalID : UUID().uuidString
            let oldAnswer = Task<String, Error> { "Finite original synthetic answer" }
            let replacementAnswer = Task<String, Error> { "Finite replacement synthetic answer" }
            let oldControl = Task<Void, Never> {}
            let replacementControl = Task<Void, Never> {}
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            register(role, answer: oldAnswer, control: oldControl, app: app, generationID: originalID)
            var replaced = false
            var observedCommittedClear = false
            let subscription = app.generationCoordinator.objectWillChange.sink { _ in
                guard !replaced, app.currentGenerationID == originalID, slotIsEmpty(role, app: app) else { return }
                replaced = true
                observedCommittedClear = true
                if !sameGeneration {
                    app.activateGeneration(question: replacement, generationID: replacementID,
                        triggerPath: .regenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                }
                register(role, answer: replacementAnswer, control: replacementControl,
                    app: app, generationID: replacementID)
            }
            clear(role, app: app, generationID: originalID)
            subscription.cancel()
            #expect(replaced && observedCommittedClear)
            #expect(app.currentGenerationID == replacementID)
            switch role {
            case .stageA:
                #expect(app.generationCoordinator.stageATask == replacementAnswer)
                #expect(app.providerStreamActive)
                #expect(app.activeTaskSummary.contains("providerStream=true"))
                #expect(!replacementAnswer.isCancelled)
            case .stageB, .cancelStageB:
                #expect(app.generationCoordinator.stageBTask == replacementControl)
                #expect(app.stageBTaskActive)
                #expect(app.activeTaskSummary.contains("stageB=true"))
                #expect(!replacementControl.isCancelled)
            case .fallback:
                #expect(app.generationCoordinator.fallbackWatchdogTask == replacementControl)
                #expect(app.fallbackWatchdogActive)
                #expect(app.activeTaskSummary.contains("fallbackWatchdog=true"))
                #expect(!replacementControl.isCancelled)
            }
            app.generationCoordinator.invalidateAndCancel()
            oldAnswer.cancel(); replacementAnswer.cancel(); oldControl.cancel(); replacementControl.cancel()
            _ = await oldAnswer.result
            _ = await replacementAnswer.result
            await oldControl.value
            await replacementControl.value
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func committedStageBRegistrationPublishesItsActualOwnedState() async throws {
        try await withApplication { app, session in
            let submitted = question(session: session, suffix: "stage-b-register", text: "Explain transaction atomicity?")
            let generationID = UUID().uuidString
            app.activateGeneration(question: submitted, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let task = Task<Void, Never> {}
            var observedRegisteredState: Bool?
            let subscription = app.objectWillChange.sink { _ in
                guard observedRegisteredState == nil, app.currentGenerationID == generationID,
                      app.generationCoordinator.stageBTask == task else { return }
                observedRegisteredState = app.stageBTaskActive
            }
            app.registerStageBTask(task, generationID: generationID)
            subscription.cancel()
            #expect(observedRegisteredState == true,
                "App observers must see the committed Stage B owner when its registration is published.")
            #expect(app.stageBTaskActive)
            #expect(app.activeTaskSummary.contains("stageB=true"))
            app.clearStageBTask(generationID: generationID)
            await task.value
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func committedStageBClearPublishesItsActualOwnedState(cancel: Bool) async throws {
        try await withApplication { app, session in
            let submitted = question(session: session, suffix: "stage-b-clear", text: "Explain transaction atomicity?")
            let generationID = UUID().uuidString
            app.activateGeneration(question: submitted, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let task = Task<Void, Never> {}
            app.registerStageBTask(task, generationID: generationID)
            var observedClearedState: Bool?
            let subscription = app.objectWillChange.sink { _ in
                guard observedClearedState == nil, app.currentGenerationID == generationID,
                      app.generationCoordinator.stageBTask == nil else { return }
                observedClearedState = app.stageBTaskActive
            }
            if cancel { app.cancelActiveStageBTask(generationID: generationID) }
            else { app.clearStageBTask(generationID: generationID) }
            subscription.cancel()
            #expect(observedClearedState == false,
                "App observers must see the committed Stage B clear when the owner publishes it.")
            #expect(!app.stageBTaskActive)
            #expect(app.activeTaskSummary.contains("stageB=false"))
            #expect(task.isCancelled == cancel)
            await task.value
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalAndCancellationDoNotPretendAnOwnedStageBTaskHasExited() async throws {
        try await withApplication { app, session in
            let submitted = question(session: session, suffix: "stage-b-terminal", text: "Explain transaction atomicity?")
            let generationID = UUID().uuidString
            app.activateGeneration(question: submitted, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let task = Task<Void, Never> {}
            app.registerStageBTask(task, generationID: generationID)
            app.setGenerationUIState(.answerReady(questionID: submitted.id,
                generationID: generationID, triggerPath: .manualGenerate), generationID: generationID)
            #expect(app.generationUIState.isTerminal)
            #expect(app.generationCoordinator.stageBTask == task)
            #expect(app.stageBTaskActive, "A UI terminal is not a task release or cleanup join.")
            task.cancel()
            #expect(task.isCancelled)
            #expect(app.generationCoordinator.stageBTask == task)
            #expect(app.stageBTaskActive, "Cancellation alone is not owner slot release.")
            app.cancelActiveStageBTask(generationID: generationID)
            #expect(!app.stageBTaskActive)
            await task.value
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func releasedStageBStateDoesNotHideItsOwnedRetirementJoin() async throws {
        try await withApplication { app, session in
            let submitted = question(session: session, suffix: "stage-b-retirement", text: "Explain transaction atomicity?")
            let generationID = UUID().uuidString
            app.activateGeneration(question: submitted, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let task = Task<Void, Never> {}
            app.registerStageBTask(task, generationID: generationID)
            app.cancelActiveStageBTask(generationID: generationID)
            #expect(app.generationCoordinator.stageBTask == nil)
            #expect(!app.stageBTaskActive)
            // No suspension since task creation: the MainActor retirement join
            // is still owned even though current-generation registration is gone.
            #expect(app.generationCoordinator.retiringTaskCount > 0)
            await task.value
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    private func withApplication(
        _ operation: @MainActor (AppState, InterviewSession) async throws -> Void
    ) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.owner-callback-admission." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { _ in nil })
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic owner callback admission")
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
            answerStrategy: .technicalExplanation, confidence: 0.99, reason: "Synthetic App entry characterization",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", createdAt: Date())
    }

    private func register(_ role: AppGenerationClearRole, answer: Task<String, Error>,
        control: Task<Void, Never>, app: AppState, generationID: String) {
        switch role {
        case .stageA: app.registerStageATask(answer, generationID: generationID)
        case .stageB, .cancelStageB: app.registerStageBTask(control, generationID: generationID)
        case .fallback: app.registerFallbackWatchdogTask(control, generationID: generationID)
        }
    }

    private func clear(_ role: AppGenerationClearRole, app: AppState, generationID: String) {
        switch role {
        case .stageA: app.clearStageATask(generationID: generationID)
        case .stageB: app.clearStageBTask(generationID: generationID)
        case .cancelStageB: app.cancelActiveStageBTask(generationID: generationID)
        case .fallback: app.clearFallbackWatchdogTask(generationID: generationID)
        }
    }

    private func slotIsEmpty(_ role: AppGenerationClearRole, app: AppState) -> Bool {
        switch role {
        case .stageA: return app.generationCoordinator.stageATask == nil
        case .stageB, .cancelStageB: return app.generationCoordinator.stageBTask == nil
        case .fallback: return app.generationCoordinator.fallbackWatchdogTask == nil
        }
    }
}

fileprivate enum AppGenerationClearRole: String, CaseIterable, Sendable {
    case stageA, stageB, cancelStageB, fallback
}
