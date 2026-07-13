import Foundation
import Combine
import SwiftUI

extension AppState {
    func beginAction(_ id: String, title: String, message: String) {
        actionLoadingStates[id] = true
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
        actionLoadingStates[id] = false
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

    func warnAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 6.0) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .warning,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func failAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = nil) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .error,
                autoDismissAfter: autoDismissAfter
            )
        )
        updateDiagnostics { $0.lastError = message }
    }

    func infoAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4.0) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .info,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func clearActionFeedback(_ id: String) {
        actionLoadingStates[id] = false
        activeActionFeedbacks.removeAll { $0.actionID == id }
        actionFeedbackDismissTasks[id]?.cancel()
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

    func setActionFeedback(_ feedback: ActionFeedback) {
        actionFeedbackDismissTasks[feedback.actionID]?.cancel()
        activeActionFeedbacks.removeAll { $0.actionID == feedback.actionID }
        activeActionFeedbacks.append(feedback)
        if activeActionFeedbacks.count > 8 {
            activeActionFeedbacks = Array(activeActionFeedbacks.suffix(8))
        }
        guard let autoDismissAfter = feedback.autoDismissAfter else { return }
        actionFeedbackDismissTasks[feedback.actionID] = Task { [weak self, feedbackID = feedback.id, actionID = feedback.actionID] in
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            await MainActor.run {
                guard let self else { return }
                self.activeActionFeedbacks.removeAll { $0.id == feedbackID }
                if self.actionFeedbackDismissTasks[actionID]?.isCancelled == false {
                    self.actionFeedbackDismissTasks[actionID] = nil
                }
            }
        }
    }
}
