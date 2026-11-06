import AppKit

// Transitional application call sites assemble narrow view inputs here. The
// settings/provider views retain and observe only their concrete feature owner.
extension SettingsView {
    @MainActor
    init(appState app: AppState) {
        self.init(settingsState: app.settingsState,
            relevantContextStatus: app.userFacingRelevantContextStatus,
            embeddingState: app.documentsState.embeddings,
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            requestFeedback: { [weak app] value in
                guard let app else { return }
                app.publishActionFeedback(value, recordsError: false)
            },
            addProvider: { [weak app] provider in
                guard let app else { return }
                app.beginAction(ActionID.providerSave, title: "Adding provider", message: "Creating \(provider.name)...")
                app.settingsState.saveProviderConfiguration(provider)
                app.completeAction(ActionID.providerSave, title: "Provider added", message: "\(provider.name) is ready to configure.")
            },
            rebuildCleanRAGIndex: { [weak app] in app?.rebuildCleanRAGIndex() },
            clearTrace: { [weak app] in
                guard let app else { return }
                do { try app.clearRuntimeTranscriptTrace() }
                catch { app.showError("Could not clear diagnostic trace: \(error.localizedDescription)") }
            },
            deleteAllLocalData: { [weak app] in app?.deleteAllLocalData(includeAPIKey: $0) },
            showError: { [weak app] in app?.showError($0) })
    }
}

extension LLMProviderQuickSwitcherView {
    @MainActor
    init(appState app: AppState, isCompact: Bool = false) {
        self.init(settingsState: app.settingsState,
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            errorMessage: app.errorMessage,
            openSettings: { [weak app] in app?.selectedSection = .settings },
            isCompact: isCompact)
    }
}
