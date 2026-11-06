import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var documentsState: DocumentsState
    @State private var cvText = ""
    @State private var jdText = ""
    @State private var apiKey = ""

    init(appState: AppState) {
        self.appState = appState
        self.documentsState = appState.documentsState
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hireva")
                        .font(.largeTitle.weight(.bold))
                    Text("Ground real-time interview notes in your CV and the target job before any AI suggestion is generated.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    checklistRow("CV added", complete: documentsState.hasCV)
                    checklistRow("JD added", complete: documentsState.hasJD)
                    checklistRow("Cloud API key added (optional)", complete: appState.hasAPIKey)
                }
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Text("AI features send only the detected question, recent transcript, and top relevant CV/JD snippets to configured API providers. Cloud API keys are securely saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
            }
            .padding(36)
            .frame(width: 390)
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingDocumentEditor(documents: documentsState,
                        title: "CV / Resume",
                        type: .cv,
                        placeholder: "Paste resume text here. Plain text, .txt, and .md content work best in this MVP.",
                        text: $cvText,
                        isLoading: appState.isActionLoading(ActionID.saveDocument(.cv)),
                        feedback: appState.latestActionFeedback(for: ActionID.saveDocument(.cv)),
                        action: { appState.saveDocument(type: .cv, title: "CV / Resume", content: cvText) }
                    )

                    OnboardingDocumentEditor(documents: documentsState,
                        title: "Job Description",
                        type: .jobDescription,
                        placeholder: "Paste the target role's job description here.",
                        text: $jdText,
                        isLoading: appState.isActionLoading(ActionID.saveDocument(.jobDescription)),
                        feedback: appState.latestActionFeedback(for: ActionID.saveDocument(.jobDescription)),
                        action: { appState.saveDocument(type: .jobDescription, title: "Job Description", content: jdText) }
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional DeepSeek API Key")
                            .font(.headline)
                        SecureField("DeepSeek API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            ActionButton(
                                appState: appState,
                                actionID: ActionID.providerSaveKey,
                                title: "Save Key",
                                loadingTitle: "Saving securely...",
                                successTitle: "Saved",
                                systemImage: "key.fill",
                                disabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ) {
                                appState.saveAPIKey(apiKey)
                                apiKey = ""
                            }
                            ActionButton(
                                appState: appState,
                                actionID: ActionID.testDeepSeek,
                                title: "Test DeepSeek",
                                loadingTitle: "Testing...",
                                successTitle: "Connected",
                                systemImage: "network",
                                disabled: !appState.hasAPIKey || appState.isTestingConnection
                            ) {
                                appState.testDeepSeekConnection()
                            }
                            if appState.isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        InlineStatusBanner(appState.latestActionFeedback(matching: [ActionID.providerSaveKey, ActionID.testDeepSeek]))
                        if let result = appState.connectionResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Spacer()
                        ActionButton(
                            appState: appState,
                            actionID: ActionID.runReadiness,
                            title: appState.onboardingComplete ? "Enter App" : "Add CV and JD",
                            loadingTitle: "Opening...",
                            successTitle: "Home opened",
                            systemImage: "arrow.right",
                            isProminent: true,
                            controlSize: .large,
                            disabled: !appState.onboardingComplete
                        ) {
                            appState.beginAction(ActionID.runReadiness, title: "Opening app", message: "Taking you to Home / Interview.")
                            appState.selectSection(.home)
                            appState.completeAction(ActionID.runReadiness, title: "Home opened", message: "Start with the readiness check or Start Interview.")
                        }
                    }
                }
                .padding(28)
            }
        }
    }

    private func checklistRow(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(complete ? .green : .secondary)
            .font(.callout.weight(.medium))
    }

}
