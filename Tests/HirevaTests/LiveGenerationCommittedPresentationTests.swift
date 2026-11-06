import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct LiveGenerationCommittedPresentationTests {
    @Test(.timeLimit(.minutes(1)), arguments: PresentationEntry.allCases)
    fileprivate func actualActivationCannotWriteItsFirstSetterOverSubscriberReplacement(entry: PresentationEntry) async throws {
        try await withApplication { app, session in
            let original = question(session: session, suffix: "original", text: "Explain database transactions and atomicity.")
            let replacement = question(session: session, suffix: "replacement", text: "Explain transaction isolation and visibility.")
            let submitted = question(session: session, suffix: "submitted", text: "Explain transaction durability and recovery.")
            try app.suggestionRepository.saveDetectedQuestion(original)
            try app.suggestionRepository.saveDetectedQuestion(replacement)
            let originalID = UUID().uuidString, replacementID = UUID().uuidString, submittedID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            let originalCard = card(question: original, generationID: originalID,
                contextSnapshotID: session.contextSnapshotID,
                answer: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.")
            #expect(app.displaySuggestionIfAligned(originalCard, question: original,
                generationID: originalID, triggerPath: .manualGenerate))
            _ = try #require(app.currentSuggestion)
            let replacementCard = card(question: replacement, generationID: replacementID,
                contextSnapshotID: session.contextSnapshotID,
                answer: "Transaction isolation controls which concurrent database changes each transaction can observe. The selected isolation level determines permitted anomalies such as dirty reads, nonrepeatable reads and phantoms; stronger levels can require more coordination or retrying conflicting transactions.")
            let replacementAnswer = Task<String, Error> { "Finite replacement-owned answer" }
            var replacementRoot: Task<Void, Never>?
            var acceptedReplacement: SuggestionCard?
            var replaced = false
            @MainActor func replace() {
                guard !replaced else { return }
                replaced = true
                app.startGenerationRequest(triggerPath: .regenerate) { _ in }
                replacementRoot = app.activeAITask
                guard let requestID = app.generationCoordinator.activeRequest?.id else {
                    Issue.record("The subscriber must own its replacement request")
                    return
                }
                app.activateGeneration(question: replacement, generationID: replacementID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                    speaker: .unknown, requestID: requestID)
                app.registerStageATask(replacementAnswer, generationID: replacementID)
                #expect(app.displaySuggestionIfAligned(replacementCard, question: replacement,
                    generationID: replacementID, triggerPath: .regenerate))
                acceptedReplacement = app.currentSuggestion
            }
            let observation: AnyCancellable
            switch entry {
            case .phase:
                observation = app.liveInterview.generationStateUpdates.dropFirst().sink { incoming in
                    if incoming.generationID == submittedID { replace() }
                }
            case .suggestion:
                observation = app.liveInterview.suggestionUpdates.dropFirst().sink { incoming in
                    if incoming == nil { replace() }
                }
            case .telemetry:
                observation = app.generationTelemetryUpdates.dropFirst().sink { incoming in
                    if incoming.generationID == submittedID { replace() }
                }
            case .providerStream:
                observation = app.providerStreamActiveUpdates.dropFirst().sink { incoming in
                    if !incoming && app.currentGenerationID == submittedID { replace() }
                }
            case .streamedAnswer:
                observation = app.liveInterview.streamedSayFirstUpdates.dropFirst().sink { incoming in
                    if incoming.isEmpty && app.currentGenerationID == submittedID { replace() }
                }
            case .retrievedChunks:
                observation = app.liveInterview.$currentSuggestionRetrievedChunks.dropFirst().sink { incoming in
                    if incoming.isEmpty && app.currentGenerationID == submittedID { replace() }
                }
            }
            app.activateGeneration(question: submitted, generationID: submittedID,
                triggerPath: .manualGenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            observation.cancel()
            #expect(replaced)
            #expect(acceptedReplacement != nil,
                "The subscriber's Q2 card must itself pass the actual production publication guard")
            #expect(app.currentGenerationID == replacementID)
            #expect(app.activeQuestionID == replacement.id)
            #expect(app.currentSuggestion == acceptedReplacement,
                "An older first setter must not erase the validated Q2 presentation")
            #expect(app.generationUIState == .preparing(questionID: replacement.id,
                generationID: replacementID, triggerPath: .regenerate))
            #expect(app.currentGenerationTelemetry.generationID == replacementID)
            #expect(app.currentGenerationTelemetry.questionID == replacement.id)
            #expect(app.currentPromptPrimaryQuestion == replacement.questionText)
            #expect(app.generationCoordinator.stageATask == replacementAnswer)
            #expect(app.providerStreamActive)
            #expect(!replacementAnswer.isCancelled)
            await replacementRoot?.value
            _ = await replacementAnswer.result
            app.generationCoordinator.invalidateAndCancel()
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    // Installed Combine behavior characterization, not a product RED or a
    // substitute for the real application-entry regressions above.
    @Test
    func currentValueSubjectCommitsBeforeItsSynchronousSubscriberAndRetainsNestedWrite() {
        let subject = CurrentValueSubject<Int, Never>(0)
        var observedStoredValues: [Int] = []
        let observation = subject.dropFirst().sink { incoming in
            observedStoredValues.append(subject.value)
            if incoming == 1 { subject.send(2) }
        }
        subject.send(1)
        #expect(observedStoredValues == [1, 2])
        #expect(subject.value == 2)
        var replayed: [Int] = []
        let replay = subject.sink { replayed.append($0) }
        subject.send(2)
        #expect(replayed == [2, 2], "Initial and explicit same-value delivery remain part of the contract")
        observation.cancel()
        replay.cancel()
    }

    private func withApplication(_ operation: @MainActor (AppState, InterviewSession) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.committed-presentation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { _ in nil })
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic committed presentation")
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
        DetectedQuestion(id: "synthetic-live-" + suffix + "-" + UUID().uuidString, sessionID: session.id,
            transcriptSegmentID: nil, questionText: text, intent: .technical,
            answerStrategy: .technicalExplanation, confidence: 0.99, reason: "Synthetic App entry",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", createdAt: Date())
    }

    private func card(question: DetectedQuestion, generationID: String,
                      contextSnapshotID: String?, answer: String) -> SuggestionCard {
        var card = SuggestionCard(id: UUID().uuidString, sessionID: question.sessionID,
            questionID: question.id, strategy: "Explanation", sayFirst: answer,
            keyPoints: [], followUpReady: [], confidence: 0.95, caution: nil,
            evidenceUsed: [], riskLevel: .low, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", rawJSON: nil, createdAt: Date())
        card.detectedQuestionID = question.id
        card.generationID = generationID
        card.questionText = question.questionText
        card.promptQuestionText = question.questionText
        card.promptPrimaryQuestion = question.questionText
        card.contextSnapshotID = contextSnapshotID
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        return card
    }
}

fileprivate enum PresentationEntry: String, CaseIterable, Sendable {
    case phase, suggestion, telemetry, providerStream, streamedAnswer, retrievedChunks
}
