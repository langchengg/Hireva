import SwiftUI

struct RootView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { appState.selectedSection },
                set: { appState.selectSection($0 ?? .home) }
            )) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Hireva")
        } detail: {
            detailView
        }
        .overlay(alignment: .topTrailing) {
            ToastBanner(feedbacks: appState.activeActionFeedbacks)
        }
        .overlay(alignment: .top) {
            if let warning = appState.staleBundleWarning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: 720)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.top, 12)
            }
        }
        .alert("Hireva", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onAppear {
            appState.runLaunchLiveSystemAudioDiagnosticIfRequested()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSection {
        case .home:
            HomeView(appState: appState)
        case .documents:
            DocumentsView(appState: appState)
        case .sessions:
            SessionsView(appState: appState)
        case .readinessCheck:
            ReadinessCheckView(appState: appState)
        case .localModels:
            LocalModelsSetupView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        case .diagnostics:
            DiagnosticsView(appState: appState)
        }
    }
}
