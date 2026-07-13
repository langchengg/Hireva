import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @State private var cvText = ""
    @State private var jdText = ""
    @State private var apiKey = ""

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
                    checklistRow("CV added", complete: appState.hasCV)
                    checklistRow("JD added", complete: appState.hasJD)
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
                    documentEditor(
                        title: "CV / Resume",
                        type: .cv,
                        placeholder: "Paste resume text here. Plain text, .txt, and .md content work best in this MVP.",
                        text: $cvText,
                        action: { appState.saveDocument(type: .cv, title: "CV / Resume", content: cvText) }
                    )

                    documentEditor(
                        title: "Job Description",
                        type: .jobDescription,
                        placeholder: "Paste the target role's job description here.",
                        text: $jdText,
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
        .onAppear {
            if let cv = appState.documents.first(where: { $0.type == .cv }) {
                cvText = cv.content
            }
            if let jd = appState.documents.first(where: { $0.type == .jobDescription }) {
                jdText = jd.content
            }
        }
    }

    private func checklistRow(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(complete ? .green : .secondary)
            .font(.callout.weight(.medium))
    }

    private func documentEditor(
        title: String,
        type: DocumentType,
        placeholder: String,
        text: Binding<String>,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(text.wrappedValue.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? "Paste at least 80 characters to complete this step." : "Ready to save.")
                    .font(.caption)
                    .foregroundStyle(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? Color.secondary : Color.green)
                Spacer()
                ActionButton(
                    appState: appState,
                    actionID: ActionID.saveDocument(type),
                    title: "Save \(title)",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "square.and.arrow.down",
                    isProminent: true,
                    disabled: text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 80,
                    action: action
                )
            }
            InlineStatusBanner(appState.latestActionFeedback(for: ActionID.saveDocument(type)))
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
