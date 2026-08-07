import Foundation
import Testing
@testable import Hireva

@Suite
struct ReleasePersistenceOrderingRegressionTests {
    @Test
    func duplicateDetectedQuestionWriteIsIdempotent() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Persistence regression")
        let question = makeQuestion(sessionID: session.id)

        try suggestions.saveDetectedQuestion(question)
        try suggestions.saveDetectedQuestion(question)

        let saved = try suggestions.questions(sessionID: session.id)
        #expect(saved.count == 1)
        #expect(saved.first?.id == question.id)
    }

    @Test
    func olderIncompleteSnapshotCannotOverwriteCompletedSuggestion() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Monotonic suggestion regression")
        let question = makeQuestion(sessionID: session.id)
        try suggestions.saveDetectedQuestion(question)

        var completed = makeCard(
            sessionID: session.id,
            questionID: question.id,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        completed.strategy = "Completed strategy"
        completed.sayFirst = "Completed grounded answer"
        completed.keyPoints = ["Complete point one", "Complete point two"]
        completed.stageBCompleted = true
        completed.stageBStatus = "completed"
        completed.fullCardVisibleMS = 480
        try suggestions.saveSuggestionCard(completed)

        var olderIncomplete = makeCard(
            sessionID: session.id,
            questionID: question.id,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        olderIncomplete.strategy = "Older partial strategy"
        olderIncomplete.sayFirst = "Older partial answer"
        olderIncomplete.keyPoints = []
        olderIncomplete.stageBCompleted = false
        olderIncomplete.stageBStatus = "streaming"
        olderIncomplete.fullCardVisibleMS = nil
        try suggestions.saveSuggestionCard(olderIncomplete)

        let saved = try #require(suggestions.suggestions(sessionID: session.id).first)
        #expect(saved.id == completed.id)
        #expect(saved.strategy == completed.strategy)
        #expect(saved.sayFirst == completed.sayFirst)
        #expect(saved.keyPoints == completed.keyPoints)
        #expect(saved.stageBCompleted == true)
        #expect(saved.stageBStatus == "completed")
        #expect(saved.fullCardVisibleMS == completed.fullCardVisibleMS)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaReleasePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeQuestion(sessionID: String) -> DetectedQuestion {
        DetectedQuestion(
            id: "release-question",
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: "What did you build and how did you validate it?",
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.95,
            reason: "Deterministic persistence regression fixture.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test-model",
            promptVersion: "test-prompt",
            rawJSON: nil,
            createdAt: Date(timeIntervalSince1970: 50)
        )
    }

    private func makeCard(
        sessionID: String,
        questionID: String,
        createdAt: Date
    ) -> SuggestionCard {
        SuggestionCard(
            id: "release-card",
            sessionID: sessionID,
            questionID: questionID,
            strategy: "Fixture strategy",
            sayFirst: "Fixture answer",
            keyPoints: ["Fixture point"],
            followUpReady: ["Fixture follow-up"],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "test-model",
            promptVersion: "test-prompt",
            rawJSON: nil,
            createdAt: createdAt,
            questionText: "What did you build and how did you validate it?",
            generationID: "release-generation",
            stageBCompleted: false,
            stageBStatus: "streaming"
        )
    }
}
