import SwiftUI

struct HomeView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Interview Copilot")
                    .font(.largeTitle.weight(.bold))
                Text("A native macOS assistant for candidate-owned context, real-time notes, concise suggestions, and post-interview practice.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    StatusPill(title: appState.hasCV ? "CV loaded" : "CV missing", systemImage: "doc.text", tint: appState.hasCV ? .green : .orange)
                    StatusPill(title: appState.hasJD ? "JD loaded" : "JD missing", systemImage: "briefcase", tint: appState.hasJD ? .green : .orange)
                    StatusPill(title: appState.activeRealtimeProviderBadge, systemImage: "brain", tint: appState.activeRealtimeProvider?.kind == .ollamaLocal ? .green : .blue)
                }

                HStack(spacing: 14) {
                    actionCard("Live Interview", icon: "waveform.and.mic", message: appState.liveBlockedReason ?? "Start live transcription and open the floating assistant.", actionTitle: "Open") {
                        appState.selectSection(.live)
                    }
                    actionCard("Documents", icon: "doc.text.magnifyingglass", message: "Update local CV and target JD context.", actionTitle: "Edit") {
                        appState.selectSection(.documents)
                    }
                    actionCard("Sessions", icon: "clock.arrow.circlepath", message: "Review transcripts, suggestions, and recaps.", actionTitle: "View") {
                        appState.selectSection(.sessions)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Responsible Use Notice", systemImage: "checkmark.shield")
                        .font(.headline)
                    Text("This app does not implement stealth, anti-detection, or screen-share bypass behavior. You are responsible for following interview rules and getting consent where required.")
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(28)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
    }

    private func actionCard(_ title: String, icon: String, message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.blue)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
