import SwiftUI

struct FloatingAssistantView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var systemAudio = ScreenCaptureKitSystemAudioCaptureService.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @State private var eventMonitor: Any? = nil
    @State private var mockQuestionText: String = ""

    private var compact: Bool {
        appState.settings.compactMode
    }

    private var effectiveOpacity: Double {
        if appState.settings.highContrastFloatingPanel {
            return max(appState.settings.floatingWindowOpacity, 0.65)
        } else {
            return appState.settings.floatingWindowOpacity
        }
    }

    private func adjustOpacity(by delta: Double) {
        var next = appState.settings
        let minOpacity = next.highContrastFloatingPanel ? 0.65 : 0.35
        next.floatingWindowOpacity = min(max(next.floatingWindowOpacity + delta, minOpacity), 1.0)
        appState.saveSettings(next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            deviceBanner
            
            // Mirror segmented mode selector at the top!
            Picker("Mode", selection: $appState.interviewCopilotMode) {
                ForEach(InterviewCopilotMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 2)
            
            Divider()

            switch appState.interviewCopilotMode {
            case .autoDetect:
                if compact {
                    compactBody
                } else {
                    fullBody
                }
            case .manualCapture:
                manualCaptureBody
            case .practiceMock:
                practiceMockBody
            }
        }
        .padding(14)
        .frame(minWidth: 340, minHeight: 280, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(appState.settings.highContrastFloatingPanel ? .regularMaterial : .ultraThinMaterial)
                .opacity(effectiveOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(appState.settings.highContrastFloatingPanel ? 0.3 : 0.15), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .onAppear {
            setupEventMonitor()
        }
        .onDisappear {
            removeEventMonitor()
        }
    }

    private func setupEventMonitor() {
        removeEventMonitor() // Prevent duplicate monitor
        
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmdOpt = modifierFlags == [.command, .option]
            
            if isCmdOpt {
                if event.keyCode == 126 { // Up arrow
                    adjustOpacity(by: 0.05)
                    return nil // consume event
                } else if event.keyCode == 125 { // Down arrow
                    adjustOpacity(by: -0.05)
                    return nil // consume event
                }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            self.eventMonitor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusPill(title: activeStatusTitle, systemImage: "dot.radiowaves.left.and.right", tint: activeStatusTint)
            
            MicLevelIndicatorView(appState: appState, isMini: true)
            
            LLMProviderQuickSwitcherView(appState: appState, isCompact: true)
            Spacer()
            
            // Transparency controls
            HStack(spacing: 2) {
                Button {
                    adjustOpacity(by: -0.05)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("More Transparent (Cmd+Opt+Down)")
                
                Text(String(format: "%.0f%%", effectiveOpacity * 100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Button {
                    adjustOpacity(by: 0.05)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Less Transparent (Cmd+Opt+Up)")
            }
            .padding(.trailing, 4)

            Button {
                var next = appState.settings
                next.compactMode.toggle()
                appState.saveSettings(next)
            } label: {
                Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help(compact ? "Expand" : "Compact Mode")

            Button {
                appState.stopListening()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop Listening")
            .disabled(!appState.liveState.canStop)

            Button {
                appState.openMainWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Main Window")
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ollamaFallbackPanel
            
            if let question = appState.possibleQuestion ?? appState.lastDetectedQuestion {
                Text(question.questionText)
                    .font(.headline)
                    .lineLimit(3)
            } else {
                Text(appState.lastTranscriptSnippet.isEmpty ? "Listening for interviewer questions." : appState.lastTranscriptSnippet)
                    .font(.headline)
                    .lineLimit(3)
            }

            if let card = appState.currentSuggestion {
                Text(card.sayFirst)
                    .font(.callout.weight(.semibold))
                    .lineLimit(4)
            } else {
                Text(secondaryStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fullBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ollamaFallbackPanel
                transcriptSnippet
                detectedQuestion
                suggestion
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcriptSnippet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Current Audio", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(appState.lastTranscriptSnippet.isEmpty ? "Waiting for transcription..." : appState.lastTranscriptSnippet)
                .font(.callout)
                .lineLimit(4)
                .foregroundStyle(appState.lastTranscriptSnippet.isEmpty ? .secondary : .primary)
        }
        .padding(12)
        .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detectedQuestion: some View {
        if let possible = appState.possibleQuestion {
            VStack(alignment: .leading, spacing: 6) {
                Label("Possible question detected", systemImage: "questionmark.bubble")
                    .font(.headline)
                Text(possible.questionText)
                    .font(.callout)
                    .lineLimit(5)
                Text("Confidence \(Int(possible.confidence * 100))%. Use Answer Now in the main window if this should be answered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else if let question = appState.lastDetectedQuestion {
            VStack(alignment: .leading, spacing: 6) {
                Label("Detected Question", systemImage: "checkmark.bubble")
                    .font(.headline)
                Text(question.questionText)
                    .font(.callout)
                    .lineLimit(5)
                Text("\(question.intent.displayName) • \(Int(question.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var suggestion: some View {
        if let card = appState.currentSuggestion {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(card.strategy)
                        .font(.title3.weight(.bold))
                    Spacer()
                    if let confidence = card.confidence {
                        StatusPill(title: "\(Int(confidence * 100))%", systemImage: "gauge.medium", tint: confidence >= 0.75 ? .green : .orange)
                    }
                }

                Text(card.sayFirst)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                bulletSection("Key Points", items: card.keyPoints)
                bulletSection("Follow-up Ready", items: card.followUpReady)

                HStack(spacing: 8) {
                    if let latency = card.latencyMS {
                        StatusPill(title: "\(latency) ms", systemImage: "timer", tint: .secondary)
                    }
                    StatusPill(
                        title: card.isLocal ? "Local" : "Cloud",
                        systemImage: card.isLocal ? "desktopcomputer" : "cloud",
                        tint: card.isLocal ? .green : .blue
                    )
                }

                if let caution = card.caution, !caution.isEmpty {
                    Text(caution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("No suggestion yet", systemImage: "sparkles")
                    .font(.headline)
                Text(secondaryStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var secondaryStatusText: String {
        let mode = appState.settings.audioCaptureMode
        if mode == .microphoneOnly && AudioDeviceManager.shared.isUsingHeadphonesOrBluetooth {
            return "Headset mode warning: microphone captures you; interviewer audio requires System Audio capture mode."
        }
        switch appState.liveState {
        case .requestingPermission:
            return "Requesting microphone and speech recognition permissions."
        case .permissionDenied:
            return "Permission is blocked. Open the main window for recovery controls."
        case .detectingQuestion:
            if appState.activeRealtimeProvider?.kind == .ollamaLocal {
                return "Ollama is thinking (detecting question)..."
            }
            return "Checking whether the interviewer asked a complete question."
        case .generatingSuggestion:
            if appState.activeRealtimeProvider?.kind == .ollamaLocal {
                return "Ollama is thinking (generating suggestion)..."
            }
            return "Generating a concise suggestion card."
        case .listening, .transcribing:
            return "Automatic question detection is running."
        case .stopped:
            return "Listening has stopped."
        case .error(let message):
            return message
        default:
            return "Click Start Listening in the main window."
        }
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

    private var activeStatusTitle: String {
        if appState.isRecoveringAudioRoute {
            return "Reconnecting audio"
        }
        if appState.noAudioWarningVisible {
            if appState.audioRouteError?.contains("No microphone signal") == true {
                return "No input signal"
            }
            if appState.audioRouteError == "Audio input restored." {
                return "Restored"
            }
            return "Audio issue"
        }
        switch appState.liveState {
        case .listening, .transcribing:
            return "Listening"
        case .requestingPermission:
            return "Requesting access"
        case .permissionDenied:
            return "Permission blocked"
        case .detectingQuestion:
            return "Detecting..."
        case .generatingSuggestion:
            return "Generating..."
        case .stopped:
            return "Stopped"
        case .error:
            return "Error"
        default:
            return "Idle"
        }
    }

    private var activeStatusTint: Color {
        if appState.isRecoveringAudioRoute {
            return .orange
        }
        if appState.noAudioWarningVisible {
            if appState.audioRouteError == "Audio input restored." {
                return .green
            }
            return .red
        }
        switch appState.liveState {
        case .listening, .transcribing:
            return .green
        case .permissionDenied, .error:
            return .red
        case .generatingSuggestion, .detectingQuestion:
            return .blue
        default:
            return .secondary
        }
    }

    private func bulletSection(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items.prefix(4), id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                    Text(item)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var deviceBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Selected Mode and Status Dots
            HStack {
                Text("Mode: \(appState.settings.audioCaptureMode.displayName)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.settings.audioCaptureMode == .systemAudioOnly ? Color.secondary : (AudioEngineManager.shared.isEngineRunning ? Color.green : Color.red))
                            .frame(width: 5, height: 5)
                        Text(appState.settings.audioCaptureMode == .systemAudioOnly ? "Mic: Off" : "Mic: Active")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(systemAudio.isCapturing ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text("System: \(systemAudio.isCapturing ? "Active" : "Off")")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Render level meters directly in deviceBanner
            MicLevelIndicatorView(appState: appState, isMini: false)
                .padding(.vertical, 2)
            
            // Separate Input and Output Devices Display
            VStack(alignment: .leading, spacing: 4) {
                if appState.settings.audioCaptureMode != .systemAudioOnly {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Input: \(audioDeviceManager.currentInputDeviceName)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                        Text("Input Mic: Off")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("Output: \(audioDeviceManager.currentOutputDeviceName)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var ollamaFallbackPanel: some View {
        if appState.activeRealtimeProvider?.kind == .ollamaLocal, let lastFailed = appState.lastFailedTaskType {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ollama Failure", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                
                if let errorMsg = appState.errorMessage {
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                
                HStack(spacing: 8) {
                    Button {
                        appState.retryLastFailedAITask()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    if appState.providerConfigurations.contains(where: { $0.kind == .deepSeek }) {
                        Button {
                            appState.switchToDeepSeekFallback()
                        } label: {
                            Label("Use DeepSeek", systemImage: "cloud.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Button {
                        appState.selectedSection = .settings
                        appState.openMainWindow()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .help("Open Settings")
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Conditional Views
    
    private var manualCaptureBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Recording status indicator
                HStack {
                    Label(appState.manualCaptureState.displayName, 
                          systemImage: appState.manualCaptureState == .recording ? "record.circle.fill" : "hand.tap.fill")
                        .font(.headline)
                        .foregroundStyle(appState.manualCaptureState == .recording ? .red : .purple)
                    
                    Spacer()
                    
                    Text(formatDuration(appState.manualCaptureDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                
                // Volume Meter (recording only)
                if appState.manualCaptureState == .recording {
                    ProgressView(value: appState.manualCaptureLevel)
                        .progressViewStyle(.linear)
                }
                
                // Big Recording Buttons
                HStack(spacing: 8) {
                    if appState.manualCaptureState == .idle || 
                       appState.manualCaptureState == .transcriptReady || 
                       appState.manualCaptureState == .suggestionReady ||
                       caseError(appState.manualCaptureState) {
                        Button {
                            appState.startManualCapture()
                        } label: {
                            Label("Record", systemImage: "record.circle")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    
                    if appState.manualCaptureState == .recording {
                        Button {
                            appState.stopAndTranscribeManualCapture()
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    
                    if appState.manualCaptureState == .recording || 
                       appState.manualCaptureState == .transcribing || 
                       appState.manualCaptureState == .generatingSuggestion {
                        Button {
                            appState.cancelManualCapture()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if appState.manualCaptureState == .transcriptReady {
                        Button {
                            appState.sendManualCaptureToAI()
                        } label: {
                            Label("Ask AI", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                    
                    if appState.manualCaptureState == .suggestionReady {
                        Button {
                            appState.retryManualCapture()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                // Live/Partial or final transcript collapsible section
                if !appState.manualCaptureTranscript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transcript Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        TextEditor(text: $appState.manualCaptureTranscript)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 100)
                            .cornerRadius(4)
                            .disabled(appState.manualCaptureState == .generatingSuggestion)
                        
                        if appState.manualCaptureState == .transcriptReady || appState.manualCaptureState == .suggestionReady {
                            HStack {
                                Button("Regenerate") {
                                    appState.regenerateManualSuggestion()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                
                // Result card
                if let card = appState.manualCaptureSuggestion {
                    suggestionCardPanel(card)
                } else if appState.manualCaptureState == .generatingSuggestion {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(appState.activeRealtimeProvider?.kind == .ollamaLocal ? "Ollama is thinking..." : "Generating answer...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
            }
        }
    }
    
    private var practiceMockBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Practice Questions")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                TextField("Type test question and hit enter", text: $mockQuestionText, onCommit: {
                    guard !mockQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    appState.submitMockQuestion(mockQuestionText)
                    mockQuestionText = ""
                })
                .textFieldStyle(.roundedBorder)
                
                if let card = appState.currentSuggestion {
                    suggestionCardPanel(card)
                } else {
                    Text("Type a question and press enter above to test the full pipeline in practice mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private func suggestionCardPanel(_ card: SuggestionCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.strategy)
                    .font(.title3.weight(.bold))
                Spacer()
                if let confidence = card.confidence {
                    StatusPill(title: "\(Int(confidence * 100))%", systemImage: "gauge.medium", tint: confidence >= 0.75 ? .green : .orange)
                }
            }

            Text(card.sayFirst)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            bulletSection("Key Points", items: card.keyPoints)
            bulletSection("Follow-up Ready", items: card.followUpReady)

            HStack(spacing: 8) {
                if let latency = card.latencyMS {
                    StatusPill(title: "\(latency) ms", systemImage: "timer", tint: .secondary)
                }
                StatusPill(
                    title: card.isLocal ? "Local" : "Cloud",
                    systemImage: card.isLocal ? "desktopcomputer" : "cloud",
                    tint: card.isLocal ? .green : .blue
                )
            }

            if let caution = card.caution, !caution.isEmpty {
                Text(caution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(appState.settings.highContrastFloatingPanel ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func formatDuration(_ duration: Double) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private func caseError(_ state: ManualCaptureState) -> Bool {
        if case .error = state { return true }
        return false
    }
}
