import Foundation
import Testing
import FSRS
@testable import Hireva

/// Actual controller/repository admission tests. Each case owns an independent
/// in-memory database; no model, cloud, microphone or system permissions run.
@Suite
@MainActor
struct PracticeReviewAdmissionTests {
    @Test
    func savingADraftBindsItsSourceRevisionWithoutCertifyingItsFacts() async throws {
        let fixture = try await makeFixture()
        do {
            var run = fixture.run
            run.attempts[0].revision = 2
            run.attempts[0].feedback?.reference = "A failed statement always rolls back every earlier statement."
            run.attempts[0].feedback?.referenceOrigin = .modelDraft
            try fixture.repository.save(run)
            fixture.controller.deleteReview(fixture.review.id)
            fixture.controller.restore(sessionID: run.sessionID)
            fixture.controller.addKnowledgeCard()
            let card = try #require(try fixture.repository.reviews().first)
            #expect(card.sourceAttemptRevision == 2)
            #expect(card.answer == run.attempts[0].feedback?.reference)
            #expect(try fixture.repository.referenceOrigin(for: card) == .modelDraft)
            var changedAnswer = card
            changedAnswer.answer = "An unrelated or edited reference."
            #expect(try fixture.repository.referenceOrigin(for: changedAnswer) == nil)
            try fixture.repository.correctAttempt(sessionID: run.sessionID, attemptID: card.id,
                question: card.question, answer: "A corrected candidate answer.")
            #expect(try fixture.repository.referenceOrigin(for: card) == nil)
            #expect(try fixture.repository.reviews().first?.needsReevaluation == true)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func changingSourceRevisionRejectsAnOldRatingEvenWithIdenticalText() async throws {
        let fixture = try await makeFixture()
        do {
            var current = fixture.review
            current.sourceAttemptRevision = 3
            try fixture.repository.saveReview(current)
            fixture.controller.rate(fixture.review, rating: .easy, now: fixture.nextReview)
            let stored = try #require(try fixture.repository.reviews().first)
            #expect(stored.sourceAttemptRevision == 3)
            #expect(stored.card == current.card && stored.log == current.log)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func legacyReferencesRemainUnknownAndDoNotBecomeVerifiedOnDecode() async throws {
        let fixture = try await makeFixture()
        do {
            let feedback = try #require(fixture.run.attempts.first?.feedback)
            let decoded = try JSONDecoder().decode(PracticeFeedback.self, from: JSONEncoder().encode(feedback))
            #expect(decoded.referenceOrigin == nil)
            #expect(fixture.review.sourceAttemptRevision == nil)
            #expect(try fixture.repository.referenceOrigin(for: fixture.review) == nil)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func anOldReviewValueCannotBypassSourceCorrectionReevaluation() async throws {
        let fixture = try await makeFixture()
        do {
            let old = fixture.review
            // This is the actual transactional correction used by the app;
            // restore/refresh are its normal post-correction feature actions.
            try fixture.repository.correctAttempt(sessionID: fixture.run.sessionID,
                attemptID: old.id, question: old.question, answer: "Stop after a corrected finite retry budget.")
            fixture.controller.restore(sessionID: fixture.run.sessionID)
            fixture.controller.refreshReviews()
            let correctedReview = try #require(try fixture.repository.reviews().first)
            let correctedAttempt = try #require(try fixture.repository.load(sessionID: fixture.run.sessionID)?.attempts.first)
            #expect(correctedReview.needsReevaluation == true)
            #expect(correctedAttempt.feedback == nil)
            #expect(correctedAttempt.corrections?.first?.answer == fixture.run.attempts.first?.answer)
            #expect(correctedAttempt.corrections?.first?.feedback == fixture.run.attempts.first?.feedback)

            fixture.controller.rate(old, rating: .good, now: fixture.nextReview)
            let stored = try #require(try fixture.repository.reviews().first)
            expectSameReview(stored, correctedReview)
            #expect(stored.needsReevaluation == true)
            #expect(try fixture.repository.load(sessionID: fixture.run.sessionID)?.attempts.first == correctedAttempt)
            #expect(fixture.controller.error == nil)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func anOldReviewValueCannotRecreateAnExplicitlyDeletedCard() async throws {
        let fixture = try await makeFixture()
        do {
            let old = fixture.review
            fixture.controller.deleteReview(old.id)
            #expect(try fixture.repository.reviews().isEmpty)
            fixture.controller.rate(old, rating: .easy, now: fixture.nextReview)
            #expect(try fixture.repository.reviews().isEmpty)
            #expect(fixture.controller.reviews.isEmpty)
            #expect(fixture.controller.error == nil)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    @Test
    func anOldReviewValueCannotEraseAnAlreadyRecordedUserRating() async throws {
        let fixture = try await makeFixture()
        do {
            let old = fixture.review
            fixture.controller.rate(old, rating: .good, now: fixture.nextReview)
            let accepted = try #require(try fixture.repository.reviews().first)
            #expect(accepted.log.count == old.log.count + 1)
            #expect(accepted.log.last?.rating == .good)
            #expect(Array(accepted.log.prefix(old.log.count)) == old.log)
            fixture.controller.rate(old, rating: .easy, now: fixture.nextReview.addingTimeInterval(86400))
            let afterStaleAction = try #require(try fixture.repository.reviews().first)
            expectSameReview(afterStaleAction, accepted)

            // Rejecting a stale value must not disable a fresh user action.
            let freshNow = fixture.nextReview.addingTimeInterval(2 * 86400)
            fixture.controller.rate(afterStaleAction, rating: .again, now: freshNow)
            let refreshed = try #require(try fixture.repository.reviews().first)
            #expect(Array(refreshed.log.prefix(accepted.log.count)) == accepted.log)
            #expect(refreshed.log.count == accepted.log.count + 1)
            #expect(refreshed.log.last?.rating == .again)
            #expect(refreshed.card.lastReview == freshNow)
            #expect(fixture.controller.error == nil)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    /// Characterization: every real user grade and legacy nil invalidation flag
    /// remain valid when the caller holds the current persisted card.
    @Test(arguments: [Rating.again.rawValue, Rating.hard.rawValue, Rating.good.rawValue, Rating.easy.rawValue])
    func aCurrentLegacyCardStillRecordsTheUsersExactRating(_ ratingRawValue: Int) async throws {
        let rating: Rating = try #require(Rating(rawValue: ratingRawValue))
        let fixture = try await makeFixture()
        do {
            let current = fixture.review
            #expect(current.needsReevaluation == nil)
            fixture.controller.rate(current, rating: rating, now: fixture.nextReview)
            let next = try #require(try fixture.repository.reviews().first)
            #expect(next.log.count == current.log.count + 1)
            #expect(Array(next.log.prefix(current.log.count)) == current.log)
            #expect(next.log.last?.rating == rating)
            #expect(next.card.lastReview == fixture.nextReview)
            #expect(next.question == current.question && next.answer == current.answer)
            #expect(next.algorithm == current.algorithm && next.hinted == current.hinted)
            #expect(fixture.controller.error == nil)
            try await fixture.close()
        } catch { try? await fixture.close(); throw error }
    }

    private func expectSameReview(_ actual: KnowledgeReviewCard, _ expected: KnowledgeReviewCard) {
        #expect(actual.id == expected.id && actual.sessionID == expected.sessionID)
        #expect(actual.question == expected.question && actual.answer == expected.answer)
        #expect(actual.card == expected.card)
        #expect(actual.log == expected.log)
        #expect(actual.hinted == expected.hinted && actual.algorithm == expected.algorithm)
        #expect(actual.needsReevaluation == expected.needsReevaluation)
        #expect(actual.sourceAttemptRevision == expected.sourceAttemptRevision)
    }

    private func makeFixture() async throws -> ReviewFixture {
        let database = try AppDatabase(inMemory: true)
        let repository = PracticeRepository(database: database)
        let consent = PersistenceConsent()
        let controller = PracticeController(dependencies: PracticeDependencies(
            repository: repository, sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database), contexts: InterviewContextRepository(database: database),
            persistenceConsent: consent,
            context: { .init(historyEnabled: true,
                selection: .init(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general),
                temporarySnapshotID: nil) },
            evaluationConfiguration: { throw MaterialError.invalid("Evaluation is not part of a review admission fixture.") },
            selectedASRProvider: { .localParakeet }, isLiveCaptureActive: { false }, prepareForPractice: {},
            requestAudioPermissions: { _ in throw MaterialError.invalid("Audio is not part of this fixture.") },
            makeAudioProvider: { _ in throw MaterialError.invalid("Audio is not part of this fixture.") },
            historyDidChange: { _ in }, delayProvider: RealDelayProvider()))
        do {
            let session = try SessionRepository(database: database).createSession(mode: .mock)
            var task = InterviewTaskDescriptor(question: "Explain a finite retry budget.", kind: .coding, language: "en")
            task.criteria = ["Explain a retry bound"]
            let answer = "Stop after a finite number of retries."
            let feedback = PracticeFeedback(covered: [.init(criterion: task.criteria[0], quote: answer)],
                missing: [], suggestions: [], followUp: nil, reason: "The supplied criterion is covered.",
                reference: "Use a finite retry budget.")
            let attempt = PracticeAttempt(questionID: UUID().uuidString, question: task.question, answer: answer,
                revision: 0, hinted: false, skipped: false, source: "synthetic-keyboard", task: task, feedback: feedback)
            var run = PracticeRun(sessionID: session.id, task: task, questionID: attempt.questionID,
                mainQuestionID: attempt.questionID, phase: .completed)
            run.attempts = [attempt]
            try repository.save(run)
            let start = Date(timeIntervalSince1970: 1700000000)
            let card = KnowledgeReviewCard(id: attempt.id, sessionID: session.id, question: attempt.question,
                answer: feedback.reference, card: Card(due: start, lastReview: start), hinted: false)
            try repository.saveReview(card)
            controller.restore(sessionID: session.id)
            controller.refreshReviews()
            // Use the real existing rate entry to seed a real user history;
            // this fake fixture does not reproduce FSRS scheduling logic.
            let persisted = try #require(try repository.reviews().first)
            controller.rate(persisted, rating: .hard, now: start.addingTimeInterval(86400))
            let review = try #require(try repository.reviews().first)
            #expect(review.log.map(\.rating) == [.hard])
            return ReviewFixture(database: database, repository: repository, controller: controller,
                run: run, review: review, nextReview: start.addingTimeInterval(2 * 86400))
        } catch {
            await controller.shutdown()
            try? database.close()
            throw error
        }
    }
}

@MainActor
private struct ReviewFixture {
    let database: AppDatabase
    let repository: PracticeRepository
    let controller: PracticeController
    let run: PracticeRun
    let review: KnowledgeReviewCard
    let nextReview: Date
    func close() async throws {
        await controller.shutdown()
        try database.close()
    }
}
