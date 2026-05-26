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
                    Text("InterviewCopilotMac")
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

                Text("AI features send only the detected question, recent transcript, and top relevant CV/JD snippets to the active provider. Local Ollama mode keeps prompts on this Mac. Cloud API keys are stored in Keychain.")
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
                        placeholder: "Paste resume text here. Plain text, .txt, and .md content work best in this MVP.",
                        text: $cvText,
                        action: { appState.saveDocument(type: .cv, title: "CV / Resume", content: cvText) }
                    )

                    documentEditor(
                        title: "Job Description",
                        placeholder: "Paste the target role's job description here.",
                        text: $jdText,
                        action: { appState.saveDocument(type: .jobDescription, title: "Job Description", content: jdText) }
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional DeepSeek API Key")
                            .font(.headline)
                        SecureField("Optional for cloud mode; local Ollama does not need a key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save Key") {
                                appState.saveAPIKey(apiKey)
                                apiKey = ""
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Test DeepSeek") {
                                appState.testDeepSeekConnection()
                            }
                            .disabled(!appState.hasAPIKey || appState.isTestingConnection)
                            if appState.isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
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
                        PrimaryButton(
                            title: appState.onboardingComplete ? "Enter App" : "Add CV and JD",
                            systemImage: "arrow.right",
                            isDisabled: !appState.onboardingComplete
                        ) {
                            appState.selectSection(.home)
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
                Button("Save \(title)") { action() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
