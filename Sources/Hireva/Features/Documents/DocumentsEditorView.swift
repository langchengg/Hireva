import SwiftUI

/// The editor observes its document owner directly. Context/Live controls and
/// global action feedback remain at the application boundary.
struct DocumentsEditorView: View {
    @ObservedObject var documents: DocumentsState
    let contextIndexStatus: String
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let save: (DocumentType, String) -> Void
    let clear: (DocumentRecord) -> Void
    let rebuildIndex: () -> Void
    let previewFeedback: (DocumentType, Bool) -> Void
    let clearDraftFeedback: (DocumentType) -> Void
    @State private var cvText = ""
    @State private var jdText = ""
    @State private var notesText = ""
    @State private var previewedTypes: Set<DocumentType> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            documentCard(type: .cv, text: $cvText)
            documentCard(type: .jobDescription, text: $jdText)
            documentCard(type: .additionalNotes, text: $notesText)
        }
        .onAppear(perform: hydrateEditors)
        .onChange(of: documents.documents) { _, _ in hydrateEditors() }
    }

    private func documentCard(type: DocumentType, text: Binding<String>) -> some View {
        let document = documents.documents.first { $0.type == type }
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = DocumentTextSanitizer.sanitize(trimmed)
        let hasLatexWarning = sanitized.wasSanitized || !(document?.sanitizationWarnings?.isEmpty ?? true)
        let chunks = chunkCount(for: type)
        let saved = document != nil
        let previewExpanded = previewedTypes.contains(type)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label(type.title, systemImage: type.systemImage)
                    .font(.title3.weight(.semibold))
                Spacer()
                StatusPill(
                    title: saved ? "Saved" : "Not saved",
                    systemImage: saved ? "checkmark.circle.fill" : "circle",
                    tint: saved ? .green : .orange
                )
            }

            if let document, let source = try? documents.source(documentID: document.id) {
                Text("Source: \(source.material.filename) · \(source.material.sections.count) locations · \(Array(Set(source.material.sections.map(\.method))).joined(separator: ", "))")
                    .font(.caption).textSelection(.enabled)
                Text(source.material.warnings.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                if let image = NSImage(data: source.data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                }
                Button("Reprocess Saved Original") { documents.reprocessDocument(document) }
            }
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: type == .additionalNotes ? 130 : 190)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if hasLatexWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("LaTeX formatting was detected. The app will preserve your original document but use a cleaned plain-text version for relevant context.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                summaryMetric("Sanitized", sanitized.wasSanitized || saved ? "Ready" : "No text", "wand.and.stars")
                summaryMetric("Chunks", "\(chunks)", "square.stack.3d.up")
                summaryMetric("Context index", chunks > 0 ? contextIndexStatus : "Needs rebuild", "doc.text.magnifyingglass")
                summaryMetric("Last rebuilt", document.map { DateFormatter.localizedString(from: $0.updatedAt, dateStyle: .medium, timeStyle: .short) } ?? "Never", "clock")
            }

            HStack(spacing: 10) {
                ActionButtonContent(
                    isLoading: loadingStates[ActionID.saveDocument(type)] == true,
                    feedback: feedbacks.last { $0.actionID == ActionID.saveDocument(type) },
                    title: "Save Document",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "square.and.arrow.down",
                    isProminent: true,
                    disabled: trimmed.count < 80
                ) {
                    save(type, text.wrappedValue)
                }

                ProgressButtonContent(
                    isLoading: loadingStates[ActionID.rebuildCleanRAG] == true,
                    feedback: feedbacks.last { $0.actionID == ActionID.rebuildCleanRAG },
                    title: "Rebuild Clean RAG Index",
                    loadingTitle: "Rebuilding...",
                    systemImage: "arrow.triangle.2.circlepath",
                    progress: nil,
                    disabled: loadingStates[ActionID.rebuildCleanRAG] == true
                ) {
                    rebuildIndex()
                }

                ActionButtonContent(
                    isLoading: loadingStates[ActionID.previewDocument(type)] == true,
                    feedback: feedbacks.last { $0.actionID == ActionID.previewDocument(type) },
                    title: previewExpanded ? "Hide Clean Text" : "Preview Clean Text",
                    loadingTitle: "Opening preview...",
                    successTitle: previewExpanded ? "Preview hidden" : "Preview shown",
                    systemImage: previewExpanded ? "eye.slash" : "eye",
                    disabled: trimmed.isEmpty && document?.sanitizedContent?.isEmpty != false
                ) {
                    previewFeedback(type, previewExpanded)
                    if previewExpanded {
                        previewedTypes.remove(type)
                    } else {
                        previewedTypes.insert(type)
                    }
                }

                ActionButtonContent(
                    isLoading: loadingStates[ActionID.clearDocument(type)] == true,
                    feedback: feedbacks.last { $0.actionID == ActionID.clearDocument(type) },
                    title: "Clear Document",
                    loadingTitle: "Clearing...",
                    successTitle: "Cleared",
                    systemImage: "trash",
                    role: .destructive,
                    disabled: !saved && trimmed.isEmpty
                ) {
                    if let document {
                        clear(document)
                    } else {
                        clearDraftFeedback(type)
                    }
                    clearEditor(type)
                }
            }

            InlineStatusBanner(documentFeedback(for: type))

            if trimmed.count < 80 {
                Text("Paste at least 80 characters before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if previewExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clean text preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(cleanPreview(for: document, fallback: sanitized))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func chunkCount(for type: DocumentType) -> Int {
        documents.chunkCount(type: type)
    }

    private func documentFeedback(for type: DocumentType) -> ActionFeedback? {
        let ids = [
            ActionID.saveDocument(type),
            ActionID.previewDocument(type),
            ActionID.clearDocument(type),
            ActionID.rebuildCleanRAG,
            ActionID.rebuildEmbeddings
        ]
        return feedbacks.last { ids.contains($0.actionID) }
    }

    private func cleanPreview(for document: DocumentRecord?, fallback: DocumentTextSanitizer.Result) -> String {
        let saved = document?.sanitizedContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty {
            return saved
        }
        return fallback.sanitizedContent
    }

    private func hydrateEditors() {
        cvText = documents.documents.first(where: { $0.type == .cv })?.content ?? ""
        jdText = documents.documents.first(where: { $0.type == .jobDescription })?.content ?? ""
        notesText = documents.documents.first(where: { $0.type == .additionalNotes })?.content ?? ""
    }

    private func clearEditor(_ type: DocumentType) {
        switch type {
        case .cv:
            cvText = ""
        case .jobDescription:
            jdText = ""
        case .additionalNotes:
            notesText = ""
        }
    }
}

struct DocumentsImportStatusView: View {
    @ObservedObject var documents: DocumentsState
    var body: some View {
        if !documents.importStatus.isEmpty {
            Text(documents.importStatus).font(.callout).textSelection(.enabled)
            Button("Cancel Import") { documents.cancelImport() }
        }
    }
}
