import SwiftUI
import UniformTypeIdentifiers

struct DocumentsView: View {
    @ObservedObject var documents: DocumentsState
    @ObservedObject var context: InterviewContextState
    let storySettings: SettingsState
    let storyRepository: PreparationRepository
    let contextIndexStatus: String
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let save: (DocumentType, String) -> Void
    let clear: (DocumentRecord) -> Void
    let rebuildIndex: () -> Void
    let previewFeedback: (DocumentType, Bool) -> Void
    let clearDraftFeedback: (DocumentType) -> Void
    let importDocument: (URL, DocumentType) -> Void
    let showError: (String) -> Void
    let startInterview: () -> Void
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
                DocumentsImportStatusView(documents: documents)
                if showEvidenceReview {
                    evidenceReview
                    if let profile = context.activeCandidateProfile { StoryCardsView(settings: storySettings, repository: storyRepository, profile: profile).id(profile.id) }
                }

                DocumentsEditorView(documents: documents,
                    contextIndexStatus: contextIndexStatus, feedbacks: feedbacks,
                    loadingStates: loadingStates, save: save, clear: clear,
                    rebuildIndex: rebuildIndex, previewFeedback: previewFeedback,
                    clearDraftFeedback: clearDraftFeedback)

                if documents.documents.isEmpty {
                    emptyDocumentsState
                }
            }
            .padding(28)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .navigationTitle("Documents")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText, .pdf, .image, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "md")!],
            allowsMultipleSelection: false
        ) { result in
            guard let type = importType else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { importDocument(url, type) }
            case .failure(let error):
                showError("Could not open the document: \(error.localizedDescription)")
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

            if documents.documents.isEmpty {
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
                    context.requestRebuild()
                } label: {
                    Label("Regenerate Context", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .disabled(documents.documents.isEmpty || context.automaticContextReadiness == .extracting)
                Button {
                    showEvidenceReview.toggle()
                } label: {
                    Label(showEvidenceReview ? "Hide Review" : "Review Extracted Facts", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .disabled(context.activeCandidateProfile == nil && context.activeOpportunityContext == nil)
                Button {
                    startInterview()
                } label: {
                    Label("Start Interview", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(context.automaticContextReadiness == .extracting )
            }

            if let warnings = context.automaticContextBuildResult?.warnings, !warnings.isEmpty {
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
                value: context.activeCandidateProfile?.displayName ?? "No candidate profile yet",
                detail: candidateSourceDetail,
                metric: "\(context.contextReadiness.candidateFactCount) facts",
                icon: "person.text.rectangle"
            )
            Divider()
            contextSummaryRow(
                title: "Target Opportunity",
                value: context.activeOpportunityContext?.title ?? "No target opportunity provided",
                detail: opportunitySourceDetail,
                metric: "\(context.contextReadiness.opportunityRequirementCount) requirements",
                icon: "briefcase"
            )
            Divider()
            contextSummaryRow(
                title: "Interview Domain",
                value: context.automaticContextBuildResult?.inferredDomain.displayName ?? context.activeInterviewDomainID.displayName,
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
            Text("Configuration source: \(context.contextConfigurationOrigin?.rawValue ?? "not_configured")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Candidate Profile").foregroundStyle(.secondary)
                    Picker("Candidate Profile override", selection: Binding(
                        get: { context.activeCandidateProfileID },
                        set: { @MainActor value in context.selectCandidateProfile(value) }
                    )) {
                        Text("None").tag(String?.none)
                        ForEach(context.productionCandidateProfiles) { profile in
                            Text(profile.displayName ?? "Candidate Profile").tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Target Opportunity").foregroundStyle(.secondary)
                    Picker("Target Opportunity override", selection: Binding(
                        get: { context.activeOpportunityContextID },
                        set: { @MainActor value in context.selectOpportunityContext(value) }
                    )) {
                        Text("General / None").tag(String?.none)
                        ForEach(context.productionOpportunityContexts) { opportunity in
                            Text(opportunity.title ?? "Target Opportunity").tag(Optional(opportunity.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Interview Domain").foregroundStyle(.secondary)
                    Picker("Interview Domain override", selection: Binding(
                        get: { context.activeInterviewDomainID },
                        set: { @MainActor value in context.selectInterviewDomain(value) }
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
                    context.createCandidateProfile(named: newProfileName)
                    newProfileName = ""
                } label: { Image(systemName: "person.badge.plus") }
                .help("Create candidate profile override")
                TextField("New opportunity name", text: $newOpportunityName)
                Button {
                    context.createOpportunityContext(named: newOpportunityName)
                    newOpportunityName = ""
                } label: { Image(systemName: "briefcase.badge.plus") }
                .help("Create target opportunity override")
            }
            if let snapshot = context.activeContextSnapshot {
                Text("Snapshot: \(snapshot.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var evidenceReview: some View {
        if let profile = context.activeCandidateProfile {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Candidate Profile Review", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text("v\(profile.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(profile.reviewEvidence) { evidence in
                    ProfileEvidenceReviewRow(context: context, evidence: evidence, scope: InterviewContextSelection(candidateProfileID: profile.id, opportunityContextID: nil, domainProfileID: context.activeInterviewDomainID))
                    Divider()
                }

                HStack {
                    TextField("Add a declared skill or experience gap", text: $newDeclaredGap)
                    Button {
                        context.addDeclaredGap(newDeclaredGap)
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
        if let opportunity = context.activeOpportunityContext {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Opportunity Review", systemImage: "briefcase")
                        .font(.headline)
                    Spacer()
                    Text("v\(opportunity.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(opportunity.reviewEvidence) { evidence in
                    ProfileEvidenceReviewRow(context: context, evidence: evidence, scope: InterviewContextSelection(candidateProfileID: nil, opportunityContextID: opportunity.id, domainProfileID: context.activeInterviewDomainID))
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var contextStatusTitle: String {
        switch context.automaticContextReadiness {
        case .noDocuments: return "Not generated"
        case .extracting: return "Building"
        case .needsReview: return "Needs Review"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var contextStatusIcon: String {
        switch context.automaticContextReadiness {
        case .noDocuments: return "circle"
        case .extracting: return "arrow.triangle.2.circlepath"
        case .needsReview: return "exclamationmark.circle"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }

    private var contextStatusTint: Color {
        switch context.automaticContextReadiness {
        case .ready: return .green
        case .extracting: return .blue
        case .needsReview: return .orange
        case .failed: return .red
        case .noDocuments: return .secondary
        }
    }

    private var candidateSourceDetail: String {
        let titles = context.automaticContextBuildResult?.evidenceSummary.candidateSourceTitles ?? []
        if let first = titles.first { return "Auto-generated from: \(first)" }
        return "Upload a CV to personalise answers"
    }

    private var opportunitySourceDetail: String {
        let titles = context.automaticContextBuildResult?.evidenceSummary.opportunitySourceTitles ?? []
        if let first = titles.first { return "Auto-generated from: \(first)" }
        return "Add a job or PhD description for role-specific answers"
    }

    private var domainConfidence: String {
        guard let domain = context.automaticContextBuildResult?.inferredDomain else { return "Not inferred" }
        return "\(domain.confidenceLabel) heuristic match"
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


}

private struct ProfileEvidenceReviewRow: View {
    @ObservedObject var context: InterviewContextState
    let evidence: ProfileEvidence
    let scope: InterviewContextSelection
    @State private var draft: String
    @State private var facts: FactConfirmation

    init(context: InterviewContextState, evidence: ProfileEvidence, scope: InterviewContextSelection) {
        self.context = context
        self.evidence = evidence
        self.scope = scope
        _draft = State(initialValue: evidence.statement)
        _facts = State(initialValue: evidence.confirmation ?? FactConfirmation())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(evidence.evidenceType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 105, alignment: .leading)
                TextField("Evidence", text: $draft)
                    .onSubmit { context.editProfileEvidence(evidence.id, statement: draft, scope: scope) }
                Text(reviewStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(reviewTint)
                Button {
                    if draft != evidence.statement { context.editProfileEvidence(evidence.id, statement: draft, scope: scope) }
                    if facts != evidence.confirmation ?? FactConfirmation() { context.editFactConfirmation(evidence.id, value: facts, scope: scope) }
                    context.confirmProfileEvidence(evidence.id, scope: scope)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Confirm evidence")
                Button {
                    context.rejectProfileEvidence(evidence.id, scope: scope)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Reject evidence")
            }
            DisclosureGroup("Contribution and experiment boundaries / 贡献与实验条件") {
                Picker("Ownership", selection: $facts.ownership) { ForEach(["unknown", "individual", "team"], id: \.self) { Text($0) } }
                TextField("Personal contribution (leave unknown blank)", text: $facts.contribution)
                Picker("Status", selection: $facts.status) { ForEach(["unknown", "completed", "planned"], id: \.self) { Text($0) } }
                Picker("Environment", selection: $facts.environment) { ForEach(["unknown", "simulation", "real-world", "production"], id: \.self) { Text($0) } }
                Picker("Scope", selection: $facts.scope) { ForEach(["unknown", "baseline", "full-system"], id: \.self) { Text($0) } }
                TextField("Metric and units (optional)", text: $facts.metric)
                TextField("Sample, conditions and range (optional)", text: $facts.conditions)
                Text("Edits are unconfirmed until you press Confirm evidence. Source support and your confirmation are not independent verification. If a correction contradicts the source, retain that distinction.").font(.caption)
                if evidence.sourceSpan != nil && evidence.sourceSpan != draft { Text("Edited statement differs from the original source; review the difference before confirming.").foregroundStyle(.orange).font(.caption) }
                Button("Save Boundary Draft") { context.editFactConfirmation(evidence.id, value: facts, scope: scope) }
            }
            if let source = evidence.sourceSpan, !source.isEmpty {
                Text("Source: \(source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
