import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct ManualSessionDeletionPublicationTests {
    /// Delete is admitted from the actual Manual preactivation publication.
    /// Clearing that session synchronously starts a later reviewed submission.
    /// All records, transcripts and providers are isolated synthetic fixtures.
    @Test(.timeLimit(.minutes(1)))
    func successfulDeletionSessionClearKeepsReentrantNewManualSubmission() async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var manualObservation: AnyCancellable?
        var sessionObservation: AnyCancellable?
        var deleted = false
        var submitted = false
        var nilWasCommitted = false
        let replacementText = "Explain transaction isolation and concurrency."
        do {
            let originalSnapshot = try #require(fixture.app.activeContextSnapshot)
            let next = try fixture.app.createContextBoundSession(mode: .mock,
                title: "Synthetic replacement after deletion")
            let nextSnapshot = try #require(fixture.app.activeContextSnapshot)
            fixture.app.activeContextSnapshot = originalSnapshot
            fixture.app.currentSession = fixture.session
            sessionObservation = fixture.app.liveInterview.currentSessionUpdates.dropFirst().sink { session in
                guard deleted, !submitted, session == nil else { return }
                nilWasCommitted = fixture.app.currentSession == nil
                submitted = true
                fixture.app.currentSession = next
                fixture.app.activeContextSnapshot = nextSnapshot
                fixture.app.manualCaptureTranscript = replacementText
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.sendManualCaptureToAI()
                if let worker = fixture.app.stageBTask { roots.append(worker) }
            }
            manualObservation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !deleted, state == .generatingSuggestion else { return }
                deleted = true
                fixture.app.deleteSession(fixture.session)
            }
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            fixture.app.sendManualCaptureToAI()
            manualObservation?.cancel(); manualObservation = nil
            sessionObservation?.cancel(); sessionObservation = nil
            #expect(deleted && submitted)
            #expect(nilWasCommitted,
                "The actual session-clear publication must commit nil before accepting replacement work.")
            #expect(try fixture.app.sessionRepository.session(id: fixture.session.id) == nil)
            #expect(try fixture.app.sessionRepository.session(id: next.id) != nil)
            #expect(fixture.app.currentSession?.id == next.id)
            #expect(fixture.app.activeContextSnapshot?.id == nextSnapshot.id)
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            let worker = try #require(roots.last)
            #expect(identity.sessionID == next.id && identity.contextSnapshotID == nextSnapshot.id)
            #expect(identity.questionText == replacementText)
            #expect(fixture.app.stageBTask == worker && !worker.isCancelled)
            #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
            roots.forEach { $0.cancel() }
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            manualObservation?.cancel(); sessionObservation?.cancel()
            roots.forEach { $0.cancel() }
            try? await fixture.close(roots)
            throw error
        }
    }
}
