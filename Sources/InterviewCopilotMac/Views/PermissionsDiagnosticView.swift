import SwiftUI

struct PermissionsDiagnosticView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var micDiagnostics: MicrophoneDiagnosticsService
    @ObservedObject private var systemAudio = ScreenCaptureKitSystemAudioCaptureService.shared

    init(appState: AppState) {
        self.appState = appState
        self._micDiagnostics = ObservedObject(wrappedValue: appState.microphoneDiagnostics)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                permissionGrid
                microphoneTestCard
                systemAudioTestCard
                audioDeviceConfigPanel
                troubleshooting
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
                    action: appState.requestMicrophonePermission
                )
                permissionCard(
                    title: "Speech Recognition",
                    status: appState.permissionSnapshot.speechRecognition.displayName,
                    icon: "text.bubble",
                    tint: appState.permissionSnapshot.speechRecognition == .granted ? .green : .orange,
                    actionTitle: "Request",
                    action: appState.requestSpeechPermission
                )
            }
            GridRow {
                permissionCard(
                    title: "Screen & System Audio Recording",
                    status: appState.permissionSnapshot.screenRecording.displayName,
                    icon: "rectangle.on.rectangle",
                    tint: appState.permissionSnapshot.screenRecording == .granted ? .green : .orange,
                    actionTitle: "Request",
                    action: appState.requestScreenRecordingPermission
                )
                permissionCard(
                    title: "System Audio Capture Status",
                    status: appState.permissionSnapshot.systemAudioCapture.displayName,
                    icon: "speaker.wave.2",
                    tint: appState.permissionSnapshot.systemAudioCapture == .granted ? .green : .orange,
                    actionTitle: "Open Settings",
                    action: appState.openSystemPrivacySettings
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
            diagnosticRow("Last transcription", appState.lastTranscriptSnippet.isEmpty ? "None" : appState.lastTranscriptSnippet)

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
}
