import SwiftUI

struct ProviderEditorView: View {
    @ObservedObject var settingsState: SettingsState
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let requestFeedback: (ActionFeedback) -> Void
    @State private var draft: LLMProviderConfiguration
    @State private var apiKey = ""
    @State private var confirmDeleteProvider = false

    init(settingsState: SettingsState, provider: LLMProviderConfiguration,
         feedbacks: [ActionFeedback], loadingStates: [String: Bool],
         requestFeedback: @escaping (ActionFeedback) -> Void) {
        self.settingsState = settingsState
        self.feedbacks = feedbacks
        self.loadingStates = loadingStates
        self.requestFeedback = requestFeedback
        _draft = State(initialValue: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(draft.name, systemImage: "cloud")
                    .font(.headline)
                Spacer()
                StatusPill(title: draft.kind.displayName, systemImage: "cpu", tint: .blue)
            }

            HStack {
                TextField("Provider name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(visibleProviderKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .frame(width: 210)
            }

            TextField("Base URL", text: $draft.baseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $draft.model)
                .textFieldStyle(.roundedBorder)

            if draft.apiKeyAccount != nil {
                HStack {
                    SecureField("API key for \(draft.name)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    ActionButtonContent(
                        isLoading: loadingStates[saveKeyActionID] == true,
                        feedback: latestFeedback(for: saveKeyActionID),
                        title: "Save Key",
                        loadingTitle: "Saving securely...",
                        successTitle: "Saved",
                        systemImage: "key.fill",
                        disabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        settingsState.saveAPIKey(apiKey, for: draft)
                        apiKey = ""
                    }
                }
            }

            HStack {
                Toggle("JSON mode", isOn: $draft.supportsJSONMode)
                Toggle("Streaming", isOn: $draft.supportsStreaming)
                Toggle("Thinking", isOn: $draft.supportsThinking)
            }
            .font(.caption)

            InlineStatusBanner(providerFeedback)

            HStack {
                ActionButtonContent(
                    isLoading: loadingStates[ActionID.providerSwitch] == true,
                    feedback: latestFeedback(for: ActionID.providerSwitch),
                    title: "Use for Realtime",
                    loadingTitle: "Switching...",
                    successTitle: "Using realtime",
                    systemImage: "dot.radiowaves.left.and.right"
                ) {
                    settingsState.setActiveRealtimeProvider(draft)
                }
                .tint(settingsState.activeRealtimeProvider?.id == draft.id ? .accentColor : .secondary)

                ActionButtonContent(
                    isLoading: loadingStates[saveActionID] == true,
                    feedback: latestFeedback(for: saveActionID),
                    title: "Use for Recap",
                    loadingTitle: "Saving...",
                    successTitle: "Using recap",
                    systemImage: "doc.text"
                ) {
                    settingsState.setActiveRecapProvider(draft)
                }
                .tint(settingsState.activeRecapProvider?.id == draft.id ? .accentColor : .secondary)

                Spacer()

                ActionButtonContent(
                    isLoading: loadingStates[testActionID] == true,
                    feedback: latestFeedback(for: testActionID),
                    title: "Test",
                    loadingTitle: "Testing...",
                    successTitle: "Connected",
                    systemImage: "network"
                ) {
                    settingsState.testProviderConnection(draft)
                }

                ActionButtonContent(
                    isLoading: loadingStates[saveActionID] == true,
                    feedback: latestFeedback(for: saveActionID),
                    title: "Save",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "checkmark.circle",
                    isProminent: true
                ) {
                    settingsState.saveProviderConfiguration(draft)
                }

                ActionButtonContent(
                    isLoading: loadingStates[deleteActionID] == true,
                    feedback: latestFeedback(for: deleteActionID),
                    title: "Delete",
                    loadingTitle: "Deleting...",
                    successTitle: "Deleted",
                    systemImage: "trash",
                    role: .destructive,
                    controlSize: .small
                ) {
                    infoAction(deleteActionID, title: "Confirm provider delete", message: "Confirm before removing \(draft.name).", autoDismissAfter: nil)
                    confirmDeleteProvider = true
                }
            }

            if let result = settingsState.providerConnectionResults[draft.id] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: draft.kind) { _, newKind in
            if newKind == .ollamaLocal {
                draft.kind = .deepSeek
                draft.baseURL = "https://api.deepseek.com"
                draft.model = "deepseek-v4-flash"
                draft.apiKeyAccount = KeychainConstants.deepSeekAccount
            } else if draft.apiKeyAccount == nil {
                draft.apiKeyAccount = "custom.\(draft.id.uuidString)"
            }
        }
        .confirmationDialog("Delete provider?", isPresented: $confirmDeleteProvider) {
            Button("Delete Provider", role: .destructive) {
                settingsState.deleteProviderConfiguration(draft)
            }
            Button("Cancel", role: .cancel) {
                infoAction(deleteActionID, title: "Delete cancelled", message: "\(draft.name) was left unchanged.")
            }
        } message: {
            Text("This removes \(draft.name) from normal provider choices. Saved keys remain hidden.")
        }
    }

    private var visibleProviderKinds: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0 != .ollamaLocal }
    }

    private var saveKeyActionID: String {
        ActionID.provider(ActionID.providerSaveKey, draft.id)
    }

    private var testActionID: String {
        ActionID.provider(ActionID.providerTest, draft.id)
    }

    private var saveActionID: String {
        ActionID.provider(ActionID.providerSave, draft.id)
    }

    private var deleteActionID: String {
        ActionID.provider(ActionID.providerDelete, draft.id)
    }

    private var providerFeedback: ActionFeedback? {
        latestFeedback(matching: [
            saveKeyActionID,
            testActionID,
            saveActionID,
            deleteActionID,
            ActionID.providerSwitch
        ])
    }

    private func latestFeedback(for actionID: String) -> ActionFeedback? {
        feedbacks.last { $0.actionID == actionID }
    }
    private func latestFeedback(matching actionIDs: [String]) -> ActionFeedback? {
        let ids = Set(actionIDs)
        return feedbacks.last { ids.contains($0.actionID) }
    }

    private func infoAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4) {
        requestFeedback(ActionFeedback(actionID: id, title: title, message: message,
            kind: .info, autoDismissAfter: autoDismissAfter))
    }
}
