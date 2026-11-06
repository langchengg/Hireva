import Foundation
import Testing
@testable import Hireva

// These behavior tests compile both before and after the ownership move. They
// call current production boundaries and do not depend on the new feature type.
@MainActor
struct LiveContentCharacterizationTests {
    @Test(.timeLimit(.minutes(1)))
    func actualTranscriptCallbacksPreserveFinalAndResetSemantics() async throws {
        try await withApp { app, _ in
            let owner = app
            app.recordTranscriptRuntimeEvent(.asrPartial(sessionID: "synthetic-live-session",
                text: "Synthetic partial", recognitionTaskID: "synthetic-recognition", eventSequence: 1,
                sourceStartUTF16: 0, sourceEndUTF16: 17, isFinal: false, timestamp: Date()))
            #expect(owner.rawTranscriptText == "Synthetic partial")
            #expect(owner.partialTranscriptText == "Synthetic partial")
            #expect(app.displayTranscriptText == "Synthetic partial")
            app.recordTranscriptRuntimeEvent(.asrFinal(sessionID: "synthetic-live-session",
                text: "Synthetic final", recognitionTaskID: "synthetic-recognition", eventSequence: 2,
                sourceStartUTF16: 0, sourceEndUTF16: 15, isFinal: true, timestamp: Date()))
            #expect(owner.rawTranscriptText == "Synthetic final")
            #expect(owner.finalTranscriptText == "Synthetic final")
            #expect(owner.partialTranscriptText.isEmpty)
            #expect(app.displayTranscriptText == "Synthetic final")
            app.lastAcceptedQuestionText = "Synthetic accepted question"
            app.resetRuntimeTranscriptState(clearEvents: true)
            #expect(owner.rawTranscriptText.isEmpty)
            #expect(owner.finalTranscriptText.isEmpty)
            #expect(owner.lastAcceptedQuestionText.isEmpty)
            #expect(app.displayTranscriptText.isEmpty)
            #expect(app.partialUtteranceFinalizationTasks.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualPublicationPreservesCardQuestionBeforeLaterDetection() async throws {
        try await withApp { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let first = makeQuestion(sessionID: session.id, id: "visible-q1", text: "Explain database transactions and atomicity.")
            let second = makeQuestion(sessionID: session.id, id: "detected-q2", text: "Explain transaction isolation.")
            let generationID = "synthetic-live-generation"
            app.activateGeneration(question: first, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            try #require(app.publishStreamingSections(.init(strategy: "Explanation",
                sayFirst: "A database transaction groups operations into an atomic unit that either commits or rolls back together.",
                keyPoints: ["Atomicity commits or rolls back the complete transaction."],
                followUpReady: [], caution: ""), cardID: "synthetic-visible-card", generationID: generationID,
                question: first, session: session, requestStart: Date(), stageBStreamStartedMS: nil))
            app.lastDetectedQuestion = second
            let ownerRender = app.visibleAssistantRenderState
            #expect(ownerRender.questionText == first.questionText)
            #expect(ownerRender.activeQuestionID == first.id)
            #expect(ownerRender.hasAnswerText)
            #expect(app.currentSuggestion?.detectedQuestionID == first.id)
            #expect(!app.shouldShowBlockingAnswerSpinner)
            #expect(app.shouldShowAnswerExpansionStatus)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func productionHistoryCallerPreservesUpsertCapAndSeparateHistorySelection() async throws {
        try await withApp { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            app.selectedSessionID = session.id
            for index in 0..<22 {
                var card = makeCard(sessionID: session.id, id: "history-\(index)", questionID: "history-q-\(index)")
                card.createdAt = Date(timeIntervalSince1970: Double(index))
                app.recordVisibleSuggestionInHistory(card)
            }
            #expect(app.liveSuggestionHistory.count == 20)
            #expect(app.liveSuggestionHistory.first?.id == "history-2")
            #expect(app.selectedSessionSuggestions == app.liveSuggestionHistory)
            var replacement = try #require(app.liveSuggestionHistory.last)
            replacement.sayFirst = "Synthetic updated historical answer."
            app.recordVisibleSuggestionInHistory(replacement)
            #expect(app.liveSuggestionHistory.count == 20)
            #expect(app.liveSuggestionHistory.last?.sayFirst == replacement.sayFirst)
            var rejected = replacement
            rejected.id = "partial-history"
            rejected.isPartial = true
            app.recordVisibleSuggestionInHistory(rejected)
            rejected.id = "foreign-history"
            rejected.isPartial = false
            rejected.sessionID = "different-session"
            app.recordVisibleSuggestionInHistory(rejected)
            rejected.id = "empty-history"
            rejected.sessionID = session.id
            rejected.sayFirst = "  "
            app.recordVisibleSuggestionInHistory(rejected)
            #expect(app.liveSuggestionHistory.count == 20)
            #expect(app.liveSuggestionHistory.allSatisfy { !$0.id.contains("-history") })
            #expect(app.selectedSessionSuggestions == app.liveSuggestionHistory)
        }
    }

    private func withApp(_ body: @MainActor (AppState, AppDatabase) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            try await body(app, database)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private func makeQuestion(sessionID: String, id: String, text: String) -> DetectedQuestion {
        DetectedQuestion(id: id, sessionID: sessionID, transcriptSegmentID: nil, questionText: text,
            intent: .technical, answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic Live owner fixture",
            shouldTrigger: true, questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }

    private func makeCard(sessionID: String, id: String, questionID: String) -> SuggestionCard {
        SuggestionCard(id: id, sessionID: sessionID, questionID: questionID, strategy: "Synthetic",
            sayFirst: "Synthetic complete answer.", keyPoints: [], followUpReady: [], confidence: nil, caution: nil,
            evidenceUsed: [], riskLevel: nil, modelName: "fixture", promptVersion: "fixture", rawJSON: nil, createdAt: Date())
    }

}
