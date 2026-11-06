import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationRevocationManualReentryTests {
    enum PublicAction: CaseIterable, Sendable { case cancelManual, selectContext }

    @Test(.timeLimit(.minutes(1)), arguments: PublicAction.allCases)
    func publicRevocationDoesNotClearReviewedManualSubmittedByItsOwnerNotification(action: PublicAction) async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var nextProducer: Task<String, Error>?
        var submitted = false
        do {
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            fixture.app.sendManualCaptureToAI()
            let completed = try #require(fixture.app.stageBTask)
            roots.append(completed)
            try await fixture.join(completed)
            try #require(fixture.app.manualCaptureState == .suggestionReady)
            try #require(!fixture.app.isActionLoading(ActionID.manualGenerate))
            let original = try #require(fixture.app.activeGenerationController?.identity)
            var nextIdentity: GenerationIdentity?
            observation = fixture.app.generationCoordinator.objectWillChange.sink { _ in
                guard !submitted, fixture.app.generationCoordinator.activeGeneration == nil,
                      fixture.app.generationCoordinator.activeRequest == nil else { return }
                submitted = true
                fixture.app.manualCaptureTranscript = "Explain transaction isolation and atomicity."
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.sendManualCaptureToAI()
                nextIdentity = fixture.app.activeGenerationController?.identity
                if let root = fixture.app.stageBTask { roots.append(root) }
                if let identity = nextIdentity {
                    // Real registration establishes this owner-bound phase;
                    // no test writes a parallel provider/stream boolean.
                    let producer = Task<String, Error> { "Finite newly registered provider" }
                    nextProducer = producer
                    fixture.app.registerStageATask(producer, generationID: identity.generationID)
                }
            }
            switch action {
            case .cancelManual: fixture.app.cancelManualCapture()
            case .selectContext: fixture.app.selectInterviewDomain(.roboticsResearch)
            }
            observation?.cancel(); observation = nil
            let retained = try #require(nextIdentity)
            #expect(submitted && retained.generationID != original.generationID)
            #expect(fixture.app.generationCoordinator.isCurrent(retained))
            #expect(fixture.app.currentSession?.id == retained.sessionID)
            #expect(fixture.app.currentSession?.contextSnapshotID == retained.contextSnapshotID)
            #expect(fixture.app.manualCaptureState == .generatingSuggestion)
            #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
            #expect(fixture.app.generationUIState == .generatingFirstAnswer(
                questionID: retained.acceptedQuestionID, generationID: retained.generationID, triggerPath: .manualCapture))
            #expect(fixture.app.stageBTask != nil && fixture.app.stageBTask?.isCancelled == false)
            #expect(fixture.app.generationCoordinator.stageATask == nextProducer && nextProducer?.isCancelled == false)
            #expect(fixture.app.providerStreamActive,
                "A new exact provider registration cannot be cleared by an earlier revocation tail.")
            roots.forEach { $0.cancel() }; nextProducer?.cancel()
            if let nextProducer { _ = try? await nextProducer.value }
            #expect(await fixture.original.requests().count == 1,
                "The replacement is still queued; only the original local answer ran.")
            #expect(fixture.remote.requests().isEmpty)
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); roots.forEach { $0.cancel() }; nextProducer?.cancel()
            if let nextProducer { _ = try? await nextProducer.value }
            try? await fixture.close(roots)
            throw error
        }
    }
}
