import Foundation
import Combine
import Testing
@testable import Hireva

/// Actual AppState fallback/replacement entries, isolated synthetic state only.
/// No installed model, audio device, GUI, cloud credential or production DB.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SupersededHistoryEvidenceBoundaryTests {
    @Test(arguments: [
        "Explain a bounded message queue and its admission limit.",
        "Explain a database transaction and atomicity.",
        "解释有界工作队列和容量限制。"
    ])
    func unresolvedGeneralFallbackDoesNotPromoteAProfileToTheAnswer(_ text: String) async throws {
        try await withApplication { app, session in
            let question = makeQuestion(text, session: session)
            let card = app.makeInitialFirstAnswerFallbackCard(cardID: UUID().uuidString,
                question: question, session: session, requestStart: Date())
            #expect(card.sayFirst.isEmpty,
                "An unresolved generic task is not permission to substitute biography.")
            #expect(card.candidateEvidenceIDs.isEmpty)
            #expect(card.keyPoints.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func routedGeneralReplacementKeepsTheQuestionWithoutAProfileAnswer(sameTopic: Bool) async throws {
        try await withApplication { app, session in
            let text = sameTopic ? "Explain a database transaction and atomicity." : "Explain a bounded message queue and its admission limit."
            var original = makeQuestion(text, session: session)
            applyDecision(.notRequired, task: .generalKnowledge, basis: .generalKnowledge,
                question: &original, snapshotID: session.contextSnapshotID)
            try app.suggestionRepository.saveDetectedQuestion(original)
            app.activateGeneration(question: original, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let replacement = makeQuestion("Explain a finite scheduling queue and its boundaries.", session: session)
            // The production caller publishes Q2 before cancelling Q1. Do not
            // accidentally let a proposed fix borrow lastDetectedQuestion's Q2.
            app.lastDetectedQuestion = replacement
            app.activateGeneration(question: replacement, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            await app.generationCoordinator.drainRetiredTasks()
            let questions = try app.suggestionRepository.questions(sessionID: session.id)
            #expect(questions.contains { $0.id == original.id && $0.questionText == original.questionText })
            #expect(questions.first { $0.id == original.id }?.taskDescriptor?.decision?.personalEvidence == .notRequired)
            let history = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(history.allSatisfy { $0.detectedQuestionID != original.id },
                "Keep accepted-question history; an ungenerated generic answer must not become a CV snapshot.")
            #expect(app.activeGenerationController?.questionID == replacement.id)
            #expect(app.currentSuggestion == nil)
        }
    }

    @Test(arguments: [false, true])
    func anAllowedPersonalReplacementRetainsItsExactDecisionAndSourceHistory(providerAlreadyFailed: Bool) async throws {
        try await withApplication { app, session in
            var original = makeQuestion("Describe your small synthetic scheduling project.", session: session)
            applyDecision(.required, task: .project, basis: .candidateRecord,
                question: &original, snapshotID: session.contextSnapshotID)
            try app.suggestionRepository.saveDetectedQuestion(original)
            app.activateGeneration(question: original, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            if providerAlreadyFailed {
                app.markGenerationFailed(generationID: app.currentGenerationID,
                    reason: "Synthetic unsupported personal claim")
            }
            let replacement = makeQuestion("Explain a finite work queue and its capacity limit.", session: session)
            app.lastDetectedQuestion = replacement
            app.activateGeneration(question: replacement, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            await app.generationCoordinator.drainRetiredTasks()
            let saved = try #require(try app.suggestionRepository.suggestions(sessionID: session.id)
                .first { $0.detectedQuestionID == original.id })
            #expect(saved.stageBStatus == "superseded")
            #expect(saved.finalVisibleSource == "local_superseded_question_snapshot")
            #expect(saved.caution == "Local question snapshot retained after replacement; this record does not contain an accepted provider answer.")
            #expect(app.liveSuggestionHistory.contains { $0.id == saved.id })
            #expect(saved.questionDecision == original.taskDescriptor?.decision)
            #expect(saved.candidateEvidenceIDs == ["test-candidate-evidence-0"])
            #expect(saved.sayFirst.contains(Self.evidence))
            #expect(app.activeGenerationController?.questionID == replacement.id)
            #expect(app.currentSuggestion == nil)
        }
    }

    @Test
    func aRevokedTicketCannotSaveAnOtherwiseAllowedPersonalSnapshot() async throws {
        try await withApplication { app, session in
            var question = makeQuestion("Describe your small synthetic scheduling project.", session: session)
            applyDecision(.required, task: .project, basis: .candidateRecord,
                question: &question, snapshotID: session.contextSnapshotID)
            try app.suggestionRepository.saveDetectedQuestion(question)
            let oldTicket = app.persistenceConsent.ticket()
            var settings = app.settings
            settings.saveTranscriptsLocally = false; app.saveSettings(settings)
            settings.saveTranscriptsLocally = true; app.saveSettings(settings)
            app.persistAcceptedQuestionHistorySnapshot(for: question, session: session,
                stageBStatus: "superseded", finalVisibleSource: "local_superseded_question_snapshot",
                caution: "Synthetic revoked ticket", modelName: "synthetic-no-model",
                promptVersion: "synthetic-ticket", consentTicket: oldTicket)
            await app.generationCoordinator.drainRetiredTasks()
            let savedHistory = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(savedHistory.isEmpty)
        }
    }

    /// The existing save entry publishes its request label before creating its
    /// detached writer. A real synchronous subscriber can supersede an already
    /// routed question in that pre-durable window; no test hook or sleep is used.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func historyUsesFrozenQuestionWhenReplacementPrecedesBackgroundSave(beforeSave: Bool) async throws {
        try await withApplication { app, session in
            var original = makeQuestion("Describe your small synthetic scheduling project.", session: session)
            applyDecision(.required, task: .project, basis: .candidateRecord,
                question: &original, snapshotID: session.contextSnapshotID)
            let replacement = makeQuestion("Explain a finite work queue and its capacity limit.", session: session)
            var subscriber: AnyCancellable?
            var callbackError: Error?
            var replacedBeforeSave = false
            @MainActor func replace() {
                app.activateGeneration(question: original, generationID: UUID().uuidString,
                    triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                app.lastDetectedQuestion = replacement
                app.activateGeneration(question: replacement, generationID: UUID().uuidString,
                    triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            }
            if beforeSave {
                subscriber = app.$lastSQLiteOperation.sink { incoming in
                    guard incoming == "Saving detected question in background", !replacedBeforeSave else { return }
                    replacedBeforeSave = true
                    do {
                        let existing = try app.suggestionRepository.questions(sessionID: session.id)
                        #expect(existing.isEmpty)
                        replace()
                        // Establish the real foreign key only after the old
                        // history decision has already been selected. Its
                        // detached card writer first awaits the MainActor gate.
                        try app.suggestionRepository.saveDetectedQuestion(original)
                    } catch { callbackError = error }
                }
            }
            app.saveDetectedQuestionInBackground(original)
            subscriber?.cancel()
            if let callbackError { throw callbackError }
            if beforeSave {
                #expect(replacedBeforeSave)
            } else {
                await app.generationCoordinator.drainRetiredTasks()
                let existing = try app.suggestionRepository.questions(sessionID: session.id)
                #expect(existing.first { $0.id == original.id }?.taskDescriptor?.decision == original.taskDescriptor?.decision)
                replace()
            }
            await app.generationCoordinator.drainRetiredTasks()
            let history = try app.suggestionRepository.suggestions(sessionID: session.id)
            let saved = try #require(history.first { $0.detectedQuestionID == original.id })
            #expect(history.filter { $0.detectedQuestionID == original.id }.count == 1)
            #expect(saved.questionDecision == original.taskDescriptor?.decision)
            #expect(saved.candidateEvidenceIDs == ["test-candidate-evidence-0"])
            #expect(saved.sayFirst.contains(Self.evidence))
            #expect(app.activeQuestionID == replacement.id)
            #expect(app.currentSuggestion == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func completedRouteIsFrozenBeforeClearedSlotSubscriberReplacesTheQuestion() async throws {
        let trace = TestEventWaitTrace(label: "CompletedRouteHistory")
        trace.mark("body.enter")
        defer { trace.mark("body.exit") }
        try await withApplication { app, session in
            let original = makeQuestion("Describe your small synthetic scheduling project.", session: session)
            let replacement = makeQuestion("Explain a finite work queue and its capacity limit.", session: session)
            // Persist only the unresolved ingress version. Route completion's
            // descriptor UPDATE occurs after its child-cleared notification.
            try app.suggestionRepository.saveDetectedQuestion(original)
            var sawRoutingChild = false
            var replaced = false
            var callbackError: Error?
            var rootError: Error?
            let subscriber = app.generationCoordinator.objectWillChange.sink { _ in
                guard app.activeQuestionID == original.id else { return }
                if app.activeGenerationController?.questionRoutingTask != nil {
                    sawRoutingChild = true
                    return
                }
                guard sawRoutingChild, !replaced,
                    app.activeGenerationController?.questionSnapshot?.taskDescriptor?.decision?.questionID == original.id else { return }
                trace.mark("route.result.committed.before.slot_clear")
                replaced = true
                do {
                    let rows = try app.suggestionRepository.questions(sessionID: session.id)
                    #expect(rows.first { $0.id == original.id }?.taskDescriptor?.decision == nil)
                    app.lastDetectedQuestion = replacement
                    app.activateGeneration(question: replacement, generationID: UUID().uuidString,
                        triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                } catch { callbackError = error }
            }
            app.startGenerationRequest(triggerPath: .autoDetect) { requestID in
                do {
                    try await app.generateSuggestion(for: original, session: session,
                        transcript: original.questionText, autoGenerated: true,
                        requestID: requestID, localProvider: HermeticQuestionRoutingProvider(),
                        localModelName: "synthetic-route-history-model", answerMode: .localQwenPrimary)
                } catch { rootError = error }
            }
            let root = try #require(app.activeAITask)
            await withTaskCancellationHandler { await root.value } onCancel: { root.cancel() }
            subscriber.cancel()
            if let callbackError { throw callbackError }
            if let rootError, !(rootError is CancellationError) { throw rootError }
            #expect(sawRoutingChild)
            #expect(replaced)
            #expect(root.isCancelled)
            await app.generationCoordinator.drainRetiredTasks()
            let history = try app.suggestionRepository.suggestions(sessionID: session.id)
            let saved = try #require(history.first { $0.detectedQuestionID == original.id })
            let decision = try #require(saved.questionDecision)
            #expect(decision.questionID == original.id)
            #expect(decision.contextSnapshotID == session.contextSnapshotID)
            #expect(decision.task == .project)
            #expect(decision.personalEvidence == .required)
            #expect(decision.basis == .candidateRecord)
            #expect(decision.model == "synthetic-route-history-model")
            #expect(decision.routerVersion == InterviewQuestionRouter.version)
            #expect(saved.candidateEvidenceIDs == ["test-candidate-evidence-0"])
            #expect(app.activeQuestionID == replacement.id)
            #expect(app.currentSuggestion == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aPreviousPersistedDecisionCannotReplaceTheSubmittedRouteInHistory() async throws {
        try await withApplication { app, session in
            var original = makeQuestion("Describe your small synthetic scheduling project.", session: session)
            applyDecision(.required, task: .project, basis: .candidateRecord,
                question: &original, snapshotID: session.contextSnapshotID)
            var stale = original
            // This is synthetic old model metadata, not changed router gold.
            applyDecision(.notRequired, task: .generalKnowledge, basis: .generalKnowledge,
                question: &stale, snapshotID: session.contextSnapshotID)
            try app.suggestionRepository.saveDetectedQuestion(stale)
            app.activateGeneration(question: original, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let replacement = makeQuestion("Explain a finite work queue and its capacity limit.", session: session)
            app.lastDetectedQuestion = replacement
            app.activateGeneration(question: replacement, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            await app.generationCoordinator.drainRetiredTasks()
            let history = try app.suggestionRepository.suggestions(sessionID: session.id)
            let saved = try #require(history.first { $0.detectedQuestionID == original.id })
            #expect(saved.questionDecision == original.taskDescriptor?.decision)
            #expect(saved.questionDecision != stale.taskDescriptor?.decision)
            #expect(saved.candidateEvidenceIDs == ["test-candidate-evidence-0"])
            #expect(saved.sayFirst.contains(Self.evidence))
            #expect(app.activeQuestionID == replacement.id)
            #expect(app.currentSuggestion == nil)
        }
    }

    private static let evidence = "I built a small synthetic scheduling prototype with a database queue and validated its result using repeatable tests."

    private func withApplication(_ operation: @MainActor (AppState, InterviewSession) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.history-evidence." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { _ in nil })
        let clock = ControlledGenerationWatchdogClock()
        app.generationWatchdogDelayProvider = clock
        do {
            await app.automaticContextBuildTask?.value
            let profile = TestSupport.makeCandidateProfile(statements: [Self.evidence])
            try app.interviewContextRepository.saveCandidateProfile(profile)
            app.refreshAll(); app.selectCandidateProfile(profile.id)
            var settings = app.settings; settings.saveTranscriptsLocally = true
            app.saveSettings(settings)
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic history evidence boundary")
            app.currentSession = session
            try await operation(app, session)
            clock.cancelAll()
            await app.shutdownForTesting(); try database.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            clock.cancelAll()
            await app.shutdownForTesting(); try? database.close()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }

    private func makeQuestion(_ text: String, session: InterviewSession) -> DetectedQuestion {
        .init(id: UUID().uuidString, sessionID: session.id, transcriptSegmentID: nil,
            questionText: text, intent: .technical, answerStrategy: .technicalExplanation,
            confidence: 0.99, reason: "Synthetic actual App entry", shouldTrigger: true,
            questionComplete: true, modelName: "synthetic-no-model", promptVersion: "history-evidence-contract",
            createdAt: Date())
    }

    private func applyDecision(_ evidence: PersonalEvidenceRequirement, task: InterviewTaskKind,
                               basis: QuestionAnswerBasis, question: inout DetectedQuestion,
                               snapshotID: String?) {
        var descriptor = InterviewTaskDescriptor(question: question.questionText)
        descriptor.apply(.init(task: task, personalEvidence: evidence, basis: basis,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-history-contract", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: question.id, questionRevision: 0,
            contextSnapshotID: snapshotID, artifactRevision: 0, model: "synthetic-no-model",
            failure: nil, latencyMS: 0))
        question.taskDescriptor = descriptor
    }
}
