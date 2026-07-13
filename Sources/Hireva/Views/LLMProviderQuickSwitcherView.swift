import SwiftUI
import AppKit

struct LLMProviderQuickSwitcherView: View {
    @ObservedObject var appState: AppState
    var isCompact: Bool = false

    @State private var isShowingPopover = false
    @State private var manualModelName: String = ""
    
    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
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
        .onChange(of: appState.activeRealtimeProvider) { _, newProvider in
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
        .blue
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

            mainSwitcherView
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
                        ActionButton(
                            appState: appState,
                            actionID: ActionID.provider(ActionID.providerTest, active.id),
                            title: "Test",
                            loadingTitle: "Testing...",
                            successTitle: "Connected",
                            systemImage: "network",
                            controlSize: .small,
                            disabled: appState.isTestingConnection
                        ) {
                            appState.testProviderConnection(active)
                        }
                    }
                    InlineStatusBanner(quickSwitcherFeedback)
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
                    ForEach(visibleProviderConfigurations) { provider in
                        let isActive = provider.id == appState.activeRealtimeProvider?.id
                        Button {
                            selectProvider(provider)
                        } label: {
                            HStack {
                                Image(systemName: "cloud")
                                    .foregroundStyle(.blue)
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
                        .disabled(appState.isActionLoading(ActionID.providerSwitch))
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

                    if active.kind == .deepSeek {
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
                                    .disabled(appState.isActionLoading(ActionID.providerSwitch))
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
                                    .disabled(appState.isActionLoading(ActionID.providerSwitch))
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
                            
                            ActionButton(
                                appState: appState,
                                actionID: ActionID.providerSwitch,
                                title: "Apply",
                                loadingTitle: "Applying...",
                                successTitle: "Applied",
                                systemImage: "checkmark",
                                controlSize: .small,
                                disabled: manualModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ) {
                                commitManualModel()
                            }
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

    private func selectProvider(_ provider: LLMProviderConfiguration) {
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

    private var visibleProviderConfigurations: [LLMProviderConfiguration] {
        appState.providerConfigurations.filter { $0.kind != .ollamaLocal }
    }

    private var quickSwitcherFeedback: ActionFeedback? {
        guard let active = appState.activeRealtimeProvider else {
            return appState.latestActionFeedback(for: ActionID.providerSwitch)
        }
        return appState.latestActionFeedback(matching: [
            ActionID.providerSwitch,
            ActionID.provider(ActionID.providerTest, active.id)
        ])
    }

}
