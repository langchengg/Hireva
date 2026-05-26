import SwiftUI

struct FloatingAssistantView: View {
    @ObservedObject var appState: AppState
    @State private var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .padding(14)
        .frame(minWidth: 340, minHeight: 280, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusPill(title: appState.liveState.displayName, systemImage: "dot.radiowaves.left.and.right", tint: stateTint)
            
            MicLevelIndicatorView(appState: appState, isMini: true)
            
            StatusPill(
                title: appState.activeRealtimeProviderBadge,
                systemImage: appState.activeRealtimeProvider?.kind == .ollamaLocal ? "desktopcomputer" : "cloud",
                tint: appState.activeRealtimeProvider?.kind == .ollamaLocal ? .green : .blue
            )
            Spacer()
            Button {
                compact.toggle()
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var secondaryStatusText: String {
        switch appState.liveState {
        case .requestingPermission:
            return "Requesting microphone and speech recognition permissions."
        case .permissionDenied:
            return "Permission is blocked. Open the main window for recovery controls."
        case .detectingQuestion:
            return "Checking whether the interviewer asked a complete question."
        case .generatingSuggestion:
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
}
