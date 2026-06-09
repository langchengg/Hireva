import SwiftUI

struct ReadinessCheckView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                resultCard
                BuildIdentityCardView(identity: appState.buildIdentity, compact: true)
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
        VStack(alignment: .leading, spacing: 12) {
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
                ActionButton(
                    appState: appState,
                    actionID: ActionID.runReadiness,
                    title: appState.coreInterviewReadinessPassed ? "Open Interview" : "Fix First Issue",
                    loadingTitle: "Checking...",
                    successTitle: appState.coreInterviewReadinessPassed ? "Interview open" : "Issue opened",
                    systemImage: appState.coreInterviewReadinessPassed ? "house" : "arrow.right.circle",
                    isProminent: true,
                    controlSize: .large
                ) {
                    appState.beginAction(ActionID.runReadiness, title: "Checking readiness", message: "Reviewing the pre-interview checklist...")
                    if appState.coreInterviewReadinessPassed {
                        appState.selectSection(.home)
                        appState.completeAction(ActionID.runReadiness, title: "Interview screen opened", message: "Start Interview is ready.")
                    } else {
                        focusFirstFailure()
                        appState.completeAction(ActionID.runReadiness, title: "First issue opened", message: "Complete the highlighted setup step, then rerun the checklist.")
                    }
                }
            }

            InlineStatusBanner(readinessFeedback)
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
                ActionButton(
                    appState: appState,
                    actionID: actionID(for: action),
                    title: title,
                    loadingTitle: "Working...",
                    successTitle: "Done",
                    systemImage: "arrow.right.circle"
                ) {
                    perform(action)
                }
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
        let id = actionID(for: action)
        switch action {
        case .openSettings:
            appState.beginAction(id, title: "Opening settings", message: "Go to AI Provider and Audio cards to fix setup.")
            appState.selectSection(.settings)
            appState.completeAction(id, title: "Settings opened", message: "Fix the missing setting, then rerun readiness.")
        case .openDocuments:
            appState.beginAction(id, title: "Opening documents", message: "Add CV and job description context.")
            appState.selectSection(.documents)
            appState.completeAction(id, title: "Documents opened", message: "Save documents and rebuild the clean index.")
        case .testDeepSeek:
            appState.testDeepSeekConnection()
        case .rebuildRAG:
            appState.rebuildCleanRAGIndex()
        case .openPermissions:
            appState.beginAction(id, title: "Opening permissions", message: "Opening macOS privacy settings.")
            appState.openSystemPrivacySettings()
            appState.selectSection(.diagnostics)
            appState.completeAction(id, title: "Permissions opened", message: "Grant access in macOS, then return and refresh.")
        case .showFloatingPanel:
            appState.showFloatingAssistant()
        case .openHome:
            appState.beginAction(id, title: "Opening interview", message: "Returning to the main interview workflow.")
            appState.selectSection(.home)
            appState.completeAction(id, title: "Interview opened", message: "Start Interview is the primary action.")
        }
    }

    private func actionID(for action: ReadinessAction) -> String {
        switch action {
        case .testDeepSeek:
            return ActionID.testDeepSeek
        case .rebuildRAG:
            return ActionID.rebuildCleanRAG
        case .showFloatingPanel:
            return ActionID.showFloatingPanel
        default:
            return ActionID.readiness(action)
        }
    }

    private var readinessFeedback: ActionFeedback? {
        var ids = [ActionID.runReadiness, ActionID.testDeepSeek, ActionID.rebuildCleanRAG, ActionID.showFloatingPanel]
        ids.append(contentsOf: ReadinessAction.allCases.map(ActionID.readiness))
        return appState.latestActionFeedback(matching: ids)
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
