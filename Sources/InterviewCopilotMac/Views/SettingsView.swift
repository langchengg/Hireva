import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var settings = AppSettings.default
    @State private var includeAPIKeyInDelete = false
    @State private var newProviderKind: LLMProviderKind = .openAICompatible

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.largeTitle.weight(.bold))

                aiProvidersSection
                modelSection
                privacySection
                advancedSection
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            settings = appState.settings
        }
    }

    private var aiProvidersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Providers", systemImage: "server.rack")
                .font(.headline)

            HStack {
                Text("Realtime")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appState.activeRealtimeProviderBadge)
                    .font(.callout.weight(.medium))
            }
            HStack {
                Text("Recap")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appState.activeRecapProvider.map { "\($0.name): \($0.model)" } ?? "No recap provider")
                    .font(.callout.weight(.medium))
            }
            Text(appState.activeRealtimeProviderPrivacyNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(appState.providerConfigurations) { provider in
                ProviderEditorView(appState: appState, provider: provider)
            }

            HStack {
                Picker("New provider", selection: $newProviderKind) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Button {
                    appState.saveProviderConfiguration(makeNewProvider(kind: newProviderKind))
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Models and Automation", systemImage: "brain")
                .font(.headline)
            Toggle("Enable automatic question detection", isOn: $settings.automaticQuestionDetectionEnabled)
            Toggle("Enable manual-only mode", isOn: $settings.manualOnlyMode)
            Toggle("Save transcripts locally", isOn: $settings.saveTranscriptsLocally)
            Toggle("Allow question detection from microphone-only audio", isOn: $settings.allowQuestionDetectionFromMicrophoneOnly)
            Button("Save Settings") {
                appState.saveSettings(settings)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Privacy Controls", systemImage: "hand.raised")
                .font(.headline)
            Text("When AI features are used, InterviewCopilotMac sends the detected question, recent transcript up to 800 words, and top relevant CV/JD chunks up to 1,500 CV words and 1,000 JD words to the active provider. In local Ollama mode, prompts stay on this Mac. API keys and full documents are never logged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete provider API keys from Keychain", isOn: $includeAPIKeyInDelete)
            Button("Delete All Local Data", role: .destructive) {
                appState.deleteAllLocalData(includeAPIKey: includeAPIKeyInDelete)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Advanced Diagnostics", systemImage: "stethoscope")
                .font(.headline)
            diagnosticRow("State", appState.diagnostics.liveState.displayName)
            diagnosticRow("API calls", "\(appState.diagnostics.apiCallCount)")
            diagnosticRow("Last latency", appState.diagnostics.lastAPILatencyMS.map { "\($0) ms" } ?? "None")
            diagnosticRow("Last provider", appState.diagnostics.lastProviderName ?? "None")
            diagnosticRow("Last model", appState.diagnostics.lastProviderModel ?? "None")
            diagnosticBox("Last detected question JSON", appState.diagnostics.lastDetectedQuestionJSON)
            diagnosticBox("Last suggestion JSON", appState.diagnostics.lastSuggestionJSON)
            diagnosticBox("Last error", appState.diagnostics.lastError)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func diagnosticBox(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "None")
                .font(.caption.monospaced())
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func makeNewProvider(kind: LLMProviderKind) -> LLMProviderConfiguration {
        let now = Date()
        switch kind {
        case .ollamaLocal:
            var provider = LLMProviderConfiguration.localOllamaDefault()
            provider.id = UUID()
            provider.name = "Local Ollama"
            provider.createdAt = now
            provider.updatedAt = now
            provider.isDefaultForRealtime = false
            return provider
        case .deepSeek:
            var provider = LLMProviderConfiguration.deepSeekDefault()
            provider.id = UUID()
            provider.createdAt = now
            provider.updatedAt = now
            provider.isDefaultForRecap = false
            provider.apiKeyAccount = "deepseek.\(provider.id.uuidString)"
            return provider
        case .openAICompatible:
            var provider = LLMProviderConfiguration.openAICompatibleDefault()
            provider.id = UUID()
            provider.name = "Custom OpenAI-compatible"
            provider.createdAt = now
            provider.updatedAt = now
            provider.apiKeyAccount = "custom.\(provider.id.uuidString)"
            return provider
        case .openAI, .anthropic, .gemini:
            return LLMProviderConfiguration(
                id: UUID(),
                name: kind.displayName,
                kind: kind,
                baseURL: "",
                model: "",
                apiKeyAccount: "\(kind.rawValue).\(UUID().uuidString)",
                isDefaultForRealtime: false,
                isDefaultForRecap: false,
                supportsJSONMode: false,
                supportsStreaming: false,
                supportsThinking: false,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}
