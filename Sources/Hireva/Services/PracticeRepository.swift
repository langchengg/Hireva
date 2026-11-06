import Foundation
import GRDB
import FSRS

final class PracticeRepository {
    let database: AppDatabase
    init(database: AppDatabase) { self.database = database }
    func save(_ run: PracticeRun) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO practice_runs (session_id, payload_json) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET payload_json = excluded.payload_json", arguments: [run.sessionID, try JSONEncoder().encode(run)])
        }
    }
    func load(sessionID: String) throws -> PracticeRun? {
        try database.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload_json FROM practice_runs WHERE session_id = ?", arguments: [sessionID]).map { try JSONDecoder().decode(PracticeRun.self, from: $0) }
        }
    }
    func correctAttempt(sessionID: String, attemptID: String, question: String, answer: String) throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 6000, answer.count <= 24000 else { throw MaterialError.invalid("Correction exceeds input budget or lacks a question.") }
        try database.dbQueue.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload_json FROM practice_runs WHERE session_id = ?", arguments: [sessionID]) else { throw CancellationError() }
            var run = try JSONDecoder().decode(PracticeRun.self, from: data)
            guard let index = run.attempts.firstIndex(where: { $0.id == attemptID }) else { throw CancellationError() }
            var attempt = run.attempts[index]
            guard attempt.question != question || attempt.answer != answer else { return }
            let old = PracticeAttemptRevision(hinted: attempt.hinted, revision: attempt.revision, question: attempt.question, answer: attempt.answer, task: attempt.task, feedback: attempt.feedback, correctedAt: Date())
            attempt.corrections = (attempt.corrections ?? []) + [old]
            attempt.hinted = attempt.hinted || attempt.feedback != nil
            attempt.question = question; attempt.answer = answer; attempt.revision += 1
            attempt.feedback = nil
            var task = attempt.task ?? InterviewTaskDescriptor(question: question)
            task.question = question
            task.decision = nil
            task.conversationContext = nil
            task.conversationContextCaptured = nil
            if old.question != question && task.selectedTask == nil {
                task.kind = InterviewTaskDescriptor.classify(question)
                task.criteria = task.kind.criteria
            }
            attempt.task = task
            run.attempts[index] = attempt
            var affectedIDs = [attemptID]
            var affectedQuestions: Set<String> = [attempt.questionID]
            // Follow-ups depend on the corrected answer as well as their own
            // text. Preserve their old feedback as a version, and invalidate
            // only descendants; explicit FSRS ratings remain untouched.
            for childIndex in run.attempts.indices where childIndex > index {
                guard let parent = run.attempts[childIndex].parentQuestionID,
                      affectedQuestions.contains(parent) else { continue }
                var child = run.attempts[childIndex]
                child.corrections = (child.corrections ?? []) + [.init(hinted: child.hinted, revision: child.revision, question: child.question, answer: child.answer, task: child.task, feedback: child.feedback, correctedAt: Date())]
                child.hinted = child.hinted || child.feedback != nil
                child.revision += 1
                child.feedback = nil
                child.task?.decision = nil
                child.task?.conversationContext = nil
                child.task?.conversationContextCaptured = nil
                run.attempts[childIndex] = child
                affectedIDs.append(child.id)
                affectedQuestions.insert(child.questionID)
                if run.questionID == child.questionID, let childTask = child.task {
                    run.task = childTask; run.hinted = child.hinted
                }
            }
            run.revision += 1
            if run.questionID == attempt.questionID { run.task = task; run.draft = answer; run.hinted = attempt.hinted }
            run.phase = .completed
            try db.execute(sql: "UPDATE practice_runs SET payload_json = ? WHERE session_id = ?", arguments: [try JSONEncoder().encode(run), sessionID])
            try db.execute(sql: "UPDATE interview_sessions SET content_revision = content_revision + 1 WHERE id = ?", arguments: [sessionID])
            for affectedID in affectedIDs {
                if let bytes = try Data.fetchOne(db, sql: "SELECT payload_json FROM knowledge_reviews WHERE id = ?", arguments: [affectedID]) {
                    var card = try JSONDecoder().decode(KnowledgeReviewCard.self, from: bytes)
                    card.needsReevaluation = true
                    try db.execute(sql: "UPDATE knowledge_reviews SET payload_json = ? WHERE id = ?", arguments: [try JSONEncoder().encode(card), affectedID])
                }
            }
        }
    }
    func saveReview(_ card: KnowledgeReviewCard) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO knowledge_reviews (id, session_id, payload_json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json", arguments: [card.id, card.sessionID, try JSONEncoder().encode(card)])
        }
    }
    /// A UI action carries the card it displayed. Check that value against the
    /// current row and update within the same writer transaction; rating an old
    /// value must not undo source invalidation, replace ratings, or insert a row.
    func rateReview(expected: KnowledgeReviewCard, rating: Rating, now: Date) throws {
        try database.dbQueue.write { db in
            guard let bytes = try Data.fetchOne(db,
                sql: "SELECT payload_json FROM knowledge_reviews WHERE id = ? AND session_id = ?",
                arguments: [expected.id, expected.sessionID]) else { return }
            let current = try JSONDecoder().decode(KnowledgeReviewCard.self, from: bytes)
            guard current.id == expected.id, current.sessionID == expected.sessionID,
                  current.question == expected.question, current.answer == expected.answer,
                  current.card == expected.card, current.log == expected.log,
                  current.hinted == expected.hinted, current.algorithm == expected.algorithm,
                  current.sourceAttemptRevision == expected.sourceAttemptRevision,
                  current.needsReevaluation != true, expected.needsReevaluation != true,
                  now >= current.card.lastReview else { return }
            // Legacy nil and explicit false invalidation flags both mean eligible.
            // The user supplies Rating; the scheduler does not infer it from feedback.
            guard let result = FSRS().repeat(card: current.card, now: now)[rating] else { return }
            var next = current
            next.card = result.card
            next.log.append(result.reviewLog)
            try db.execute(sql: "UPDATE knowledge_reviews SET payload_json = ? WHERE id = ? AND session_id = ?",
                arguments: [try JSONEncoder().encode(next), current.id, current.sessionID])
        }
    }

    func reviews() throws -> [KnowledgeReviewCard] {
        try database.dbQueue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload_json FROM knowledge_reviews").map { try JSONDecoder().decode(KnowledgeReviewCard.self, from: $0) }.sorted { $0.card.due < $1.card.due }
        }
    }
    func referenceOrigin(for card: KnowledgeReviewCard) throws -> PracticeFeedback.ReferenceOrigin? {
        guard let revision = card.sourceAttemptRevision,
              let attempt = try load(sessionID: card.sessionID)?.attempts.first(where: { $0.id == card.id }),
              attempt.revision == revision, attempt.question == card.question,
              let feedback = attempt.feedback, feedback.reference == card.answer else { return nil }
        return feedback.referenceOrigin
    }
    func deleteReview(id: String) throws {
        try database.dbQueue.write { try $0.execute(sql: "DELETE FROM knowledge_reviews WHERE id = ?", arguments: [id]) }
    }
}
