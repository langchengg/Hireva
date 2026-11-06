import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppGenerationCompletionAuditAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func completionAuditCannotBorrowPresentationFromItsSubscriberReplacement(replaceAfterAudit: Bool) async throws {
        try await withApplication { app, session in
            let original = question(session: session, text: "Explain database transactions and atomicity.")
            let replacement = question(session: session, text: "Explain transaction isolation and visibility.")
            try app.suggestionRepository.saveDetectedQuestion(original)
            try app.suggestionRepository.saveDetectedQuestion(replacement)
            let originalID = UUID().uuidString, replacementID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            #expect(app.displaySuggestionIfAligned(card(question: original, generationID: originalID,
                snapshotID: session.contextSnapshotID,
                answer: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."),
                question: original, generationID: originalID, triggerPath: .manualGenerate))
            _ = try #require(app.currentSuggestion)
            let replacementCard = card(question: replacement, generationID: replacementID,
                snapshotID: session.contextSnapshotID,
                answer: "Transaction isolation controls which concurrent database changes each transaction can observe. The selected isolation level determines permitted anomalies such as dirty reads, nonrepeatable reads and phantoms; stronger levels can require more coordination or retrying conflicting transactions.")
            var replaced = false
            var root: Task<Void, Never>?
            var answer: Task<String, Error>?
            let observation = app.diagnosticsState.$recentEvents.dropFirst().sink { records in
                guard replaceAfterAudit, !replaced, let record = records.last,
                      record.name == "generationCompleted", record.generationID == originalID else { return }
                replaced = true
                app.startGenerationRequest(triggerPath: .regenerate) { _ in }
                root = app.activeAITask
                guard let requestID = app.generationCoordinator.activeRequest?.id else {
                    Issue.record("The diagnostic subscriber must own its replacement request")
                    return
                }
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                    speaker: .unknown, requestID: requestID)
                let owned = Task<String, Error> { "Finite replacement answer" }
                answer = owned
                app.registerStageATask(owned, generationID: replacementID)
                #expect(app.displaySuggestionIfAligned(replacementCard, question: replacement,
                    generationID: replacementID, triggerPath: .regenerate),
                    "The replacement must itself pass the real card publication guard")
            }
            app.markFullCardVisible(generationID: originalID)
            observation.cancel()
            let acceptedAudit = app.diagnosticsState.recentEvents.filter {
                $0.name == "generationCompleted" && $0.generationID == originalID
            }
            #expect(acceptedAudit.count == 1, "The already accepted historical completion is retained")
            #expect(acceptedAudit.first?.questionID == original.id)
            let followingAudit = app.diagnosticsState.recentEvents.filter {
                $0.name == "answer.stream.completed" && $0.generationID == originalID
            }
            if replaceAfterAudit {
                #expect(replaced)
                #expect(app.currentGenerationID == replacementID)
                #expect(app.currentSuggestion?.detectedQuestionID == replacement.id)
                #expect(app.generationUIState == .preparing(questionID: replacement.id,
                    generationID: replacementID, triggerPath: .regenerate))
                #expect(followingAudit.isEmpty,
                    "The old caller must stop before a lifecycle wrapper enriches its audit with Q2 presentation")
            } else {
                #expect(!replaced)
                #expect(followingAudit.count == 1, "Normal completion still records the second audit")
                #expect(followingAudit.first?.questionID == original.id)
                #expect(followingAudit.first?.visibleQuestionText == original.questionText)
                #expect(followingAudit.first?.currentState.contains(GenerationUIState.answerReady(
                    questionID: original.id, generationID: originalID, triggerPath: .manualGenerate).displayName) == true)
            }
            await root?.value
            _ = await answer?.result
            app.generationCoordinator.invalidateAndCancel()
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    private func withApplication(_ operation: @MainActor (AppState, InterviewSession) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaCompletionAudit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let store = RuntimeTranscriptTraceStore()
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.completion-audit." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults, embeddingProviderResolverOverride: { _ in nil },
            diagnosticsTraceStore: store)
        do {
            try #require(app.settings.effectiveDiagnosticTraceMode == .off)
            // Configure the private URL before admitting any synthetic text.
            app.runtimeTranscriptTraceLogURL = folder.appendingPathComponent("trace.jsonl")
            app.settings.saveTranscriptsLocally = true
            app.settings.diagnosticTraceMode = .fullText
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic audit reentry")
            app.currentSession = session
            try await operation(app, session)
            await app.shutdownForTesting()
            await store.finishPendingOperationsForTesting()
            try database.close()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: folder)
        } catch {
            await app.shutdownForTesting()
            await store.finishPendingOperationsForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func question(session: InterviewSession, text: String) -> DetectedQuestion {
        DetectedQuestion(id: UUID().uuidString, sessionID: session.id, transcriptSegmentID: nil,
            questionText: text, intent: .technical, answerStrategy: .technicalExplanation, confidence: 0.99,
            reason: "Synthetic completion audit", shouldTrigger: true, questionComplete: true,
            modelName: "synthetic-no-provider", promptVersion: "synthetic-no-provider", createdAt: Date())
    }

    private func card(question: DetectedQuestion, generationID: String,
                      snapshotID: String?, answer: String) -> SuggestionCard {
        var card = SuggestionCard(id: UUID().uuidString, sessionID: question.sessionID,
            questionID: question.id, strategy: "Explanation", sayFirst: answer, keyPoints: [], followUpReady: [],
            confidence: 0.95, caution: nil, evidenceUsed: [], riskLevel: .low,
            modelName: "synthetic-no-provider", promptVersion: "synthetic-no-provider", rawJSON: nil, createdAt: Date())
        card.detectedQuestionID = question.id
        card.generationID = generationID
        card.questionText = question.questionText
        card.promptQuestionText = question.questionText
        card.promptPrimaryQuestion = question.questionText
        card.contextSnapshotID = snapshotID
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        return card
    }
}
