import SwiftUI
import UniformTypeIdentifiers

struct DocumentsView: View {
    @ObservedObject var appState: AppState
    @State private var cvText = ""
    @State private var jdText = ""
    @State private var notesText = ""
    @State private var previewedTypes: Set<DocumentType> = []
    @State private var newProfileName = ""
    @State private var newOpportunityName = ""
    @State private var newDeclaredGap = ""
    @State private var importType: DocumentType?
    @State private var isImporterPresented = false
    @State private var showEvidenceReview = false
    @State private var showAdvancedOverrides = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                contextSetup
                if showEvidenceReview {
                    evidenceReview
                }

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
        .onChange(of: appState.documents) { _, _ in hydrateEditors() }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            guard let type = importType else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { appState.importPlainTextDocument(from: url, as: type) }
            case .failure(let error):
                appState.showError("Could not open the document: \(error.localizedDescription)")
            }
            importType = nil
        }
    }

    private var contextSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Interview Context", systemImage: "person.text.rectangle")
                    .font(.title2.weight(.semibold))
                Spacer()
                StatusPill(
                    title: contextStatusTitle,
                    systemImage: contextStatusIcon,
                    tint: contextStatusTint
                )
            }

            if appState.documents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No context generated yet")
                        .font(.headline)
                    Text("Upload your CV, add the job or PhD description, then review the generated profile.")
                        .foregroundStyle(.secondary)
                }
            } else {
                generatedContextSummary
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                contextAction("Upload CV", "doc.badge.plus", type: .cv)
                contextAction("Add Opportunity", "briefcase.badge.plus", type: .jobDescription)
                contextAction("Add Notes", "note.text.badge.plus", type: .additionalNotes)
                Button {
                    Task { await appState.rebuildAutomaticInterviewContext() }
                } label: {
                    Label("Regenerate Context", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .disabled(appState.documents.isEmpty || appState.automaticContextReadiness == .extracting)
                Button {
                    showEvidenceReview.toggle()
                } label: {
                    Label(showEvidenceReview ? "Hide Review" : "Review Extracted Facts", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .disabled(appState.activeCandidateProfile == nil && appState.activeOpportunityContext == nil)
                Button {
                    if appState.coreInterviewReadinessPassed {
                        appState.startListening(mode: .microphone)
                    } else {
                        appState.selectSection(.readinessCheck)
                    }
                } label: {
                    Label("Start Interview", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.automaticContextReadiness == .extracting || appState.activeCandidateProfile == nil)
            }

            if let warnings = appState.automaticContextBuildResult?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup(isExpanded: $showAdvancedOverrides) {
                advancedOverrides
                    .padding(.top, 10)
            } label: {
                Label("Advanced Context Overrides", systemImage: "slider.horizontal.3")
                    .font(.headline)
            }
        }
        .padding(.vertical, 4)
    }

    private var generatedContextSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextSummaryRow(
                title: "Candidate",
                value: appState.activeCandidateProfile?.displayName ?? "No candidate profile yet",
                detail: candidateSourceDetail,
                metric: "\(appState.contextReadiness.candidateFactCount) facts",
                icon: "person.text.rectangle"
            )
            Divider()
            contextSummaryRow(
                title: "Target Opportunity",
                value: appState.activeOpportunityContext?.title ?? "No target opportunity provided",
                detail: opportunitySourceDetail,
                metric: "\(appState.contextReadiness.opportunityRequirementCount) requirements",
                icon: "briefcase"
            )
            Divider()
            contextSummaryRow(
                title: "Interview Domain",
                value: appState.automaticContextBuildResult?.inferredDomain.displayName ?? appState.activeInterviewDomainID.displayName,
                detail: "Automatically inferred",
                metric: domainConfidence,
                icon: "scope"
            )
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var advancedOverrides: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Normally these values are inferred automatically from your documents.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Configuration source: \(appState.contextConfigurationOrigin?.rawValue ?? "not_configured")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Candidate Profile").foregroundStyle(.secondary)
                    Picker("Candidate Profile override", selection: Binding(
                        get: { appState.activeCandidateProfileID },
                        set: appState.selectCandidateProfile
                    )) {
                        Text("None").tag(String?.none)
                        ForEach(appState.productionCandidateProfiles) { profile in
                            Text(profile.displayName ?? "Candidate Profile").tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Target Opportunity").foregroundStyle(.secondary)
                    Picker("Target Opportunity override", selection: Binding(
                        get: { appState.activeOpportunityContextID },
                        set: appState.selectOpportunityContext
                    )) {
                        Text("General / None").tag(String?.none)
                        ForEach(appState.productionOpportunityContexts) { opportunity in
                            Text(opportunity.title ?? "Target Opportunity").tag(Optional(opportunity.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Interview Domain").foregroundStyle(.secondary)
                    Picker("Interview Domain override", selection: Binding(
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
            HStack(spacing: 8) {
                TextField("New profile name", text: $newProfileName)
                Button {
                    appState.createCandidateProfile(named: newProfileName)
                    newProfileName = ""
                } label: { Image(systemName: "person.badge.plus") }
                .help("Create candidate profile override")
                TextField("New opportunity name", text: $newOpportunityName)
                Button {
                    appState.createOpportunityContext(named: newOpportunityName)
                    newOpportunityName = ""
                } label: { Image(systemName: "briefcase.badge.plus") }
                .help("Create target opportunity override")
            }
            if let snapshot = appState.activeContextSnapshot {
                Text("Snapshot: \(snapshot.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var evidenceReview: some View {
        if let profile = appState.activeCandidateProfile {
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
        if let opportunity = appState.activeOpportunityContext {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Opportunity Review", systemImage: "briefcase")
                        .font(.headline)
                    Spacer()
                    Text("v\(opportunity.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(opportunity.allEvidence.prefix(16)) { evidence in
                    ProfileEvidenceReviewRow(appState: appState, evidence: evidence)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var contextStatusTitle: String {
        switch appState.automaticContextReadiness {
        case .noDocuments: return "Not generated"
        case .extracting: return "Building"
        case .needsReview: return "Needs Review"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var contextStatusIcon: String {
        switch appState.automaticContextReadiness {
        case .noDocuments: return "circle"
        case .extracting: return "arrow.triangle.2.circlepath"
        case .needsReview: return "exclamationmark.circle"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }

    private var contextStatusTint: Color {
        switch appState.automaticContextReadiness {
        case .ready: return .green
        case .extracting: return .blue
        case .needsReview: return .orange
        case .failed: return .red
        case .noDocuments: return .secondary
        }
    }

    private var candidateSourceDetail: String {
        let titles = appState.automaticContextBuildResult?.evidenceSummary.candidateSourceTitles ?? []
        if let first = titles.first { return "Auto-generated from: \(first)" }
        return "Upload a CV to personalise answers"
    }

    private var opportunitySourceDetail: String {
        let titles = appState.automaticContextBuildResult?.evidenceSummary.opportunitySourceTitles ?? []
        if let first = titles.first { return "Auto-generated from: \(first)" }
        return "Add a job or PhD description for role-specific answers"
    }

    private var domainConfidence: String {
        guard let domain = appState.automaticContextBuildResult?.inferredDomain else { return "Not inferred" }
        return "\(domain.confidenceLabel) confidence"
    }

    private func contextAction(_ title: String, _ icon: String, type: DocumentType) -> some View {
        Button {
            importType = type
            isImporterPresented = true
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
    }

    private func contextSummaryRow(
        title: String,
        value: String,
        detail: String,
        metric: String,
        icon: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(metric)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(evidence.evidenceType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 105, alignment: .leading)
                TextField("Evidence", text: $draft)
                    .onSubmit { appState.editProfileEvidence(evidence.id, statement: draft) }
                Text(reviewStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(reviewTint)
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
            if let source = evidence.sourceSpan, !source.isEmpty {
                Text("Source: \(String(source.prefix(180)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var reviewStatus: String {
        switch evidence.explicitness {
        case .explicit: return "Extracted"
        case .inferred: return "Uncertain"
        case .userConfirmed: return "Confirmed"
        case .userRejected: return "Rejected"
        }
    }

    private var reviewTint: Color {
        switch evidence.explicitness {
        case .explicit, .userConfirmed: return .green
        case .inferred: return .orange
        case .userRejected: return .red
        }
    }
}
