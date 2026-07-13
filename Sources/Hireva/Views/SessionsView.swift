import SwiftUI

struct SessionsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedSessionID) {
                ForEach(appState.sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .lineLimit(1)
                        Text(session.startedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Sessions")
            .onChange(of: appState.selectedSessionID) { _, newValue in
                if let newValue {
                    appState.loadSessionDetails(sessionID: newValue)
                }
            }
        } detail: {
            if let sessionID = appState.selectedSessionID,
               let session = appState.sessions.first(where: { $0.id == sessionID }) {
                SessionDetailView(appState: appState, session: session)
            } else if appState.sessions.isEmpty {
                EmptyStateView(title: "No sessions yet", message: "Create one from Live Interview or Mock Mode.", systemImage: "clock")
            } else {
                EmptyStateView(title: "Select a session", message: "Review transcript, suggestions, and recap.", systemImage: "sidebar.left")
            }
        }
    }
}
