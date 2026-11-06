import SwiftUI

struct ManualCaptureWorkspaceView: View {
    @ObservedObject var live: LiveInterviewFeature
    @ObservedObject var manual: ManualCaptureController
    @ObservedObject var settingsState: SettingsState
    let startManualCapture: () -> Void
    let stopAndTranscribeManualCapture: () -> Void
    let cancelManualCapture: () -> Void
    let sendManualCaptureToAI: (Bool) -> Void
    let retryManualCapture: () -> Void
    let clearManualCapture: () -> Void
    let selectSection: (AppSection) -> Void
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let beginFeedback: (String, String, String) -> Void
    let completeFeedback: (String, String, String) -> Void
    let infoFeedback: (String, String, String, TimeInterval?) -> Void

    init(live: LiveInterviewFeature,
        manual: ManualCaptureController,
        settingsState: SettingsState,
        startManualCapture: @escaping () -> Void,
        stopAndTranscribeManualCapture: @escaping () -> Void,
        cancelManualCapture: @escaping () -> Void,
        sendManualCaptureToAI: @escaping (Bool) -> Void,
        retryManualCapture: @escaping () -> Void,
        clearManualCapture: @escaping () -> Void,
        selectSection: @escaping (AppSection) -> Void,
        feedbacks: [ActionFeedback],
        loadingStates: [String: Bool],
        beginFeedback: @escaping (String, String, String) -> Void,
        completeFeedback: @escaping (String, String, String) -> Void,
        infoFeedback: @escaping (String, String, String, TimeInterval?) -> Void) {
        self.live = live
        self.manual = manual
        self.settingsState = settingsState
        self.startManualCapture = startManualCapture
        self.stopAndTranscribeManualCapture = stopAndTranscribeManualCapture
        self.cancelManualCapture = cancelManualCapture
        self.sendManualCaptureToAI = sendManualCaptureToAI
        self.retryManualCapture = retryManualCapture
        self.clearManualCapture = clearManualCapture
        self.selectSection = selectSection
        self.feedbacks = feedbacks
        self.loadingStates = loadingStates
        self.beginFeedback = beginFeedback
        self.completeFeedback = completeFeedback
        self.infoFeedback = infoFeedback
    }
    private var isWide = false
    @State private var showDeepSeekConfirmation = false

    // Width is local presentation input, not capture or generation state.
    func layout(isWide: Bool) -> Self {
        var result = self
        result.isWide = isWide
        return result
    }

    var body: some View {
        manualCaptureWorkspace(isWide: isWide)
            .alert("Confirm Cloud Fallback", isPresented: $showDeepSeekConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Confirm") { sendManualCaptureToAI(true) }
            } message: {
                Text("This will send the captured question and selected CV/JD snippets to DeepSeek.")
            }
    }

    func manualCaptureWorkspace(isWide: Bool) -> some View {
        Group {
            if isWide {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            manualCaptureControlsCard(isCompact: false)
                            
                            if !manual.transcript.isEmpty {
                                manualCaptureTranscriptReviewCard
                            }
                            
                            TranscriptView(segments: live.transcriptSegments)
                        }
                        .padding(18)
                    }
                    .frame(minWidth: 520)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Suggestion Card", systemImage: "lightbulb.fill")
                                .font(.headline)
                                .foregroundStyle(.purple)
                            
                            if let card = manual.suggestion {
                                SuggestionCardView(card: card, retrievedChunks: live.currentSuggestionRetrievedChunks)
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
                        
                        if !manual.transcript.isEmpty {
                            manualCaptureTranscriptReviewCard
                        }
                        
                        Divider()
                        
                        Label("Suggestion Card", systemImage: "lightbulb.fill")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        
                        if let card = manual.suggestion {
                            SuggestionCardView(card: card, retrievedChunks: live.currentSuggestionRetrievedChunks)
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
                        
                        TranscriptView(segments: live.transcriptSegments)
                    }
                    .padding(18)
                }
            }
        }
    }

    private func computeLevelText() -> String {
        let bufferCount = manual.bufferCount
        if manual.state == .recording {
            return String(format: "Timer: %@  •  Buffers: %d", 
                          formatDuration(manual.duration),
                          bufferCount)
        } else if manual.bufferCount > 0 {
            let sourceName = manual.source == "systemAudio" ? "System Audio" : "Microphone"
            let lastTimeStr: String
            if let lastTime = manual.lastBufferTimestamp {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                lastTimeStr = formatter.string(from: lastTime)
            } else {
                lastTimeStr = "N/A"
            }
            return String(format: "Captured: %d buffers  •  %.1fs  •  Source: %@  •  Last: %@", 
                          manual.bufferCount,
                          manual.duration,
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
            InlineStatusBanner(manualFeedback)
            
            // Level Meter
            if manual.state == .recording {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Audio Signal Meter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f dBFS", manual.decibels))
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: manual.level)
                        .progressViewStyle(.linear)
                }
            }
            
            // Large Trigger Buttons
            HStack(spacing: 12) {
                if manual.state == .idle ||
                   manual.state == .transcriptReady ||
                   manual.state == .suggestionReady ||
                   caseError(manual.state) {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualRecord),
                        feedback: latestActionFeedback(for: ActionID.manualRecord),
                        title: isCompact ? "Record" : "Record Question",
                        loadingTitle: "Preparing...",
                        successTitle: "Recording",
                        systemImage: "record.circle",
                        isProminent: true,
                        controlSize: .large
                    ) {
                        startManualCapture()
                    }
                    .tint(.red)
                }
                
                if manual.state == .recording {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualStopTranscribe),
                        feedback: latestActionFeedback(for: ActionID.manualStopTranscribe),
                        title: isCompact ? "Stop" : "Stop & Transcribe",
                        loadingTitle: "Transcribing...",
                        successTitle: "Transcript ready",
                        systemImage: "stop.circle.fill",
                        isProminent: true,
                        controlSize: .large
                    ) {
                        stopAndTranscribeManualCapture()
                    }
                    .tint(.blue)
                }
                
                if manual.state == .recording ||
                   manual.state == .transcribing ||
                   manual.state == .generatingSuggestion {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualCancel),
                        feedback: latestActionFeedback(for: ActionID.manualCancel),
                        title: "Cancel",
                        loadingTitle: "Cancelling...",
                        successTitle: "Cancelled",
                        systemImage: "xmark.circle",
                        controlSize: .large
                    ) {
                        cancelManualCapture()
                    }
                }
                
                if manual.state == .transcriptReady {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualGenerate),
                        feedback: latestActionFeedback(for: ActionID.manualGenerate),
                        title: isCompact ? "Ask" : "Send to AI",
                        loadingTitle: "Generating...",
                        successTitle: "Answer ready",
                        systemImage: "paperplane.fill",
                        isProminent: true,
                        controlSize: .large
                    ) {
                        sendManualCaptureToAI(false)
                    }
                    .tint(.green)
                }
                
                if manual.state == .suggestionReady {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualRecord),
                        feedback: latestActionFeedback(for: ActionID.manualRecord),
                        title: isCompact ? "Retry" : "Retry Recording",
                        loadingTitle: "Resetting...",
                        successTitle: "Ready",
                        systemImage: "arrow.clockwise.circle",
                        controlSize: .large
                    ) {
                        retryManualCapture()
                    }
                }
                
                if case .suggestionError = manual.state {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualGenerate),
                        feedback: latestActionFeedback(for: ActionID.manualGenerate),
                        title: "Retry LLM",
                        loadingTitle: "Generating...",
                        successTitle: "Answer ready",
                        systemImage: "arrow.clockwise",
                        isProminent: true,
                        controlSize: .large
                    ) {
                        sendManualCaptureToAI(false)
                    }
                    .tint(.green)
                    
                    Button {
                        infoAction(ActionID.manualGenerate, title: "Confirm DeepSeek retry", message: "Confirm before sending the transcript to DeepSeek.", autoDismissAfter: nil)
                        self.showDeepSeekConfirmation = true
                    } label: {
                        Label("Regenerate with DeepSeek", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.readiness(.openSettings)),
                        feedback: latestActionFeedback(for: ActionID.readiness(.openSettings)),
                        title: "Open Provider Settings",
                        loadingTitle: "Opening...",
                        successTitle: "Settings open",
                        systemImage: "gearshape",
                        controlSize: .large
                    ) {
                        beginAction(ActionID.readiness(.openSettings), title: "Opening settings", message: "Opening provider settings for recovery.")
                        selectSection(.settings)
                        completeAction(ActionID.readiness(.openSettings), title: "Settings opened", message: "Check provider key and model configuration.")
                    }
                    
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualRecord),
                        feedback: latestActionFeedback(for: ActionID.manualRecord),
                        title: "Retry Recording",
                        loadingTitle: "Resetting...",
                        successTitle: "Ready",
                        systemImage: "record.circle",
                        controlSize: .large
                    ) {
                        retryManualCapture()
                    }
                    
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualClear),
                        feedback: latestActionFeedback(for: ActionID.manualClear),
                        title: "Clear",
                        loadingTitle: "Clearing...",
                        successTitle: "Cleared",
                        systemImage: "trash",
                        controlSize: .large
                    ) {
                        clearManualCapture()
                    }
                }
                
                Spacer()
                
                // Show Warning if source is microphone
                if settingsState.settings.manualCaptureSource == .microphone {
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
        switch manual.state {
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
            
            TextEditor(text: $manual.transcript)
                .font(.system(.body, design: .monospaced))
                .padding(6)
                .frame(minHeight: 80, maxHeight: 150)
                .cornerRadius(4)
                .disabled(manual.state == .generatingSuggestion)
            
            HStack {
                if manual.state == .transcriptReady ||
                   manual.state == .suggestionReady ||
                   caseSuggestionError(manual.state) {
                    ActionButtonContent(
                        isLoading: isActionLoading(ActionID.manualGenerate),
                        feedback: latestActionFeedback(for: ActionID.manualGenerate),
                        title: "Send to AI",
                        loadingTitle: "Generating...",
                        successTitle: "Answer ready",
                        systemImage: "paperplane.fill",
                        isProminent: true,
                        disabled: manual.transcript.isEmpty
                    ) {
                        sendManualCaptureToAI(false)
                    }
                    
                    Button {
                        infoAction(ActionID.manualGenerate, title: "Confirm DeepSeek retry", message: "Confirm before sending the transcript to DeepSeek.", autoDismissAfter: nil)
                        self.showDeepSeekConfirmation = true
                    } label: {
                        Label("Regenerate with DeepSeek", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manual.transcript.isEmpty)
                }
                
                Spacer()
                
                if settingsState.settings.manualCaptureSource == .microphone {
                    Text("Review text before sending to clean room echo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var manualFeedback: ActionFeedback? {
        latestActionFeedback(matching: [
            ActionID.manualRecord,
            ActionID.manualStopTranscribe,
            ActionID.manualCancel,
            ActionID.manualGenerate,
            ActionID.manualClear,
            ActionID.readiness(.openSettings)
        ])
    }
    private func caseSuggestionError(_ state: ManualCaptureState) -> Bool {
        if case .suggestionError = state { return true }
        return false
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
