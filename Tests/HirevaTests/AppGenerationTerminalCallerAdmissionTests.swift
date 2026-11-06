import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppGenerationTerminalCallerAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func completedCardRestoreKeepsReplacementSessionDiagnostics(timedOut: Bool) async throws {
        try await withApplication { app, session, _ in
            let original = question(session: session, suffix: "restore-original",
                text: "Explain database transactions and atomicity.")
            let replacementSession = try app.sessionRepository.createSession(mode: .mock,
                title: "Synthetic replacement diagnostic session")
            let replacement = question(session: replacementSession, suffix: "restore-replacement",
                text: "Explain transaction isolation and visibility.")
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID, triggerPath: .manualGenerate,
                requestStart: Date(), source: .mock, speaker: .unknown, answerProviderMode: .deepSeekPrimary)
            app.liveState = .generatingSuggestion
            app.currentCaptureRuntimeState = .generating
            let sections = StreamingSuggestionSections(strategy: "Explanation", sayFirst: Self.answer,
                keyPoints: ["An explicit transaction can commit or be rolled back."], followUpReady: [], caution: "")
            #expect(app.publishStreamingSections(sections, cardID: UUID().uuidString,
                generationID: originalID, question: original, session: session, requestStart: Date(),
                stageBStreamStartedMS: nil))
            let card = try #require(app.currentSuggestion)
            var replaced = false
            let observation = app.liveInterview.liveStateUpdates.dropFirst().sink { state in
                guard state == .stopped, !replaced else { return }
                replaced = true
                app.currentSession = replacementSession
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .mock, speaker: .unknown,
                    answerProviderMode: .localQwenPrimary)
                app.liveState = .generatingSuggestion
                app.currentCaptureRuntimeState = .generating
                app.recordTranscriptRuntimeEvent(.generationStarted(sessionID: replacementSession.id,
                    questionID: replacement.id, generationID: replacementID,
                    question: replacement.questionText, timestamp: Date()))
                app.recordTranscriptRuntimeEvent(.generationRejected(sessionID: replacementSession.id,
                    question: replacement.questionText, reason: .pipelineRejected, timestamp: Date()))
            }
            defer { observation.cancel() }
            #expect(app.finishGenerationWithVisibleCard(card, generationID: originalID,
                question: original, session: session, requestStart: Date(), retrievedChunks: [],
                triggerPath: .manualGenerate, timedOut: timedOut))
            #expect(replaced)
            #expect(app.currentGenerationID == replacementID)
            #expect(app.liveState == .generatingSuggestion && app.currentCaptureRuntimeState == .generating)
            #expect(app.diagnosticsState.runtime.audioSessionID == replacementSession.id)
            #expect(app.diagnosticsState.runtime.lastGenerationRejectedReason == QuestionRuntimeRejectionReason.pipelineRejected.rawValue)
            #expect(app.diagnosticsState.recentEvents.contains {
                $0.generationID == originalID && $0.name == "answer.stream.completed"
            }, "Q1's legitimate completion audit must remain historical")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: TerminalEntry.allCases)
    fileprivate func completedOldCallerCannotFinishReplacementPresentation(entry: TerminalEntry) async throws {
        try await withApplication { app, session, clock in
            var settings = app.settings
            settings.saveTranscriptsLocally = true
            app.saveSettings(settings)
            let original = question(session: session, suffix: "original", text: "Explain database transactions and atomicity.")
            let replacement = question(session: session, suffix: "replacement", text: "Explain transaction isolation and visibility.")
            try app.suggestionRepository.saveDetectedQuestion(original)
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown,
                answerProviderMode: .deepSeekPrimary)
            var card = SuggestionCard(id: UUID().uuidString, sessionID: session.id,
                questionID: original.id, strategy: "Explanation", sayFirst: Self.answer,
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
                generationID: originalID, triggerPath: .manualGenerate))
            let admitted = try #require(app.currentSuggestion)
            let persistenceValidation = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(admitted)
            #expect(persistenceValidation.accepted)
            let expectedStored = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(
                admitted, result: persistenceValidation)
            let identity = try #require(app.activeGenerationController?.identity)
            let replacementAnswer = Task<String, Error> { "Finite replacement-owned answer" }
            var replacementRoot: Task<Void, Never>?
            var watchdog: Task<Void, Never>?
            var telemetryObservation: AnyCancellable?
            var laterTelemetryPublications = 0
            var replacementChangedAt: Date?
            var replaced = false
            let observation = app.generationCoordinator.objectWillChange.sink { _ in
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
                    replacementChangedAt = app.lastGenerationStateChangeAt
                    telemetryObservation = app.generationTelemetryUpdates.dropFirst().sink { _ in
                        laterTelemetryPublications += 1
                    }
                } else {
                    Issue.record("The actual subscriber must register its replacement request")
                }
            }
            @MainActor func releaseAndJoin() async {
                observation.cancel()
                telemetryObservation?.cancel()
                clock.cancelAll()
                await replacementRoot?.value
                _ = await replacementAnswer.result
                await watchdog?.value
                await app.generationCoordinator.drainRetiredTasks()
            }
            do {
                switch entry {
                case .fullCard:
                    app.markFullCardVisible(generationID: originalID)
                case .failure:
                    app.markGenerationFailed(generationID: originalID,
                        reason: "Synthetic old request failure", timeout: true)
                case .stageB:
                    let sections = StreamingSuggestionSections(strategy: "Explanation", sayFirst: Self.answer,
                        keyPoints: admitted.keyPoints, followUpReady: [], caution: "")
                    let plan = StageBApplicationPlan(generationID: originalID, detectedQuestionID: original.id,
                        action: .applyFullCard, fallbackReason: nil, shouldPersist: true,
                        shouldUpdateVisibleCard: true, safeDiagnostics: [:], identity: identity)
                    try await app.applyStageBApplicationPlan(plan, sections: sections, cardID: admitted.id,
                        generationID: originalID, question: original, session: session,
                        requestStart: Date(), stageBStreamStartedMS: nil, retrievedChunks: [],
                        triggerPath: .manualGenerate, source: .systemAudio, speaker: .unknown,
                        preserveFallbackSayFirst: false)
                case .watchdog:
                    app.generationFullCardWatchdogNanoseconds = 7_000_000_000
                    app.startFullCardWatchdog(generationID: originalID, cardID: admitted.id,
                        question: original, session: session, requestStart: Date(),
                        triggerPath: .manualGenerate, delayProvider: clock)
                    watchdog = app.generationCoordinator.fullCardWatchdogTask
                    let exactWatchdog = try #require(watchdog)
                    try await clock.waitUntilPending(nanoseconds: 7_000_000_000)
                    clock.advance(by: 7_000_000_000)
                    await exactWatchdog.value
                }
                #expect(replaced)
                #expect(app.terminalGenerationIDs.contains(originalID))
                #expect(app.currentGenerationID == replacementID)
                #expect(app.activeQuestionID == replacement.id)
                #expect(app.generationUIState == .preparing(questionID: replacement.id,
                    generationID: replacementID, triggerPath: .regenerate))
                #expect(app.currentGenerationTelemetry.generationID == replacementID)
                #expect(app.currentGenerationTelemetry.fullCardAt == nil)
                #expect(app.currentGenerationTelemetry.failureReason == nil)
                #expect(laterTelemetryPublications == 0,
                    "An old terminal caller must not republish the new generation's telemetry")
                #expect(app.lastGenerationStateChangeAt == replacementChangedAt)
                #expect(app.isActionLoading(ActionID.generateAnswer))
                #expect(app.providerStreamActive)
                #expect(app.generationCoordinator.stageATask == replacementAnswer)
                #expect(!replacementAnswer.isCancelled)
                #expect(app.currentSuggestion == nil)
                let completionAudit = app.diagnosticsState.recentEvents.filter {
                    $0.generationID == originalID &&
                        ($0.name == "generationCompleted" || $0.name == "answer.stream.completed")
                }
                #expect(completionAudit.allSatisfy { $0.questionID == original.id },
                    "An old audit may remain historical but must not borrow Q2's question identity")
                await releaseAndJoin()
                if entry == .stageB || entry == .watchdog {
                    let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
                    #expect(saved.count == 1)
                    #expect(saved.first?.detectedQuestionID == original.id)
                    #expect(saved.first?.generationID == originalID)
                    #expect(saved.first?.sayFirst == expectedStored.sayFirst)
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

    private func withApplication(
        _ operation: @MainActor (AppState, InterviewSession, ControlledGenerationWatchdogClock) async throws -> Void
    ) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.terminal-caller." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { _ in nil })
        let clock = ControlledGenerationWatchdogClock()
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic terminal caller")
            app.currentSession = session
            try await operation(app, session, clock)
            clock.cancelAll()
            await app.shutdownForTesting()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
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

    private static let answer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."

    private func question(session: InterviewSession, suffix: String, text: String) -> DetectedQuestion {
        DetectedQuestion(id: "synthetic-terminal-" + suffix + "-" + UUID().uuidString, sessionID: session.id,
            transcriptSegmentID: nil, questionText: text, intent: .technical,
            answerStrategy: .technicalExplanation, confidence: 0.99, reason: "Synthetic App entry",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", createdAt: Date())
    }
}

fileprivate enum TerminalEntry: String, CaseIterable, Sendable { case fullCard, failure, stageB, watchdog }
