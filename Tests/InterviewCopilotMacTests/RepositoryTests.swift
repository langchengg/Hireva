import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct RepositoryTests {
    @Test
    func documentRepositoryPersistsDocumentsChunksAndOnboardingGate() throws {
        let database = try makeTemporaryDatabase()
        let repository = DocumentRepository(database: database)

        #expect(try !repository.isOnboardingComplete())

        _ = try repository.saveDocument(
            type: .cv,
            title: "Resume",
            content: String(repeating: "Swift robotics machine learning leadership ", count: 10)
        )
        #expect(try !repository.isOnboardingComplete())

        _ = try repository.saveDocument(
            type: .jobDescription,
            title: "ML Engineer JD",
            content: String(repeating: "Build production AI applications with Swift macOS and reliable APIs ", count: 10)
        )

        #expect(try repository.isOnboardingComplete())
        #expect(try repository.documents().count == 2)
        #expect(try !repository.chunks(type: .cv).isEmpty)
    }

    @Test
    func sessionTranscriptSuggestionAndRecapCRUD() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let recaps = RecapRepository(database: database)

        let session = try sessions.createSession(mode: .mock, title: "Mock Interview")
        let segment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: session.id,
            speaker: .unknown,
            text: "Can you walk me through your robotics project?",
            startTime: nil,
            endTime: nil,
            createdAt: Date()
        )
        try transcripts.saveSegment(segment)

        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: session.id,
            transcriptSegmentID: segment.id,
            questionText: segment.text,
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.91,
            reason: "Direct project walkthrough prompt.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-v4-flash",
            promptVersion: PromptLibrary.questionDetector.versionTag,
            rawJSON: #"{"should_trigger":true}"#,
            createdAt: Date()
        )
        try suggestions.saveDetectedQuestion(question)

        let card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: session.id,
            questionID: question.id,
            strategy: "Project walkthrough",
            sayFirst: "I worked on a grounded robotics project.",
            keyPoints: ["Problem", "Method", "Contribution"],
            followUpReady: ["How did you evaluate it?"],
            confidence: 0.9,
            caution: "Avoid overclaiming.",
            evidenceUsed: ["robotics project"],
            riskLevel: .low,
            modelName: "deepseek-v4-flash",
            promptVersion: PromptLibrary.suggestionGenerator.versionTag,
            rawJSON: #"{"strategy":"Project walkthrough"}"#,
            createdAt: Date()
        )
        try suggestions.saveSuggestionCard(card)

        let recap = RecapReport(
            id: UUID().uuidString,
            sessionID: session.id,
            markdown: "# Interview Recap",
            modelName: "deepseek-v4-pro",
            promptVersion: PromptLibrary.recap.versionTag,
            createdAt: Date()
        )
        try recaps.saveRecap(recap)

        #expect(try transcripts.segments(sessionID: session.id).count == 1)
        #expect(try suggestions.questions(sessionID: session.id).first?.modelName == "deepseek-v4-flash")
        #expect(try suggestions.suggestions(sessionID: session.id).first?.evidenceUsed == ["robotics project"])
        #expect(try recaps.recap(sessionID: session.id)?.markdown == "# Interview Recap")

        try sessions.deleteSession(id: session.id)
        #expect(try sessions.session(id: session.id) == nil)
        #expect(try transcripts.segments(sessionID: session.id).isEmpty)
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
