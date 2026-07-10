import SwiftUI

struct DocumentsView: View {
    @ObservedObject var appState: AppState
    @State private var cvText = ""
    @State private var jdText = ""
    @State private var notesText = ""
    @State private var previewedTypes: Set<DocumentType> = []
    @State private var newProfileName = ""
    @State private var newOpportunityName = ""
    @State private var newDeclaredGap = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                contextSetup
                evidenceReview

                documentCard(type: .cv, text: $cvText)
                documentCard(type: .jobDescription, text: $jdText)
                documentCard(type: .additionalNotes, text: $notesText)

                if appState.documents.isEmpty {
                    emptyDocumentsState
                }
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .navigationTitle("Documents")
        .onAppear(perform: hydrateEditors)
    }

    private var contextSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Interview Context", systemImage: "person.text.rectangle")
                .font(.title2.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Candidate Profile").foregroundStyle(.secondary)
                    Picker("Candidate Profile", selection: Binding(
                        get: { appState.activeCandidateProfileID },
                        set: appState.selectCandidateProfile
                    )) {
                        Text("None").tag(String?.none)
                        ForEach(appState.candidateProfiles) { profile in
                            Text(profile.displayName ?? "Candidate Profile").tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Target Opportunity").foregroundStyle(.secondary)
                    Picker("Target Opportunity", selection: Binding(
                        get: { appState.activeOpportunityContextID },
                        set: appState.selectOpportunityContext
                    )) {
                        Text("General / None").tag(String?.none)
                        ForEach(appState.opportunityContexts) { opportunity in
                            Text(opportunity.title ?? "Target Opportunity").tag(Optional(opportunity.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Interview Domain").foregroundStyle(.secondary)
                    Picker("Interview Domain", selection: Binding(
                        get: { appState.activeInterviewDomainID },
                        set: appState.selectInterviewDomain
                    )) {
                        ForEach(InterviewDomainID.allCases) { domain in
                            Text(domain.displayName).tag(domain)
                        }
                    }
                    .labelsHidden()
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                summaryMetric("Candidate facts", "\(appState.contextReadiness.candidateFactCount)", "person.text.rectangle")
                summaryMetric("Opportunity requirements", "\(appState.contextReadiness.opportunityRequirementCount)", "briefcase")
                summaryMetric("Uncertain facts", "\(appState.contextReadiness.uncertainFactCount)", "questionmark.circle")
                summaryMetric("Declared gaps", "\(appState.contextReadiness.declaredGapCount)", "arrow.up.right")
                summaryMetric("Context status", contextStatusTitle, "checkmark.shield")
            }

            HStack(spacing: 8) {
                TextField("New profile name", text: $newProfileName)
                Button {
                    appState.createCandidateProfile(named: newProfileName)
                    newProfileName = ""
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Create candidate profile")

                TextField("New opportunity name", text: $newOpportunityName)
                Button {
                    appState.createOpportunityContext(named: newOpportunityName)
                    newOpportunityName = ""
                } label: {
                    Image(systemName: "briefcase.badge.plus")
                }
                .help("Create target opportunity")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var evidenceReview: some View {
        if let profile = appState.candidateProfiles.first(where: { $0.id == appState.activeCandidateProfileID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Candidate Profile Review", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text("v\(profile.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(profile.allEvidence.prefix(16)) { evidence in
                    ProfileEvidenceReviewRow(appState: appState, evidence: evidence)
                    Divider()
                }

                HStack {
                    TextField("Add a declared skill or experience gap", text: $newDeclaredGap)
                    Button {
                        appState.addDeclaredGap(newDeclaredGap)
                        newDeclaredGap = ""
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .disabled(newDeclaredGap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add declared gap")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var contextStatusTitle: String {
        switch appState.contextReadiness.status {
        case .ready: return "Ready"
        case .needsReview: return "Needs Review"
        case .missing: return "Missing"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Documents")
                .font(.largeTitle.weight(.bold))
            Text("Your CV, job description, and notes are the memory used to personalize interview answers.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyDocumentsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add your CV and job description to personalize answers.")
                .font(.headline)
            Text("Paste plain text or Markdown. If LaTeX formatting is detected, the original stays saved and a cleaned version is used for relevant context.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func documentCard(type: DocumentType, text: Binding<String>) -> some View {
        let document = appState.documents.first { $0.type == type }
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
                summaryMetric("Context index", chunks > 0 ? appState.userFacingRelevantContextStatus : "Needs rebuild", "doc.text.magnifyingglass")
                summaryMetric("Last rebuilt", document.map { DateFormatter.localizedString(from: $0.updatedAt, dateStyle: .medium, timeStyle: .short) } ?? "Never", "clock")
            }

            HStack(spacing: 10) {
                ActionButton(
                    appState: appState,
                    actionID: ActionID.saveDocument(type),
                    title: "Save Document",
                    loadingTitle: "Saving...",
                    successTitle: "Saved",
                    systemImage: "square.and.arrow.down",
                    isProminent: true,
                    disabled: trimmed.count < 80
                ) {
                    appState.saveDocument(type: type, title: type.title, content: text.wrappedValue)
                }

                ProgressButton(
                    appState: appState,
                    actionID: ActionID.rebuildCleanRAG,
                    title: "Rebuild Clean RAG Index",
                    loadingTitle: "Rebuilding...",
                    systemImage: "arrow.triangle.2.circlepath",
                    progress: nil,
                    disabled: appState.isActionLoading(ActionID.rebuildCleanRAG)
                ) {
                    appState.rebuildCleanRAGIndex()
                }

                ActionButton(
                    appState: appState,
                    actionID: ActionID.previewDocument(type),
                    title: previewExpanded ? "Hide Clean Text" : "Preview Clean Text",
                    loadingTitle: "Opening preview...",
                    successTitle: previewExpanded ? "Preview hidden" : "Preview shown",
                    systemImage: previewExpanded ? "eye.slash" : "eye",
                    disabled: trimmed.isEmpty && document?.sanitizedContent?.isEmpty != false
                ) {
                    let actionID = ActionID.previewDocument(type)
                    appState.beginAction(actionID, title: previewExpanded ? "Hiding preview" : "Opening clean preview", message: "Showing the text used for relevant context.")
                    if previewExpanded {
                        previewedTypes.remove(type)
                        appState.completeAction(actionID, title: "Preview hidden", message: "\(type.title) clean text preview is collapsed.")
                    } else {
                        previewedTypes.insert(type)
                        appState.completeAction(actionID, title: "Clean preview shown", message: "This is the plain-text version used for relevant context.")
                    }
                }

                ActionButton(
                    appState: appState,
                    actionID: ActionID.clearDocument(type),
                    title: "Clear Document",
                    loadingTitle: "Clearing...",
                    successTitle: "Cleared",
                    systemImage: "trash",
                    role: .destructive,
                    disabled: !saved && trimmed.isEmpty
                ) {
                    if let document {
                        appState.deleteDocument(document)
                    } else {
                        appState.completeAction(ActionID.clearDocument(type), title: "Editor cleared", message: "\(type.title) draft text was cleared.")
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
        (try? appState.documentRepository.chunks(type: type).count) ?? 0
    }

    private func documentFeedback(for type: DocumentType) -> ActionFeedback? {
        appState.latestActionFeedback(matching: [
            ActionID.saveDocument(type),
            ActionID.previewDocument(type),
            ActionID.clearDocument(type),
            ActionID.rebuildCleanRAG,
            ActionID.rebuildEmbeddings
        ])
    }

    private func cleanPreview(for document: DocumentRecord?, fallback: DocumentTextSanitizer.Result) -> String {
        let saved = document?.sanitizedContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty {
            return saved
        }
        return fallback.sanitizedContent
    }

    private func hydrateEditors() {
        cvText = appState.documents.first(where: { $0.type == .cv })?.content ?? ""
        jdText = appState.documents.first(where: { $0.type == .jobDescription })?.content ?? ""
        notesText = appState.documents.first(where: { $0.type == .additionalNotes })?.content ?? ""
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

private struct ProfileEvidenceReviewRow: View {
    @ObservedObject var appState: AppState
    let evidence: ProfileEvidence
    @State private var draft: String

    init(appState: AppState, evidence: ProfileEvidence) {
        self.appState = appState
        self.evidence = evidence
        _draft = State(initialValue: evidence.statement)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(evidence.evidenceType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)
            TextField("Evidence", text: $draft)
                .onSubmit { appState.editProfileEvidence(evidence.id, statement: draft) }
            Button {
                appState.confirmProfileEvidence(evidence.id)
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("Confirm evidence")
            Button {
                appState.rejectProfileEvidence(evidence.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Reject evidence")
        }
    }
}
