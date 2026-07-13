import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var appState: AppState
    var session: InterviewSession
    @State private var confirmDeleteSession = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.title)
                            .font(.largeTitle.weight(.bold))
                        Text("\(session.mode.displayName) • \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ActionButton(
                        appState: appState,
                        actionID: ActionID.sessionDelete,
                        title: "Delete Session",
                        loadingTitle: "Deleting...",
                        successTitle: "Deleted",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        appState.infoAction(ActionID.sessionDelete, title: "Confirm session delete", message: "Confirm before removing this session.", autoDismissAfter: nil)
                        confirmDeleteSession = true
                    }
                }

                InlineStatusBanner(sessionFeedback)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recap")
                            .font(.headline)
                        Spacer()
                        ActionButton(
                            appState: appState,
                            actionID: ActionID.sessionRecap,
                            title: "Generate Recap",
                            loadingTitle: "Generating...",
                            successTitle: "Recap ready",
                            systemImage: "wand.and.stars",
                            isProminent: true,
                            disabled: appState.isGeneratingRecap
                        ) {
                            appState.generateRecap(for: session)
                        }
                        ActionButton(
                            appState: appState,
                            actionID: ActionID.sessionExport,
                            title: "Export Markdown",
                            loadingTitle: "Exporting...",
                            successTitle: "Exported",
                            systemImage: "square.and.arrow.up",
                            disabled: appState.selectedSessionRecap == nil
                        ) {
                            appState.exportSelectedRecap()
                        }
                    }
                    InlineStatusBanner(sessionFeedback)
                    if appState.isGeneratingRecap {
                        ProgressView("Generating recap...")
                    }
                    Text(appState.selectedSessionRecap?.markdown ?? "No recap generated yet.")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Suggestions")
                        .font(.headline)
                    if appState.selectedSessionSuggestions.isEmpty {
                        Text("No suggestion cards saved for this session.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.selectedSessionSuggestions) { card in
                            SuggestionCardView(card: card, retrievedChunks: appState.historicalSuggestionChunks[card.id] ?? [], isSourcesExpandedInitially: true)
                                .frame(minHeight: 240)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcript")
                        .font(.headline)
                    ForEach(appState.selectedSessionTranscript) { segment in
                        Text("\(segment.speaker.displayName): \(segment.text)")
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(28)
        }
        .onAppear {
            appState.loadSessionDetails(sessionID: session.id)
        }
        .confirmationDialog("Delete session?", isPresented: $confirmDeleteSession) {
            Button("Delete Session", role: .destructive) {
                appState.deleteSession(session)
            }
            Button("Cancel", role: .cancel) {
                appState.infoAction(ActionID.sessionDelete, title: "Delete cancelled", message: "\(session.title) was left unchanged.")
            }
        } message: {
            Text("This removes the transcript, suggestions, and recap for this interview session.")
        }
    }

    private var sessionFeedback: ActionFeedback? {
        appState.latestActionFeedback(matching: [
            ActionID.sessionDelete,
            ActionID.sessionRecap,
            ActionID.sessionExport
        ])
    }
}
