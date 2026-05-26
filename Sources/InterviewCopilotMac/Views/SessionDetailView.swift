import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var appState: AppState
    var session: InterviewSession

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
                    Button(role: .destructive) {
                        appState.deleteSession(session)
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recap")
                            .font(.headline)
                        Spacer()
                        Button {
                            appState.generateRecap(for: session)
                        } label: {
                            Label("Generate Recap", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isGeneratingRecap)
                        Button {
                            appState.exportSelectedRecap()
                        } label: {
                            Label("Export Markdown", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.selectedSessionRecap == nil)
                    }
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
                            SuggestionCardView(card: card)
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
    }
}
