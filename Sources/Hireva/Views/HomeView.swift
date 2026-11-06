import SwiftUI

struct HomeView: View {
    @ObservedObject var live: LiveInterviewFeature
    @ObservedObject var manual: ManualCaptureController
    @ObservedObject var settingsState: SettingsState
    @Binding var hirevaMode: HirevaMode
    let activeIdentity: GenerationIdentity?
    private var generationState: GenerationUIState { live.generationUIState }
    let elapsedMS: Int
    private var isStreaming: Bool { live.isStreamingSayFirst }
    private var isExpanding: Bool { live.isExpandingSuggestionCard }
    let providerStreamActive: Bool
    let productInterviewStatus: ProductInterviewStatus
    let primaryHomeActionTitle: String
    let primaryHomeActionSystemImage: String
    let primaryHomeActionShouldStop: Bool
    let coreInterviewReadinessPassed: Bool
    let liveBlockedReason: String?
    let anyCaptureRunning: Bool
    let isListening: Bool
    let selectedAnswerProviderStatusTitle: String
    let selectedAnswerProviderConfigured: Bool
    let userFacingRelevantContextStatus: String
    let candidateDisplayName: String
    let opportunityTitle: String
    let domainDisplayName: String
    let contextReadinessStatus: ContextReadinessStatus
    let permissionSummary: String
    let isFloatingAssistantVisible: Bool
    let manualWorkspace: ManualCaptureWorkspaceView
    let cancelManualCapture: () -> Void
    let clearManualCapture: () -> Void
    let refreshPermissions: () -> Void
    let saveSettings: (AppSettings) -> Void
    let selectSection: (AppSection) -> Void
    let showFloatingAssistant: () -> Void
    let answerCurrentQuestionOrTranscriptNow: () -> Void
    let stopListening: () -> Void
    let startListening: () -> Void
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let beginFeedback: (String, String, String) -> Void
    let completeFeedback: (String, String, String) -> Void
    let infoFeedback: (String, String, String, TimeInterval?) -> Void

    init(live: LiveInterviewFeature,
        manual: ManualCaptureController,
        settingsState: SettingsState,
        hirevaMode: Binding<HirevaMode>,
        activeIdentity: GenerationIdentity?,
        elapsedMS: Int,
        providerStreamActive: Bool,
        productInterviewStatus: ProductInterviewStatus,
        primaryHomeActionTitle: String,
        primaryHomeActionSystemImage: String,
        primaryHomeActionShouldStop: Bool,
        coreInterviewReadinessPassed: Bool,
        liveBlockedReason: String?,
        anyCaptureRunning: Bool,
        isListening: Bool,
        selectedAnswerProviderStatusTitle: String,
        selectedAnswerProviderConfigured: Bool,
        userFacingRelevantContextStatus: String,
        candidateDisplayName: String,
        opportunityTitle: String,
        domainDisplayName: String,
        contextReadinessStatus: ContextReadinessStatus,
        permissionSummary: String,
        isFloatingAssistantVisible: Bool,
        manualWorkspace: ManualCaptureWorkspaceView,
        cancelManualCapture: @escaping () -> Void,
        clearManualCapture: @escaping () -> Void,
        refreshPermissions: @escaping () -> Void,
        saveSettings: @escaping (AppSettings) -> Void,
        selectSection: @escaping (AppSection) -> Void,
        showFloatingAssistant: @escaping () -> Void,
        answerCurrentQuestionOrTranscriptNow: @escaping () -> Void,
        stopListening: @escaping () -> Void,
        startListening: @escaping () -> Void,
        feedbacks: [ActionFeedback],
        loadingStates: [String: Bool],
        beginFeedback: @escaping (String, String, String) -> Void,
        completeFeedback: @escaping (String, String, String) -> Void,
        infoFeedback: @escaping (String, String, String, TimeInterval?) -> Void) {
        self.live = live
        self.manual = manual
        self.settingsState = settingsState
        self._hirevaMode = hirevaMode
        self.activeIdentity = activeIdentity
        self.elapsedMS = elapsedMS
        self.providerStreamActive = providerStreamActive
        self.productInterviewStatus = productInterviewStatus
        self.primaryHomeActionTitle = primaryHomeActionTitle
        self.primaryHomeActionSystemImage = primaryHomeActionSystemImage
        self.primaryHomeActionShouldStop = primaryHomeActionShouldStop
        self.coreInterviewReadinessPassed = coreInterviewReadinessPassed
        self.liveBlockedReason = liveBlockedReason
        self.anyCaptureRunning = anyCaptureRunning
        self.isListening = isListening
        self.selectedAnswerProviderStatusTitle = selectedAnswerProviderStatusTitle
        self.selectedAnswerProviderConfigured = selectedAnswerProviderConfigured
        self.userFacingRelevantContextStatus = userFacingRelevantContextStatus
        self.candidateDisplayName = candidateDisplayName
        self.opportunityTitle = opportunityTitle
        self.domainDisplayName = domainDisplayName
        self.contextReadinessStatus = contextReadinessStatus
        self.permissionSummary = permissionSummary
        self.isFloatingAssistantVisible = isFloatingAssistantVisible
        self.manualWorkspace = manualWorkspace
        self.cancelManualCapture = cancelManualCapture
        self.clearManualCapture = clearManualCapture
        self.refreshPermissions = refreshPermissions
        self.saveSettings = saveSettings
        self.selectSection = selectSection
        self.showFloatingAssistant = showFloatingAssistant
        self.answerCurrentQuestionOrTranscriptNow = answerCurrentQuestionOrTranscriptNow
        self.stopListening = stopListening
        self.startListening = startListening
        self.feedbacks = feedbacks
        self.loadingStates = loadingStates
        self.beginFeedback = beginFeedback
        self.completeFeedback = completeFeedback
        self.infoFeedback = infoFeedback
    }
    @State private var showManualCapture = false
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    var renderState: VisibleAssistantRenderState {
        live.renderState(activeIdentity: activeIdentity, generationState: generationState,
            elapsedMS: elapsedMS, isStreaming: isStreaming, isExpanding: isExpanding,
            providerStreamActive: providerStreamActive)
    }
    private var shouldShowBlockingAnswerSpinner: Bool {
        live.shouldShowBlockingAnswerSpinner(generationState: generationState, elapsedMS: elapsedMS)
    }
    private var shouldShowAnswerExpansionStatus: Bool {
        live.shouldShowAnswerExpansionStatus(generationState: generationState, isExpanding: isExpanding)
    }
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
        .sheet(isPresented: $showManualCapture, onDismiss: {
            cancelManualCapture()
            hirevaMode = .autoDetect
        }) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Source", selection: Binding(
                        get: { settingsState.settings.manualCaptureSource },
                        set: { source in
                            var settings = settingsState.settings
                            settings.manualCaptureSource = source
                            saveSettings(settings)
                        }
                    )) {
                        ForEach(ManualCaptureSource.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(manual.state != .idle)
                    Spacer()
                    Button("Clear") { clearManualCapture() }
                    Button("Close") { showManualCapture = false }
                }.padding()
                Divider()
                manualWorkspace.layout(isWide: false)
            }
            .frame(width: 720, height: 720)
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hireva")
                    .font(.largeTitle.weight(.bold))
                Text("Set up your context, start listening, and keep the floating answer card ready.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                beginAction(ActionID.diagnosticsRefresh, title: "Opening diagnostics", message: "Developer diagnostics are opening.")
                selectSection(.diagnostics)
                completeAction(ActionID.diagnosticsRefresh, title: "Diagnostics opened", message: "Technical details are available for troubleshooting.")
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }
    }

    private var interviewStatusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: productInterviewStatus.systemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(productInterviewStatus.title)
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
                metric("Capture mode", settingsState.settings.audioCaptureMode.shortDisplayName, "waveform.and.mic")
                metric("Answer provider", selectedAnswerProviderStatusTitle, selectedAnswerProviderConfigured ? "sparkles" : "key")
                metric("Relevant context", userFacingRelevantContextStatus, "doc.text.magnifyingglass")
                metric("Candidate", candidateDisplayName, "person.crop.circle")
                metric("Opportunity", opportunityTitle, "briefcase")
                metric("Domain", domainDisplayName, "square.grid.2x2")
                metric("Context readiness", contextReadinessTitle, "checkmark.shield")
                metric("Permissions", permissionSummary, "hand.raised")
                metric("Floating panel", isFloatingAssistantVisible ? "Visible" : "Hidden", "macwindow")
            }

            HStack(spacing: 10) {
                Button("Capture Question", systemImage: "hand.tap") {
                    cancelManualCapture()
                    hirevaMode = .manualCapture
                    showManualCapture = true
                }
                .disabled(anyCaptureRunning)
                ActionButtonContent(
                    isLoading: isActionLoading(ActionID.runReadiness),
                    feedback: latestActionFeedback(for: ActionID.runReadiness),
                    title: "Run Readiness Check",
                    loadingTitle: "Opening check...",
                    systemImage: "checklist.checked"
                ) {
                    beginAction(ActionID.runReadiness, title: "Opening readiness check", message: "Showing the pre-interview checklist...")
                    selectSection(.readinessCheck)
                    completeAction(ActionID.runReadiness, title: "Readiness check opened", message: "Fix failed items before starting.")
                }

                ActionButtonContent(
                    isLoading: isActionLoading(ActionID.showFloatingPanel),
                    feedback: latestActionFeedback(for: ActionID.showFloatingPanel),
                    title: isFloatingAssistantVisible ? "Show Floating Panel" : "Open Floating Panel",
                    loadingTitle: "Opening panel...",
                    systemImage: "macwindow.badge.plus"
                ) {
                    showFloatingAssistant()
                }

                if live.lastDetectedQuestion != nil || live.possibleQuestion != nil {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.generateAnswer),
                        feedback: latestActionFeedback(for: ActionID.generateAnswer),
                        title: "Generate Answer",
                        loadingTitle: "Generating first answer...",
                        successTitle: "Answer ready",
                        systemImage: "sparkles",
                        isProminent: true,
                        disabled: !live.liveState.canAnswerNow
                    ) {
                        answerCurrentQuestionOrTranscriptNow()
                    }
                }
            }

            InlineStatusBanner(homeFeedback)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var contextReadinessTitle: String {
        switch contextReadinessStatus {
        case .ready: return "Ready"
        case .needsReview: return "Needs Review"
        case .missing: return "Missing"
        }
    }

    private var primaryAction: some View {
        ActionButtonContent(
            isLoading: isActionLoading(primaryActionID),
            feedback: latestActionFeedback(for: primaryActionID),
            title: primaryHomeActionTitle,
            loadingTitle: primaryLoadingTitle,
            successTitle: primarySuccessTitle,
            systemImage: primaryHomeActionSystemImage,
            isProminent: true,
            controlSize: .large
        ) {
            if primaryHomeActionShouldStop {
                stopListening()
            } else if !coreInterviewReadinessPassed {
                beginAction(ActionID.runReadiness, title: "Opening readiness check", message: "Showing exactly what needs attention...")
                selectSection(.readinessCheck)
                completeAction(ActionID.runReadiness, title: "Readiness check opened", message: "Fix failed items before starting.")
            } else {
                startListening()
            }
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Capture Mode", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text(anyCaptureRunning ? "Stop listening to change mode." : "Choose what the app listens to.")
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
                if shouldShowBlockingAnswerSpinner {
                    ProgressView()
                        .controlSize(.small)
                } else if shouldShowAnswerExpansionStatus {
                    Text("Expanding full answer...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            if let errorText = renderState.generationErrorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let card = live.currentSuggestion, !card.sayFirst.isEmpty {
                answerCard(card)
                recentAnswersList
            } else if shouldShowBlockingAnswerSpinner || renderState.hasAnswerText {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Say First")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(renderState.hasAnswerText ? renderState.answerText : "Generating first answer...")
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !coreInterviewReadinessPassed {
                emptyAction(
                    title: "Setup is incomplete",
                    message: "Run the readiness check to see exactly what needs attention before the interview.",
                    buttonTitle: "Run Readiness Check",
                    systemImage: "checklist.checked",
                    actionID: ActionID.runReadiness,
                    loadingTitle: "Opening check...",
                    successTitle: "Checklist open"
                ) {
                    beginAction(ActionID.runReadiness, title: "Opening readiness check", message: "Showing exactly what needs attention...")
                    selectSection(.readinessCheck)
                    completeAction(ActionID.runReadiness, title: "Readiness check opened", message: "Fix failed items before starting.")
                }
            } else if !isListening {
                emptyAction(
                    title: "Listening is stopped",
                    message: "Start listening or capture a question to generate an answer.",
                    buttonTitle: "Start Listening",
                    systemImage: "play.fill",
                    actionID: ActionID.startInterview,
                    loadingTitle: "Starting...",
                    successTitle: "Listening started"
                ) {
                    startListening()
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

    @ViewBuilder
    private var recentAnswersList: some View {
        let cards = Array(live.liveSuggestionHistory.suffix(4).reversed())
        if cards.count > 1 {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent answers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.questionText ?? "Interview question")
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        Text(card.sayFirst)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let caution = card.caution, !caution.isEmpty {
                            Text(caution)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
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
        let selected = settingsState.settings.audioCaptureMode == mode
        return Button {
            guard !anyCaptureRunning else { return }
            var next = settingsState.settings
            next.audioCaptureMode = mode
            infoAction(ActionID.switchCaptureMode, title: "Capture mode selected", message: "\(mode.shortDisplayName): \(mode.userFacingDescription)")
            saveSettings(next)
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
        .disabled(anyCaptureRunning)
    }

    private func emptyAction(
        title: String,
        message: String,
        buttonTitle: String,
        systemImage: String,
        actionID: String,
        loadingTitle: String,
        successTitle: String,
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
            ActionButtonContent(
                isLoading: isActionLoading(actionID),
                feedback: latestActionFeedback(for: actionID),
                title: buttonTitle,
                loadingTitle: loadingTitle,
                successTitle: successTitle,
                systemImage: systemImage,
                isProminent: true,
                action: action
            )
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 190)
    }

    private var statusTint: Color {
        switch productInterviewStatus {
        case .ready: return .green
        case .listening, .questionDetected, .generatingFirstAnswer, .expandingAnswer: return .blue
        case .needsAttention: return .orange
        case .stopped: return .secondary
        }
    }

    private var statusMessage: String {
        switch productInterviewStatus {
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
            return liveBlockedReason ?? permissionSummary
        case .stopped:
            return "Listening is stopped."
        }
    }

    private var currentQuestionText: String? {
        !renderState.questionText.isEmpty ? renderState.questionText : nil
    }

    private var speakerLeakWarningVisible: Bool {
        let input = audioDeviceManager.currentInputDeviceName.lowercased()
        let output = audioDeviceManager.currentOutputDeviceName.lowercased()
        let builtInInput = input.contains("macbook") || input.contains("built-in") || input.contains("built in")
        let builtInOutput = output.contains("macbook") || output.contains("built-in") || output.contains("built in")
        return builtInInput && builtInOutput && settingsState.settings.audioCaptureMode != .systemAudioOnly
    }

    private func modeIcon(_ mode: AudioCaptureMode) -> String {
        switch mode {
        case .systemAudioOnly: return "speaker.wave.2.fill"
        case .microphoneOnly: return "mic.fill"
        case .microphoneAndSystem: return "headphones"
        }
    }

    private var homeFeedback: ActionFeedback? {
        latestActionFeedback(matching: [
            ActionID.startInterview,
            ActionID.stopListening,
            ActionID.runReadiness,
            ActionID.showFloatingPanel,
            ActionID.generateAnswer,
            ActionID.switchCaptureMode,
            ActionID.diagnosticsRefresh
        ])
    }

    private var primaryActionID: String {
        if primaryHomeActionShouldStop {
            return ActionID.stopListening
        }
        if !coreInterviewReadinessPassed {
            return ActionID.runReadiness
        }
        return ActionID.startInterview
    }

    private var primaryLoadingTitle: String {
        if primaryHomeActionShouldStop {
            return "Stopping..."
        }
        if !coreInterviewReadinessPassed {
            return "Opening check..."
        }
        return "Starting..."
    }

    private var primarySuccessTitle: String {
        if primaryHomeActionShouldStop {
            return "Stopped"
        }
        if !coreInterviewReadinessPassed {
            return "Checklist open"
        }
        return "Listening started"
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
