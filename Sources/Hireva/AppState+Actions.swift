import Foundation
import Combine
import SwiftUI

private enum ActionFeedbackDismissalExecutionScope {
    @TaskLocal static var id: UUID? = nil
}

extension AppState {
    // Inherited scope metadata can outlive a completed launch. Reject only
    // the exact worker still retained by this App's existing action owner.
    var canDrainActionFeedbackDismissalsFromCurrentTask: Bool {
        guard let id = ActionFeedbackDismissalExecutionScope.id else { return true }
        return actionFeedbackDismissalTasksToDrain[id] == nil
    }

    func beginAction(_ id: String, title: String, message: String) {
        let feedbackBeforePublication = activeActionFeedbacks.last { $0.actionID == id }
        let dismissalBeforePublication = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = true
        guard activeActionFeedbacks.last(where: { $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissalBeforePublication else { return }
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .loading
            )
        )
    }

    func completeAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4.0) {
        let feedbackBeforePublication = activeActionFeedbacks.last { $0.actionID == id }
        let dismissalBeforePublication = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = false
        guard activeActionFeedbacks.last(where: { $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissalBeforePublication else { return }
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .success,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func warnAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 6.0, whileCurrent: (() -> Bool)? = nil) {
        guard whileCurrent?() != false else { return }
        let feedbackBeforePublication = activeActionFeedbacks.last { $0.actionID == id }
        let dismissalBeforePublication = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = false
        guard activeActionFeedbacks.last(where: { $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissalBeforePublication else { return }
        guard whileCurrent?() != false else { return }
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .warning,
                autoDismissAfter: autoDismissAfter
            ),
            whileCurrent: whileCurrent
        )
    }

    func failAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = nil, whileCurrent: (() -> Bool)? = nil) {
        guard whileCurrent?() != false else { return }
        let feedbackBeforePublication = activeActionFeedbacks.last { $0.actionID == id }
        let dismissalBeforePublication = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = false
        guard activeActionFeedbacks.last(where: { $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissalBeforePublication else { return }
        guard whileCurrent?() != false else { return }
        let feedback = ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .error,
                autoDismissAfter: autoDismissAfter
        )
        guard setActionFeedback(feedback, whileCurrent: whileCurrent) else { return }
        guard whileCurrent?() != false, activeActionFeedbacks.contains(feedback) else { return }
        updateDiagnostics { $0.lastError = message }
    }

    func failGenerationNonBlocking(title: String = "Generation failed", message: String, whileCurrent: (() -> Bool)? = nil) {
        guard whileCurrent?() != false else { return }
        errorMessage = nil
        guard whileCurrent?() != false else { return }
        failAction(ActionID.generateAnswer, title: title, message: message, whileCurrent: whileCurrent)
    }

    func infoAction(
        _ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4.0,
        whileCurrent: (() -> Bool)? = nil
    ) {
        guard whileCurrent?() != false else { return }
        let feedbackBeforePublication = activeActionFeedbacks.last { $0.actionID == id }
        let dismissalBeforePublication = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = false
        guard activeActionFeedbacks.last(where: { $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissalBeforePublication else { return }
        guard whileCurrent?() != false else { return }
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .info,
                autoDismissAfter: autoDismissAfter
            ),
            whileCurrent: whileCurrent
        )
    }

    func clearActionFeedback(_ id: String) {
        let feedbackBeforePublication = activeActionFeedbacks.filter { $0.actionID == id }
        let feedbackIDs = Set(feedbackBeforePublication.map(\.id))
        let dismissal = actionFeedbackDismissTasks[id]
        actionLoadingStates[id] = false
        guard activeActionFeedbacks.filter({ $0.actionID == id }) == feedbackBeforePublication,
              actionFeedbackDismissTasks[id] == dismissal else { return }
        activeActionFeedbacks.removeAll { $0.actionID == id && feedbackIDs.contains($0.id) }
        guard actionFeedbackDismissTasks[id] == dismissal else { return }
        dismissal?.cancel()
        guard actionFeedbackDismissTasks[id] == dismissal else { return }
        actionFeedbackDismissTasks[id] = nil
    }

    func isActionLoading(_ id: String) -> Bool {
        actionLoadingStates[id] == true
    }

    func latestActionFeedback(for id: String) -> ActionFeedback? {
        activeActionFeedbacks.last { $0.actionID == id }
    }

    func latestActionFeedback(matching ids: [String]) -> ActionFeedback? {
        activeActionFeedbacks.last { ids.contains($0.actionID) }
    }

    /// Publish the feature-supplied value through the existing action state.
    /// Each synchronous publication must preserve the existing value/task receipt.
    func publishActionFeedback(_ feedback: ActionFeedback, recordsError: Bool = true) {
        let previousFeedback = activeActionFeedbacks.filter { $0.actionID == feedback.actionID }
        let previousDismissal = actionFeedbackDismissTasks[feedback.actionID]
        actionLoadingStates[feedback.actionID] = feedback.kind == .loading
        guard activeActionFeedbacks.filter({ $0.actionID == feedback.actionID }) == previousFeedback,
              actionFeedbackDismissTasks[feedback.actionID] == previousDismissal else { return }
        guard setActionFeedback(feedback) else { return }
        if recordsError && feedback.kind == .error {
            updateDiagnostics { $0.lastError = feedback.message }
        }
    }

    @discardableResult
    func setActionFeedback(_ feedback: ActionFeedback, whileCurrent: (() -> Bool)? = nil) -> Bool {
        guard whileCurrent?() != false else { return false }
        let dismissalBeforePublication = actionFeedbackDismissTasks[feedback.actionID]
        let feedbackBeforeCancellation = activeActionFeedbacks.filter { $0.actionID == feedback.actionID }
        dismissalBeforePublication?.cancel()
        guard actionFeedbackDismissTasks[feedback.actionID] == dismissalBeforePublication,
              activeActionFeedbacks.filter({ $0.actionID == feedback.actionID }) == feedbackBeforeCancellation else { return false }
        guard whileCurrent?() != false else { return false }
        var feedbacks = activeActionFeedbacks
        feedbacks.removeAll { $0.actionID == feedback.actionID }
        feedbacks.append(feedback)
        activeActionFeedbacks = Array(feedbacks.suffix(8))
        guard whileCurrent?() != false else { return false }
        guard activeActionFeedbacks.contains(feedback),
              actionFeedbackDismissTasks[feedback.actionID] == dismissalBeforePublication else { return false }
        guard !isShuttingDown, let autoDismissAfter = feedback.autoDismissAfter else { return true }
        let dismissalDelay = delayProvider
        let dismissalNanoseconds = UInt64(max(0, autoDismissAfter) * 1_000_000_000)
        let dismissalID = UUID()
        let task = Task { [weak self, feedbackID = feedback.id, actionID = feedback.actionID] in
            // No suspension follows retirement: only this exact launch can
            // remove its lifecycle receipt after the real operation returns.
            defer { self?.actionFeedbackDismissalTasksToDrain[dismissalID] = nil }
            await ActionFeedbackDismissalExecutionScope.$id.withValue(dismissalID) {
                do {
                    try await dismissalDelay.sleep(nanoseconds: dismissalNanoseconds)
                    try Task.checkCancellation()
                } catch { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled,
                          self.actionFeedbackDismissTasks[actionID] == self.actionFeedbackDismissalTasksToDrain[dismissalID],
                          self.activeActionFeedbacks.contains(where: { $0.actionID == actionID && $0.id == feedbackID }) else { return }
                    self.activeActionFeedbacks.removeAll { $0.id == feedbackID }
                    // A committed publication can install a newer role. The
                    // lifecycle receipt still belongs to this exact old launch.
                    guard !Task.isCancelled,
                          self.actionFeedbackDismissTasks[actionID] == self.actionFeedbackDismissalTasksToDrain[dismissalID],
                          !self.activeActionFeedbacks.contains(where: { $0.actionID == actionID }) else { return }
                    self.actionFeedbackDismissTasks[actionID] = nil
                }
            }
        }
        // The existing per-action map selects the current publisher; this
        // same-owner collection retains every live launch until actual exit.
        actionFeedbackDismissalTasksToDrain[dismissalID] = task
        actionFeedbackDismissTasks[feedback.actionID] = task
        return true
    }
}
