import SwiftUI
import AppKit

struct LLMProviderQuickSwitcherView: View {
    @ObservedObject var appState: AppState
    var isCompact: Bool = false

    @State private var isShowingPopover = false
    @State private var manualModelName: String = ""
    
    // Cloud warning local state
    @State private var showingCloudWarning = false
    @State private var warningTargetProvider: LLMProviderConfiguration? = nil
    @State private var warningTargetModel: String? = nil
    @State private var dontShowWarningCheckbox = false

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.activeRealtimeProvider?.kind == .ollamaLocal ? "desktopcomputer" : "cloud")
                    .imageScale(.small)
                Text(isCompact ? (appState.activeRealtimeProvider?.name ?? "Realtime") : appState.activeRealtimeProviderBadge)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tintColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .frame(minWidth: isCompact ? 100 : 160, maxWidth: 260, alignment: .leading)
            .background(tintColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("LLM Provider Switcher")
        .onAppear {
            if let active = appState.activeRealtimeProvider {
                manualModelName = active.model
            }
        }
        .onChange(of: appState.activeRealtimeProvider) { newProvider in
            if let active = newProvider {
                manualModelName = active.model
            }
        }
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 320)
                .padding()
        }
    }

    private var tintColor: Color {
        appState.activeRealtimeProvider?.kind == .ollamaLocal ? .green : .blue
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("AI Provider Switcher")
                    .font(.headline)
                Spacer()
                Button {
                    appState.selectedSection = .settings
                    isShowingPopover = false
                } label: {
                    Image(systemName: "gearshape")
                        .help("Configure Providers in Settings")
                }
                .buttonStyle(.borderless)
            }
            
            Divider()

            if showingCloudWarning {
                cloudWarningView
            } else {
                mainSwitcherView
            }
        }
    }

    private var mainSwitcherView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Active status & connection state
            if let active = appState.activeRealtimeProvider {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Currently Active:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(active.name)
                                .font(.subheadline).bold()
                            Text("Model: \(active.model)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Test") {
                                appState.testProviderConnection(active)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    if let result = appState.providerConnectionResults[active.id] {
                        Text(result)
                            .font(.system(size: 10))
                            .foregroundStyle(result.contains("Found") || result.contains("success") ? .green : .red)
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            // Providers Grid/List
            Text("Select Provider:")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(appState.providerConfigurations) { provider in
                        let isActive = provider.id == appState.activeRealtimeProvider?.id
                        Button {
                            selectProvider(provider)
                        } label: {
                            HStack {
                                Image(systemName: provider.kind == .ollamaLocal ? "desktopcomputer" : "cloud")
                                    .foregroundStyle(provider.kind == .ollamaLocal ? .green : .blue)
                                Text(provider.name)
                                    .font(.subheadline)
                                Spacer()
                                if isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(isActive ? Color.blue.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)

            Divider()

            // Model customization
            if let active = appState.activeRealtimeProvider {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Model:")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)

                    if active.kind == .ollamaLocal {
                        // Ollama dynamic models
                        HStack {
                            Text("Local Models:")
                                .font(.caption)
                            Spacer()
                            Button {
                                appState.refreshOllamaModels(for: active)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .disabled(appState.isTestingConnection)
                        }

                        if appState.ollamaModels.isEmpty {
                            Text("No local models found. Make sure Ollama is running.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(appState.ollamaModels) { info in
                                        let isCurrent = info.name == active.model
                                        Button(info.name) {
                                            switchModel(info.name)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(isCurrent ? .blue : .secondary)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    } else if active.kind == .deepSeek {
                        // Recommended DeepSeek models
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(["deepseek-v4-flash", "deepseek-chat", "deepseek-coder", "deepseek-reasoner"], id: \.self) { dsModel in
                                    let isCurrent = dsModel == active.model
                                    Button(dsModel) {
                                        switchModel(dsModel)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(isCurrent ? .blue : .secondary)
                                    .controlSize(.small)
                                }
                            }
                        }
                    } else if active.kind == .openAICompatible {
                        // Recommended OpenAI Compatible models
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(["gpt-4o", "gpt-4o-mini", "claude-3-5-sonnet-latest"], id: \.self) { recModel in
                                    let isCurrent = recModel == active.model
                                    Button(recModel) {
                                        switchModel(recModel)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(isCurrent ? .blue : .secondary)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    // Editable Manual Model
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Model Name:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Enter model name", text: $manualModelName, onCommit: {
                                commitManualModel()
                            })
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            
                            Button("Apply") {
                                commitManualModel()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(manualModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var cloudWarningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("Cloud Privacy Warning")
                    .font(.headline)
            }

            Text("You are switching from a local LLM (Ollama) to a cloud-based provider (\(warningTargetProvider?.name ?? "Cloud")).")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text("This means your live interview question transcripts, CV, and job description context will be sent to external servers. Proceed only if you have permission to do so.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't show this warning again", isOn: $dontShowWarningCheckbox)
                .font(.caption)
                .padding(.top, 4)

            HStack {
                Button("Cancel") {
                    showingCloudWarning = false
                    warningTargetProvider = nil
                    warningTargetModel = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("I Understand, Switch") {
                    confirmCloudSwitch()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.top, 8)
        }
    }

    private func selectProvider(_ provider: LLMProviderConfiguration) {
        let isCurrentLocal = appState.activeRealtimeProvider?.kind == .ollamaLocal
        let isTargetCloud = provider.kind != .ollamaLocal

        if isCurrentLocal && isTargetCloud {
            let skipWarning = appState.settings.dontShowCloudWarningAgain || appState.cloudWarningAcceptedThisSession
            if !skipWarning {
                warningTargetProvider = provider
                warningTargetModel = provider.model
                dontShowWarningCheckbox = appState.settings.dontShowCloudWarningAgain
                showingCloudWarning = true
                return
            }
        }

        // Perform normal switch
        appState.updateActiveRealtimeProvider(provider: provider, model: nil)
    }

    private func switchModel(_ model: String) {
        guard let active = appState.activeRealtimeProvider else { return }
        
        appState.updateActiveRealtimeProvider(provider: active, model: model)
    }

    private func commitManualModel() {
        let cleaned = manualModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let active = appState.activeRealtimeProvider else { return }
        appState.updateActiveRealtimeProvider(provider: active, model: cleaned)
    }

    private func confirmCloudSwitch() {
        guard let provider = warningTargetProvider else { return }
        
        // Save preferences if checked
        if dontShowWarningCheckbox {
            var updatedSettings = appState.settings
            updatedSettings.dontShowCloudWarningAgain = true
            appState.saveSettings(updatedSettings)
        }
        
        // Set session approval
        appState.cloudWarningAcceptedThisSession = true
        
        // Perform the switch
        appState.updateActiveRealtimeProvider(provider: provider, model: warningTargetModel)
        
        // Reset warning states
        showingCloudWarning = false
        warningTargetProvider = nil
        warningTargetModel = nil
    }
}
