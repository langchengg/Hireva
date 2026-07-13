import SwiftUI

struct TranscriptView: View {
    var segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Transcript")
                .font(.headline)
            if segments.isEmpty {
                EmptyStateView(title: "No transcript yet", message: "Start Listening to begin live microphone transcription.", systemImage: "text.bubble")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(segments) { segment in
                                transcriptRow(segment)
                                    .id(segment.id)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: segments.count) { _, _ in
                        if let last = segments.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func transcriptRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(segment.speaker == .system ? Color.secondary : Color.blue)
                Spacer()
                Text(segment.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(segment.speaker == .system ? Color.secondary.opacity(0.08) : Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
