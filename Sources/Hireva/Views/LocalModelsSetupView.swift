import AppKit
import SwiftUI

private enum LocalSetupStep: String, CaseIterable, Identifiable {
    case welcome
    case permissions
    case models
    case provider
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .models: return "Model Setup"
        case .provider: return "Provider Setup"
        case .ready: return "Ready"
        }
    }
}

struct LocalModelsSetupView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: LocalModelsSetupViewModel
    @ObservedObject private var settingsState: SettingsState
    @State private var selectedStep: LocalSetupStep = .welcome
    @State private var permissionsSkipped = false
    init(appState: AppState) {
        self.appState = appState
        viewModel = appState.localModelsSetupState
        settingsState = appState.settingsState
    }

    private var selectedQwenModel: String { settingsState.selectedQwenModelName }

    var qwenModelSelection: Binding<String> {
        Binding(get: { settingsState.selectedQwenModelName }, set: { settingsState.setSelectedQwenModelName($0) })
    }

    var answerProviderSelection: Binding<String> {
        Binding(get: { appState.selectedAnswerProviderMode.rawValue },
            set: { settingsState.setSelectedAnswerProviderMode(AnswerProviderMode(storedValue: $0),
                currentMode: appState.selectedAnswerProviderMode) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stepPicker

                switch selectedStep {
                case .welcome:
                    welcomeSection
                case .permissions:
                    permissionsSection
                case .models:
                    modelsSection
                case .provider:
                    providerSection
                case .ready:
                    readySection
                }

                if let error = viewModel.lastError, !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .navigationTitle("Setup & Local Models")
        .task { await refreshReadinessForSetup() }
    }

    // One actual setup action freezes the model outcome and migration ticket.
    // The view does not publish readiness from a later mutable model snapshot.
    func refreshReadinessForSetup() async {
        appState.refreshPermissions()
        let ticket = settingsState.makeLocalQwenMigrationTicket()
        guard let snapshot = await viewModel.refreshSnapshot(qwenModel: selectedQwenModel),
              !Task.isCancelled, viewModel.isCurrent(snapshot), let ticket else { return }
        settingsState.applyLocalQwenMigrationReadiness(snapshot.qwenHealth, ticket: ticket)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup & Local Models")
                .font(.largeTitle.weight(.bold))
            Text("Prepare the recommended local Qwen answer model and local Parakeet transcription path with truthful readiness checks.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var stepPicker: some View {
        Picker("Setup step", selection: $selectedStep) {
            ForEach(LocalSetupStep.allCases) { step in
                Text(step.title).tag(step)
            }
        }
        .pickerStyle(.segmented)
    }

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            setupCard(
                icon: "checklist",
                title: "Local-first setup, optional by default",
                status: "Local Qwen is primary; Apple Speech is the default ASR.",
                tint: .blue
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local Qwen is the default answer provider. Apple Speech is the default transcription provider; Local Parakeet remains experimental until both model files and runtime are ready.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            selectedStep = .permissions
                        } label: {
                            Label("Start Setup", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            selectedStep = .models
                        } label: {
                            Label("Open Models", systemImage: "square.stack.3d.up")
                        }
                    }
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionCard(
                title: "Microphone",
                detail: appState.microphoneRequired ? "Required for candidate microphone capture." : "Not required for the selected capture mode.",
                granted: !appState.microphoneRequired || appState.microphonePermissionState == .authorized,
                actionTitle: appState.microphonePermissionState == .notDetermined ? "Grant Permission" : "Open Settings",
                action: { appState.requestMicrophonePermission() }
            )
            permissionCard(
                title: "Speech Recognition",
                detail: speechRecognitionRequiredForSetup ? "Required by Apple Speech transcription." : "Not required for the selected ASR provider.",
                granted: !speechRecognitionRequiredForSetup || appState.permissionSnapshot.speechRecognition == .granted,
                actionTitle: appState.permissionSnapshot.speechRecognition == .notDetermined ? "Grant Permission" : "Open Settings",
                action: { appState.requestSpeechPermission() }
            )
            permissionCard(
                title: "System Audio",
                detail: appState.systemAudioRequired ? "Required to capture interviewer audio from calls." : "Not required for the selected capture mode.",
                granted: !appState.systemAudioRequired || appState.systemAudioPermissionState == .granted,
                actionTitle: "Open Screen Audio Settings",
                action: { appState.requestScreenRecordingPermission() }
            )

            HStack {
                Button {
                    appState.refreshPermissions()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    permissionsSkipped = true
                    selectedStep = .models
                } label: {
                    Label("Skip for now", systemImage: "forward")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    selectedStep = .models
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!permissionPolicy.canFinishSetup)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupCard(
                icon: "square.and.arrow.down",
                title: "Recommended Local Setup",
                status: "Parakeet TDT 0.6B + Qwen3.5 4B",
                tint: .purple
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticRow("Recommended ASR", viewModel.transcriptionModel.displayName)
                    diagnosticRow("Recommended LLM", LocalModelDescriptor.defaultQwenLocalLLM.id)
                    diagnosticRow("Runtime defaults", "Local Qwen primary, Apple Speech ASR")
                    Button {
                        viewModel.installRecommended(qwenModel: selectedQwenModel)
                    } label: {
                        Label("Install Recommended Local Models", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isInstallingRecommended)
                }
            }
            localModelCard
            qwenModelCard
            HStack {
                Button {
                    selectedStep = .provider
                } label: {
                    Label("Provider Setup", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    setAnswerProviderMode(.deepSeekPrimary)
                    selectedStep = .provider
                } label: {
                    Label("Continue with DeepSeek only", systemImage: "cloud")
                }
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupCard(
                icon: "bolt.horizontal.circle",
                title: "Answer Provider",
                status: providerMode.displayName,
                tint: .indigo
            ) {
                Picker("Answer Provider", selection: answerProviderSelection) {
                    ForEach(AnswerProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Button {
                        setAnswerProviderMode(.deepSeekPrimary)
                    } label: {
                        Label("Use DeepSeek", systemImage: "cloud")
                    }
                    .buttonStyle(.bordered)
                    .tint(providerMode == .deepSeekPrimary ? .accentColor : .secondary)

                    Button {
                        setAnswerProviderMode(.deepSeekWithLocalQwenFallback)
                    } label: {
                        Label("Enable Qwen Fallback", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .tint(providerMode == .deepSeekWithLocalQwenFallback ? .accentColor : .secondary)
                    .disabled(!viewModel.qwenHealth.isReady)

                    Button {
                        setAnswerProviderMode(.localQwenPrimary)
                    } label: {
                        Label("Use Qwen Primary", systemImage: "cpu")
                    }
                    .buttonStyle(.bordered)
                    .tint(providerMode == .localQwenPrimary ? .accentColor : .secondary)
                    .disabled(!viewModel.qwenHealth.isReady)
                }

                Divider()

                diagnosticRow("DeepSeek configured", settingsState.hasAPIKey ? "true" : "false")
                diagnosticRow("Local Qwen ready", viewModel.qwenHealth.isReady ? "true" : "false")
                diagnosticRow("Selected Qwen model", selectedQwenModel)
                diagnosticRow("Qwen selection status", viewModel.qwenHealth.isReady ? "enabled" : "model_not_ready")
                diagnosticRow("Local source", AnswerSource.ollamaQwen.rawValue)
                diagnosticRow("Default answer provider", AnswerProviderMode.localQwenPrimary.rawValue)

                HStack {
                    Button {
                        settingsState.testDeepSeekConnection()
                    } label: {
                        Label("Test DeepSeek", systemImage: "network")
                    }
                    .disabled(!settingsState.hasAPIKey || settingsState.isTestingConnection)

                    Button {
                        viewModel.requestRefresh(qwenModel: selectedQwenModel)
                    } label: {
                        Label("Refresh Local Qwen", systemImage: "arrow.clockwise")
                    }
                }
            }

            setupCard(
                icon: "waveform.badge.magnifyingglass",
                title: "Transcription Provider",
                status: settingsState.selectedASRProviderID.displayName,
                tint: .teal
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    diagnosticRow("Selected default", ASRProviderID.appleSpeech.displayName)
                    diagnosticRow("Recommended local ASR", ASRProviderID.localParakeet.displayName)
                    diagnosticRow("Parakeet model status", viewModel.transcriptionStatus.displayName)
                    diagnosticRow("Parakeet runtime status", viewModel.parakeetRuntimeStatusText)
                    diagnosticRow("Selected ASR source", settingsState.selectedASRProviderID.source.rawValue)
                    diagnosticRow("Active ASR provider", appState.activeASRProviderDisplayName)
                    HStack {
                        Button {
                            settingsState.setSelectedASRProvider(.appleSpeech)
                        } label: {
                            Label("Use Apple Speech", systemImage: "apple.logo")
                        }
                        .buttonStyle(.bordered)
                        .tint(settingsState.selectedASRProviderID == .appleSpeech ? .accentColor : .secondary)

                        Button {
                            if viewModel.canEnableParakeet() {
                                settingsState.setSelectedASRProvider(.localParakeet)
                            } else if !viewModel.transcriptionStatus.isReady {
                                viewModel.lastError = "Parakeet model_not_ready. Install the model before enabling Local Parakeet."
                            } else {
                                viewModel.lastError = "parakeet_native_runtime_unavailable. Repair the bundled native helper before enabling it."
                            }
                        } label: {
                            Label("Enable Local Parakeet", systemImage: "waveform.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .tint(settingsState.selectedASRProviderID == .localParakeet ? .accentColor : .secondary)
                        .disabled(!viewModel.canEnableParakeet())
                    }
                }
                Text("Apple Speech is the default. Local Parakeet is experimental and final-only, and activates only after the model and bundled native helper pass readiness checks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Use selected opportunity skills for Parakeet recognition", isOn: Binding(
                    get: { settingsState.parakeetContextBiasEnabled },
                    set: { settingsState.setParakeetContextBiasEnabled($0) }))
                Text("Optional: uses up to 32 short English skill terms at the next start. Context bias can also cause recognition mistakes; leave it off for ordinary speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                selectedStep = .ready
            } label: {
                Label("Review Ready State", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var readySection: some View {
        setupCard(
            icon: readinessOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            title: readinessOK ? "You're ready to start Hireva" : "Setup still needs attention",
            status: readinessOK ? "Required permissions are satisfied." : "Fix permissions or continue with safe defaults.",
            tint: readinessOK ? .green : .orange
        ) {
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow("Answer mode", providerMode.displayName)
                diagnosticRow("Selected ASR mode", settingsState.selectedASRProviderID.displayName)
                diagnosticRow("Active ASR mode", appState.activeASRProviderDisplayName)
                diagnosticRow("Latest transcript ASR source", appState.latestTranscriptASRSource)
                diagnosticRow("Transcription model", viewModel.transcriptionStatus.displayName)
                diagnosticRow("Ollama Qwen", viewModel.qwenHealth.statusText)
                diagnosticRow("Final visible local source", AnswerSource.ollamaQwen.rawValue)
                diagnosticRow("DeepSeek source", AnswerSource.deepseekStream.rawValue)

                HStack {
                    Button {
                        appState.selectSection(.home)
                    } label: {
                        Label("Open Interview", systemImage: "house")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        selectedStep = .permissions
                    } label: {
                        Label("Review Permissions", systemImage: "hand.raised")
                    }
                }
            }
        }
    }

    private var localModelCard: some View {
        setupCard(
            icon: "mic.badge.plus",
            title: "Transcription Engine",
            status: viewModel.transcriptionStatus.displayName,
            tint: viewModel.transcriptionStatus.isReady ? .green : .blue
        ) {
            modelMetrics(
                modelName: viewModel.transcriptionModel.displayName,
                size: viewModel.transcriptionModel.sizeBytes,
                status: viewModel.transcriptionStatus,
                progress: viewModel.transcriptionProgress
            )
            diagnosticRow("Model id", viewModel.transcriptionModel.id)
            diagnosticRow("Model path", viewModel.modelPath(for: viewModel.transcriptionModel).path)
            diagnosticRow("ASR source when active", ASRSource.localParakeetASR.rawValue)
            diagnosticRow("Runtime integration", viewModel.parakeetRuntimeStatusText)
            HStack {
                Button {
                    viewModel.downloadTranscriptionModel()
                } label: {
                    Label(buttonTitle(for: viewModel.transcriptionStatus), systemImage: "arrow.down.circle")
                }
                .disabled(viewModel.isDownloadingTranscription || viewModel.transcriptionStatus.isReady || viewModel.transcriptionModel.downloadURL == nil)

                Button {
                    copy(viewModel.modelPath(for: viewModel.transcriptionModel).path)
                } label: {
                    Label("Copy Model Folder", systemImage: "doc.on.doc")
                }

                Button {
                    viewModel.deleteTranscriptionModel()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!viewModel.transcriptionStatus.isReady)
            }
        }
    }

    private var qwenModelCard: some View {
        setupCard(
            icon: "sparkles",
            title: "Local Answer Model",
            status: viewModel.qwenHealth.statusText,
            tint: viewModel.qwenHealth.isReady ? .green : .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Qwen model name", text: qwenModelSelection)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.requestRefresh(qwenModel: selectedQwenModel)
                    }
                diagnosticRow("Ollama running", viewModel.qwenHealth.ollamaRunning ? "true" : "false")
                diagnosticRow("Model installed", viewModel.qwenHealth.modelInstalled ? "true" : "false")
                diagnosticRow("Provider source", AnswerSource.ollamaQwen.rawValue)
                if let error = viewModel.qwenHealth.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let progress = viewModel.qwenProgress {
                    progressBlock(progress)
                }
                HStack {
                    Button {
                        viewModel.requestRefresh(qwenModel: selectedQwenModel)
                    } label: {
                        Label("Check Ollama", systemImage: "stethoscope")
                    }
                    Button {
                        viewModel.pullQwen(modelName: selectedQwenModel)
                    } label: {
                        Label("Pull Model", systemImage: "arrow.down.circle")
                    }
                    .disabled(!viewModel.qwenHealth.ollamaRunning || viewModel.isPullingQwen)
                    Button {
                        copy("ollama pull \(selectedQwenModel)")
                    } label: {
                        Label("Copy Pull Command", systemImage: "doc.on.doc")
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                    } label: {
                        Label("Get Ollama", systemImage: "safari")
                    }
                }
            }
        }
    }

    private var permissionPolicy: SetupPermissionPolicy {
        SetupPermissionPolicy(
            microphone: (!appState.microphoneRequired || appState.microphonePermissionState == .authorized) ? .granted : .notGranted,
            speechRecognition: (!speechRecognitionRequiredForSetup || appState.permissionSnapshot.speechRecognition == .granted) ? .granted : .notGranted,
            systemAudio: (!appState.systemAudioRequired || appState.systemAudioPermissionState == .granted) ? .granted : .notGranted,
            screenRecording: .notRequired,
            permissionsExplicitlySkipped: permissionsSkipped
        )
    }

    private var readinessOK: Bool {
        permissionPolicy.canFinishSetup
    }

    private var speechRecognitionRequiredForSetup: Bool {
        appState.speechRecognitionRequired
    }

    private var providerMode: AnswerProviderMode {
        appState.selectedAnswerProviderMode
    }

    private func setAnswerProviderMode(_ mode: AnswerProviderMode) {
        settingsState.setSelectedAnswerProviderMode(mode, currentMode: appState.selectedAnswerProviderMode)
    }

    private func permissionCard(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        setupCard(
            icon: granted ? "checkmark.circle.fill" : "hand.raised",
            title: title,
            status: granted ? "Access Granted" : "Not Granted",
            tint: granted ? .green : .orange
        ) {
            HStack(alignment: .center, spacing: 12) {
                Text(detail)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: action) {
                    Label(actionTitle, systemImage: granted ? "gearshape" : "plus.circle")
                }
                .disabled(granted)
            }
        }
    }

    private func setupCard<Content: View>(
        icon: String,
        title: String,
        status: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(status)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(tint)
                }
                Spacer()
            }
            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func modelMetrics(
        modelName: String,
        size: Int64?,
        status: LocalModelStatus,
        progress: ModelDownloadProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            diagnosticRow("Model", modelName)
            diagnosticRow("Size", size.map(formatBytes) ?? "Configured externally")
            diagnosticRow("Status", status.displayName)
            if let progress {
                progressBlock(progress)
            } else if case let .downloading(value, downloaded, total, speed) = status {
                progressBlock(ModelDownloadProgress(
                    modelID: modelName,
                    progress: value,
                    downloadedBytes: downloaded,
                    totalBytes: total,
                    speedBytesPerSecond: speed,
                    statusMessage: "Downloading"
                ))
            }
        }
    }

    private func progressBlock(_ progress: ModelDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.progress)
            HStack {
                Text("\(formatBytes(progress.downloadedBytes)) / \(progress.totalBytes.map(formatBytes) ?? "Unknown")")
                Spacer()
                if let speed = progress.speedBytesPerSecond {
                    Text("\(formatBytes(Int64(speed)))/s")
                }
                Text("\(Int(progress.progress * 100))%")
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func buttonTitle(for status: LocalModelStatus) -> String {
        switch status {
        case .failed:
            return "Retry"
        default:
            return "Download"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
