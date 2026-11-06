import SwiftUI

struct SessionDetailView: View {
    let appState: AppState
    @ObservedObject private var history: HistoryState
    var session: InterviewSession
    @State private var confirmDeleteSession = false

    init(appState: AppState, session: InterviewSession) {
        self.appState = appState
        self.session = session
        history = appState.historyState
    }

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

                SessionHistoryEditor(appState: appState, session: session)

                HStack {
                    Button("Export JSON") { appState.exportSessionJSON(session) }
                    if (try? PracticeRepository(database: appState.database).load(sessionID: session.id)) != nil {
                        Button("Open Practice / Resume") { appState.practiceController.restore(sessionID: session.id); appState.selectSection(.practice) }
                    }
                }
                HistoryActionFeedbackView(appState: appState)

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
                            disabled: history.isGeneratingRecap
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
                            disabled: history.selectedSessionRecap == nil
                        ) {
                            appState.exportSelectedRecap()
                        }
                    }
                    HistoryActionFeedbackView(appState: appState)
                    if history.isGeneratingRecap {
                        ProgressView("Generating recap...")
                    }
                    if let recap = history.selectedSessionRecap {
                        let revision = (try? appState.sessionRepository.session(id: session.id))?.contentRevision ?? 0
                        Text("Recap input v\(recap.contentRevision ?? 0)\((recap.contentRevision ?? 0) < revision ? " · Based on old inputs — explicitly regenerate / 基于旧版本，请重评" : " · Current input")")
                            .foregroundStyle((recap.contentRevision ?? 0) < revision ? .orange : .secondary)
                    }
                    Text(history.selectedSessionRecap?.markdown ?? "No recap generated yet.")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Suggestions · frozen original inputs")
                        .font(.headline)
                    if history.selectedSessionSuggestions.isEmpty {
                        Text("No suggestion cards saved for this session.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(history.selectedSessionSuggestions) { card in
                            SuggestionCardView(card: card, retrievedChunks: history.historicalSuggestionChunks[card.id] ?? [], isSourcesExpandedInitially: true)
                                .frame(minHeight: 240)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcript")
                        .font(.headline)
                    ForEach(history.selectedSessionTranscript) { segment in
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
}

/// Action feedback still belongs to the app policy surface. Keep that observation
/// scoped to the banner; history records observe their own owner directly.
private struct HistoryActionFeedbackView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        InlineStatusBanner(appState.latestActionFeedback(matching: [
            ActionID.sessionDelete,
            ActionID.sessionRecap,
            ActionID.sessionExport
        ]))
    }
}
