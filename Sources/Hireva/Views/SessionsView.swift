import SwiftUI

struct SessionsView: View {
    let appState: AppState
    @ObservedObject private var history: HistoryState

    init(appState: AppState) {
        self.appState = appState
        history = appState.historyState
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { history.selectedSessionID },
                set: { sessionID in
                    if let sessionID {
                        appState.loadSessionDetails(sessionID: sessionID)
                    } else {
                        history.clearSelection()
                    }
                }
            )) {
                ForEach(history.sessions) { session in
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

        } detail: {
            if let sessionID = history.selectedSessionID,
               let session = history.sessions.first(where: { $0.id == sessionID }) {
                SessionDetailView(appState: appState, session: session)
            } else if history.sessions.isEmpty {
                EmptyStateView(title: "No sessions yet", message: "Create one from Live Interview or Mock Mode.", systemImage: "clock")
            } else {
                EmptyStateView(title: "Select a session", message: "Review transcript, suggestions, and recap.", systemImage: "sidebar.left")
            }
        }
    }
}
