import SwiftUI

struct ProviderEditorView: View {
    @ObservedObject var appState: AppState
    @State private var draft: LLMProviderConfiguration
    @State private var apiKey = ""
    @State private var confirmDeleteProvider = false

    init(appState: AppState, provider: LLMProviderConfiguration) {
        self.appState = appState
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
                    ActionButton(
                        appState: appState,
                        actionID: saveKeyActionID,
                        title: "Save Key",
                        loadingTitle: "Saving securely...",
                        successTitle: "Saved",
                        systemImage: "key.fill",
                        disabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        appState.saveAPIKey(apiKey, for: draft)
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
                ActionButton(
                    appState: appState,
                    actionID: ActionID.providerSwitch,
                    title: "Use for Realtime",
                    loadingTitle: "Switching...",
                    successTitle: "Using realtime",
                    systemImage: "dot.radiowaves.left.and.right"
                ) {
                    appState.setActiveRealtimeProvider(draft)
                }
                .tint(appState.activeRealtimeProvider?.id == draft.id ? .accentColor : .secondary)

                ActionButton(
                    appState: appState,
                    actionID: saveActionID,
                    title: "Use for Recap",
                    loadingTitle: "Saving...",
                    successTitle: "Using recap",
                    systemImage: "doc.text"
                ) {
                    appState.setActiveRecapProvider(draft)
                }
                .tint(appState.activeRecapProvider?.id == draft.id ? .accentColor : .secondary)

                Spacer()

                ActionButton(
                    appState: appState,
                    actionID: testActionID,
                    title: "Test",
                    loadingTitle: "Testing...",
                    successTitle: "Connected",
                    systemImage: "network"
                ) {
                    appState.testProviderConnection(draft)
                }

                ActionButton(
                    appState: appState,
                    actionID: saveActionID,
                    title: "Save",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "checkmark.circle",
                    isProminent: true
                ) {
                    appState.saveProviderConfiguration(draft)
                }

                ActionButton(
                    appState: appState,
                    actionID: deleteActionID,
                    title: "Delete",
                    loadingTitle: "Deleting...",
                    successTitle: "Deleted",
                    systemImage: "trash",
                    role: .destructive,
                    controlSize: .small
                ) {
                    appState.infoAction(deleteActionID, title: "Confirm provider delete", message: "Confirm before removing \(draft.name).", autoDismissAfter: nil)
                    confirmDeleteProvider = true
                }
            }

            if let result = appState.providerConnectionResults[draft.id] {
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
                appState.deleteProviderConfiguration(draft)
            }
            Button("Cancel", role: .cancel) {
                appState.infoAction(deleteActionID, title: "Delete cancelled", message: "\(draft.name) was left unchanged.")
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
        appState.latestActionFeedback(matching: [
            saveKeyActionID,
            testActionID,
            saveActionID,
            deleteActionID,
            ActionID.providerSwitch
        ])
    }
}
