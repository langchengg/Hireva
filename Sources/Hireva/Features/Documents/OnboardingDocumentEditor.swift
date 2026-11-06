import SwiftUI

struct OnboardingDocumentEditor: View {
    @ObservedObject var documents: DocumentsState
    let title: String
    let type: DocumentType
    let placeholder: String
    @Binding var text: String
    let isLoading: Bool
    let feedback: ActionFeedback?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(text.count) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? "Paste at least 80 characters to complete this step." : "Ready to save.")
                    .font(.caption)
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? Color.secondary : Color.green)
                Spacer()
                ActionButtonContent(
                    isLoading: isLoading,
                    feedback: feedback,
                    title: "Save \(title)",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "square.and.arrow.down",
                    isProminent: true,
                    disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).count < 80,
                    action: action
                )
            }
            InlineStatusBanner(feedback)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if let saved = documents.documents.first(where: { $0.type == type }) {
                text = saved.content
            }
        }
    }
}
