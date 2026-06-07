import SwiftUI

struct ProviderEditorView: View {
    @ObservedObject var appState: AppState
    @State private var draft: LLMProviderConfiguration
    @State private var apiKey = ""

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
                    ForEach(LLMProviderKind.allCases) { kind in
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
                    Button("Save Key") {
                        appState.saveAPIKey(apiKey, for: draft)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack {
                Toggle("JSON mode", isOn: $draft.supportsJSONMode)
                Toggle("Streaming", isOn: $draft.supportsStreaming)
                Toggle("Thinking", isOn: $draft.supportsThinking)
            }
            .font(.caption)

            HStack {
                Button("Use for Realtime") {
                    appState.setActiveRealtimeProvider(draft)
                }
                .buttonStyle(.bordered)
                .tint(appState.activeRealtimeProvider?.id == draft.id ? .accentColor : .secondary)

                Button("Use for Recap") {
                    appState.setActiveRecapProvider(draft)
                }
                .buttonStyle(.bordered)
                .tint(appState.activeRecapProvider?.id == draft.id ? .accentColor : .secondary)

                Spacer()

                Button("Test") {
                    appState.testProviderConnection(draft)
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    appState.saveProviderConfiguration(draft)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    appState.deleteProviderConfiguration(draft)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
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
    }
}
