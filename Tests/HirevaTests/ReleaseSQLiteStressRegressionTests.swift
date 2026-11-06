import Foundation
import GRDB
import SQLite3
import Testing
@testable import Hireva

@Suite("Release SQLite stress regressions")
struct ReleaseSQLiteStressRegressionTests {
    @Test
    func outerSavepointStartsTransactionWithoutBeginAndRollbackToKeepsItActive() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        try database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE savepoint_probe(v INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO savepoint_probe VALUES(0)")
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 1)
            try db.execute(sql: "SAVEPOINT outer_probe")
            defer { if db.isInsideTransaction { try? db.execute(sql: "ROLLBACK") } }
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 0)
            try db.execute(sql: "INSERT INTO savepoint_probe VALUES(1)")
            try db.execute(sql: "SAVEPOINT inner_probe")
            try db.execute(sql: "INSERT INTO savepoint_probe VALUES(2)")
            try db.execute(sql: "ROLLBACK TO inner_probe")
            #expect(try Int.fetchAll(db, sql: "SELECT v FROM savepoint_probe ORDER BY v") == [0, 1])
            #expect(db.isInsideTransaction)
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 0)
            try db.execute(sql: "RELEASE inner_probe")
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 0)
            try db.execute(sql: "RELEASE outer_probe")
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 1)
            #expect(try Int.fetchAll(db, sql: "SELECT v FROM savepoint_probe ORDER BY v") == [0, 1])
            print("SQLite \(String(cString: sqlite3_libversion())) outer SAVEPOINT: no BEGIN, rollback-to active, outer RELEASE committed")
        }
    }

    @Test(arguments: ["", "OR ROLLBACK", "OR FAIL", "wrapper rollback"], ["UNIQUE", "PRIMARY KEY"])
    func statementFailureDoesNotImplyWholeTransactionRollback(policy: String, constraint: String) throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        try database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE conflict_probe(v INTEGER \(constraint))")
            try db.execute(sql: "INSERT INTO conflict_probe VALUES(0)")
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 1)
            try db.execute(sql: "BEGIN")
            defer { if db.isInsideTransaction { try? db.execute(sql: "ROLLBACK") } }
            try db.execute(sql: "INSERT INTO conflict_probe VALUES(10)")
            let clause = policy == "wrapper rollback" ? "" : policy
            do {
                try db.execute(sql: "INSERT \(clause) INTO conflict_probe VALUES(2),(0),(3)")
                Issue.record("The duplicate must fail")
            } catch let error as DatabaseError {
                #expect(error.resultCode == .SQLITE_CONSTRAINT)
                #expect(error.extendedResultCode == (constraint == "UNIQUE" ? .SQLITE_CONSTRAINT_UNIQUE : .SQLITE_CONSTRAINT_PRIMARYKEY))
            }
            if policy == "wrapper rollback" { try db.execute(sql: "ROLLBACK") }
            let wholeRollback = policy == "OR ROLLBACK" || policy == "wrapper rollback"
            let expected = wholeRollback ? [0] : policy == "OR FAIL" ? [0, 2, 10] : [0, 10]
            #expect(try Int.fetchAll(db, sql: "SELECT v FROM conflict_probe ORDER BY v") == expected)
            #expect(db.isInsideTransaction == !wholeRollback)
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == (wholeRollback ? 1 : 0))
            print("SQLite \(String(cString: sqlite3_libversion())) \(constraint) \(policy): rows=\(expected), active=\(!wholeRollback)")
        }
    }

    @Test
    func failPreservesEarlierRowsWithoutKeepingAnImplicitTransactionOpen() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        try database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE implicit_conflict_probe(v INTEGER UNIQUE)")
            try db.execute(sql: "INSERT INTO implicit_conflict_probe VALUES(0)")
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 1)
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db.sqliteConnection,
                "INSERT OR FAIL INTO implicit_conflict_probe VALUES(2),(0),(3)",
                -1, &statement, nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == ResultCode.SQLITE_CONSTRAINT_UNIQUE.rawValue)
            #expect(sqlite3_extended_errcode(db.sqliteConnection) == ResultCode.SQLITE_CONSTRAINT_UNIQUE.rawValue)
            #expect(sqlite3_finalize(statement) == ResultCode.SQLITE_CONSTRAINT_UNIQUE.rawValue)
            #expect(sqlite3_get_autocommit(db.sqliteConnection) == 1)
            #expect(!db.isInsideTransaction)
            #expect(try Int.fetchAll(db, sql: "SELECT v FROM implicit_conflict_probe ORDER BY v") == [0, 2])
            print("SQLite \(String(cString: sqlite3_libversion())) implicit OR FAIL: rows=[0, 2], autocommit=1")
        }
    }

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
