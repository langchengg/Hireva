import SwiftUI

/// A premium real-time visual indicator for microphone capture levels, permission state, and audio engine errors.
struct MicLevelIndicatorView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var micDiagnostics: MicrophoneDiagnosticsService
    var isMini: Bool

    init(appState: AppState, isMini: Bool = false) {
        self.appState = appState
        self.micDiagnostics = appState.microphoneDiagnostics
        self.isMini = isMini
    }

    public var body: some View {
        HStack(spacing: 8) {
            indicatorIcon
                .font(isMini ? .callout : .title3)
            
            if !isMini {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                    
                    if appState.microphonePermissionState == .authorized, micDiagnostics.lastError == nil {
                        Text(String(format: "dBFS: %.1f", micDiagnostics.decibels))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if appState.microphonePermissionState == .authorized, micDiagnostics.lastError == nil {
                    // Small real-time level bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            
                            Capsule()
                                .fill(levelColor)
                                .frame(width: geo.size.width * CGFloat(micDiagnostics.normalizedLevel), height: 6)
                                .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: micDiagnostics.normalizedLevel)
                        }
                        .frame(height: 6)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    .frame(width: 60, height: 12)
                }
            }
        }
        .padding(.horizontal, isMini ? 6 : 12)
        .padding(.vertical, isMini ? 4 : 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        if appState.microphonePermissionState != .authorized {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
        } else if micDiagnostics.lastError != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if micDiagnostics.isRunning || appState.liveState == .listening || appState.liveState == .transcribing {
            if micDiagnostics.decibels > -45.0 {
                // Active speech / audio capturing (glow green)
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, options: .repeating, value: micDiagnostics.decibels > -45.0)
            } else {
                // Silence (grey/inactive status)
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if appState.microphonePermissionState != .authorized {
            return "Mic Blocked"
        } else if micDiagnostics.lastError != nil {
            return "Audio Error"
        } else if micDiagnostics.isRunning || appState.liveState == .listening || appState.liveState == .transcribing {
            return micDiagnostics.decibels > -45.0 ? "Audio Active" : "Silence"
        } else {
            return "Mic Idle"
        }
    }

    private var statusSubtitle: String {
        if appState.microphonePermissionState == .denied || appState.microphonePermissionState == .restricted {
            return "System Settings denied"
        } else if appState.microphonePermissionState == .notDetermined {
            return "Pending Authorization"
        } else if let error = micDiagnostics.lastError {
            return error.prefix(25) + "..."
        } else {
            return "Not capturing"
        }
    }

    private var statusColor: Color {
        if appState.microphonePermissionState != .authorized || micDiagnostics.lastError != nil {
            return .red
        } else if micDiagnostics.isRunning || appState.liveState == .listening || appState.liveState == .transcribing {
            return micDiagnostics.decibels > -45.0 ? .green : .secondary
        } else {
            return .secondary
        }
    }

    private var levelColor: Color {
        if micDiagnostics.decibels > -20.0 {
            return .orange // Loud
        } else if micDiagnostics.decibels > -45.0 {
            return .green // Normal
        } else {
            return .secondary // Quiet / Silence
        }
    }
}
