import SwiftUI

struct LiveInterviewView<PracticeContent: View>: View {
    @ObservedObject var live: LiveInterviewFeature
    @ObservedObject var settingsState: SettingsState
    @ObservedObject var permissions: SystemAudioPermissionController
    let micDiagnostics: MicrophoneDiagnosticsService
    let systemAudio: ScreenCaptureKitSystemAudioCaptureService
    @Binding var hirevaMode: HirevaMode
    let manualWorkspace: ManualCaptureWorkspaceView
    let practiceContent: PracticeContent
    let liveBlockedReason: String?
    let anyCaptureRunning: Bool
    let canStopCapture: Bool
    let isFloatingAssistantVisible: Bool
    let onboardingComplete: Bool
    let noAudioWarningVisible: Bool
    let audioRouteError: String?
    let errorMessage: String?
    let saveSettings: (AppSettings) -> Void
    let startListening: () -> Void
    let stopListening: () -> Void
    let showFloatingAssistant: () -> Void
    let answerCurrentQuestionOrTranscriptNow: () -> Void
    let clearLiveSession: () -> Void
    let restartAudioInput: () -> Void
    let refreshPermissions: () -> Void
    let requestMicrophonePermission: () -> Void
    let requestScreenRecordingPermission: () -> Void
    let openMicrophonePrivacySettings: () -> Void
    let selectSection: (AppSection) -> Void
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let beginFeedback: (String, String, String) -> Void
    let completeFeedback: (String, String, String) -> Void
    let infoFeedback: (String, String, String, TimeInterval?) -> Void

    init(live: LiveInterviewFeature,
        settingsState: SettingsState,
        permissions: SystemAudioPermissionController,
        micDiagnostics: MicrophoneDiagnosticsService,
        systemAudio: ScreenCaptureKitSystemAudioCaptureService,
        hirevaMode: Binding<HirevaMode>,
        manualWorkspace: ManualCaptureWorkspaceView,
        practiceContent: PracticeContent,
        liveBlockedReason: String?,
        anyCaptureRunning: Bool,
        canStopCapture: Bool,
        isFloatingAssistantVisible: Bool,
        onboardingComplete: Bool,
        noAudioWarningVisible: Bool,
        audioRouteError: String?,
        errorMessage: String?,
        saveSettings: @escaping (AppSettings) -> Void,
        startListening: @escaping () -> Void,
        stopListening: @escaping () -> Void,
        showFloatingAssistant: @escaping () -> Void,
        answerCurrentQuestionOrTranscriptNow: @escaping () -> Void,
        clearLiveSession: @escaping () -> Void,
        restartAudioInput: @escaping () -> Void,
        refreshPermissions: @escaping () -> Void,
        requestMicrophonePermission: @escaping () -> Void,
        requestScreenRecordingPermission: @escaping () -> Void,
        openMicrophonePrivacySettings: @escaping () -> Void,
        selectSection: @escaping (AppSection) -> Void,
        feedbacks: [ActionFeedback],
        loadingStates: [String: Bool],
        beginFeedback: @escaping (String, String, String) -> Void,
        completeFeedback: @escaping (String, String, String) -> Void,
        infoFeedback: @escaping (String, String, String, TimeInterval?) -> Void) {
        self.live = live
        self.settingsState = settingsState
        self.permissions = permissions
        self.micDiagnostics = micDiagnostics
        self.systemAudio = systemAudio
        self._hirevaMode = hirevaMode
        self.manualWorkspace = manualWorkspace
        self.practiceContent = practiceContent
        self.liveBlockedReason = liveBlockedReason
        self.anyCaptureRunning = anyCaptureRunning
        self.canStopCapture = canStopCapture
        self.isFloatingAssistantVisible = isFloatingAssistantVisible
        self.onboardingComplete = onboardingComplete
        self.noAudioWarningVisible = noAudioWarningVisible
        self.audioRouteError = audioRouteError
        self.errorMessage = errorMessage
        self.saveSettings = saveSettings
        self.startListening = startListening
        self.stopListening = stopListening
        self.showFloatingAssistant = showFloatingAssistant
        self.answerCurrentQuestionOrTranscriptNow = answerCurrentQuestionOrTranscriptNow
        self.clearLiveSession = clearLiveSession
        self.restartAudioInput = restartAudioInput
        self.refreshPermissions = refreshPermissions
        self.requestMicrophonePermission = requestMicrophonePermission
        self.requestScreenRecordingPermission = requestScreenRecordingPermission
        self.openMicrophonePrivacySettings = openMicrophonePrivacySettings
        self.selectSection = selectSection
        self.feedbacks = feedbacks
        self.loadingStates = loadingStates
        self.beginFeedback = beginFeedback
        self.completeFeedback = completeFeedback
        self.infoFeedback = infoFeedback
    }
    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 800
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                Divider()

                if let reason = liveBlockedReason {
                    EmptyStateView(title: "Live Interview Locked", message: reason, systemImage: "lock")
                } else {
                    switch hirevaMode {
                    case .autoDetect:
                        autoDetectWorkspace(isWide: isWide)
                    case .manualCapture:
                        manualWorkspace.layout(isWide: isWide)
                    case .practiceMock:
                        practiceContent
                    }
                }
            }
        }
        .navigationTitle("Live Interview")
        .onAppear {
            refreshPermissions()
        }

    }

    private var modeSelector: some View {
        Picker("Mode", selection: $hirevaMode) {
            ForEach(HirevaMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
    }

    @ViewBuilder
    private func primaryActions(isCompact: Bool) -> some View {
        if hirevaMode == .autoDetect {
            ActionButtonContent(
                isLoading: isActionLoading(ActionID.startInterview),
                feedback: latestActionFeedback(for: ActionID.startInterview),
                title: isCompact ? "Start" : "Start Listening",
                loadingTitle: "Starting...",
                successTitle: "Listening",
                systemImage: "mic.fill",
                isProminent: true,
                controlSize: .large,
                disabled: anyCaptureRunning || !live.liveState.canStartListening || liveBlockedReason != nil
            ) {
                startListening()
            }

            Picker("", selection: audioCaptureModeBinding) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Text(mode.shortDisplayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .disabled(anyCaptureRunning || !live.liveState.canStartListening)
            .help("Choose what audio streams to capture: \n• Mic: Microphone Only\n• System: System Audio Only\n• Mic + System: Microphone + System Audio")

            ActionButtonContent(
                isLoading: isActionLoading(ActionID.stopListening),
                feedback: latestActionFeedback(for: ActionID.stopListening),
                title: isCompact ? "Stop" : "Stop",
                loadingTitle: "Stopping...",
                successTitle: "Stopped",
                systemImage: "stop.fill",
                controlSize: .large,
                disabled: !canStopCapture
            ) {
                stopListening()
            }
        }
    }

    @ViewBuilder
    private func secondaryControls(isCompact: Bool) -> some View {
        ActionButtonContent(
            isLoading: isActionLoading(ActionID.showFloatingPanel),
            feedback: latestActionFeedback(for: ActionID.showFloatingPanel),
            title: isCompact ? "Overlay" : "Floating Assistant",
            loadingTitle: "Opening...",
            successTitle: "Visible",
            systemImage: "macwindow.badge.plus",
            controlSize: .large
        ) {
            showFloatingAssistant()
        }

        if hirevaMode == .autoDetect {
            Toggle(isOn: automaticDetectionBinding) {
                Label(isCompact ? "Auto" : "Auto Detect", systemImage: "scope")
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Automatically detect complete interviewer questions and generate suggestions.")

            ActionButtonContent(
                isLoading: isActionLoading(ActionID.generateAnswer),
                feedback: latestActionFeedback(for: ActionID.generateAnswer),
                title: isCompact ? "Fallback" : "Answer Fallback",
                loadingTitle: "Generating...",
                successTitle: "Answer ready",
                systemImage: "keyboard",
                controlSize: .large,
                disabled: !live.liveState.canAnswerNow || liveBlockedReason != nil
            ) {
                answerCurrentQuestionOrTranscriptNow()
            }
            .help("Fallback: manually trigger generation from the current question when available, otherwise from the recent transcript.")
        }

        ActionButtonContent(
            isLoading: isActionLoading(ActionID.clearLiveSession),
            feedback: latestActionFeedback(for: ActionID.clearLiveSession),
            title: isCompact ? "Clear" : "Clear",
            loadingTitle: "Clearing...",
            successTitle: "Cleared",
            systemImage: "trash",
            controlSize: .large
        ) {
            clearLiveSession()
        }

        if hirevaMode == .autoDetect {
            ActionButtonContent(
                isLoading: isActionLoading(ActionID.restartAudioInput),
                feedback: latestActionFeedback(for: ActionID.restartAudioInput),
                title: isCompact ? "Restart" : "Restart",
                loadingTitle: "Restarting...",
                successTitle: "Restarted",
                systemImage: "arrow.clockwise.circle",
                controlSize: .large
            ) {
                restartAudioInput()
            }
            .help("Manual audio capture reset if device changes.")
        }
    }

    private var utilityButtons: some View {
        HStack(spacing: 8) {
            Button {
                selectSection(.diagnostics)
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(.borderless)
            .help("Audio Diagnostics")

            Button {
                selectSection(.settings)
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
                    
                    if hirevaMode == .autoDetect {
                        MicLevelIndicatorView(live: live, settingsState: settingsState, permissions: permissions, micDiagnostics: micDiagnostics, systemAudio: systemAudio, isMini: false)
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
                        
                        if hirevaMode == .autoDetect {
                            MicLevelIndicatorView(live: live, settingsState: settingsState, permissions: permissions, micDiagnostics: micDiagnostics, systemAudio: systemAudio, isMini: true)
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
                title: live.liveState.displayName,
                compactTitle: live.liveState.displayName,
                systemImage: "dot.radiowaves.left.and.right",
                tint: stateTint,
                isCompact: isCompact
            )
            StatusPill(
                title: "Mic \(permissions.microphonePermissionState.displayName)",
                compactTitle: "Mic: \(permissions.microphonePermissionState == .authorized ? "✓" : "✗")",
                systemImage: "mic",
                tint: permissions.microphonePermissionState == .authorized ? .green : .orange,
                isCompact: isCompact
            )
            StatusPill(
                title: "System Audio \(permissions.permissionSnapshot.systemAudioCapture == .granted ? "Granted" : "Required")",
                compactTitle: "System: \(permissions.permissionSnapshot.systemAudioCapture == .granted ? "✓" : "Required")",
                systemImage: "speaker.wave.2",
                tint: permissions.permissionSnapshot.systemAudioCapture == .granted ? .green : .orange,
                isCompact: isCompact
            )
            LLMProviderQuickSwitcherView(settingsState: settingsState, feedbacks: feedbacks,
                loadingStates: loadingStates, errorMessage: errorMessage,
                openSettings: { selectSection(.settings) }, isCompact: isCompact)
            StatusPill(
                title: onboardingComplete ? "CV/JD loaded" : "CV/JD missing",
                compactTitle: onboardingComplete ? "CV/JD ✓" : "CV/JD ✗",
                systemImage: "doc.on.doc",
                tint: onboardingComplete ? .green : .red,
                isCompact: isCompact
            )
        }
    }

    @ViewBuilder
    private var permissionRecovery: some View {
        let captureMode = settingsState.settings.audioCaptureMode
        let needsScreen = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem
        let hasScreen = permissions.permissionSnapshot.screenRecording == .granted
        let hasMic = permissions.microphonePermissionState == .authorized
        let needsMic = captureMode == .microphoneOnly || captureMode == .microphoneAndSystem

        if live.liveState == .permissionDenied ||
            (!hasMic && needsMic) || 
            (!hasScreen && needsScreen) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Permissions required to start interview", systemImage: "hand.raised.fill")
                    .font(.headline)
                
                if !hasMic && needsMic {
                    Text("• Microphone permission is required for the selected capture mode. Apple Speech also requires Speech Recognition permission. Grant access in macOS Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                if needsScreen && !hasScreen {
                    Text("• Screen & System Audio Recording permission is required for the selected system audio capture mode. Enable it in System Settings -> Privacy & Security.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    if !hasMic && needsMic {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.openPermissions),
                        feedback: latestActionFeedback(for: ActionID.openPermissions),
                        title: "Request Microphone",
                        loadingTitle: "Opening...",
                        successTitle: "Opened",
                        systemImage: "mic"
                    ) {
                        infoAction(ActionID.openPermissions, title: "Requesting microphone", message: "macOS may ask for permission. If access is denied, System Settings will open.")
                        requestMicrophonePermission()
                    }
                }
                    
                if needsScreen && !hasScreen {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.openPermissions),
                        feedback: latestActionFeedback(for: ActionID.openPermissions),
                        title: "Request Screen Recording",
                        loadingTitle: "Opening...",
                        successTitle: "Opened",
                        systemImage: "display"
                    ) {
                        infoAction(ActionID.openPermissions, title: "Opening screen recording permissions", message: "Grant Screen & System Audio Recording in macOS Privacy & Security.")
                        requestScreenRecordingPermission()
                    }
                }
                    
                ActionButtonContent(
                    isLoading: isActionLoading(ActionID.openPermissions),
                    feedback: latestActionFeedback(for: ActionID.openPermissions),
                    title: "Open System Settings",
                    loadingTitle: "Opening...",
                    successTitle: "Opened",
                    systemImage: "gearshape",
                    isProminent: true
                ) {
                    beginAction(ActionID.openPermissions, title: "Opening System Settings", message: "Opening macOS Privacy & Security.")
                    openMicrophonePrivacySettings()
                    completeAction(ActionID.openPermissions, title: "System Settings opened", message: "Grant permissions, then refresh.")
                }
                    
                Button("Refresh") {
                    refreshPermissions()
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
            ActionButtonContent(
                isLoading: isActionLoading(ActionID.showFloatingPanel),
                feedback: latestActionFeedback(for: ActionID.showFloatingPanel),
                title: isFloatingAssistantVisible ? "Show Overlay" : "Launch Overlay",
                loadingTitle: "Opening...",
                successTitle: "Visible",
                systemImage: "macwindow.badge.plus",
                isProminent: true,
                controlSize: .large
            ) {
                showFloatingAssistant()
            }
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
                    title: settingsState.settings.automaticQuestionDetectionEnabled && !settingsState.settings.manualOnlyMode ? "Enabled" : "Manual Only",
                    systemImage: settingsState.settings.automaticQuestionDetectionEnabled && !settingsState.settings.manualOnlyMode ? "checkmark.circle.fill" : "hand.raised",
                    tint: settingsState.settings.automaticQuestionDetectionEnabled && !settingsState.settings.manualOnlyMode ? .green : .orange
                )
            }
            Text("When a complete interviewer question is detected with a heuristic score of at least 0.75, the app generates a suggestion automatically. A heuristic score of 0.55–0.75 appears as a possible question.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detectedQuestionPanel: some View {
        if let possible = live.possibleQuestion {
            possibleQuestionView(possible)
        } else if let question = live.lastDetectedQuestion {
            VStack(alignment: .leading, spacing: 8) {
                Label("Detected Question", systemImage: "checkmark.bubble")
                    .font(.headline)
                Text(question.questionText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusPill(title: question.intent.displayName, systemImage: "tag", tint: .blue)
                    StatusPill(title: "Heuristic match", systemImage: "gauge.medium", tint: question.confidence >= 0.75 ? .green : .orange)
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
    
    private var audioCaptureModeBinding: Binding<AudioCaptureMode> {
        Binding(
            get: { settingsState.settings.audioCaptureMode },
            set: { mode in
                var next = settingsState.settings
                next.audioCaptureMode = mode
                saveSettings(next)
            }
        )
    }

    private var automaticDetectionBinding: Binding<Bool> {
        Binding(
            get: { settingsState.settings.automaticQuestionDetectionEnabled && !settingsState.settings.manualOnlyMode },
            set: { enabled in
                var next = settingsState.settings
                next.automaticQuestionDetectionEnabled = enabled
                next.manualOnlyMode = !enabled
                saveSettings(next)
            }
        )
    }

    private var stateTint: Color {
        switch live.liveState {
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
            Text(QuestionCandidatePipeline.isContextDependentRequest(question.questionText) ? (question.reason ?? "Please clarify the earlier question this refers to.") : "Rule-based match; not a calibrated probability. Use Answer Now if this is the question to answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var audioRouteWarning: some View {
        if noAudioWarningVisible, let error = audioRouteError {
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
                    restartAudioInput()
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
        guard let session = live.currentSession else {
            return settingsState.settings.audioCaptureMode.displayName
        }
        switch session.mode {
        case .mock:
            return "Mock"
        case .microphone:
            return settingsState.settings.audioCaptureMode.displayName
        }
    }

    private var routeWarningMessage: String? {
        let manager = AudioDeviceManager.shared
        let sessionMode = live.currentSession?.mode ?? .microphone
        
        if sessionMode == .mock {
            return nil
        }
        
        var baseWarning = ""
        let captureMode = settingsState.settings.audioCaptureMode
        
        if captureMode == .microphoneOnly {
            baseWarning = "Microphone-only capture is selected. Remote audio played through headphones may not reach the microphone. Audio source does not establish speaker identity."
            if !settingsState.settings.allowQuestionDetectionFromMicrophoneOnly {
                baseWarning += " Note: Microphone-only question detection is off by default for safety."
            }
        } else if captureMode == .systemAudioOnly {
            baseWarning = "System Audio Only captures system playback without microphone input. Audio source does not establish speaker identity."
        } else {
            if manager.isUsingHeadphonesOrBluetooth {
                baseWarning = "Combined captures microphone input and system playback separately. Audio source does not establish speaker identity."
            } else {
                baseWarning = "Combined captures microphone input and system playback separately. Speaker playback may also reach the microphone. Audio source does not establish speaker identity."
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
                            InlineStatusBanner(liveFeedback)
                            audioDeviceConfigPanel
                            audioRouteWarning
                            permissionRecovery
                            floatingAssistantStatus
                            autoDetectionStatus
                            TranscriptView(segments: live.transcriptSegments)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 520)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            detectedQuestionPanel
                            SuggestionCardView(card: live.currentSuggestion, retrievedChunks: live.currentSuggestionRetrievedChunks)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 360)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statusStrip(isCompact: true)
                        InlineStatusBanner(liveFeedback)
                        audioDeviceConfigPanel
                        audioRouteWarning
                        permissionRecovery
                        floatingAssistantStatus
                        autoDetectionStatus
                        
                        Divider()
                        
                        Text("Question & Suggestions")
                            .font(.title2.weight(.bold))
                            
                        detectedQuestionPanel
                        SuggestionCardView(card: live.currentSuggestion, retrievedChunks: live.currentSuggestionRetrievedChunks)
                        
                        Divider()
                        
                        TranscriptView(segments: live.transcriptSegments)
                    }
                    .padding(18)
                }
            }
        }
    }
    
    private var liveFeedback: ActionFeedback? {
        latestActionFeedback(matching: [
            ActionID.startInterview,
            ActionID.stopListening,
            ActionID.showFloatingPanel,
            ActionID.generateAnswer,
            ActionID.clearLiveSession,
            ActionID.restartAudioInput,
            ActionID.openPermissions,
            ActionID.saveSettings
        ])
    }
    

    private func isActionLoading(_ id: String) -> Bool { loadingStates[id] == true }
    private func latestActionFeedback(for id: String) -> ActionFeedback? {
        feedbacks.last { $0.actionID == id }
    }
    private func latestActionFeedback(matching ids: [String]) -> ActionFeedback? {
        feedbacks.last { ids.contains($0.actionID) }
    }
    private func beginAction(_ id: String, title: String, message: String) {
        beginFeedback(id, title, message)
    }
    private func completeAction(_ id: String, title: String, message: String) {
        completeFeedback(id, title, message)
    }
    private func infoAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4) {
        infoFeedback(id, title, message, autoDismissAfter)
    }

}
