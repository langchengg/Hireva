import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var settings = AppSettings.default
    @State private var includeAPIKeyInDelete = false
    @State private var newProviderKind: LLMProviderKind = .openAICompatible
    @State private var embeddingAPIKey = ""
    @State private var confirmClearLocalData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.largeTitle.weight(.bold))

                aiProviderCard
                relevantContextCard
                audioCard
                dialogueCard
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
                statusLine("DeepSeek key", deepSeekKeyStatusText)
                Spacer()
                ActionButton(
                    appState: appState,
                    actionID: ActionID.testDeepSeek,
                    title: "Test Connection",
                    loadingTitle: "Testing...",
                    successTitle: "Connected",
                    systemImage: "network",
                    disabled: !appState.keychainDeepSeekKeyExists || appState.isTestingConnection
                ) {
                    appState.testDeepSeekConnection()
                }
            }

            if let warning = appState.keychainAuthorizationWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusLine("Realtime model", appState.activeRealtimeProvider?.model ?? settings.realtimeModel.displayName)
            statusLine("Full answer model", appState.activeRecapProvider?.model ?? settings.recapModel.displayName)

            InlineStatusBanner(aiProviderFeedback)

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
                    ForEach(visibleProviderKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                ActionButton(
                    appState: appState,
                    actionID: ActionID.providerSave,
                    title: "Add Provider",
                    loadingTitle: "Adding...",
                    successTitle: "Provider added",
                    systemImage: "plus"
                ) {
                    let provider = makeNewProvider(kind: newProviderKind)
                    appState.beginAction(ActionID.providerSave, title: "Adding provider", message: "Creating \(provider.name)...")
                    appState.saveProviderConfiguration(provider)
                    appState.completeAction(ActionID.providerSave, title: "Provider added", message: "\(provider.name) is ready to configure.")
                }
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
                    ActionButton(
                        appState: appState,
                        actionID: ActionID.saveEmbeddingKey,
                        title: "Save Key",
                        loadingTitle: "Saving securely...",
                        successTitle: "Saved",
                        systemImage: "key.fill",
                        disabled: embeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        appState.saveSettings(settings)
                        appState.saveEmbeddingAPIKey(embeddingAPIKey, account: settings.embeddingApiKeyAccount)
                        embeddingAPIKey = ""
                    }
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

            InlineStatusBanner(relevantContextFeedback)

            if appState.isRebuildingEmbeddings {
                ProgressView(value: appState.rebuildProgress, total: 1.0)
                Button("Cancel Rebuild") {
                    appState.cancelEmbeddingRebuild()
                }
                .buttonStyle(.bordered)
            } else {
                HStack {
                    ActionButton(
                        appState: appState,
                        actionID: ActionID.rebuildCleanRAG,
                        title: "Rebuild Clean Context Index",
                        loadingTitle: "Rebuilding...",
                        successTitle: "Context rebuilt",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) {
                        appState.rebuildCleanRAGIndex()
                    }

                    ProgressButton(
                        appState: appState,
                        actionID: ActionID.rebuildEmbeddings,
                        title: "Rebuild Embeddings",
                        loadingTitle: "Rebuilding...",
                        systemImage: "square.stack.3d.up",
                        progress: appState.rebuildProgress,
                        disabled: !settings.enableVectorRAG
                    ) {
                        appState.rebuildAllEmbeddings()
                    }

                    ActionButton(
                        appState: appState,
                        actionID: ActionID.saveSettings,
                        title: "Save Context Settings",
                        loadingTitle: "Saving...",
                        successTitle: "Saved",
                        systemImage: "checkmark.circle",
                        isProminent: true
                    ) {
                        appState.saveSettings(settings)
                    }
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

            InlineStatusBanner(appState.latestActionFeedback(for: ActionID.saveSettings))

            ActionButton(
                appState: appState,
                actionID: ActionID.saveSettings,
                title: "Save Audio Settings",
                loadingTitle: "Saving...",
                successTitle: "Saved",
                systemImage: "checkmark.circle",
                isProminent: true
            ) {
                appState.saveSettings(settings)
            }
        }
    }

    private var dialogueCard: some View {
        settingsCard("Interview Dialogue", icon: "person.3.fill") {
            Picker("Interview Domain", selection: Binding(
                get: { appState.activeInterviewDomainID },
                set: appState.selectInterviewDomain
            )) {
                ForEach(InterviewDomainID.allCases) { domain in
                    Text(domain.displayName).tag(domain)
                }
            }
            .pickerStyle(.menu)

            Picker("Interview Mode", selection: $appState.interviewSessionMode) {
                ForEach(InterviewSessionMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Answer panel questions", isOn: $appState.answerPanelQuestionsEnabled)
            Toggle("Suppress presentation", isOn: Binding(
                get: { appState.candidatePresentationMode == .suppressAnswers },
                set: { appState.candidatePresentationMode = $0 ? .suppressAnswers : .normal }
            ))
            Toggle("Suppress candidate questions to panel", isOn: Binding(
                get: { appState.candidateAsksPanelMode == .suppressAnswers },
                set: { appState.candidateAsksPanelMode = $0 ? .suppressAnswers : .normal }
            ))
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

            InlineStatusBanner(appState.latestActionFeedback(matching: [ActionID.saveSettings, ActionID.floatingDisplayMode]))

            ActionButton(
                appState: appState,
                actionID: ActionID.saveSettings,
                title: "Save Floating Window Settings",
                loadingTitle: "Saving...",
                successTitle: "Saved",
                systemImage: "checkmark.circle",
                isProminent: true
            ) {
                appState.saveSettings(settings)
            }
        }
    }

    private var privacyCard: some View {
        settingsCard("Privacy & Security", icon: "lock.shield") {
            Text("Provider keys are securely saved and never shown in raw form. Documents, transcripts, and sessions are stored locally unless you clear them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Also delete securely saved provider keys", isOn: $includeAPIKeyInDelete)

            InlineStatusBanner(appState.latestActionFeedback(for: ActionID.clearLocalData))

            ActionButton(
                appState: appState,
                actionID: ActionID.clearLocalData,
                title: "Clear Local Data",
                loadingTitle: "Clearing...",
                successTitle: "Cleared",
                systemImage: "trash",
                role: .destructive
            ) {
                appState.infoAction(ActionID.clearLocalData, title: "Confirm clear local data", message: "Confirm before deleting local documents, sessions, and transcripts.", autoDismissAfter: nil)
                confirmClearLocalData = true
            }
        }
        .confirmationDialog("Clear local app data?", isPresented: $confirmClearLocalData) {
            Button("Clear Local Data", role: .destructive) {
                appState.deleteAllLocalData(includeAPIKey: includeAPIKeyInDelete)
            }
            Button("Cancel", role: .cancel) {
                appState.infoAction(ActionID.clearLocalData, title: "Clear cancelled", message: "Local documents, sessions, transcripts, and keys were left unchanged.")
            }
        } message: {
            Text(includeAPIKeyInDelete ? "This clears local documents, sessions, transcripts, and securely saved provider keys." : "This clears local documents, sessions, and transcripts. Securely saved provider keys are kept.")
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

    private var visibleProviderKinds: [LLMProviderKind] {
        LLMProviderKind.allCases.filter { $0 != .ollamaLocal }
    }

    private var aiProviderFeedback: ActionFeedback? {
        let providerIDs = visibleProviderConfigurations.flatMap { provider in
            [
                ActionID.provider(ActionID.providerSaveKey, provider.id),
                ActionID.provider(ActionID.providerTest, provider.id),
                ActionID.provider(ActionID.providerSave, provider.id),
                ActionID.provider(ActionID.providerDelete, provider.id)
            ]
        }
        return appState.latestActionFeedback(matching: [ActionID.testDeepSeek, ActionID.providerSave, ActionID.providerSwitch] + providerIDs)
    }

    private var deepSeekKeyStatusText: String {
        if appState.keychainDeepSeekKeyExists {
            return "Securely saved"
        }
        if appState.keychainAuthorizationWarning != nil {
            return "Needs re-authorization"
        }
        return "Missing"
    }

    private var relevantContextFeedback: ActionFeedback? {
        appState.latestActionFeedback(matching: [
            ActionID.saveEmbeddingKey,
            ActionID.rebuildCleanRAG,
            ActionID.rebuildEmbeddings,
            ActionID.saveSettings,
            ActionID.providerTest
        ])
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
