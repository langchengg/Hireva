import Foundation
import Combine
import Testing
@testable import Hireva

/// Actual existing owner APIs with synchronous subscribers. All tasks are
/// finite and explicitly joined even when an ownership assertion fails.
@Suite
@MainActor
struct GenerationCoordinatorCommittedPublicationTests {
    @Test
    func beginPublishesOneCommittedRequestAndNewerSubscriberRequestWins() async {
        let owner = GenerationCoordinator()
        let originalTask = Task<Void, Never> {}
        let replacementTask = Task<Void, Never> {}
        let originalID = owner.beginRequest(triggerPath: .manualGenerate)
        #expect(owner.registerRequestTask(originalTask, requestID: originalID))
        var replacementID: String?
        var replacementAccepted = false
        var replaced = false
        var firstObservedID: String?
        let subscription = owner.objectWillChange.sink { _ in
            guard !replaced else { return }
            replaced = true
            firstObservedID = owner.activeRequest?.id
            let next = owner.beginRequest(triggerPath: .regenerate)
            replacementID = next
            replacementAccepted = owner.registerRequestTask(replacementTask, requestID: next)
        }
        let submitted = owner.beginRequest(triggerPath: .autoDetect)
        subscription.cancel()
        #expect(replaced)
        #expect(firstObservedID == submitted,
            "An ownership subscriber must see the committed submission, not an invalidation intermediate.")
        #expect(replacementID != submitted)
        #expect(owner.activeRequest?.id == replacementID)
        #expect(owner.requestTask == replacementTask)
        #expect(replacementAccepted)
        #expect(originalTask.isCancelled)
        owner.closeAdmission()
        originalTask.cancel(); replacementTask.cancel()
        await originalTask.value
        await replacementTask.value
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func activatePublishesOneCompleteRecordBeforeSubscriberReplacement() async {
        let owner = GenerationCoordinator()
        let original = Self.identity("original")
        let submitted = Self.identity("submitted")
        let replacement = Self.identity("replacement")
        let originalTask = Task<String, Error> { "old finite child" }
        let replacementTask = Task<String, Error> { "new finite child" }
        let replacementLaunch = UUID()
        owner.activate(identity: original, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        #expect(owner.registerStageATask(originalTask, generationID: original.generationID))
        var firstObserved: GenerationIdentity?
        var firstObservedTicket: Int?
        var observedOldCancellation = false
        var replaced = false
        var replacementAccepted = false
        let subscription = owner.objectWillChange.sink { _ in
            guard !replaced else { return }
            replaced = true
            firstObserved = owner.activeGeneration?.identity
            firstObservedTicket = owner.activeGeneration?.persistenceTicket
            observedOldCancellation = originalTask.isCancelled
            owner.activate(identity: replacement, persistenceTicket: 3, triggerPath: .regenerate, startedAt: Date())
            replacementAccepted = owner.registerStageATask(replacementTask,
                generationID: replacement.generationID, launchID: replacementLaunch)
        }
        owner.activate(identity: submitted, persistenceTicket: 2, triggerPath: .manualGenerate, startedAt: Date())
        subscription.cancel()
        #expect(firstObserved == submitted && firstObservedTicket == 2)
        #expect(observedOldCancellation,
            "The replaced task must already be retained/cancelled when the complete new record is published.")
        #expect(owner.activeGeneration?.identity == replacement)
        #expect(owner.stageATask == replacementTask)
        #expect(owner.activeGeneration?.stageALaunchID == replacementLaunch)
        #expect(replacementAccepted)
        owner.closeAdmission()
        originalTask.cancel(); replacementTask.cancel()
        _ = await originalTask.result
        _ = await replacementTask.result
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func stageARegistrationPublishesTaskAndLaunchTogetherOnce() async {
        let owner = GenerationCoordinator()
        let identity = Self.identity("atomic-registration")
        owner.activate(identity: identity, persistenceTicket: 4, triggerPath: .manualGenerate, startedAt: Date())
        let task = Task<String, Error> { "finite answer" }
        let launch = UUID()
        var observations: [(GenerationIdentity?, Bool, UUID?)] = []
        let subscription = owner.objectWillChange.sink { _ in
            observations.append((owner.activeGeneration?.identity, owner.stageATask == task,
                owner.activeGeneration?.stageALaunchID))
        }
        let accepted = owner.registerStageATask(task, generationID: identity.generationID, launchID: launch)
        subscription.cancel()
        #expect(accepted)
        #expect(observations.count == 1)
        #expect(observations.allSatisfy { $0.0 == identity && $0.1 && $0.2 == launch })
        owner.closeAdmission()
        task.cancel()
        _ = await task.result
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test(arguments: [false, true])
    func stageARegistrationCannotOverwriteSubscriberChildOrReportItsOwnAuthority(
        sameGeneration: Bool
    ) async {
        let owner = GenerationCoordinator()
        let initial = Self.identity("stage-a-initial")
        let replacement = sameGeneration ? initial : Self.identity("stage-a-replacement")
        let oldTask = Task<String, Error> { "old finite answer" }
        let submittedTask = Task<String, Error> { "submitted finite answer" }
        let replacementTask = Task<String, Error> { "replacement finite answer" }
        let submittedLaunch = UUID(), replacementLaunch = UUID()
        owner.activate(identity: initial, persistenceTicket: 5, triggerPath: .manualGenerate, startedAt: Date())
        #expect(owner.registerStageATask(oldTask, generationID: initial.generationID))
        var replaced = false
        var replacementAccepted = false
        let subscription = owner.objectWillChange.sink { _ in
            guard !replaced else { return }
            replaced = true
            owner.activate(identity: replacement, persistenceTicket: 6, triggerPath: .regenerate, startedAt: Date())
            replacementAccepted = owner.registerStageATask(replacementTask,
                generationID: replacement.generationID, launchID: replacementLaunch)
        }
        let accepted = owner.registerStageATask(submittedTask,
            generationID: initial.generationID, launchID: submittedLaunch)
        subscription.cancel()
        #expect(replaced && replacementAccepted)
        #expect(!accepted, "A synchronous replacement has revoked this exact task/launch, even if generation ID is reused.")
        #expect(owner.activeGeneration?.identity == replacement)
        #expect(owner.stageATask == replacementTask)
        #expect(owner.activeGeneration?.stageALaunchID == replacementLaunch)
        #expect(oldTask.isCancelled && submittedTask.isCancelled)
        owner.closeAdmission()
        oldTask.cancel(); submittedTask.cancel(); replacementTask.cancel()
        _ = await oldTask.result
        _ = await submittedTask.result
        _ = await replacementTask.result
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func terminalSubscribersSeeCommittedFenceAndCannotMarkReplacementTerminal() async {
        let owner = GenerationCoordinator()
        let initial = Self.identity("terminal-original"), replacement = Self.identity("terminal-replacement")
        owner.activate(identity: initial, persistenceTicket: 7, triggerPath: .manualGenerate, startedAt: Date())
        var observedCommittedFence = false
        var replaced = false
        let subscription = owner.objectWillChange.sink { _ in
            guard !replaced else { return }
            replaced = true
            observedCommittedFence = owner.terminalGenerationIDs.contains(initial.generationID)
            owner.activate(identity: replacement, persistenceTicket: 8, triggerPath: .regenerate, startedAt: Date())
        }
        owner.markTerminal(generationID: initial.generationID)
        subscription.cancel()
        #expect(observedCommittedFence)
        #expect(owner.terminalGenerationIDs.contains(initial.generationID))
        #expect(!owner.terminalGenerationIDs.contains(replacement.generationID))
        #expect(owner.canPublish(replacement))
        owner.closeAdmission()
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    @Test
    func terminalResetPublishesOnlyAfterExistingAuditFencesAreRemoved() async {
        let owner = GenerationCoordinator()
        let initial = Self.identity("terminal-reset")
        owner.activate(identity: initial, persistenceTicket: 9, triggerPath: .manualGenerate, startedAt: Date())
        owner.markTerminal(generationID: initial.generationID)
        owner.invalidateAndCancel()
        var observations: [Bool] = []
        let subscription = owner.objectWillChange.sink { _ in
            observations.append(owner.terminalGenerationIDs.isEmpty)
        }
        owner.resetTerminalHistory()
        subscription.cancel()
        #expect(observations == [true])
        #expect(owner.terminalGenerationIDs.isEmpty)
        owner.closeAdmission()
        await owner.drainRetiredTasks()
    }

    private static func identity(_ id: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-\(id)", generationID: id,
            sessionID: "synthetic-session", questionText: "Explain transaction isolation",
            promptPrimaryQuestion: "Explain transaction isolation", contextSnapshotID: "synthetic-context")
    }
}
