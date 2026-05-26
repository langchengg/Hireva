import SwiftUI

struct LiveInterviewView: View {
    @ObservedObject var appState: AppState
    @State private var mockQuestion = ""
    @State private var practiceExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let reason = appState.liveBlockedReason {
                EmptyStateView(title: "Live Interview Locked", message: reason, systemImage: "lock")
            } else {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            statusStrip
                            permissionRecovery
                            floatingAssistantStatus
                            autoDetectionStatus
                            TranscriptView(segments: appState.transcriptSegments)
                            practiceTestingSection
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 560)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            detectedQuestionPanel
                            SuggestionCardView(card: appState.currentSuggestion)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 390, maxWidth: 520)
                }
            }
        }
        .navigationTitle("Live Interview")
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            PrimaryButton(
                title: "Start Listening",
                systemImage: "mic.fill",
                isDisabled: !appState.liveState.canStartListening || appState.liveBlockedReason != nil
            ) {
                appState.startListening(mode: .microphone)
            }

            Button {
                appState.stopListening()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.liveState.canStop)

            Button {
                appState.showFloatingAssistant()
            } label: {
                Label("Show Floating Assistant", systemImage: "macwindow.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Toggle(isOn: automaticDetectionBinding) {
                Label("Auto Detection", systemImage: "scope")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Automatically detect complete interviewer questions and generate suggestions.")

            Button {
                appState.manualAnswerNow()
            } label: {
                Label("Answer Now", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.liveState.canAnswerNow || appState.liveBlockedReason != nil)
            .help("Fallback: generate a suggestion from the recent transcript.")

            Button {
                appState.clearLiveSession()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()
            Button {
                appState.selectSection(.permissions)
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(.borderless)
            .help("Audio Diagnostics")

            Button {
                appState.selectSection(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(14)
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatusPill(title: appState.liveState.displayName, systemImage: "dot.radiowaves.left.and.right", tint: stateTint)
                StatusPill(
                    title: "Mic \(appState.microphonePermissionState.displayName)",
                    systemImage: "mic",
                    tint: appState.microphonePermissionState == .authorized ? .green : .orange
                )
                StatusPill(title: "ASR Apple Speech", systemImage: "text.bubble", tint: .blue)
                StatusPill(title: appState.activeRealtimeProviderBadge, systemImage: "brain", tint: appState.activeRealtimeProvider?.kind == .ollamaLocal ? .green : .blue)
                StatusPill(title: appState.onboardingComplete ? "CV/JD loaded" : "CV/JD missing", systemImage: "doc.on.doc", tint: appState.onboardingComplete ? .green : .red)
            }
        }
    }

    @ViewBuilder
    private var permissionRecovery: some View {
        if appState.liveState == .permissionDenied || appState.microphonePermissionState == .denied || appState.microphonePermissionState == .restricted {
            VStack(alignment: .leading, spacing: 10) {
                Label("Grant microphone permission to start live transcription", systemImage: "mic.slash")
                    .font(.headline)
                Text("After granting access in macOS, return here and Start Listening again. If the badge does not update, use Refresh or restart the app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Request Permission") {
                        appState.requestMicrophonePermission()
                    }
                    .buttonStyle(.bordered)

                    Button("Open System Settings") {
                        appState.openMicrophonePrivacySettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh") {
                        appState.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var floatingAssistantStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Floating Assistant")
                    .font(.headline)
                Text(appState.isFloatingAssistantVisible ? "Visible above normal app windows." : "Opens automatically after Start Listening succeeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(appState.isFloatingAssistantVisible ? "Show" : "Open") {
                appState.showFloatingAssistant()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var autoDetectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Automatic Question Detection", systemImage: "scope")
                    .font(.headline)
                Spacer()
                StatusPill(
                    title: appState.settings.automaticQuestionDetectionEnabled && !appState.settings.manualOnlyMode ? "Enabled" : "Manual Only",
                    systemImage: appState.settings.automaticQuestionDetectionEnabled && !appState.settings.manualOnlyMode ? "checkmark.circle.fill" : "hand.raised",
                    tint: appState.settings.automaticQuestionDetectionEnabled && !appState.settings.manualOnlyMode ? .green : .orange
                )
            }
            Text("When a complete interviewer question is detected with confidence 75% or higher, the app generates a suggestion automatically. 55–75% confidence appears as a possible question.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detectedQuestionPanel: some View {
        if let possible = appState.possibleQuestion {
            possibleQuestionView(possible)
        } else if let question = appState.lastDetectedQuestion {
            VStack(alignment: .leading, spacing: 8) {
                Label("Detected Question", systemImage: "checkmark.bubble")
                    .font(.headline)
                Text(question.questionText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusPill(title: question.intent.displayName, systemImage: "tag", tint: .blue)
                    StatusPill(title: "\(Int(question.confidence * 100))%", systemImage: "gauge.medium", tint: question.confidence >= 0.75 ? .green : .orange)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyStateView(
                title: "No question detected yet",
                message: "Start Listening. The app will watch the live transcript and generate suggestions automatically.",
                systemImage: "questionmark.bubble"
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var practiceTestingSection: some View {
        DisclosureGroup(isExpanded: $practiceExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use this to test the full AI pipeline without microphone input: mock transcript → question detection → context retrieval → suggestion generation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("Paste an interviewer question, for example: Walk me through your robotics project.", text: $mockQuestion, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    Button {
                        appState.submitMockQuestion(mockQuestion)
                        mockQuestion = ""
                    } label: {
                        Label("Send Test Question", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(mockQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Practice / Developer Testing", systemImage: "keyboard")
                .font(.headline)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var automaticDetectionBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.automaticQuestionDetectionEnabled && !appState.settings.manualOnlyMode },
            set: { enabled in
                var next = appState.settings
                next.automaticQuestionDetectionEnabled = enabled
                next.manualOnlyMode = !enabled
                appState.saveSettings(next)
            }
        )
    }

    private var stateTint: Color {
        switch appState.liveState {
        case .permissionDenied, .error:
            return .red
        case .generatingSuggestion, .detectingQuestion, .transcribing:
            return .blue
        case .listening:
            return .green
        default:
            return .secondary
        }
    }

    private func possibleQuestionView(_ question: DetectedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Possible question detected", systemImage: "questionmark.bubble")
                .font(.headline)
            Text(question.questionText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Confidence \(Int(question.confidence * 100))%. Use Answer Now if this is the question to answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
