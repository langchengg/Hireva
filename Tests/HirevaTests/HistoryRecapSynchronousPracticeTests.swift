import Foundation
import Testing
@testable import Hireva

/// Real HistoryState API and repositories. The held previous root establishes
/// deterministic ordering; no UI busy guard, audio, model or cloud is involved.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HistoryRecapSynchronousPracticeTests {
    @Test
    func synchronousPracticeRecapRevokesThePreviousRootBeforePublishing() async throws {
        let fixture = try await RecapEntryFixture(localOnly: true, holdRouting: true)
        let history = fixture.app.historyState
        var roots: [Task<Void, Never>] = []
        var oldPublications = 0
        var revokedBeforeSuccess = false
        do {
            let old = try #require(try history.requestRecap(sessionID: fixture.session.id,
                providerConfiguration: fixture.configuration, routingProvider: fixture.local,
                routingModel: fixture.originalModel, localOnly: true, persistenceAllowed: { true },
                onFeedback: { _ in }, onError: { _ in }, didPublish: { _ in oldPublications += 1 }))
            roots.append(old)
            try await fixture.routingGate.waitUntilEntered()
            let practiceSession = try savedSyntheticPractice(fixture)
            try history.loadSessionDetails(sessionID: practiceSession.id)
            let synchronous = try history.requestRecap(sessionID: practiceSession.id,
                providerConfiguration: nil, routingProvider: fixture.replacement,
                routingModel: fixture.originalModel, localOnly: true, persistenceAllowed: { true },
                onFeedback: { feedback in
                    if feedback.kind == .success {
                        revokedBeforeSuccess = old.isCancelled && history.recapTask == nil
                            && history.retiringRecapTaskCount == 1
                    }
                }, onError: { _ in Issue.record("A saved Practice summary must not emit an error.") },
                didPublish: { _ in Issue.record("A synchronous Practice summary invokes no model.") })
            #expect(synchronous == nil)
            #expect(old.isCancelled)
            #expect(revokedBeforeSuccess,
                "The synchronous branch must revoke/retain the old root before its success callback.")
            #expect(history.recapTask == nil && !history.isGeneratingRecap)
            #expect(history.retiringRecapTaskCount == 1)
            #expect(history.pendingRecapTaskCount == 1)
            let displayed = try #require(history.selectedSessionRecap)
            #expect(displayed.sessionID == practiceSession.id)
            #expect(displayed.modelName == "Practice feedback · structural checks only")
            fixture.routingGate.releaseAll()
            try await fixture.join(old)
            #expect(oldPublications == 0)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            let reports = try fixture.app.recapRepository.versions(sessionID: practiceSession.id)
            #expect(reports.count == 1)
            var normalized = displayed
            normalized.createdAt = DateCoding.date(from: DateCoding.string(from: normalized.createdAt))
            #expect(normalized == reports.first)
            #expect(history.selectedSessionRecap == displayed)
            #expect(history.pendingRecapTaskCount == 0)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test
    func synchronousPracticeRecapDoesNotReplaceAnotherSelectedSessionsDisplay() async throws {
        let fixture = try await RecapEntryFixture(localOnly: true)
        do {
            let practiceSession = try savedSyntheticPractice(fixture)
            let history = fixture.app.historyState
            #expect(history.selectedSessionID == fixture.session.id)
            #expect(history.selectedSessionRecap == nil)
            let synchronous = try history.requestRecap(sessionID: practiceSession.id,
                providerConfiguration: nil, routingProvider: fixture.replacement,
                routingModel: fixture.originalModel, localOnly: true, persistenceAllowed: { true },
                onFeedback: { _ in }, onError: { _ in }, didPublish: { _ in
                    Issue.record("A saved Practice summary invokes no model.")
                })
            #expect(synchronous == nil)
            #expect(history.selectedSessionID == fixture.session.id)
            #expect(history.selectedSessionRecap == nil,
                "A different stored summary does not belong in the currently selected session display.")
            #expect(try fixture.app.recapRepository.versions(sessionID: practiceSession.id).count == 1)
            #expect(await fixture.local.requests().isEmpty)
            #expect(await fixture.replacement.requests().isEmpty)
            try await fixture.close([])
        } catch {
            try? await fixture.close([])
            throw error
        }
    }

    private func savedSyntheticPractice(_ fixture: RecapEntryFixture) throws -> InterviewSession {
        let session = try fixture.app.sessionRepository.createSession(mode: .mock,
            title: "Synthetic synchronous Practice summary")
        let task = InterviewTaskDescriptor(question: "Explain bounded retries.",
            kind: .generalKnowledge, language: "en")
        let questionID = "synthetic-practice-" + UUID().uuidString
        // A saved skipped attempt proves only existing deterministic summary
        // behavior; no fabricated evaluated feedback or model rating is created.
        var run = PracticeRun(sessionID: session.id, snapshotID: session.contextSnapshotID,
            task: task, questionID: questionID, mainQuestionID: questionID,
            phase: .completed, maxFollowUps: 0)
        run.attempts = [.init(questionID: questionID, question: task.question, answer: "",
            contextSnapshotID: run.snapshotID, revision: 0, hinted: false, skipped: true,
            source: "synthetic-user-skipped", task: task)]
        try PracticeRepository(database: fixture.database).save(run)
        return session
    }
}
