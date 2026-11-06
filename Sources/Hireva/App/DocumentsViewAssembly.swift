import SwiftUI

/// Transitional assembly for remaining application action/readiness values.
/// The leaf owns no AppState reference and observes Documents and Context.
@MainActor
struct DocumentsApplicationHost: View {
    @ObservedObject var appState: AppState
    var body: some View { content }
    var content: DocumentsView {
        DocumentsView(documents: appState.documentsState, context: appState.interviewContextState,
            storySettings: appState.settingsState,
            storyRepository: PreparationRepository(database: appState.database),
            contextIndexStatus: appState.userFacingRelevantContextStatus,
            feedbacks: appState.activeActionFeedbacks, loadingStates: appState.actionLoadingStates,
            save: { [weak appState] type, text in appState?.saveDocument(type: type, title: type.title, content: text) },
            clear: { [weak appState] in appState?.deleteDocument($0) },
            rebuildIndex: { [weak appState] in appState?.rebuildCleanRAGIndex() },
            previewFeedback: { [weak appState] type, expanded in
                guard let appState else { return }
                let id = ActionID.previewDocument(type)
                appState.beginAction(id, title: expanded ? "Hiding preview" : "Opening clean preview", message: "Showing the text used for relevant context.")
                appState.completeAction(id, title: expanded ? "Preview hidden" : "Clean preview shown",
                    message: expanded ? "\(type.title) clean text preview is collapsed." : "This is the plain-text version used for relevant context.")
            },
            clearDraftFeedback: { [weak appState] type in
                appState?.completeAction(ActionID.clearDocument(type), title: "Editor cleared", message: "\(type.title) draft text was cleared.")
            },
            importDocument: { [weak appState] in appState?.importPlainTextDocument(from: $0, as: $1) },
            showError: { [weak appState] in appState?.showError($0) },
            startInterview: { [weak appState] in
                guard let appState else { return }
                if appState.coreInterviewReadinessPassed { appState.startListening(mode: .microphone) }
                else { appState.selectSection(.readinessCheck) }
            })
    }
}
