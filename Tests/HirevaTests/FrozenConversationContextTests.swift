import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite(.serialized)
struct FrozenConversationContextTests {
    @Test
    func validCapturedParentAndDecisionSurviveAnotherVisibleCard() async throws {
        try await withFixture { (app: AppState, session: InterviewSession) throws -> Void in
            var question = makeQuestion(sessionID: session.id)
            let parent = makeParent(session: session)
            var descriptor = InterviewTaskDescriptor(question: question.questionText)
            descriptor.conversationContextCaptured = true
            descriptor.conversationContext = frozenParent(parent, mode: app.interviewSessionMode)
            descriptor.apply(decision(for: question, parent: parent))
            question.taskDescriptor = descriptor
            let originalQuestion = question
            let replacement = makeParent(session: session, id: "new-visible-parent")
            app.currentSuggestion = replacement

            app.freezeConversationContext(for: &question)

            #expect(question == originalQuestion)
            #expect(question.taskDescriptor?.decision?.parentQuestionID == parent.questionID)
            #expect(app.currentSuggestion == replacement)
        }
    }

    @Test(arguments: [ExpiredParent.session, .context, .mode])
    func obsoleteCapturedParentInvalidatesDecisionAndNeverRebinds(change: ExpiredParent) async throws {
        try await withFixture { (app: AppState, session: InterviewSession) throws -> Void in
            var question = makeQuestion(sessionID: session.id)
            let originalParent = makeParent(session: session)
            var descriptor = InterviewTaskDescriptor(question: question.questionText)
            descriptor.conversationContextCaptured = true
            descriptor.conversationContext = frozenParent(originalParent, mode: app.interviewSessionMode)
            descriptor.apply(decision(for: question, parent: originalParent))
            question.taskDescriptor = descriptor
            var replacementSession = session
            switch change {
            case .session:
                replacementSession = try app.sessionRepository.createSession(mode: .mock)
                replacementSession.contextSnapshotID = session.contextSnapshotID
                question.sessionID = replacementSession.id
            case .context:
                replacementSession.contextSnapshotID = "replacement-context"
            case .mode:
                app.interviewSessionMode = .presentation
            }
            app.currentSession = replacementSession
            let replacement = makeParent(session: replacementSession, id: "new-visible-parent")
            app.currentSuggestion = replacement

            app.freezeConversationContext(for: &question)

            #expect(question.taskDescriptor?.conversationContext == nil)
            #expect(question.taskDescriptor?.decision == nil)
            #expect(question.taskDescriptor?.conversationContextCaptured == true)
            #expect(question.taskDescriptor?.kind == descriptor.kind)
            #expect(question.taskDescriptor?.criteria == descriptor.criteria)
            #expect(app.currentSuggestion == replacement)

            // Returning to the earlier inputs must not revive an invalidated
            // parent or silently capture whichever answer is visible now.
            question.sessionID = session.id
            app.currentSession = session
            app.interviewSessionMode = .panelQuestions
            app.currentSuggestion = originalParent
            app.freezeConversationContext(for: &question)
            #expect(question.taskDescriptor?.conversationContext == nil)
            #expect(question.taskDescriptor?.decision == nil)
            #expect(question.taskDescriptor?.conversationContextCaptured == true)
        }
    }

    @Test
    func firstCaptureBindsCompleteSameContextParentOnlyOnce() async throws {
        try await withFixture { (app: AppState, session: InterviewSession) throws -> Void in
            var question = makeQuestion(sessionID: session.id)
            let parent = makeParent(session: session)
            app.currentSuggestion = parent

            app.freezeConversationContext(for: &question)

            let captured = try #require(question.taskDescriptor?.conversationContext)
            #expect(captured == frozenParent(parent, mode: .panelQuestions))
            #expect(question.taskDescriptor?.conversationContextCaptured == true)
            #expect(question.taskDescriptor?.decision == nil)
            app.currentSuggestion = makeParent(session: session, id: "later-visible-parent")
            app.freezeConversationContext(for: &question)
            #expect(question.taskDescriptor?.conversationContext == captured)
        }
    }

    @Test(arguments: RejectedParent.allCases)
    func firstCaptureRejectsUnusableParentWithoutLaterRebinding(reason: RejectedParent) async throws {
        try await withFixture { (app: AppState, session: InterviewSession) throws -> Void in
            var question = makeQuestion(sessionID: session.id)
            var parent = makeParent(session: session)
            switch reason {
            case .noVisibleCard: break
            case .differentSession: parent.sessionID = "other-session"
            case .sameQuestion: parent.questionID = question.id
            case .differentContext: parent.contextSnapshotID = "other-context"
            case .missingQuestionIdentity: parent.questionID = nil
            case .missingQuestionText: parent.questionText = nil
            case .emptyQuestionText: parent.questionText = ""
            case .partialAnswer: parent.isPartial = true
            }
            app.currentSuggestion = reason == .noVisibleCard ? nil : parent

            app.freezeConversationContext(for: &question)

            #expect(question.taskDescriptor?.conversationContext == nil)
            #expect(question.taskDescriptor?.conversationContextCaptured == true)
            app.currentSuggestion = makeParent(session: session, id: "later-valid-parent")
            app.freezeConversationContext(for: &question)
            #expect(question.taskDescriptor?.conversationContext == nil)
            #expect(question.taskDescriptor?.conversationContextCaptured == true)
        }
    }

    enum ExpiredParent: String { case session, context, mode }
    enum RejectedParent: String, CaseIterable {
        case noVisibleCard, differentSession, sameQuestion, differentContext
        case missingQuestionIdentity, missingQuestionText, emptyQuestionText, partialAnswer
    }

    private func withFixture(_ operation: (AppState, InterviewSession) throws -> Void) async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FrozenConversationContext")
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider())
        do {
            var session = try app.sessionRepository.createSession(mode: .mock)
            session.contextSnapshotID = "frozen-conversation-context"
            app.currentSession = session
            app.interviewSessionMode = .panelQuestions
            try operation(app, session)
        } catch {
            await app.shutdownForTesting()
            throw error
        }
        await app.shutdownForTesting()
    }

    private func makeQuestion(sessionID: String) -> DetectedQuestion {
        .init(id: "followup-question", sessionID: sessionID, transcriptSegmentID: nil,
            questionText: "Why did you choose that?", intent: .technical,
            answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic freeze fixture",
            shouldTrigger: true, questionComplete: true, modelName: "fixture",
            promptVersion: "fixture", createdAt: Date())
    }

    private func makeParent(session: InterviewSession, id: String = "original-parent") -> SuggestionCard {
        var card = SuggestionCard(id: id + "-card", sessionID: session.id, questionID: id,
            strategy: "Explanation", sayFirst: "Use bounded exponential backoff with jitter.",
            keyPoints: [], followUpReady: [], confidence: 1, caution: nil,
            evidenceUsed: [], riskLevel: .low, modelName: "fixture", promptVersion: "fixture",
            rawJSON: nil, createdAt: Date())
        card.questionText = "Compare retry strategies for transient requests."
        card.contextSnapshotID = session.contextSnapshotID
        card.stageBCompleted = true
        card.stageBStatus = "completed"
        return card
    }

    private func frozenParent(_ card: SuggestionCard, mode: InterviewSessionMode) -> FrozenQuestionConversation {
        .init(sessionID: card.sessionID, questionID: card.questionID ?? "",
            questionText: card.questionText ?? "", answerText: card.sayFirst,
            contextSnapshotID: card.contextSnapshotID, mode: mode.rawValue)
    }

    private func decision(for question: DetectedQuestion, parent: SuggestionCard) -> InterviewQuestionDecision {
        .init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .followUp, parentQuestionID: parent.questionID,
            parentQuestionText: parent.questionText, parentAnswerText: parent.sayFirst,
            source: "synthetic-freeze-fixture", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: question.id, questionRevision: 0,
            contextSnapshotID: parent.contextSnapshotID, artifactRevision: 0,
            model: "fixture", failure: nil, latencyMS: 0)
    }
}
