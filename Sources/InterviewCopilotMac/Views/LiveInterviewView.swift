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
                            audioDeviceConfigPanel
                            audioRouteWarning
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

            Picker("", selection: audioCaptureModeBinding) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 250)
            .disabled(!appState.liveState.canStartListening)
            .help("Choose what audio streams to capture for candidate and interviewer speech.")

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
                Label("Answer Fallback", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.liveState.canAnswerNow || appState.liveBlockedReason != nil)
            .help("Fallback: manually trigger generation from the recent transcript.")

            Button {
                appState.clearLiveSession()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                appState.restartAudioInput()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Manual audio capture reset if device changes.")

            Spacer()
            
            // Integrated visual mic level indicators
            MicLevelIndicatorView(appState: appState)

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
                StatusPill(
                    title: "System Audio \(appState.permissionSnapshot.systemAudioCapture == .granted ? "Granted" : "Required")",
                    systemImage: "speaker.wave.2",
                    tint: appState.permissionSnapshot.systemAudioCapture == .granted ? .green : .orange
                )
                StatusPill(title: appState.activeRealtimeProviderBadge, systemImage: "brain", tint: appState.activeRealtimeProvider?.kind == .ollamaLocal ? .green : .blue)
                StatusPill(title: appState.onboardingComplete ? "CV/JD loaded" : "CV/JD missing", systemImage: "doc.on.doc", tint: appState.onboardingComplete ? .green : .red)
            }
        }
    }

    @ViewBuilder
    private var permissionRecovery: some View {
        let captureMode = appState.settings.audioCaptureMode
        let needsScreen = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem
        let hasScreen = appState.permissionSnapshot.screenRecording == .granted
        let hasMic = appState.microphonePermissionState == .authorized
        let needsMic = captureMode == .microphoneOnly || captureMode == .microphoneAndSystem

        if appState.liveState == .permissionDenied || 
            (!hasMic && needsMic) || 
            (!hasScreen && needsScreen) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Permissions required to start interview", systemImage: "hand.raised.fill")
                    .font(.headline)
                
                if !hasMic && needsMic {
                    Text("• Microphone & Speech recognition permissions are required for candidate speech. Grant access in macOS Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                if needsScreen && !hasScreen {
                    Text("• Screen & System Audio Recording permission is required for interviewer speech. Enable Screen & System Audio Recording in System Settings -> Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    if !hasMic && needsMic {
                        Button("Request Microphone") {
                            appState.requestMicrophonePermission()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if needsScreen && !hasScreen {
                        Button("Request Screen Recording") {
                            appState.requestScreenRecordingPermission()
                        }
                        .buttonStyle(.bordered)
                    }
                    
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
        HStack(spacing: 16) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Floating Assistant Overlay")
                    .font(.headline)
                Text("This app operates primarily as an always-on-top floating card. Position the assistant over Zoom/Teams/Meet for hands-free real-time suggestions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(appState.isFloatingAssistantVisible ? "Show Overlay" : "Launch Overlay") {
                appState.showFloatingAssistant()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                
                Picker("Mock Speaker", selection: $appState.selectedMockSpeaker) {
                    Text("Interviewer").tag(SpeakerRole.interviewer)
                    Text("Candidate").tag(SpeakerRole.candidate)
                    Text("Unknown").tag(SpeakerRole.unknown)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

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

    private var audioCaptureModeBinding: Binding<AudioCaptureMode> {
        Binding(
            get: { appState.settings.audioCaptureMode },
            set: { mode in
                var next = appState.settings
                next.audioCaptureMode = mode
                appState.saveSettings(next)
            }
        )
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

    @ViewBuilder
    private var audioRouteWarning: some View {
        if appState.noAudioWarningVisible, let error = appState.audioRouteError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Input Alert")
                        .font(.subheadline.weight(.bold))
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Button("Restart Audio Input") {
                    appState.restartAudioInput()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var audioDeviceConfigPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Audio Hardware Status", systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                Spacer()
                Text("Capture Mode: \(captureModeDescription)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input Device (Mac Mic)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AudioDeviceManager.shared.currentInputDeviceName)
                        .font(.callout.weight(.medium))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Output Device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AudioDeviceManager.shared.currentOutputDeviceName)
                        .font(.callout.weight(.medium))
                }
            }

            if let warningText = routeWarningMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warningText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var captureModeDescription: String {
        guard let session = appState.currentSession else {
            return appState.settings.audioCaptureMode.displayName
        }
        switch session.mode {
        case .mock:
            return "Mock"
        case .microphone:
            return appState.settings.audioCaptureMode.displayName
        }
    }

    private var routeWarningMessage: String? {
        let manager = AudioDeviceManager.shared
        let sessionMode = appState.currentSession?.mode ?? .microphone
        
        if sessionMode == .mock {
            return nil
        }
        
        var baseWarning = ""
        let captureMode = appState.settings.audioCaptureMode
        
        if captureMode == .microphoneOnly {
            baseWarning = "Automatic interviewer question detection requires System Audio capture. Microphone-only mode cannot reliably hear the interviewer if you are wearing headphones."
            if !appState.settings.allowQuestionDetectionFromMicrophoneOnly {
                baseWarning += " Note: Microphone-only question detection is off by default for safety."
            }
        } else {
            if manager.isUsingHeadphonesOrBluetooth {
                baseWarning = "Headset mode: microphone captures you (Candidate); interviewer audio captured from system audio (Interviewer) for perfect separation."
            } else {
                baseWarning = "Speaker mode: microphone captures you; system audio captures interviewer. Warning: microphone may capture speaker leak. Echo protection is active."
            }
        }
        
        return baseWarning
    }
}
