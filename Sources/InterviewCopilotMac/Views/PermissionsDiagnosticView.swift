import SwiftUI

struct PermissionsDiagnosticView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var micDiagnostics: MicrophoneDiagnosticsService

    init(appState: AppState) {
        self.appState = appState
        self._micDiagnostics = ObservedObject(wrappedValue: appState.microphoneDiagnostics)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                microphoneTestCard
                permissionGrid
                troubleshooting
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
            Text("Use this screen to confirm macOS permission state and verify that the selected microphone is producing audio before starting a live interview.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var microphoneTestCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Microphone Test", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                StatusPill(
                    title: micDiagnostics.isRunning ? "Engine Running" : "Engine Stopped",
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
                    title: "Screen Recording",
                    status: appState.permissionSnapshot.screenRecording.displayName,
                    icon: "rectangle.on.rectangle",
                    tint: appState.permissionSnapshot.screenRecording == .granted ? .green : .orange,
                    actionTitle: "Request",
                    action: appState.requestScreenRecordingPermission
                )
                permissionCard(
                    title: "Future System Audio",
                    status: appState.permissionSnapshot.systemAudioCapture.displayName,
                    icon: "speaker.wave.2",
                    tint: .secondary,
                    actionTitle: "Open Settings",
                    action: appState.openSystemPrivacySettings
                )
            }
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("If the meter does not move", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text("Check the selected macOS input device, confirm microphone permission, verify any external microphone connection, and restart the app after changing permission settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
}
