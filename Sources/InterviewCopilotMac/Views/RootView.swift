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
            .navigationTitle("Interview Copilot")
        } detail: {
            detailView
        }
        .alert("InterviewCopilotMac", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
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
        case .settings:
            SettingsView(appState: appState)
        case .diagnostics:
            DiagnosticsView(appState: appState)
        }
    }
}
