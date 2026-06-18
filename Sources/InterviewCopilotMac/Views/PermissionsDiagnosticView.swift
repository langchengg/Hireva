import SwiftUI

@MainActor
struct PermissionsDiagnosticView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var micDiagnostics: MicrophoneDiagnosticsService
    @ObservedObject private var systemAudio = ScreenCaptureKitSystemAudioCaptureService.shared
    @State private var codeSigningStatusText: String = "Loading…"
    @State private var refreshTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var refreshTrigger = UUID()

    init(appState: AppState) {
        self.appState = appState
        self._micDiagnostics = ObservedObject(wrappedValue: appState.microphoneDiagnostics)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissionGrid
                pipelineDiagnosticsCard
                screenRecordingRestartBanner
                microphoneTestCard
                systemAudioTestCard
                systemAudioPipelineDiagnosticsCard
                audioDeviceConfigPanel
                appIdentityDiagnosticsCard
                troubleshooting
                shellDiagnosticsCard
                tccResetInstructionsCard
                deviceSwitchingChecklist
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions / Audio Diagnostics")
                .font(.largeTitle.weight(.bold))
            Text("Use this screen to confirm macOS permission state and verify that microphone and system audio streams are producing visual levels before starting an interview.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                permissionCard(
                    title: "Microphone",
                    status: appState.microphonePermissionState.displayName,
                    icon: "mic",
                    tint: appState.microphonePermissionState == .authorized ? .green : .orange,
                    actionTitle: "Request",
                    action: { appState.requestMicrophonePermission() }
                )
                permissionCard(
                    title: "Speech Recognition",
                    status: appState.permissionSnapshot.speechRecognition.displayName,
                    icon: "text.bubble",
                    tint: appState.permissionSnapshot.speechRecognition == .granted ? .green : .orange,
                    actionTitle: "Request",
                    action: { appState.requestSpeechPermission() }
                )
            }
            GridRow {
                permissionCard(
                    title: "Screen & System Audio Recording",
                    status: appState.permissionSnapshot.screenRecording.displayName,
                    icon: "rectangle.on.rectangle",
                    tint: appState.permissionSnapshot.screenRecording == .granted ? .green : .orange,
                    actionTitle: "Request",
                    action: { appState.requestScreenRecordingPermission() }
                )
                permissionCard(
                    title: "System Audio Capture Status",
                    status: appState.permissionSnapshot.systemAudioCapture.displayName,
                    icon: "speaker.wave.2",
                    tint: appState.permissionSnapshot.systemAudioCapture == .granted ? .green : .orange,
                    actionTitle: "Open Settings",
                    action: { appState.openSystemPrivacySettings() }
                )
            }
        }
    }

    private var microphoneTestCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Microphone Test (Candidate)", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                StatusPill(
                    title: micDiagnostics.isRunning ? "Mic Active" : "Mic Stopped",
                    systemImage: micDiagnostics.isRunning ? "play.circle.fill" : "stop.circle",
                    tint: micDiagnostics.isRunning ? .green : .secondary
                )
            }

            diagnosticRow("Microphone permission", appState.microphonePermissionState.displayName)
            diagnosticRow("Speech recognition", appState.permissionSnapshot.speechRecognition.displayName)
            diagnosticRow("Selected input", micDiagnostics.selectedInputDeviceName)
            diagnosticRow("Last transcription", appState.displayTranscriptText.isEmpty ? "None" : appState.displayTranscriptText)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Input Level")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "RMS %.4f  •  %.1f dB", micDiagnostics.rmsLevel, micDiagnostics.decibels))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: micDiagnostics.normalizedLevel)
                    .progressViewStyle(.linear)
            }

            if let error = micDiagnostics.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if appState.microphonePermissionState == .denied || appState.microphonePermissionState == .restricted {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Open System Settings → Privacy & Security → Microphone")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    Text("Microphone permission has been denied or restricted. macOS will not show the permission prompt again. You must enable it manually in macOS System Settings and then relaunch/restart the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    appState.requestMicrophonePermission()
                } label: {
                    Label("Request Microphone Permission", systemImage: "mic.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    appState.refreshPermissions()
                    if appState.microphonePermissionState == .authorized {
                        micDiagnostics.startMicTest()
                    } else {
                        appState.requestMicrophonePermission()
                    }
                } label: {
                    Label("Start Mic Test", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(micDiagnostics.isRunning)

                Button {
                    micDiagnostics.stopMicTest()
                } label: {
                    Label("Stop Mic Test", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!micDiagnostics.isRunning)

                Button {
                    appState.restartAudioInput()
                } label: {
                    Label("Restart Audio Input", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .help("Rebuild input tap and restart the capture engine dynamically.")

                Spacer()

                Button {
                    appState.openMicrophonePrivacySettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var systemAudioTestCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("System Audio Test (Interviewer / Chrome)", systemImage: "speaker.wave.2.bubble")
                    .font(.headline)
                Spacer()
                StatusPill(
                    title: systemAudio.isCapturing ? "Sys Capture Active" : "Sys Capture Stopped",
                    systemImage: systemAudio.isCapturing ? "play.circle.fill" : "stop.circle",
                    tint: systemAudio.isCapturing ? .blue : .secondary
                )
            }

            diagnosticRow("Screen Recording permission", appState.permissionSnapshot.screenRecording.displayName)
            diagnosticRow("System Audio permission", appState.permissionSnapshot.systemAudioCapture.displayName)
            diagnosticRow("Capture Status", systemAudio.isCapturing ? "Running" : "Idle")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Capture Level")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "RMS %.4f  •  %.1f dB", systemAudio.rmsLevel, systemAudio.decibels))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: systemAudio.normalizedLevel)
                    .progressViewStyle(.linear)
            }

            if let error = systemAudio.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    appState.requestScreenRecordingPermission()
                } label: {
                    Label("Request Permission", systemImage: "rectangle.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    appState.refreshPermissions()
                    if appState.permissionSnapshot.screenRecording == .granted {
                        Task {
                            try? await systemAudio.startSystemAudioCapture()
                        }
                    } else {
                        appState.requestScreenRecordingPermission()
                    }
                } label: {
                    Label("Start System Test", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(systemAudio.isCapturing)

                Button {
                    systemAudio.stopSystemAudioCapture()
                } label: {
                    Label("Stop System Test", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!systemAudio.isCapturing)

                Spacer()

                Button {
                    appState.openSystemPrivacySettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Troubleshooting tips", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text("• Microphone: Verify the selected input device in System Settings -> Sound.\n• System Audio: Ensure Screen & System Audio Recording permission is granted and you are playing audio (e.g. YouTube in Chrome/Safari) for the meter to move.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceSwitchingChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio Device Switching Test Checklist", systemImage: "checklist")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                checklistStep(1, "Start Listening using built-in Mac microphone.")
                checklistStep(2, "Speak and confirm mic level moves.")
                checklistStep(3, "Switch macOS input device to Bluetooth headset.")
                checklistStep(4, "Confirm UI shows “Audio device changed / reconnecting”.")
                checklistStep(5, "Speak into Bluetooth headset.")
                checklistStep(6, "Confirm mic level moves and transcription resumes.")
                checklistStep(7, "Switch input device back to Mac microphone.")
                checklistStep(8, "Confirm audio recovers again.")
                checklistStep(9, "Confirm app does not crash.")
                checklistStep(10, "Confirm no duplicate input taps are installed.")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var pipelineDiagnosticsCard: some View {
        let _ = refreshTrigger
        let captureMode = appState.settings.audioCaptureMode
        let micRequired = appState.microphoneRequired
        let sysRequired = appState.systemAudioRequired
        let reason = appState.streamNotRunningReason
        
        return VStack(alignment: .leading, spacing: 14) {
            Label("Dual Stream ASR Diagnostics", systemImage: "bolt.horizontal.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.purple)
            
            Divider()
            
            HStack(alignment: .top, spacing: 16) {
                // Microphone Stream Status Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Microphone (Candidate)")
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Capture Running")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micCaptureRunning ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.micCaptureRunning ? .green : .secondary)
                        }
                        GridRow {
                            Text("Buffer Count")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(appState.micBufferCount)")
                                .font(.caption.monospacedDigit())
                        }
                        GridRow {
                            Text("Last Buffer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let lastBuffer = appState.micLastBufferTimestamp {
                                Text(formatTime(lastBuffer))
                                    .font(.caption.monospacedDigit())
                            } else {
                                Text("Never")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            Text("Level (dBFS)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f dB", appState.micLevelDBFS))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(appState.micLevelDBFS > -50 ? .green : .secondary)
                        }
                        GridRow {
                            Text("ASR Request Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micASRRequestActive ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.micASRRequestActive ? .green : .secondary)
                        }
                        GridRow {
                            Text("ASR Task Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micASRTaskActive ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.micASRTaskActive ? .green : .secondary)
                        }
                        GridRow {
                            Text("Session ID")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micSessionID)
                                .font(.caption)
                        }
                        GridRow {
                            Text("Last Partial")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micLastPartialTranscript.isEmpty ? "None" : "\"\(appState.micLastPartialTranscript)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Last Final Time")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let lastFinal = appState.micLastFinalTranscript {
                                Text(formatTime(lastFinal))
                                    .font(.caption.monospacedDigit())
                            } else {
                                Text("None")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            Text("Last Error")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micLastError ?? "None")
                                .font(.caption)
                                .foregroundStyle(appState.micLastError != nil ? .red : .secondary)
                        }
                        GridRow {
                            Text("Quality Last Partial")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micLastPartialTranscriptQuality.isEmpty ? "None" : "\"\(appState.micLastPartialTranscriptQuality)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Quality Last Final")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micLastFinalTranscriptQuality.isEmpty ? "None" : "\"\(appState.micLastFinalTranscriptQuality)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Best Transcript Used")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micBestTranscriptUsed.isEmpty ? "None" : "\"\(appState.micBestTranscriptUsed)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Finalization Reason")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.micFinalizationReason.isEmpty ? "None" : appState.micFinalizationReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // System Audio Stream Status Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("System Audio (Interviewer)")
                        .font(.headline)
                        .foregroundStyle(.blue)
                    
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Capture Running")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemCaptureRunning ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.systemCaptureRunning ? .green : .secondary)
                        }
                        GridRow {
                            Text("Buffer Count")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(appState.systemBufferCount)")
                                .font(.caption.monospacedDigit())
                        }
                        GridRow {
                            Text("Last Buffer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let lastBuffer = appState.systemLastBufferTimestamp {
                                Text(formatTime(lastBuffer))
                                    .font(.caption.monospacedDigit())
                            } else {
                                Text("Never")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            Text("Level (dBFS)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f dB", appState.systemLevelDBFS))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(appState.systemLevelDBFS > -50 ? .blue : .secondary)
                        }
                        GridRow {
                            Text("ASR Request Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemASRRequestActive ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.systemASRRequestActive ? .green : .secondary)
                        }
                        GridRow {
                            Text("ASR Task Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemASRTaskActive ? "True" : "False")
                                .font(.caption)
                                .foregroundStyle(appState.systemASRTaskActive ? .green : .secondary)
                        }
                        GridRow {
                            Text("Session ID")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemSessionID)
                                .font(.caption)
                        }
                        GridRow {
                            Text("Last Partial")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemLastPartialTranscript.isEmpty ? "None" : "\"\(appState.systemLastPartialTranscript)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Last Final Time")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let lastFinal = appState.systemLastFinalTranscript {
                                Text(formatTime(lastFinal))
                                    .font(.caption.monospacedDigit())
                            } else {
                                Text("None")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            Text("Last Error")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemLastError ?? "None")
                                .font(.caption)
                                .foregroundStyle(appState.systemLastError != nil ? .red : .secondary)
                        }
                        GridRow {
                            Text("Quality Last Partial")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemLastPartialTranscriptQuality.isEmpty ? "None" : "\"\(appState.systemLastPartialTranscriptQuality)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Quality Last Final")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemLastFinalTranscriptQuality.isEmpty ? "None" : "\"\(appState.systemLastFinalTranscriptQuality)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Best Transcript Used")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemBestTranscriptUsed.isEmpty ? "None" : "\"\(appState.systemBestTranscriptUsed)\"")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Finalization Reason")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.systemFinalizationReason.isEmpty ? "None" : appState.systemFinalizationReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            // Overall Status Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Selected Capture Mode:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(captureMode.displayName)
                        .font(.caption.weight(.bold))
                }
                
                HStack {
                    Text("Microphone Required:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(micRequired ? "True" : "False")
                        .font(.caption)
                        .foregroundStyle(micRequired ? .green : .secondary)
                    
                    Spacer().frame(width: 24)
                    
                    Text("System Audio Required:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(sysRequired ? "True" : "False")
                        .font(.caption)
                        .foregroundStyle(sysRequired ? .green : .secondary)
                }
                
                HStack {
                    Text("Two Sessions Active:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(appState.twoSessionsActive ? "True" : "False")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(appState.twoSessionsActive ? .green : .orange)
                }
                
                if let reason = reason {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.top, 4)
                }
                
                // Concurrency Limit Banner if twoSessionsActive fails when mode is dual
                if captureMode == .microphoneAndSystem && !appState.twoSessionsActive && appState.isAudioEngineRunning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Speech Concurrency Restriction Detected")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                            Text("Apple Speech could not run two concurrent transcription streams. Use System Audio Only / Manual Capture or configure an alternate ASR provider.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 6)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onReceive(refreshTimer) { _ in
            refreshTrigger = UUID()
        }
    }

    private func checklistStep(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num).")
                .font(.callout.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func permissionCard(title: String, status: String, icon: String, tint: Color, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var audioDeviceConfigPanel: some View {
        let manager = AudioDeviceManager.shared
        let warningText = manager.isUsingHeadphonesOrBluetooth ?
            "Headset mode: microphone captures you (Candidate); interviewer audio requires system/process audio capture. Microphone-only mode cannot reliably hear the interviewer if you are wearing headphones." :
            "Speaker mode: microphone may capture both you and interviewer with echo. Use system audio capture for reliable separation."
        
        return VStack(alignment: .leading, spacing: 10) {
            Label("Audio Route Configuration", systemImage: "speaker.wave.2.fill")
                .font(.headline)

            diagnosticRow("Input Device", AudioDeviceManager.shared.currentInputDeviceName)
            diagnosticRow("Output Device", AudioDeviceManager.shared.currentOutputDeviceName)
            
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
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var systemAudioPipelineDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("E2E System Audio & LLM Copilot Diagnostics", systemImage: "cpu.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.blue)
            
            Divider()
            
            // Group 1: System Audio Capture Diagnostics
            VStack(alignment: .leading, spacing: 8) {
                Text("1. System Audio Capture Diagnostics")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Selected Capture Mode")
                            .font(.caption.weight(.semibold))
                        Text(appState.settings.audioCaptureMode.displayName)
                            .font(.caption)
                    }
                    GridRow {
                        Text("Capture Running")
                            .font(.caption.weight(.semibold))
                        Text(systemAudio.isCapturing ? "True" : "False")
                            .font(.caption)
                            .foregroundStyle(systemAudio.isCapturing ? .green : .secondary)
                    }
                    GridRow {
                        Text("Sample Rate")
                            .font(.caption.weight(.semibold))
                        Text(String(format: "%.1f Hz", systemAudio.sampleRate))
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Channel Count")
                            .font(.caption.weight(.semibold))
                        Text("\(systemAudio.channelCount)")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Last Frame Capacity")
                            .font(.caption.weight(.semibold))
                        Text("\(systemAudio.lastBufferFrameCapacity)")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Last Buffer Received")
                            .font(.caption.weight(.semibold))
                        if let lastBuffer = systemAudio.lastBufferReceivedAt {
                            Text(formatTime(lastBuffer))
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("No buffers received yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Audio RMS / dBFS")
                            .font(.caption.weight(.semibold))
                        Text(String(format: "RMS %.4f  •  %.1f dB", systemAudio.rmsLevel, systemAudio.decibels))
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Total Buffers Received")
                            .font(.caption.weight(.semibold))
                        Text("\(systemAudio.totalBuffersReceived)")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Last Capture Error")
                            .font(.caption.weight(.semibold))
                        Text(systemAudio.lastError ?? "None")
                            .font(.caption)
                            .foregroundStyle(systemAudio.lastError != nil ? .red : .secondary)
                    }
                    GridRow {
                        Text("Permissions State")
                            .font(.caption.weight(.semibold))
                        Text("Screen: \(appState.permissionSnapshot.screenRecording.displayName)  •  System Audio: \(appState.permissionSnapshot.systemAudioCapture.displayName)")
                            .font(.caption)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            
            Divider()
            
            // Group 2: System Audio ASR Diagnostics
            VStack(alignment: .leading, spacing: 8) {
                Text("2. System Audio ASR Diagnostics")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("ASR Task Running")
                            .font(.caption.weight(.semibold))
                        Text(appState.systemASRTaskRunning ? "True" : "False")
                            .font(.caption)
                            .foregroundStyle(appState.systemASRTaskRunning ? .green : .secondary)
                    }
                    GridRow {
                        Text("Recognition Request Active")
                            .font(.caption.weight(.semibold))
                        Text(appState.recognitionRequestActive ? "True" : "False")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Recognition Task Active")
                            .font(.caption.weight(.semibold))
                        Text(appState.recognitionTaskActive ? "True" : "False")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Total Buffers Appended")
                            .font(.caption.weight(.semibold))
                        Text("\(appState.totalSystemAudioASRBuffersAppended)")
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Last ASR Partial Transcript")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastSystemAudioASRPartialTranscript.isEmpty ? "None" : "\"\(appState.lastSystemAudioASRPartialTranscript)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Last ASR Final Transcript")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastSystemAudioASRFinalTranscript.isEmpty ? "None" : "\"\(appState.lastSystemAudioASRFinalTranscript)\"")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    GridRow {
                        Text("Last ASR Error")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastSystemAudioASRError ?? "None")
                            .font(.caption)
                            .foregroundStyle(appState.lastSystemAudioASRError != nil ? .red : .secondary)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            
            Divider()
            
            // Group 3: Segment Attribution Diagnostics
            VStack(alignment: .leading, spacing: 8) {
                Text("3. Segment Attribution Diagnostics (Last 10)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                if appState.last10SegmentsDiagnostics.isEmpty {
                    Text("No transcript segments captured yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(appState.last10SegmentsDiagnostics.reversed()) { seg in
                                HStack(spacing: 12) {
                                    Text(formatTime(seg.createdAt))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    
                                    Text(seg.source.rawValue)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 4)
                                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    
                                    Text(seg.speaker.displayName)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 4)
                                        .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    
                                    Text("\"\(seg.textPreview)\"")
                                        .font(.caption)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    if seg.eligibleForAutoDetection {
                                        Text("Eligible")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .background(Color.green, in: RoundedRectangle(cornerRadius: 3))
                                    } else {
                                        Text("Skipped (\(seg.skipReason))")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .padding(.vertical, 2)
                                .frame(minWidth: 700, alignment: .leading)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 140)
                }
            }
            
            Divider()
            
            // Group 4: Question Detection Diagnostics
            VStack(alignment: .leading, spacing: 8) {
                Text("4. Question Detection Diagnostics")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Last Submitted Segment")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastDetectionSubmittedSegmentText.isEmpty ? "None" : "\"\(appState.lastDetectionSubmittedSegmentText)\"")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Submitted Source / Speaker")
                            .font(.caption.weight(.semibold))
                        Text("Source: \(appState.lastDetectionPromptSource)  •  Speaker: \(appState.lastDetectionPromptSpeaker)")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Detection Result")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastQuestionDetectionResult)
                            .font(.caption)
                    }
                    GridRow {
                        Text("Intent / Strategy")
                            .font(.caption.weight(.semibold))
                        Text("Intent: \(appState.lastDetectionReason.isEmpty ? "None" : appState.lastDetectionReason)  •  Strategy: \(appState.lastDetectionAnswerStrategy.isEmpty ? "None" : appState.lastDetectionAnswerStrategy)")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Confidence")
                            .font(.caption.weight(.semibold))
                        Text(String(format: "%.1f%%", appState.lastDetectionConfidence * 100))
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Should Trigger")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastDetectionShouldTrigger ? "Yes" : "No")
                            .font(.caption)
                            .foregroundStyle(appState.lastDetectionShouldTrigger ? .green : .secondary)
                    }
                    GridRow {
                        Text("Question Complete")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastDetectionQuestionComplete ? "Yes" : "No")
                            .font(.caption)
                    }
                    GridRow {
                        Text("Detection Skip Reason")
                            .font(.caption.weight(.semibold))
                        Text(appState.lastDetectionSkipReason.isEmpty ? "None" : appState.lastDetectionSkipReason)
                            .font(.caption)
                            .foregroundStyle(appState.lastDetectionSkipReason.isEmpty ? Color.secondary : Color.orange)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                
                if !appState.lastDetectionRawJSON.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Raw JSON Response")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(appState.lastDetectionRawJSON)
                                .font(.system(size: 9, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.15))
                        }
                        .frame(height: 80)
                        .cornerRadius(4)
                    }
                }
            }
            
            Divider()
            
            // Group 5: Suggestion Diagnostics
            VStack(alignment: .leading, spacing: 8) {
                Text("5. Suggestion Diagnostics")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Generation Active")
                            .font(.caption.weight(.semibold))
                        Text(appState.suggestionGenerationStarted ? "True" : "False")
                            .font(.caption)
                            .foregroundStyle(appState.suggestionGenerationStarted ? .blue : .secondary)
                    }
                    GridRow {
                        Text("AI Provider / Model")
                            .font(.caption.weight(.semibold))
                        Text(appState.suggestionProviderModel.isEmpty ? "None" : appState.suggestionProviderModel)
                            .font(.caption)
                    }
                    GridRow {
                        Text("API Latency")
                            .font(.caption.weight(.semibold))
                        if let latency = appState.currentSuggestion?.latencyFullCardMS {
                            Text("\(latency) ms")
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("None")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Floating Panel Updated")
                            .font(.caption.weight(.semibold))
                        Text(appState.floatingPanelUpdated ? "Yes" : "No")
                            .font(.caption)
                            .foregroundStyle(appState.floatingPanelUpdated ? .green : .secondary)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                
                if !appState.lastSuggestionCardJSON.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Suggestion Card JSON")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(appState.lastSuggestionCardJSON)
                                .font(.system(size: 9, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.15))
                        }
                        .frame(height: 100)
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Screen Recording Restart Banner

    @ViewBuilder
    private var screenRecordingRestartBanner: some View {
        switch appState.systemAudioPermissionState {
        case .granted:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen & System Audio Recording")
                        .font(.headline)
                    Text("Permission granted. System audio capture and SCK probes are completely operational.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.3), lineWidth: 1))
            
        case .restartLikely:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Restart Required")
                            .font(.headline)
                        Text("macOS requires quitting and reopening the app before Screen & System Audio Recording takes effect.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        appState.permissionService.openScreenRecordingSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.refreshPermissions()
                    } label: {
                        Label("Refresh Permissions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit App Now", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Spacer()
                }

                Text("After toggling the permission ON in Settings, click \"Quit App Now\" and reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            
        case .identityMismatch:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Application Identity Mismatch Suspected")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("You may be running a different build, raw executable, or an unsigned copy than the registered app in System Settings. macOS will block screen capturing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                HStack(spacing: 12) {
                    Button {
                        appState.permissionService.openScreenRecordingSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.refreshPermissions()
                    } label: {
                        Label("Refresh Permissions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                }
                
                Text("Verify you are running from a signed bundle inside 'dist/InterviewCopilotMac.app'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
            
        case .permissionMissing:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.and.paperclip")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording Permission Required")
                            .font(.headline)
                        Text("System preflight and ScreenCaptureKit probes both failed. Enable Screen & System Audio Recording in macOS System Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("💡 If permission is already enabled in System Settings, macOS likely does not recognize this build due to an unstable ad-hoc signature.")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("To resolve: rebuild with a stable Apple Development signing identity, then remove (using the '-' button) and re-add the app permission in System Settings once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 12) {
                    Button {
                        appState.permissionService.openScreenRecordingSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.refreshPermissions()
                    } label: {
                        Label("Refresh Permissions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding(18)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            
        case .shareableContentProbeFailed(let err):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shareable Content Probe Failed")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("ScreenCaptureKit failed to fetch displays: \(err)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("💡 If permission is already enabled in System Settings, macOS likely does not recognize this build due to an unstable ad-hoc signature.")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("To resolve: rebuild with a stable Apple Development signing identity, then remove (using the '-' button) and re-add the app permission in System Settings once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 12) {
                    Button {
                        appState.permissionService.openScreenRecordingSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.refreshPermissions()
                    } label: {
                        Label("Refresh Permissions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding(18)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
            
        case .streamAudioProbeFailed(let err):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stream Audio Probe Failed")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("Lightweight audio stream failed to tap samples: \(err)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("💡 If permission is already enabled in System Settings, macOS likely does not recognize this build due to an unstable ad-hoc signature.")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("To resolve: rebuild with a stable Apple Development signing identity, then remove (using the '-' button) and re-add the app permission in System Settings once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 12) {
                    Button {
                        appState.permissionService.openScreenRecordingSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        appState.refreshPermissions()
                    } label: {
                        Label("Refresh Permissions", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding(18)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: - App Identity Diagnostics

    private var appIdentityDiagnosticsCard: some View {
        let ps = appState.permissionService
        let expectedBundleID = "com.langcheng.InterviewCopilotMac"
        let processPath = CommandLine.arguments.first ?? "Unknown"
        let runningFromCorrectPath = !processPath.isEmpty && processPath.hasPrefix(Bundle.main.bundlePath)
        
        return VStack(alignment: .leading, spacing: 10) {
            Label("App Identity & Signing Diagnostics", systemImage: "person.badge.shield.checkmark")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Bundle Identifier")
                        .font(.caption.weight(.semibold))
                    Text(Bundle.main.bundleIdentifier ?? "None")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Expected Bundle ID")
                        .font(.caption.weight(.semibold))
                    Text(expectedBundleID)
                        .font(.caption.monospaced())
                }
                GridRow {
                    Text("Bundle ID Matches")
                        .font(.caption.weight(.semibold))
                    Text((Bundle.main.bundleIdentifier == expectedBundleID) ? "Yes ✅" : "No ⚠️")
                        .font(.caption)
                        .foregroundStyle(Bundle.main.bundleIdentifier == expectedBundleID ? .green : .red)
                }
                GridRow {
                    Text("Bundle Path")
                        .font(.caption.weight(.semibold))
                    Text(Bundle.main.bundlePath)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Executable URL")
                        .font(.caption.weight(.semibold))
                    Text(Bundle.main.executableURL?.absoluteString ?? "None")
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Process Name")
                        .font(.caption.weight(.semibold))
                    Text(ProcessInfo.processInfo.processName)
                        .font(.caption)
                }
                GridRow {
                    Text("CommandLine.arguments[0]")
                        .font(.caption.weight(.semibold))
                    Text(processPath)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Running From Bundle")
                        .font(.caption.weight(.semibold))
                    Text(ps.isRunningFromAppBundle ? "Yes ✅" : "No (Raw Binary) ⚠️")
                        .font(.caption)
                        .foregroundStyle(ps.isRunningFromAppBundle ? .green : .red)
                }
                GridRow {
                    Text("In Launched Bundle Path")
                        .font(.caption.weight(.semibold))
                    Text(runningFromCorrectPath ? "Yes ✅" : "No ⚠️")
                        .font(.caption)
                        .foregroundStyle(runningFromCorrectPath ? .green : .red)
                }
                GridRow {
                    Text("Code Signing Info")
                        .font(.caption.weight(.semibold))
                    Text(codeSigningStatusText)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(10)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            if codeSigningStatusText.contains("Signature=adhoc") || codeSigningStatusText.contains("adhoc") {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Warning: App is signed with an Ad-Hoc signature. macOS will reset TCC permissions on every rebuild/code change. To prevent this, build with a stable Apple Development signing identity.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            
            let processInAppBundle = processPath.contains(".app/Contents/MacOS/")
            if !processInAppBundle {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Warning: Process is running outside a valid .app bundle (e.g. raw executable from .build). macOS microphone and screen permissions will NOT work.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            if !runningFromCorrectPath && processInAppBundle {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("The app is not running from the signed .app bundle. macOS permissions may not match System Settings.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .task {
            codeSigningStatusText = await appState.permissionService.fetchCodeSigningStatus()
        }
    }

    // MARK: - TCC Reset Instructions

    private var tccResetInstructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Developer: Reset Stuck Permissions", systemImage: "arrow.counterclockwise.circle")
                .font(.headline)

            Text("If permissions become stuck during development (e.g. after changing bundle ID or signing identity), reset the TCC database entries:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("tccutil reset Microphone com.langcheng.InterviewCopilotMac")
                Text("tccutil reset SpeechRecognition com.langcheng.InterviewCopilotMac")
                Text("tccutil reset ScreenCapture com.langcheng.InterviewCopilotMac")
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .textSelection(.enabled)

            Text("Or run: ./script/build_and_run.sh --reset-tcc")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Then rebuild, launch the same .app path, and grant permissions again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var shellDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Developer: Terminal Verification Commands", systemImage: "terminal.fill")
                .font(.headline)

            Text("Run these commands in terminal to inspect application packaging, signing authority, and running processes:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Text("# 1. Verify Info.plist Bundle Identifier")
                        .foregroundStyle(.secondary)
                    Text("defaults read \"$(pwd)/dist/InterviewCopilotMac.app/Contents/Info.plist\" CFBundleIdentifier")
                }
                
                Group {
                    Text("# 2. Verify Code Signature and Entitlements")
                        .foregroundStyle(.secondary)
                    Text("codesign -dvvvv dist/InterviewCopilotMac.app")
                }
                
                Group {
                    Text("# 3. Verify Designated Requirement")
                        .foregroundStyle(.secondary)
                    Text("codesign -d -r- dist/InterviewCopilotMac.app")
                }
                
                Group {
                    Text("# 4. Check Running Instances and Process Paths")
                        .foregroundStyle(.secondary)
                    Text("ps aux | grep -E \"InterviewCopilotMac|Contents/MacOS\" | grep -v grep")
                }
                
                Group {
                    Text("# 5. Reset All Audio & Screen TCC Permissions")
                        .foregroundStyle(.secondary)
                    Text("tccutil reset Microphone com.langcheng.InterviewCopilotMac && tccutil reset ScreenCapture com.langcheng.InterviewCopilotMac && tccutil reset SpeechRecognition com.langcheng.InterviewCopilotMac")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .textSelection(.enabled)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
