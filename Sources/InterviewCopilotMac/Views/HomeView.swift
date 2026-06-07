import SwiftUI

struct HomeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                interviewStatusCard
                modeSelector
                routeWarning
                liveAnswerPreview
            }
            .padding(28)
            .frame(maxWidth: 1_080, alignment: .leading)
        }
        .navigationTitle("Home / Interview")
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Interview Copilot")
                    .font(.largeTitle.weight(.bold))
                Text("Set up your context, start listening, and keep the floating answer card ready.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                appState.selectSection(.diagnostics)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }
    }

    private var interviewStatusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: appState.productInterviewStatus.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.productInterviewStatus.title)
                        .font(.title2.weight(.bold))
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                primaryAction
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                metric("Capture mode", appState.settings.audioCaptureMode.shortDisplayName, "waveform.and.mic")
                metric("DeepSeek", appState.deepSeekConfigured ? "Configured" : "Missing", appState.deepSeekConfigured ? "lock.fill" : "key")
                metric("Relevant context", appState.userFacingRelevantContextStatus, "doc.text.magnifyingglass")
                metric("Permissions", appState.permissionSummary, "hand.raised")
                metric("Floating panel", appState.isFloatingAssistantVisible ? "Visible" : "Hidden", "macwindow")
            }

            HStack(spacing: 10) {
                Button {
                    appState.selectSection(.readinessCheck)
                } label: {
                    Label("Run Readiness Check", systemImage: "checklist.checked")
                }
                .buttonStyle(.bordered)

                Button {
                    appState.showFloatingAssistant()
                } label: {
                    Label(appState.isFloatingAssistantVisible ? "Show Floating Panel" : "Open Floating Panel", systemImage: "macwindow.badge.plus")
                }
                .buttonStyle(.bordered)

                if appState.lastDetectedQuestion != nil || appState.possibleQuestion != nil {
                    Button {
                        appState.manualAnswerNow()
                    } label: {
                        Label("Generate Answer", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.liveState.canAnswerNow)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var primaryAction: some View {
        Button {
            if appState.primaryHomeActionShouldStop {
                appState.stopListening()
            } else if !appState.coreInterviewReadinessPassed {
                appState.selectSection(.readinessCheck)
            } else {
                appState.startListening(mode: .microphone)
            }
        } label: {
            Label(appState.primaryHomeActionTitle, systemImage: appState.primaryHomeActionSystemImage)
                .font(.headline)
                .frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Capture Mode", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(appState.anyCaptureRunning ? "Stop listening to change mode." : "Choose what the app listens to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    modeCard(mode)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var routeWarning: some View {
        Group {
            if speakerLeakWarningVisible {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Speaker mode may leak interviewer audio into your microphone. Use headphones for cleaner separation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var liveAnswerPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Live Answer", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                if appState.isStreamingSayFirst || appState.isExpandingSuggestionCard {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let questionText = currentQuestionText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current question")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(questionText)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if appState.isStreamingSayFirst {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Say First")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(appState.streamedSayFirst.isEmpty ? "Generating first answer..." : appState.streamedSayFirst)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let card = appState.currentSuggestion {
                answerCard(card)
            } else if !appState.coreInterviewReadinessPassed {
                emptyAction(
                    title: "Setup is incomplete",
                    message: "Run the readiness check to see exactly what needs attention before the interview.",
                    buttonTitle: "Run Readiness Check",
                    systemImage: "checklist.checked"
                ) {
                    appState.selectSection(.readinessCheck)
                }
            } else if !appState.isListening {
                emptyAction(
                    title: "Listening is stopped",
                    message: "Start listening or capture a question to generate an answer.",
                    buttonTitle: "Start Listening",
                    systemImage: "play.fill"
                ) {
                    appState.startListening(mode: .microphone)
                }
            } else {
                EmptyStateView(
                    title: "No suggestion yet",
                    message: "Start listening or capture a question to generate an answer.",
                    systemImage: "sparkles"
                )
                .frame(minHeight: 180)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func answerCard(_ card: SuggestionCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Say First")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(card.sayFirst)
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !card.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Key Points")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(card.keyPoints.prefix(4), id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                                .padding(.top, 3)
                            Text(point)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func modeCard(_ mode: AudioCaptureMode) -> some View {
        let selected = appState.settings.audioCaptureMode == mode
        return Button {
            guard !appState.anyCaptureRunning else { return }
            var next = appState.settings
            next.audioCaptureMode = mode
            appState.saveSettings(next)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: modeIcon(mode))
                        .font(.title3)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .blue : .secondary)
                }
                Text(mode.shortDisplayName)
                    .font(.headline)
                Text(mode.userFacingDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(selected ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.blue.opacity(0.55) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(appState.anyCaptureRunning)
    }

    private func emptyAction(
        title: String,
        message: String,
        buttonTitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 190)
    }

    private var statusTint: Color {
        switch appState.productInterviewStatus {
        case .ready: return .green
        case .listening, .questionDetected, .generatingFirstAnswer, .expandingAnswer: return .blue
        case .needsAttention: return .orange
        case .stopped: return .secondary
        }
    }

    private var statusMessage: String {
        switch appState.productInterviewStatus {
        case .ready:
            return "Ready to start a test interview."
        case .listening:
            return "Listening for interviewer questions."
        case .questionDetected:
            return "A question is ready for an answer."
        case .generatingFirstAnswer:
            return "Preparing the first thing to say."
        case .expandingAnswer:
            return "Adding supporting points while the first answer remains visible."
        case .needsAttention:
            return appState.liveBlockedReason ?? appState.permissionSummary
        case .stopped:
            return "Listening is stopped."
        }
    }

    private var currentQuestionText: String? {
        if let possible = appState.possibleQuestion {
            return possible.questionText
        }
        if let detected = appState.lastDetectedQuestion {
            return detected.questionText
        }
        return nil
    }

    private var speakerLeakWarningVisible: Bool {
        let input = audioDeviceManager.currentInputDeviceName.lowercased()
        let output = audioDeviceManager.currentOutputDeviceName.lowercased()
        let builtInInput = input.contains("macbook") || input.contains("built-in") || input.contains("built in")
        let builtInOutput = output.contains("macbook") || output.contains("built-in") || output.contains("built in")
        return builtInInput && builtInOutput && appState.settings.audioCaptureMode != .systemAudioOnly
    }

    private func modeIcon(_ mode: AudioCaptureMode) -> String {
        switch mode {
        case .systemAudioOnly: return "speaker.wave.2.fill"
        case .microphoneOnly: return "mic.fill"
        case .microphoneAndSystem: return "headphones"
        }
    }
}
