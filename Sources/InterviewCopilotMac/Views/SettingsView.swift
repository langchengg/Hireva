import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var settings = AppSettings.default
    @State private var includeAPIKeyInDelete = false
    @State private var newProviderKind: LLMProviderKind = .openAICompatible
    @State private var embeddingAPIKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.largeTitle.weight(.bold))

                aiProviderCard
                relevantContextCard
                audioCard
                floatingWindowCard
                privacyCard
            }
            .padding(28)
            .frame(maxWidth: 840, alignment: .leading)
        }
        .navigationTitle("Settings")
        .onAppear {
            settings = appState.settings
        }
        .onChange(of: appState.settings) { _, newValue in
            settings = newValue
        }
    }

    private var aiProviderCard: some View {
        settingsCard("AI Provider", icon: "brain") {
            HStack {
                statusLine("DeepSeek key", appState.keychainDeepSeekKeyExists ? "Securely saved" : "Missing")
                Spacer()
                Button("Test Connection") {
                    appState.testDeepSeekConnection()
                }
                .buttonStyle(.bordered)
                .disabled(!appState.keychainDeepSeekKeyExists || appState.isTestingConnection)
            }

            statusLine("Realtime model", appState.activeRealtimeProvider?.model ?? settings.realtimeModel.displayName)
            statusLine("Full answer model", appState.activeRecapProvider?.model ?? settings.recapModel.displayName)

            if appState.isTestingConnection {
                ProgressView()
                    .controlSize(.small)
            }
            if let result = appState.connectionResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            ForEach(visibleProviderConfigurations) { provider in
                ProviderEditorView(appState: appState, provider: provider)
            }

            if visibleProviderConfigurations.isEmpty {
                Text("DeepSeek is the recommended provider. Add a compatible provider only if your team uses a different API.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Picker("Add provider", selection: $newProviderKind) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Button {
                    appState.saveProviderConfiguration(makeNewProvider(kind: newProviderKind))
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var relevantContextCard: some View {
        settingsCard("Embeddings / Relevant Context", icon: "doc.text.magnifyingglass") {
            Picker("Retrieval mode", selection: relevantContextModeBinding) {
                Text("Keyword-only").tag(false)
                Text("Cloud embeddings").tag(true)
            }
            .pickerStyle(.segmented)

            if settings.enableVectorRAG {
                Picker("Embedding provider", selection: $settings.embeddingProviderKind) {
                    ForEach(EmbeddingProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                TextField("Embedding base URL", text: $settings.embeddingBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Embedding model", text: $settings.embeddingModelName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    SecureField("Embedding API key", text: $embeddingAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Key") {
                        appState.saveSettings(settings)
                        appState.saveEmbeddingAPIKey(embeddingAPIKey, account: settings.embeddingApiKeyAccount)
                        embeddingAPIKey = ""
                    }
                    .disabled(embeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                statusLine("Embedding key", appState.embeddingKeyStatus(account: settings.embeddingApiKeyAccount))
            } else {
                Text("Keyword search is local and ready after documents are saved. Cloud embeddings are optional.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusLine("Current context", appState.userFacingRelevantContextStatus)
            if let coverage = appState.embeddingCoverage {
                statusLine("Embedding coverage", "\(coverage.chunksWithEmbeddings) / \(coverage.totalChunks) chunks (\(Int(coverage.coveragePercent))%)")
            }

            if appState.isRebuildingEmbeddings {
                ProgressView(value: appState.rebuildProgress, total: 1.0)
                Button("Cancel Rebuild") {
                    appState.cancelEmbeddingRebuild()
                }
                .buttonStyle(.bordered)
            } else {
                HStack {
                    Button("Rebuild Clean Context Index") {
                        appState.rebuildCleanRAGIndex()
                    }
                    .buttonStyle(.bordered)

                    Button("Rebuild Embeddings") {
                        appState.rebuildAllEmbeddings()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.enableVectorRAG)

                    Button("Save Context Settings") {
                        appState.saveSettings(settings)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var audioCard: some View {
        settingsCard("Audio", icon: "speaker.wave.2.fill") {
            statusLine("Input device", audioDeviceManager.currentInputDeviceName)
            statusLine("Output device", audioDeviceManager.currentOutputDeviceName)

            Picker("Default capture mode", selection: $settings.audioCaptureMode) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Text(mode.shortDisplayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.audioCaptureMode.userFacingDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable automatic question detection", isOn: $settings.automaticQuestionDetectionEnabled)
            Toggle("Save transcripts locally", isOn: $settings.saveTranscriptsLocally)

            Button("Save Audio Settings") {
                appState.saveSettings(settings)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var floatingWindowCard: some View {
        settingsCard("Floating Window", icon: "macwindow") {
            Picker("Display mode", selection: $settings.floatingAssistantDisplayMode) {
                ForEach(FloatingAssistantDisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("High contrast answer card", isOn: $settings.highContrastFloatingPanel)
                .onChange(of: settings.highContrastFloatingPanel) { _, newValue in
                    if newValue {
                        settings.floatingWindowOpacity = max(settings.floatingWindowOpacity, 0.65)
                    }
                }

            HStack {
                Text("Opacity")
                    .foregroundStyle(.secondary)
                Slider(value: $settings.floatingWindowOpacity, in: (settings.highContrastFloatingPanel ? 0.65 : 0.55)...1.0)
                Text(String(format: "%.0f%%", settings.floatingWindowOpacity * 100))
                    .font(.callout.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }

            statusLine("Always on top", "On")

            Button("Save Floating Window Settings") {
                appState.saveSettings(settings)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var privacyCard: some View {
        settingsCard("Privacy & Security", icon: "lock.shield") {
            Text("Provider keys are securely saved and never shown in raw form. Documents, transcripts, and sessions are stored locally unless you clear them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Also delete securely saved provider keys", isOn: $includeAPIKeyInDelete)

            Button("Clear Local Data", role: .destructive) {
                appState.deleteAllLocalData(includeAPIKey: includeAPIKeyInDelete)
            }
            .buttonStyle(.bordered)
        }
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private var relevantContextModeBinding: Binding<Bool> {
        Binding(
            get: { settings.enableVectorRAG },
            set: { enabled in
                settings.enableVectorRAG = enabled
                if !enabled {
                    settings.embeddingProviderKind = .disabled
                } else if settings.embeddingProviderKind == .disabled {
                    settings.embeddingProviderKind = .openAICompatibleCloud
                }
            }
        )
    }

    private var visibleProviderConfigurations: [LLMProviderConfiguration] {
        appState.providerConfigurations.filter { $0.kind != .ollamaLocal }
    }

    private func makeNewProvider(kind: LLMProviderKind) -> LLMProviderConfiguration {
        let now = Date()
        switch kind {
        case .ollamaLocal:
            var provider = LLMProviderConfiguration.deepSeekDefault()
            provider.id = UUID()
            provider.createdAt = now
            provider.updatedAt = now
            provider.isDefaultForRealtime = false
            provider.isDefaultForRecap = false
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
