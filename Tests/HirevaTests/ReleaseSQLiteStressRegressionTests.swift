import Foundation
import Testing
@testable import Hireva

@Suite("Release SQLite stress regressions", .serialized, .sharedRuntimeResources)
struct ReleaseSQLiteStressRegressionTests {
    @Test
    func concurrentHundredTranscriptQuestionAndSuggestionWritesRemainComplete() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessions = SessionRepository(database: fixture.database)
        let repositories = SendableRepositoryBox(
            transcripts: TranscriptRepository(database: fixture.database),
            suggestions: SuggestionRepository(database: fixture.database)
        )
        let session = try sessions.createSession(mode: .mock, title: "SQLite release stress")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let segment = TranscriptSegment(
                        id: "stress-segment-\(index)",
                        sessionID: session.id,
                        source: .systemAudio,
                        speaker: .interviewer,
                        text: "What did you validate in stress case \(index)?",
                        createdAt: Date(timeIntervalSince1970: Double(index)),
                        confidence: 1.0,
                        asrSource: .localParakeetASR,
                        asrFinalizationReason: "final_accepted"
                    )
                    let question = DetectedQuestion(
                        id: "stress-question-\(index)",
                        sessionID: session.id,
                        transcriptSegmentID: segment.id,
                        questionText: segment.text,
                        intent: .projectDeepDive,
                        answerStrategy: .projectWalkthrough,
                        confidence: 0.95,
                        reason: "SQLite release stress fixture.",
                        shouldTrigger: true,
                        questionComplete: true,
                        modelName: "stress-model",
                        promptVersion: "stress-v1",
                        rawJSON: nil,
                        createdAt: Date(timeIntervalSince1970: Double(index) + 0.1)
                    )
                    let card = SuggestionCard(
                        id: "stress-card-\(index)",
                        sessionID: session.id,
                        questionID: question.id,
                        strategy: "Explain the validation method and result.",
                        sayFirst: "I validated stress case \(index) with a deterministic acceptance check.",
                        keyPoints: ["Input \(index)", "Observed result \(index)"],
                        followUpReady: ["I can describe the failure boundary for case \(index)."],
                        confidence: 0.9,
                        caution: nil,
                        evidenceUsed: [],
                        riskLevel: .low,
                        modelName: "stress-model",
                        promptVersion: "stress-v1",
                        rawJSON: nil,
                        createdAt: Date(timeIntervalSince1970: Double(index) + 0.2),
                        questionText: segment.text,
                        generationID: "stress-generation-\(index)",
                        stageBCompleted: true,
                        stageBStatus: "completed"
                    )

                    try repositories.transcripts.saveSegment(segment)
                    try repositories.suggestions.saveDetectedQuestion(question)
                    try repositories.suggestions.saveSuggestionCard(card)
                }
            }
            try await group.waitForAll()
        }

        let segments = try repositories.transcripts.segments(sessionID: session.id)
        let questions = try repositories.suggestions.questions(sessionID: session.id)
        let cards = try repositories.suggestions.suggestions(sessionID: session.id)
        #expect(segments.count == 100)
        #expect(questions.count == 100)
        #expect(cards.count == 100)
        #expect(Set(segments.map(\.id)).count == 100)
        #expect(Set(questions.map(\.id)).count == 100)
        #expect(Set(cards.map(\.id)).count == 100)
        #expect(Set(questions.compactMap(\.transcriptSegmentID)) == Set(segments.map(\.id)))
        #expect(Set(cards.compactMap(\.detectedQuestionID)) == Set(questions.map(\.id)))
        #expect(cards.allSatisfy { $0.stageBCompleted == true && $0.stageBStatus == "completed" })
    }

    private func makeFixture() throws -> (root: URL, database: AppDatabase) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaReleaseSQLiteStress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try AppDatabase(path: root.appendingPathComponent("stress.sqlite")))
    }
}

private final class SendableRepositoryBox: @unchecked Sendable {
    let transcripts: TranscriptRepository
    let suggestions: SuggestionRepository

    init(transcripts: TranscriptRepository, suggestions: SuggestionRepository) {
        self.transcripts = transcripts
        self.suggestions = suggestions
    }
}
