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
                ragSettingsSection
                manualCaptureSection
                floatingWindowSection
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

    private var ragSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("RAG & Vector Embeddings Settings", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            
            Toggle("Enable Hybrid Vector RAG", isOn: $settings.enableVectorRAG)
            
            if settings.enableVectorRAG {
                Toggle("Force Hybrid RAG (Bypass 80% coverage check)", isOn: $settings.forceHybridRAG)
                
                Picker("Embedding Provider", selection: $settings.embeddingProviderKind) {
                    ForEach(EmbeddingProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                
                HStack {
                    Text("Model Name:")
                        .foregroundStyle(.secondary)
                    TextField("Model Name (e.g. nomic-embed-text)", text: $settings.embeddingModelName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Semantic Similarity Weight")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", settings.hybridSemanticWeight))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: $settings.hybridSemanticWeight, in: 0.0...1.0, step: 0.1)
                        .onChange(of: settings.hybridSemanticWeight) { _, newValue in
                            settings.hybridKeywordWeight = max(0.0, 1.0 - newValue)
                        }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Keyword Overlap Weight")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", settings.hybridKeywordWeight))
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    Slider(value: $settings.hybridKeywordWeight, in: 0.0...1.0, step: 0.1)
                        .onChange(of: settings.hybridKeywordWeight) { _, newValue in
                            settings.hybridSemanticWeight = max(0.0, 1.0 - newValue)
                        }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                if let coverage = appState.embeddingCoverage {
                    HStack {
                        Text("Coverage:")
                            .foregroundStyle(.secondary)
                        Text("\(coverage.chunksWithEmbeddings) / \(coverage.totalChunks) chunks ready (\(Int(coverage.coveragePercent))%)")
                            .font(.subheadline.weight(.semibold))
                    }
                    
                    if let dim = coverage.dimension {
                        Text("Dimension: \(dim) elements")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if coverage.staleChunksCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(coverage.staleChunksCount) chunks are missing or have stale embeddings.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Text("No embedding coverage info. Rebuild below to initialize.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                if appState.isRebuildingEmbeddings {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: appState.rebuildProgress, total: 1.0)
                        HStack {
                            Text("Rebuilding: \(Int(appState.rebuildProgress * 100))% complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") {
                                appState.cancelEmbeddingRebuild()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Button("Rebuild Embeddings") {
                            appState.rebuildAllEmbeddings()
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Save RAG Settings") {
                            appState.saveSettings(settings)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var manualCaptureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Manual Capture Options (Push-to-Ask)", systemImage: "hand.tap.fill")
                .font(.headline)
                .foregroundStyle(.purple)
            
            Picker("Manual Capture Source", selection: $settings.manualCaptureSource) {
                ForEach(ManualCaptureSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)
            
            if settings.manualCaptureSource == .microphone {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Microphone capture may include your own voice, room echo, or mixed audio. System Audio is recommended for interviewer questions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            
            Toggle("Auto-send after transcription", isOn: $settings.autoSendAfterTranscription)
            Toggle("Always show transcript review before sending", isOn: $settings.showTranscriptBeforeSending)
            Toggle("Save audio clips locally", isOn: $settings.saveManualClips)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Capture Duration")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(settings.maxManualCaptureSeconds) seconds")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Slider(value: Binding(
                    get: { Double(settings.maxManualCaptureSeconds) },
                    set: { settings.maxManualCaptureSeconds = Int($0) }
                ), in: 5...120, step: 5)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ollama Request Timeout")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(settings.ollamaRequestTimeoutSeconds) seconds")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Slider(value: Binding(
                    get: { Double(settings.ollamaRequestTimeoutSeconds) },
                    set: { settings.ollamaRequestTimeoutSeconds = Int($0) }
                ), in: 30...300, step: 10)
            }
            
            Button("Save Manual Capture Settings") {
                appState.saveSettings(settings)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var floatingWindowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Floating Window Options", systemImage: "macwindow")
                .font(.headline)
            
            Toggle("High Contrast Floating Panel", isOn: $settings.highContrastFloatingPanel)
                .onChange(of: settings.highContrastFloatingPanel) { _, newValue in
                    if newValue {
                        settings.floatingWindowOpacity = max(settings.floatingWindowOpacity, 0.65)
                    }
                }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Floating Window Opacity")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", settings.floatingWindowOpacity * 100))
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                
                Slider(value: $settings.floatingWindowOpacity, in: (settings.highContrastFloatingPanel ? 0.65 : 0.35)...1.0)
            }
            
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
