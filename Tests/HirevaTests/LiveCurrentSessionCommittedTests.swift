import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct LiveCurrentSessionCommittedTests {
    enum SemanticChange: CaseIterable, Sendable { case identity, context, revision, ended, clear }

    @Test(.timeLimit(.minutes(1)), arguments: SemanticChange.allCases)
    func semanticChangeRevokesOriginalBeforePublishingAndKeepsSubscriberDetector(
        change: SemanticChange
    ) async throws {
        let owner = LiveInterviewFeature()
        let original = session()
        owner.currentSession = original
        let originalTask = try #require(owner.submitAutomaticDetection { _ in })
        var replacement = original
        switch change {
        case .identity: replacement.id = "synthetic-next-session"
        case .context: replacement.contextSnapshotID = "synthetic-next-context"
        case .revision: replacement.contentRevision = 2
        case .ended: replacement.endedAt = Date(timeIntervalSince1970: 200)
        case .clear: break
        }
        let submitted: InterviewSession? = change == .clear ? nil : replacement
        var deliveries = 0
        var subscriberTask: Task<Void, Never>?
        var committedAtDelivery = false
        var originalRevokedAtDelivery = false
        let subscription = owner.currentSessionUpdates.dropFirst().sink { value in
            guard deliveries == 0 else { return }
            deliveries += 1
            committedAtDelivery = owner.currentSession == value && value == submitted
            originalRevokedAtDelivery = originalTask.isCancelled && owner.activeDetectionTask == nil
            subscriberTask = owner.submitAutomaticDetection { _ in }
        }
        owner.currentSession = submitted
        subscription.cancel()
        #expect(deliveries == 1 && committedAtDelivery && originalRevokedAtDelivery)
        #expect(owner.currentSession == submitted)
        #expect(originalTask.isCancelled)
        #expect(subscriberTask != nil && owner.activeDetectionTask != nil)
        #expect(subscriberTask?.isCancelled == false,
            "The outer session setter must not revoke the detector accepted by its committed subscriber.")
        // Restoring the old inputs is another semantic transition. It does not
        // restore the original root or cancel flag; the subscriber root retires.
        owner.currentSession = original
        #expect(originalTask.isCancelled && subscriberTask?.isCancelled == true)
        #expect(owner.activeDetectionTask == nil)
        owner.closeAutomaticDetectionAdmission()
        #expect(await owner.drainAutomaticDetection())
        #expect(owner.pendingAutomaticDetectionTaskCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func titleAndSameValuePreserveAdmissionAndShareCommittedSource() async throws {
        let owner = LiveInterviewFeature()
        let original = session()
        owner.currentSession = original
        let originalTask = try #require(owner.submitAutomaticDetection { _ in })
        var renamed = original
        renamed.title = "Synthetic renamed title"
        var delivered: [InterviewSession?] = []
        var committed = true
        var forwarded = 0
        let values = owner.currentSessionUpdates.sink { value in
            delivered.append(value)
            committed = committed && owner.currentSession == value
        }
        let notifications = owner.objectWillChange.sink { forwarded += 1 }
        owner.currentSession = renamed
        owner.currentSession = renamed
        values.cancel(); notifications.cancel()
        #expect(delivered == [original, renamed, renamed] && committed)
        #expect(forwarded == 2)
        #expect(!originalTask.isCancelled && owner.activeDetectionTask != nil)
        owner.closeAutomaticDetectionAdmission()
        #expect(originalTask.isCancelled)
        #expect(await owner.drainAutomaticDetection())
        #expect(owner.pendingAutomaticDetectionTaskCount == 0)
    }

    private func session() -> InterviewSession {
        InterviewSession(id: "synthetic-original-session", title: "Synthetic title",
            company: nil, role: nil, startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil, mode: .mock, createdAt: Date(timeIntervalSince1970: 100),
            contentRevision: 1, contextSnapshotID: "synthetic-original-context")
    }
}
