import SwiftUI

struct ProviderDiagnosticsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ollamaDiag = OllamaDiagnostics.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Provider Diagnostics")
                    .font(.largeTitle.weight(.bold))
                
                RAGDiagnosticsView(appState: appState)
                
                Divider()
                
                Text("Inspect active AI routing, local/cloud mode, connection state, and installed Ollama models.")
                    .foregroundStyle(.secondary)

                providerSummary("Active Realtime Provider", provider: appState.activeRealtimeProvider)
                providerSummary("Active Recap Provider", provider: appState.activeRecapProvider)

                if appState.activeRealtimeProvider?.kind == .ollamaLocal || appState.activeRecapProvider?.kind == .ollamaLocal {
                    ollamaDiagnosticsCard
                    ollamaModelsSection
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("AI Router Diagnostics", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    row("Last Switched At", appState.lastProviderSwitchTimestamp.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "Never")
                    row("Last Switch Error", appState.lastProviderSwitchError ?? "None")
                    row("Q Detect Provider", appState.lastQuestionDetectionProvider ?? "None")
                    row("Q Detect Model", appState.lastQuestionDetectionModel ?? "None")
                    row("Suggestion Gen Provider", appState.lastSuggestionGenerationProvider ?? "None")
                    row("Suggestion Gen Model", appState.lastSuggestionGenerationModel ?? "None")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Label("Suggestion Provenance", systemImage: "signature")
                        .font(.headline)
                    row("Say First Source", appState.finalVisibleSource ?? "None")
                    row("Soft Fallback Used", appState.softFallbackUsed ? "Yes" : "No")
                    if let softLat = appState.softFallbackLatencyMS {
                        row("Soft Fallback Latency", "\(softLat) ms")
                    }
                    if let firstTok = appState.deepseekFirstTokenMS {
                        row("DeepSeek First Token", "\(firstTok) ms")
                    }
                    if let firstVis = appState.deepseekFirstVisibleMS {
                        row("DeepSeek First Visible", "\(firstVis) ms")
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Label("Last AI Call", systemImage: "timer")
                        .font(.headline)
                    row("Provider", appState.diagnostics.lastProviderName ?? "None")
                    row("Model", appState.diagnostics.lastProviderModel ?? "None")
                    row("Latency", appState.diagnostics.lastAPILatencyMS.map { "\($0) ms" } ?? "None")
                    row("Last Error", appState.diagnostics.lastError ?? "None")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))


            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private func providerSummary(_ title: String, provider: LLMProviderConfiguration?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "brain")
                    .font(.headline)
                Spacer()
                if title == "Active Realtime Provider" {
                    LLMProviderQuickSwitcherView(appState: appState, isCompact: false)
                } else if let provider {
                    StatusPill(title: provider.kind.isLocal ? "Local" : "Cloud", systemImage: provider.kind.isLocal ? "desktopcomputer" : "cloud", tint: provider.kind.isLocal ? .green : .blue)
                }
            }
            if let provider {
                row("Name", provider.name)
                row("Kind", provider.kind.displayName)
                row("Base URL", provider.baseURL)
                row("Model", provider.model)
                row("Connection", appState.providerConnectionResults[provider.id] ?? "Not tested")
                HStack {
                    Button("Test Connection") {
                        appState.testProviderConnection(provider)
                    }
                    .buttonStyle(.borderedProminent)
                    if provider.kind == .ollamaLocal {
                        Button("Refresh Ollama Models") {
                            appState.refreshOllamaModels(for: provider)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Text("No provider selected.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ollamaModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Installed Ollama Models", systemImage: "list.bullet.rectangle")
                .font(.headline)
            if appState.ollamaModels.isEmpty {
                Text("No models loaded in diagnostics yet. Refresh an Ollama provider to query /api/tags.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.ollamaModels) { model in
                    HStack {
                        Text(model.name)
                            .textSelection(.enabled)
                        Spacer()
                        if let size = model.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ollamaDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Ollama Diagnostics", systemImage: "server.rack")
                .font(.headline)
            row("Reachable", ollamaDiag.reachable ? "Yes" : "No")
            row("Model Installed", ollamaDiag.modelInstalled ? "Yes" : "No")
            row("Active Provider", ollamaDiag.activeProviderName ?? "None")
            row("Model", ollamaDiag.activeModel ?? "None")
            row("Endpoint", ollamaDiag.lastEndpoint ?? "None")
            row("Timeout", ollamaDiag.lastTimeout.map { String(format: "%.0f s", $0) } ?? "None")
            row("Latency", ollamaDiag.lastLatencyMS.map { "\($0) ms" } ?? "None")
            row("Last HTTP Status", ollamaDiag.lastHTTPStatus.map { String($0) } ?? "None")
            row("JSON Parse Success", ollamaDiag.jsonParseSuccess ? "Yes" : "No")
            if let failReason = ollamaDiag.jsonParseFailureReason {
                row("JSON Parse Error", failReason)
            }
            row("Fallback Card Used", ollamaDiag.fallbackCardUsed ? "Yes" : "No")
            row("Last Raw Error", ollamaDiag.lastRawError ?? "None")
            
            if let preview = ollamaDiag.lastRawResponsePreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Raw Response Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
