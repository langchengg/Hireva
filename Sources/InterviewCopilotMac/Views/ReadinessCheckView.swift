import SwiftUI

struct ReadinessCheckView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                resultCard
                checklist
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("Readiness Check")
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Readiness Check")
                .font(.largeTitle.weight(.bold))
            Text("Confirm the interview workflow is ready before you join the call.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var resultCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: appState.readinessOutcomeTitle == "Ready for interview" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(appState.readinessOutcomeTitle == "Ready for interview" ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.readinessOutcomeTitle)
                    .font(.title2.weight(.bold))
                Text(appState.readinessOutcomeTitle == "Ready for interview" ? "Start a short test and keep the floating panel visible." : "Fix the failed items before the live interview.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if appState.coreInterviewReadinessPassed {
                    appState.selectSection(.home)
                } else {
                    focusFirstFailure()
                }
            } label: {
                Label(appState.coreInterviewReadinessPassed ? "Open Interview" : "Fix First Issue", systemImage: appState.coreInterviewReadinessPassed ? "house" : "arrow.right.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(appState.readinessCheckItems) { item in
                readinessRow(item)
            }
        }
    }

    private func readinessRow(_ item: ReadinessCheckItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon(item.status))
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusTint(item.status))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if item.needsAction, let title = item.actionTitle, let action = item.action {
                Button(title) {
                    perform(action)
                }
                .buttonStyle(.bordered)
                .tint(item.status == .failed ? .accentColor : .secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func focusFirstFailure() {
        guard let action = appState.readinessCheckItems.first(where: { $0.status == .failed })?.action else {
            appState.selectSection(.home)
            return
        }
        perform(action)
    }

    private func perform(_ action: ReadinessAction) {
        switch action {
        case .openSettings:
            appState.selectSection(.settings)
        case .openDocuments:
            appState.selectSection(.documents)
        case .testDeepSeek:
            appState.testDeepSeekConnection()
        case .rebuildRAG:
            appState.rebuildCleanRAGIndex()
        case .openPermissions:
            appState.openSystemPrivacySettings()
            appState.selectSection(.diagnostics)
        case .showFloatingPanel:
            appState.showFloatingAssistant()
        case .openHome:
            appState.selectSection(.home)
        }
    }

    private func statusIcon(_ status: ReadinessCheckStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func statusTint(_ status: ReadinessCheckStatus) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}
