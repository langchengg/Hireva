import SwiftUI

struct DocumentsView: View {
    @ObservedObject var appState: AppState
    @State private var cvText = ""
    @State private var jdText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Documents")
                    .font(.largeTitle.weight(.bold))
                Text("CV and JD content are stored locally in SQLite and chunked for deterministic retrieval. PDF import and attachments are future extensions.")
                    .foregroundStyle(.secondary)

                editor(title: "CV / Resume", type: .cv, text: $cvText)
                editor(title: "Job Description", type: .jobDescription, text: $jdText)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved Documents")
                        .font(.headline)
                    if appState.documents.isEmpty {
                        Text("No documents saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.documents) { document in
                            HStack {
                                Label(document.title, systemImage: document.type == .cv ? "doc.text" : "briefcase")
                                Spacer()
                                Text(document.updatedAt, style: .date)
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    appState.deleteDocument(document)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(28)
        }
        .onAppear {
            cvText = appState.documents.first(where: { $0.type == .cv })?.content ?? ""
            jdText = appState.documents.first(where: { $0.type == .jobDescription })?.content ?? ""
        }
    }

    private func editor(title: String, type: DocumentType, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                StatusPill(title: text.wrappedValue.count >= 80 ? "Meaningful length" : "Too short", systemImage: text.wrappedValue.count >= 80 ? "checkmark" : "exclamationmark", tint: text.wrappedValue.count >= 80 ? .green : .orange)
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 190)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? "Paste at least 80 characters to complete this document." : "Ready to save.")
                    .font(.caption)
                    .foregroundStyle(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).count < 80 ? Color.secondary : Color.green)
                Spacer()
                Button("Save \(title)") {
                    appState.saveDocument(type: type, title: title, content: text.wrappedValue)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
