import SwiftUI

struct LiveInterviewView: View {
    @ObservedObject var appState: AppState
    @State private var mockQuestion = ""
    @State private var practiceExpanded = false
    @State private var showDeepSeekConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 800
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                Divider()

                if let reason = appState.liveBlockedReason {
                    EmptyStateView(title: "Live Interview Locked", message: reason, systemImage: "lock")
                } else {
                    switch appState.interviewCopilotMode {
                    case .autoDetect:
                        autoDetectWorkspace(isWide: isWide)
                    case .manualCapture:
                        manualCaptureWorkspace(isWide: isWide)
                    case .practiceMock:
                        practiceMockWorkspace(isWide: isWide)
                    }
                }
            }
        }
        .navigationTitle("Live Interview")
        .onAppear {
            appState.refreshPermissions()
        }
        .alert("Confirm Cloud Fallback", isPresented: $showDeepSeekConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm") {
                appState.sendManualCaptureToAI(forceDeepSeek: true)
            }
        } message: {
            Text("This will send the captured question and selected CV/JD snippets to DeepSeek.")
        }
    }

    private var modeSelector: some View {
        Picker("Mode", selection: $appState.interviewCopilotMode) {
            ForEach(InterviewCopilotMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
    }

    @ViewBuilder
    private func primaryActions(isCompact: Bool) -> some View {
        if appState.interviewCopilotMode == .autoDetect {
            PrimaryButton(
                title: isCompact ? "Start" : "Start Listening",
                systemImage: "mic.fill",
                isDisabled: appState.anyCaptureRunning || !appState.liveState.canStartListening || appState.liveBlockedReason != nil
            ) {
                appState.startListening(mode: .microphone)
            }

            Picker("", selection: audioCaptureModeBinding) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Text(mode.shortDisplayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .disabled(appState.anyCaptureRunning || !appState.liveState.canStartListening)
            .help("Choose what audio streams to capture: \n• Mic: Microphone Only\n• System: System Audio Only\n• Mic + System: Microphone + System Audio")

            Button {
                appState.stopListening()
            } label: {
                Label(isCompact ? "Stop" : "Stop", systemImage: "stop.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.canStopCapture)
        }
    }

    @ViewBuilder
    private func secondaryControls(isCompact: Bool) -> some View {
        Button {
            appState.showFloatingAssistant()
        } label: {
            Label(isCompact ? "Overlay" : "Floating Assistant", systemImage: "macwindow.badge.plus")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        if appState.interviewCopilotMode == .autoDetect {
            Toggle(isOn: automaticDetectionBinding) {
                Label(isCompact ? "Auto" : "Auto Detect", systemImage: "scope")
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Automatically detect complete interviewer questions and generate suggestions.")

            Button {
                appState.manualAnswerNow()
            } label: {
                Label(isCompact ? "Fallback" : "Answer Fallback", systemImage: "keyboard")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!appState.liveState.canAnswerNow || appState.liveBlockedReason != nil)
            .help("Fallback: manually trigger generation from the recent transcript.")
        }

        Button {
            appState.clearLiveSession()
        } label: {
            Label(isCompact ? "Clear" : "Clear", systemImage: "trash")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        if appState.interviewCopilotMode == .autoDetect {
            Button {
                appState.restartAudioInput()
            } label: {
                Label(isCompact ? "Restart" : "Restart", systemImage: "arrow.clockwise.circle")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Manual audio capture reset if device changes.")
        }
    }

    private var utilityButtons: some View {
        HStack(spacing: 8) {
            Button {
                appState.selectSection(.diagnostics)
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
    }

    private func toolbar(width: CGFloat) -> some View {
        Group {
            if width >= 800 {
                // Wide Toolbar: Single row layout
                HStack(spacing: 10) {
                    modeSelector
                    
                    Spacer().frame(width: 10)
                    
                    primaryActions(isCompact: false)
                    
                    secondaryControls(isCompact: false)
                    
                    Spacer()
                    
                    if appState.interviewCopilotMode == .autoDetect {
                        MicLevelIndicatorView(appState: appState, isMini: false)
                    }
                    
                    utilityButtons
                }
                .padding(14)
            } else {
                // Medium/Compact Toolbar: Two rows
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        modeSelector
                        
                        Spacer()
                        
                        primaryActions(isCompact: true)
                        
                        if appState.interviewCopilotMode == .autoDetect {
                            MicLevelIndicatorView(appState: appState, isMini: true)
                        }
                    }
                    
                    Divider()
                    
                    HStack(spacing: 10) {
                        secondaryControls(isCompact: true)
                        
                        Spacer()
                        
                        utilityButtons
                    }
                }
                .padding(14)
            }
        }
    }

    private func statusStrip(isCompact: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
            StatusPill(
                title: appState.liveState.displayName,
                compactTitle: appState.liveState.displayName,
                systemImage: "dot.radiowaves.left.and.right",
                tint: stateTint,
                isCompact: isCompact
            )
            StatusPill(
                title: "Mic \(appState.microphonePermissionState.displayName)",
                compactTitle: "Mic: \(appState.microphonePermissionState == .authorized ? "✓" : "✗")",
                systemImage: "mic",
                tint: appState.microphonePermissionState == .authorized ? .green : .orange,
                isCompact: isCompact
            )
            StatusPill(
                title: "System Audio \(appState.permissionSnapshot.systemAudioCapture == .granted ? "Granted" : "Required")",
                compactTitle: "System: \(appState.permissionSnapshot.systemAudioCapture == .granted ? "✓" : "Required")",
                systemImage: "speaker.wave.2",
                tint: appState.permissionSnapshot.systemAudioCapture == .granted ? .green : .orange,
                isCompact: isCompact
            )
            LLMProviderQuickSwitcherView(appState: appState, isCompact: isCompact)
            StatusPill(
                title: appState.onboardingComplete ? "CV/JD loaded" : "CV/JD missing",
                compactTitle: appState.onboardingComplete ? "CV/JD ✓" : "CV/JD ✗",
                systemImage: "doc.on.doc",
                tint: appState.onboardingComplete ? .green : .red,
                isCompact: isCompact
            )
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
    
    // MARK: - Conditional Workspaces
    
    private func autoDetectWorkspace(isWide: Bool) -> some View {
        Group {
            if isWide {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            statusStrip(isCompact: false)
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
                    .frame(minWidth: 520)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            detectedQuestionPanel
                            SuggestionCardView(card: appState.currentSuggestion, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 360)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusStrip(isCompact: true)
                        audioDeviceConfigPanel
                        audioRouteWarning
                        permissionRecovery
                        floatingAssistantStatus
                        autoDetectionStatus
                        
                        Divider()
                        
                        Text("Question & Suggestions")
                            .font(.title2.weight(.bold))
                            
                        detectedQuestionPanel
                        SuggestionCardView(card: appState.currentSuggestion, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                        
                        Divider()
                        
                        TranscriptView(segments: appState.transcriptSegments)
                        practiceTestingSection
                    }
                    .padding(18)
                }
            }
        }
    }
    
    private func practiceMockWorkspace(isWide: Bool) -> some View {
        Group {
            if isWide {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Practice / Mock Interview Mode")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.secondary)
                            
                            practiceTestingSectionExpanded
                            
                            TranscriptView(segments: appState.transcriptSegments)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 520)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            detectedQuestionPanel
                            SuggestionCardView(card: appState.currentSuggestion, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 360)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Practice / Mock Interview Mode")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.secondary)
                        
                        practiceTestingSectionExpanded
                        
                        Divider()
                        
                        Text("Question & Suggestions")
                            .font(.title2.weight(.bold))
                            
                        detectedQuestionPanel
                        SuggestionCardView(card: appState.currentSuggestion, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                        
                        Divider()
                        
                        TranscriptView(segments: appState.transcriptSegments)
                    }
                    .padding(18)
                }
            }
        }
    }
    
    private var practiceTestingSectionExpanded: some View {
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
                .buttonStyle(.borderedProminent)
                .disabled(mockQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func manualCaptureWorkspace(isWide: Bool) -> some View {
        Group {
            if isWide {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            manualCaptureControlsCard(isCompact: false)
                            
                            if !appState.manualCaptureTranscript.isEmpty {
                                manualCaptureTranscriptReviewCard
                            }
                            
                            TranscriptView(segments: appState.transcriptSegments)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 520)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Suggestion Card", systemImage: "lightbulb.fill")
                                .font(.headline)
                                .foregroundStyle(.purple)
                            
                            if let card = appState.manualCaptureSuggestion {
                                SuggestionCardView(card: card, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                            } else {
                                VStack(spacing: 20) {
                                    Image(systemName: "hand.tap")
                                       .font(.system(size: 40))
                                       .foregroundStyle(.secondary)
                                    Text("Generate suggestions dynamically by capturing loopback audio or speaking into the mic.")
                                       .multilineTextAlignment(.center)
                                       .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 250)
                                .padding(18)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 360)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        manualCaptureControlsCard(isCompact: true)
                        
                        if !appState.manualCaptureTranscript.isEmpty {
                            manualCaptureTranscriptReviewCard
                        }
                        
                        Divider()
                        
                        Label("Suggestion Card", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        
                        if let card = appState.manualCaptureSuggestion {
                            SuggestionCardView(card: card, retrievedChunks: appState.currentSuggestionRetrievedChunks)
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "hand.tap")
                                   .font(.system(size: 40))
                                   .foregroundStyle(.secondary)
                                Text("Generate suggestions dynamically by capturing loopback audio or speaking into the mic.")
                                   .multilineTextAlignment(.center)
                                   .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .padding(18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Divider()
                        
                        TranscriptView(segments: appState.transcriptSegments)
                    }
                    .padding(18)
                }
            }
        }
    }
    
    private func computeLevelText() -> String {
        let bufferCount = appState.manualCaptureState == .recording ? ManualQuestionCaptureService.shared.capturedBufferCount : appState.manualCaptureBufferCount
        if appState.manualCaptureState == .recording {
            return String(format: "Timer: %@  •  Buffers: %d", 
                          formatDuration(appState.manualCaptureDuration), 
                          bufferCount)
        } else if appState.manualCaptureBufferCount > 0 {
            let sourceName = appState.manualCaptureSource == "systemAudio" ? "System Audio" : "Microphone"
            let lastTimeStr: String
            if let lastTime = appState.manualCaptureLastBufferTimestamp {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                lastTimeStr = formatter.string(from: lastTime)
            } else {
                lastTimeStr = "N/A"
            }
            return String(format: "Captured: %d buffers  •  %.1fs  •  Source: %@  •  Last: %@", 
                          appState.manualCaptureBufferCount,
                          appState.manualCaptureDuration,
                          sourceName,
                          lastTimeStr)
        } else {
            return "Timer: 00:00  •  Buffers: 0"
        }
    }
    
    private func manualCaptureControlsCard(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Manual Capture (Push-to-Ask)", systemImage: "hand.tap.fill")
                    .font(.headline)
                    .foregroundStyle(.purple)
                
                Spacer()
                
                // Diagnostic Level
                Text(computeLevelText())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            // Dynamic State Banner
            manualCaptureStateBanner
            
            // Level Meter
            if appState.manualCaptureState == .recording {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Audio Signal Meter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f dBFS", ManualQuestionCaptureService.shared.decibels))
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: appState.manualCaptureLevel)
                        .progressViewStyle(.linear)
                }
            }
            
            // Large Trigger Buttons
            HStack(spacing: 12) {
                if appState.manualCaptureState == .idle || 
                   appState.manualCaptureState == .transcriptReady || 
                   appState.manualCaptureState == .suggestionReady ||
                   caseError(appState.manualCaptureState) {
                    Button {
                        appState.startManualCapture()
                    } label: {
                        Label(isCompact ? "Record" : "Record Question", systemImage: "record.circle")
                            .font(.headline)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
                
                if appState.manualCaptureState == .recording {
                    Button {
                        appState.stopAndTranscribeManualCapture()
                    } label: {
                        Label(isCompact ? "Stop" : "Stop & Transcribe", systemImage: "stop.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.large)
                }
                
                if appState.manualCaptureState == .recording || 
                   appState.manualCaptureState == .transcribing || 
                   appState.manualCaptureState == .generatingSuggestion {
                    Button {
                        appState.cancelManualCapture()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
                if appState.manualCaptureState == .transcriptReady {
                    Button {
                        appState.sendManualCaptureToAI()
                    } label: {
                        Label(isCompact ? "Ask" : "Send to AI", systemImage: "paperplane.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }
                
                if appState.manualCaptureState == .suggestionReady {
                    Button {
                        appState.retryManualCapture()
                    } label: {
                        Label(isCompact ? "Retry" : "Retry Recording", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
                if case .suggestionError = appState.manualCaptureState {
                    Button {
                        appState.sendManualCaptureToAI()
                    } label: {
                        Label("Retry LLM", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                    
                    Button {
                        self.showDeepSeekConfirmation = true
                    } label: {
                        Label("Regenerate with DeepSeek", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button {
                        appState.selectSection(.settings)
                    } label: {
                        Label("Open Provider Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button {
                        appState.retryManualCapture()
                    } label: {
                        Label("Retry Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button {
                        appState.clearManualCapture()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
                Spacer()
                
                // Show Warning if source is microphone
                if appState.settings.manualCaptureSource == .microphone {
                    Text("⚠️ Mic Mode captures room echo.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("💻 System loopback active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    
    @ViewBuilder
    private var manualCaptureStateBanner: some View {
        switch appState.manualCaptureState {
        case .idle:
            Text("Ready to capture. Play browser or Zoom audio and click Record Question.")
                .foregroundStyle(.secondary)
        case .waitingForPermission:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Validating macOS capture permissions...")
            }
        case .recording:
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text("Listening to interviewer system audio...")
                    .foregroundStyle(.red)
            }
        case .stopping:
            Text("Stopping stream and flushing buffers...")
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing recorded speech...")
            }
        case .transcriptReady:
            Text("Transcription complete. Review the question below and click Send to AI.")
                .foregroundStyle(.green)
        case .generatingSuggestion:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("AI is formulating answer Strategy...")
            }
        case .suggestionReady:
            Text("Suggestion generated successfully!")
                .foregroundStyle(.green)
        case .cancelled:
            Text("Recording discarded.")
                .foregroundStyle(.secondary)
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(msg)
                    .foregroundStyle(.red)
            }
        case .suggestionError(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Suggestion Failed: \(msg)")
                    .foregroundStyle(.red)
            }
        }
    }
    
    private func caseError(_ state: ManualCaptureState) -> Bool {
        if case .error = state { return true }
        if case .suggestionError = state { return true }
        return false
    }
    
    private func formatDuration(_ duration: Double) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private var manualCaptureTranscriptReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Captured Question Transcript", systemImage: "doc.text.fill")
                .font(.headline)
            
            TextEditor(text: $appState.manualCaptureTranscript)
                .font(.system(.body, design: .monospaced))
                .padding(6)
                .frame(minHeight: 80, maxHeight: 150)
                .cornerRadius(4)
                .disabled(appState.manualCaptureState == .generatingSuggestion)
            
            HStack {
                if appState.manualCaptureState == .transcriptReady || 
                   appState.manualCaptureState == .suggestionReady || 
                   appState.caseSuggestionError(appState.manualCaptureState) {
                    Button {
                        appState.sendManualCaptureToAI()
                    } label: {
                        Label("Send to AI", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.manualCaptureTranscript.isEmpty)
                    
                    Button {
                        self.showDeepSeekConfirmation = true
                    } label: {
                        Label("Regenerate with DeepSeek", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.manualCaptureTranscript.isEmpty)
                }
                
                Spacer()
                
                if appState.settings.manualCaptureSource == .microphone {
                    Text("Review text before sending to clean room echo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LiveInterviewView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveInterviewView(appState: AppState.bootstrap())
                .frame(width: 1600, height: 900)
                .previewDisplayName("1600x900 - Light")
            
            LiveInterviewView(appState: AppState.bootstrap())
                .frame(width: 1280, height: 800)
                .preferredColorScheme(.dark)
                .previewDisplayName("1280x800 - Dark")
            
            LiveInterviewView(appState: AppState.bootstrap())
                .frame(width: 1120, height: 720)
                .previewDisplayName("1120x720 - Compact")
        }
    }
}
