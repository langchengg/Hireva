import SwiftUI

struct ProviderDiagnosticsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Provider Diagnostics")
                    .font(.largeTitle.weight(.bold))
                Text("Inspect active AI routing, local/cloud mode, connection state, and installed Ollama models.")
                    .foregroundStyle(.secondary)

                providerSummary("Active Realtime Provider", provider: appState.activeRealtimeProvider)
                providerSummary("Active Recap Provider", provider: appState.activeRecapProvider)

                if appState.activeRealtimeProvider?.kind == .ollamaLocal || appState.activeRecapProvider?.kind == .ollamaLocal {
                    ollamaModelsSection
                }

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
                if let provider {
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
