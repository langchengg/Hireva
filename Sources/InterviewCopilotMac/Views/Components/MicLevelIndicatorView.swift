import SwiftUI

/// A premium real-time visual indicator for microphone (candidate) and system audio (interviewer) capture levels.
struct MicLevelIndicatorView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var micDiagnostics: MicrophoneDiagnosticsService
    @ObservedObject var systemAudio = ScreenCaptureKitSystemAudioCaptureService.shared
    var isMini: Bool

    init(appState: AppState, isMini: Bool = false) {
        self.appState = appState
        self.micDiagnostics = appState.microphoneDiagnostics
        self.isMini = isMini
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Render Microphone Level Meter if capture mode uses Microphone
            if appState.settings.audioCaptureMode == .microphoneOnly || appState.settings.audioCaptureMode == .microphoneAndSystem {
                HStack(spacing: 6) {
                    micIcon
                        .font(isMini ? .caption : .subheadline)
                    
                    if !isMini {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Candidate Mic")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(appState.microphonePermissionState == .authorized && micDiagnostics.lastError == nil ? String(format: "%.1f dB", micDiagnostics.decibels) : "Mic Off")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(micStatusColor)
                        }
                        
                        if appState.microphonePermissionState == .authorized, micDiagnostics.lastError == nil {
                            levelBar(level: micDiagnostics.normalizedLevel, color: micLevelColor)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }

            // Render System Audio Level Meter if capture mode uses System Audio
            if appState.settings.audioCaptureMode == .systemAudioOnly || appState.settings.audioCaptureMode == .microphoneAndSystem {
                HStack(spacing: 6) {
                    systemAudioIcon
                        .font(isMini ? .caption : .subheadline)
                    
                    if !isMini {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Interviewer Audio")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(systemAudio.isCapturing && systemAudio.lastError == nil ? String(format: "%.1f dB", systemAudio.decibels) : "Sys Off")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(systemAudioStatusColor)
                        }
                        
                        if systemAudio.isCapturing, systemAudio.lastError == nil {
                            levelBar(level: systemAudio.normalizedLevel, color: systemAudioLevelColor)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func levelBar(level: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 5)
                
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(level), height: 5)
                    .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: level)
            }
            .frame(height: 5)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(width: 45, height: 10)
    }

    // MARK: - Mic Status Aesthetics

    @ViewBuilder
    private var micIcon: some View {
        if appState.microphonePermissionState != .authorized {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
        } else if micDiagnostics.lastError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if micDiagnostics.isRunning || appState.liveState == .listening || appState.liveState == .transcribing {
            if micDiagnostics.decibels > -45.0 {
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, options: .repeating, value: micDiagnostics.decibels > -45.0)
            } else {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var micStatusColor: Color {
        if appState.microphonePermissionState != .authorized || micDiagnostics.lastError != nil {
            return .red
        } else if micDiagnostics.isRunning || appState.liveState == .listening || appState.liveState == .transcribing {
            return micDiagnostics.decibels > -45.0 ? .green : .secondary
        } else {
            return .secondary
        }
    }

    private var micLevelColor: Color {
        if micDiagnostics.decibels > -20.0 {
            return .orange
        } else if micDiagnostics.decibels > -45.0 {
            return .green
        } else {
            return .secondary
        }
    }

    // MARK: - System Audio Status Aesthetics

    @ViewBuilder
    private var systemAudioIcon: some View {
        if systemAudio.lastError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if systemAudio.isCapturing {
            if systemAudio.decibels > -45.0 {
                Image(systemName: "speaker.wave.2.bubble")
                    .foregroundStyle(.blue)
                    .symbolEffect(.bounce, options: .repeating, value: systemAudio.decibels > -45.0)
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
        }
    }

    private var systemAudioStatusColor: Color {
        if systemAudio.lastError != nil {
            return .red
        } else if systemAudio.isCapturing {
            return systemAudio.decibels > -45.0 ? .blue : .secondary
        } else {
            return .secondary
        }
    }

    private var systemAudioLevelColor: Color {
        if systemAudio.decibels > -20.0 {
            return .orange
        } else if systemAudio.decibels > -45.0 {
            return .blue
        } else {
            return .secondary
        }
    }
}
