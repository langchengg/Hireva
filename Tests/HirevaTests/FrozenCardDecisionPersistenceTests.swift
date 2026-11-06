import Foundation
import GRDB
import Testing
@testable import Hireva

/// Durable answer provenance through actual repositories and migrations. Every
/// fixture is synthetic and isolated; no model, network or native resource runs.
struct FrozenCardDecisionPersistenceTests {
    @Test
    func populatedV21MigrationPreservesLegacyUnknownPolicyAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva-card-policy-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.sqlite")
        var openDatabase: AppDatabase?
        do {
            let old = try AppDatabase(path: path, migrationTarget: "v21_history_revisions")
            openDatabase = old
            let session = try SessionRepository(database: old).createSession(mode: .mock,
                title: "Synthetic legacy policy")
            let question = makeQuestion(sessionID: session.id)
            let repository = SuggestionRepository(database: old)
            try repository.saveDetectedQuestion(question)
            let originalDescriptor = try old.dbQueue.read { db in
                try Data.fetchOne(db, sql: "SELECT task_descriptor_json FROM detected_questions WHERE id = ?",
                    arguments: [question.id])
            }
            // This intentionally populated v21 row cannot call a writer that
            // expects the new column; it is a migration fixture, not copied logic.
            try old.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO suggestion_cards(id,session_id,question_id,strategy,say_first,
                        key_points_json,follow_up_ready_json,model_name,prompt_version,created_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, arguments: ["legacy-card",session.id,question.id,"Explanation",
                        "Synthetic legacy answer remains unchanged.","[]","[]","legacy-model","legacy-prompt",
                        DateCoding.string(from: Date(timeIntervalSince1970: 1))])
            }
            try old.close(); openDatabase = nil
            let upgraded = try AppDatabase(path: path)
            openDatabase = upgraded
            let columns = try upgraded.dbQueue.read { try $0.columns(in: "suggestion_cards").map(\.name) }
            #expect(columns.contains("question_decision_json"))
            let migratedCard = try #require(try SuggestionRepository(database: upgraded).latestSuggestion(sessionID: session.id))
            #expect(migratedCard.id == "legacy-card")
            #expect(migratedCard.sayFirst == "Synthetic legacy answer remains unchanged.")
            #expect(migratedCard.questionDecision == nil,
                "A legacy unknown policy must not be inferred from today's question descriptor")
            let descriptorAfterMigration = try upgraded.dbQueue.read { db in
                try Data.fetchOne(db, sql: "SELECT task_descriptor_json FROM detected_questions WHERE id = ?",
                    arguments: [question.id])
            }
            #expect(descriptorAfterMigration == originalDescriptor)
            try upgraded.close(); openDatabase = nil
            let reopened = try AppDatabase(path: path)
            openDatabase = reopened
            let stored = try #require(try SuggestionRepository(database: reopened).latestSuggestion())
            #expect(stored.id == "legacy-card")
            #expect(stored.sayFirst == migratedCard.sayFirst)
            #expect(stored.questionDecision == nil)
            let count = try SuggestionRepository(database: reopened).suggestionCount()
            #expect(count == 1)
            try reopened.close(); openDatabase = nil
        } catch {
            try? openDatabase?.close()
            throw error
        }
    }

    @Test
    func exactDecisionSurvivesRepeatedSaveAndEveryHistoricalReadWithoutRewritingQuestionPolicy() throws {
        try withFixture { fixture in
            let frozen = decision(question: fixture.question, model: "synthetic-primary-model",
                context: "synthetic-snapshot-one")
            let card = makeCard(question: fixture.question, decision: frozen)
            for _ in 0..<3 { try fixture.repository.saveSuggestionCard(card) }
            let cards = try fixture.repository.suggestions(sessionID: fixture.session.id)
            let bySession = try fixture.repository.latestSuggestion(sessionID: fixture.session.id)
            let global = try fixture.repository.latestSuggestion()
            #expect(cards.count == 1)
            #expect(cards.first?.questionDecision == frozen)
            #expect(bySession?.questionDecision == frozen)
            #expect(global?.questionDecision == frozen)
            let questions = try fixture.repository.questions(sessionID: fixture.session.id)
            #expect(questions.first?.taskDescriptor?.decision == nil,
                "Saving an answer does not become a second question-policy writer")
        }
    }

    @Test
    func theActualPersistenceSanitizerKeepsTheFrozenQuestionBinding() throws {
        try withFixture { fixture in
            let frozen = decision(question: fixture.question, model: "synthetic-primary-model",
                context: "synthetic-snapshot-one")
            let card = makeCard(question: fixture.question, decision: frozen)
            let result = QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card)
            try #require(result.accepted)
            let sanitized = QuestionRuntimeAcceptanceGuard.sanitizedSuggestionCardForPersistence(card, result: result)
            try #require(sanitized.questionText != fixture.question.questionText,
                "This fixture must exercise the existing punctuation-normalization boundary")
            try fixture.repository.saveSuggestionCard(sanitized)
            let saved = try #require(try fixture.repository.latestSuggestion())
            #expect(saved.questionDecision == frozen)
            #expect(saved.questionText == sanitized.questionText)
        }
    }

    @Test
    func regenerationKeepsTwoDifferentFrozenDecisionsForTheSameQuestion() throws {
        try withFixture { fixture in
            var originalQuestion = fixture.question
            let firstDecision = decision(question: fixture.question, model: "synthetic-first-model",
                context: "synthetic-snapshot-one")
            var descriptor = InterviewTaskDescriptor(question: originalQuestion.questionText)
            descriptor.apply(firstDecision); originalQuestion.taskDescriptor = descriptor
            try fixture.repository.resolveQuestionTask(originalQuestion)
            let first = makeCard(question: fixture.question, decision: firstDecision, id: "first-answer")
            try fixture.repository.saveSuggestionCard(first)
            let secondDecision = decision(question: fixture.question, model: "synthetic-regenerate-model",
                context: "synthetic-snapshot-two")
            let second = makeCard(question: fixture.question, decision: secondDecision, id: "regenerated-answer",
                createdAt: Date(timeIntervalSince1970: 2))
            try fixture.repository.saveSuggestionCard(second)
            descriptor.apply(secondDecision); originalQuestion.taskDescriptor = descriptor
            try fixture.repository.resolveQuestionTask(originalQuestion)
            let cards = try fixture.repository.suggestions(sessionID: fixture.session.id)
            #expect(cards.count == 2)
            #expect(cards.first { $0.id == first.id }?.questionDecision == firstDecision)
            #expect(cards.first { $0.id == second.id }?.questionDecision == secondDecision)
            let questionHistory = try fixture.repository.questions(sessionID: fixture.session.id)
            #expect(questionHistory.first?.taskDescriptor?.decision == firstDecision,
                "The existing first-answer question history contract is preserved independently")
        }
    }

    @Test(arguments: [false, true])
    func sameCardRegenerationOwnsANewPolicyWithoutChangingTheOldGeneration(startedUnknown: Bool) throws {
        try withFixture { fixture in
            let firstDecision = decision(question: fixture.question, model: "synthetic-first-model",
                context: "synthetic-snapshot-one")
            var first = makeCard(question: fixture.question, decision: startedUnknown ? nil : firstDecision)
            first.generationID = "synthetic-generation-one"
            first.stageBCompleted = true
            try fixture.repository.saveSuggestionCard(first)
            let nextDecision = decision(question: fixture.question, model: "synthetic-regenerate-model",
                context: "synthetic-snapshot-two")
            var regenerated = makeCard(question: fixture.question, decision: nextDecision,
                createdAt: first.createdAt.addingTimeInterval(1))
            regenerated.generationID = "synthetic-generation-two"
            regenerated.stageBCompleted = true
            regenerated.sayFirst = "A newly regenerated answer owns its own frozen routing policy."
            try fixture.repository.saveSuggestionCard(regenerated)
            let saved = try #require(try fixture.repository.latestSuggestion())
            #expect(saved.id == first.id)
            #expect(saved.generationID == regenerated.generationID)
            #expect(saved.questionDecision == nextDecision)
            #expect(saved.sayFirst == regenerated.sayFirst)
            #expect(try fixture.repository.suggestionCount() == 1)
            // The actual old generation carries its original creation time.
            // A delayed delivery cannot resurrect that policy or legacy NULL.
            try fixture.repository.saveSuggestionCard(first)
            let afterOldDelivery = try #require(try fixture.repository.latestSuggestion())
            #expect(afterOldDelivery.generationID == regenerated.generationID)
            #expect(afterOldDelivery.questionDecision == nextDecision)
            #expect(afterOldDelivery.sayFirst == regenerated.sayFirst)
        }
    }

    @Test
    func aChangedPolicyCannotReplaceAnExistingCardButSamePolicyCanExpandIt() throws {
        try withFixture { fixture in
            let frozen = decision(question: fixture.question, model: "synthetic-first-model",
                context: "synthetic-snapshot-one")
            let initial = makeCard(question: fixture.question, decision: frozen)
            try fixture.repository.saveSuggestionCard(initial)
            let changed = decision(question: fixture.question, model: "synthetic-replacement-model",
                context: "synthetic-snapshot-two")
            var late = initial
            late.questionDecision = changed
            late.contextSnapshotID = changed.contextSnapshotID
            late.sayFirst = "A different policy must not replace this same answer identity."
            // Existing monotonic rejection still ignores truly older callbacks.
            late.createdAt = initial.createdAt.addingTimeInterval(-1)
            try fixture.repository.saveSuggestionCard(late)
            let afterOlder = try #require(try fixture.repository.latestSuggestion())
            #expect(afterOlder.sayFirst == initial.sayFirst)
            #expect(afterOlder.questionDecision == frozen)
            // A later timestamp does not authorize changing the same card's policy.
            late.createdAt = initial.createdAt.addingTimeInterval(1)
            #expect(throws: (any Error).self) { try fixture.repository.saveSuggestionCard(late) }
            let afterChanged = try #require(try fixture.repository.latestSuggestion())
            #expect(afterChanged.sayFirst == initial.sayFirst)
            #expect(afterChanged.contextSnapshotID == initial.contextSnapshotID)
            #expect(afterChanged.questionDecision == frozen)
            var expansion = initial
            expansion.createdAt = initial.createdAt.addingTimeInterval(2)
            expansion.keyPoints = ["Same-policy expanded detail"]
            expansion.stageBCompleted = true
            try fixture.repository.saveSuggestionCard(expansion)
            var missingOptionalSnapshot = expansion
            missingOptionalSnapshot.createdAt = expansion.createdAt.addingTimeInterval(1)
            missingOptionalSnapshot.questionDecision = nil
            missingOptionalSnapshot.keyPoints.append("Legacy callback keeps existing policy")
            try fixture.repository.saveSuggestionCard(missingOptionalSnapshot)
            let expanded = try #require(try fixture.repository.latestSuggestion())
            #expect(expanded.questionDecision == frozen)
            #expect(expanded.keyPoints == missingOptionalSnapshot.keyPoints)
            let count = try fixture.repository.suggestionCount()
            #expect(count == 1)
        }
    }

    @Test
    func aLegacyUnknownCardCannotAcquireALaterQuestionPolicy() throws {
        try withFixture { fixture in
            let unknown = makeCard(question: fixture.question, decision: nil)
            try fixture.repository.saveSuggestionCard(unknown)
            let resolved = decision(question: fixture.question, model: "synthetic-later-model", context: nil)
            var later = unknown
            later.createdAt = unknown.createdAt.addingTimeInterval(1)
            later.questionDecision = resolved
            #expect(throws: (any Error).self) { try fixture.repository.saveSuggestionCard(later) }
            let stored = try #require(try fixture.repository.latestSuggestion())
            #expect(stored.questionDecision == nil)
            #expect(stored.sayFirst == unknown.sayFirst)
        }
    }

    @Test(arguments: MalformedBinding.allCases)
    fileprivate func malformedDecisionBindingCannotInsertOrRewriteAQuestion(binding: MalformedBinding) throws {
        try withFixture { fixture in
            let frozen = decision(question: fixture.question, model: "synthetic-model",
                context: "synthetic-snapshot-one")
            var card = makeCard(question: fixture.question, decision: frozen)
            switch binding {
            case .questionID:
                let other = makeQuestion(sessionID: fixture.session.id)
                try fixture.repository.saveDetectedQuestion(other)
                card.questionDecision = decision(question: other, model: "synthetic-model",
                    context: card.contextSnapshotID)
            case .context:
                card.contextSnapshotID = "a-different-synthetic-snapshot"
            case .session:
                card.sessionID = try SessionRepository(database: fixture.database).createSession(mode: .mock).id
            case .text:
                card.questionText = "Explain an unrelated finite scheduling queue."
            }
            #expect(throws: (any Error).self) { try fixture.repository.saveSuggestionCard(card) }
            let cards = try fixture.repository.suggestions(sessionID: fixture.session.id)
            let count = try fixture.repository.suggestionCount()
            let questions = try fixture.repository.questions(sessionID: fixture.session.id)
            #expect(cards.isEmpty)
            #expect(count == 0)
            #expect(questions.first { $0.id == fixture.question.id }?.taskDescriptor?.decision == nil)
        }
    }

    @Test
    func aDeletedQuestionCannotBeRecoveredByItsQueuedCardSnapshot() throws {
        try withFixture { fixture in
            let frozen = decision(question: fixture.question, model: "synthetic-model",
                context: "synthetic-snapshot-one")
            let card = makeCard(question: fixture.question, decision: frozen)
            try fixture.database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM detected_questions WHERE id = ?", arguments: [fixture.question.id])
            }
            #expect(throws: (any Error).self) { try fixture.repository.saveSuggestionCard(card) }
            let questions = try fixture.repository.questions(sessionID: fixture.session.id)
            let cards = try fixture.repository.suggestions(sessionID: fixture.session.id)
            #expect(questions.isEmpty)
            #expect(cards.isEmpty)
        }
    }

    private func withFixture(_ operation: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        do {
            try operation(fixture)
            try fixture.database.close()
        } catch {
            try? fixture.database.close()
            throw error
        }
    }

    @Test(arguments: RegenerateBinding.allCases)
    fileprivate func explicitRegenerateKeepsStoredQuestionAndSessionBoundaries(binding: RegenerateBinding) throws {
        try withFixture { fixture in
            var question = fixture.question
            let sessions = SessionRepository(database: fixture.database)
            switch binding {
            case .normalized:
                question.questionText = try #require(QuestionRuntimeAcceptanceGuard.acceptedCandidate(
                    from: question.questionText, hasFrozenContext: false).candidate?.text)
            case .otherText:
                question.questionText = "Explain database indexes and query planning."
            case .otherSession:
                question.sessionID = try sessions.createSession(mode: .mock).id
            case .foreignTranscript:
                let other = try sessions.createSession(mode: .mock)
                let segment = TranscriptSegment(id: "other-session-transcript", sessionID: other.id,
                    source: .mock, speaker: .interviewer, text: question.questionText)
                try TranscriptRepository(database: fixture.database).saveSegment(segment)
                question.transcriptSegmentID = segment.id
            case .deletedSession:
                try sessions.deleteSession(id: fixture.session.id)
            }
            if binding == .normalized {
                try fixture.repository.saveRegeneratedQuestion(question)
            } else {
                #expect(throws: DatabaseError.self) { try fixture.repository.saveRegeneratedQuestion(question) }
            }
            let stored = try fixture.repository.questions(sessionID: fixture.session.id)
            #expect(stored.map(\.questionText) == (binding == .deletedSession ? [] : [fixture.question.questionText]))
            #expect(try fixture.repository.suggestionCount() == 0)
        }
    }
    private struct Fixture {
        let database: AppDatabase
        let session: InterviewSession
        let question: DetectedQuestion
        let repository: SuggestionRepository
        init() throws {
            database = try AppDatabase(inMemory: true)
            session = try SessionRepository(database: database).createSession(mode: .mock,
                title: "Synthetic answer decision")
            question = FrozenCardDecisionPersistenceTests().makeQuestion(sessionID: session.id)
            repository = SuggestionRepository(database: database)
            try repository.saveDetectedQuestion(question)
            // Card context identities must reference real rows. Keep the
            // mismatched-context negative valid at SQL level so its rejection
            // proves the answer-policy binding instead of an unrelated FK.
            let fixtureSessionID = session.id
            try database.dbQueue.write { db in
                for id in ["synthetic-snapshot-one", "synthetic-snapshot-two", "a-different-synthetic-snapshot"] {
                    let snapshot = InterviewContextSnapshot(id: id, sessionID: fixtureSessionID,
                        candidateProfileID: nil, candidateProfileVersion: nil,
                        opportunityContextID: nil, opportunityContextVersion: nil,
                        domainProfileID: InterviewDomainID.general.rawValue,
                        candidateEvidence: [], opportunityEvidence: [],
                        createdAt: Date(timeIntervalSince1970: 1))
                    try InterviewContextRepository.insertSnapshot(snapshot, db: db)
                }
            }
        }
    }
    private func makeQuestion(sessionID: String) -> DetectedQuestion {
        .init(id: UUID().uuidString, sessionID: sessionID, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical,
            answerStrategy: .technicalExplanation, confidence: 1, reason: "Synthetic durable policy",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic-no-model",
            promptVersion: "synthetic-no-model", createdAt: Date(timeIntervalSince1970: 1))
    }
    private func decision(question: DetectedQuestion, model: String, context: String?) -> InterviewQuestionDecision {
        .init(task: .generalKnowledge, personalEvidence: .notRequired, basis: .generalKnowledge,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-no-inference", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: question.id, questionRevision: 0,
            contextSnapshotID: context, artifactRevision: 0, model: model, failure: nil, latencyMS: 0)
    }
    private func makeCard(question: DetectedQuestion, decision: InterviewQuestionDecision?,
        id: String = "synthetic-card", createdAt: Date = Date(timeIntervalSince1970: 1)) -> SuggestionCard {
        var card = SuggestionCard(id: id, sessionID: question.sessionID, questionID: question.id,
            strategy: "Explanation", sayFirst: "Synthetic answer bound to one database transaction question.",
            keyPoints: [], followUpReady: [], confidence: 1, caution: nil, evidenceUsed: [],
            riskLevel: .low, modelName: "synthetic-no-model", promptVersion: "synthetic-no-model",
            rawJSON: nil, createdAt: createdAt)
        card.questionText = question.questionText
        card.questionDecision = decision
        card.contextSnapshotID = decision?.contextSnapshotID
        return card
    }
}

fileprivate enum MalformedBinding: CaseIterable, Sendable { case questionID, context, session, text }
fileprivate enum RegenerateBinding: CaseIterable, Sendable { case normalized, otherText, otherSession, foreignTranscript, deletedSession }
