import Combine
import Foundation

/// Owns curated context and automatic builds. A manual revision invalidates the
/// build identity before cancelling; ignored cancellation cannot restore old
/// evidence. The application alone binds immutable snapshots to live sessions.
@MainActor
final class InterviewContextState: ObservableObject {
    typealias BuilderFactory = (Bool) throws -> any InterviewContextBuilding

    // This pulse carries no business value. Fields commit before synchronous
    // observers can select a context, replace a build or close admission.
    @Published private var observationPulse: Void = ()
    var candidateProfiles: [CandidateProfile] = [] { didSet { observationPulse = () } }
    var opportunityContexts: [OpportunityContext] = [] { didSet { observationPulse = () } }
    var activeCandidateProfileID: String? {
        didSet {
            if oldValue != activeCandidateProfileID { selectionDidChange() }
            observationPulse = ()
        }
    }
    var activeOpportunityContextID: String? {
        didSet {
            if oldValue != activeOpportunityContextID { selectionDidChange() }
            observationPulse = ()
        }
    }
    var activeInterviewDomainID: InterviewDomainID = .general {
        didSet {
            if oldValue != activeInterviewDomainID { selectionDidChange() }
            observationPulse = ()
        }
    }
    var activeContextSnapshot: InterviewContextSnapshot? {
        didSet {
            if oldValue?.id != activeContextSnapshot?.id { selectionDidChange() }
            observationPulse = ()
        }
    }
    var automaticContextBuildResult: InterviewContextBuildResult? { didSet { observationPulse = () } }
    var automaticContextReadiness: AutomaticContextReadiness = .noDocuments { didSet { observationPulse = () } }
    var contextConfigurationOrigin: ContextConfigurationOrigin? { didSet { observationPulse = () } }

    private let interviewContextRepository: InterviewContextRepository
    private let documentRepository: DocumentRepository
    private let documentRecords: () -> [DocumentRecord]
    private let makeBuilder: BuilderFactory
    private let selectionWillChange: () -> Void
    private let selectionDidChange: () -> Void
    private let domainDidChange: (InterviewDomainID) -> Void
    private let contextDidChange: () throws -> Void
    private let refreshApplication: () -> Void
    private let feedback: (ActionFeedback) -> Void
    private let clearFeedback: (String) -> Void
    private let showError: (String) -> Void
    private(set) var buildID = UUID()
    private(set) var worker: Task<Void, Never>?
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var admissionClosed = false
    var builderOverride: (any InterviewContextBuilding)?

    init(repository: InterviewContextRepository, documents: DocumentRepository,
         documentRecords: @escaping () -> [DocumentRecord], makeBuilder: @escaping BuilderFactory,
         selectionWillChange: @escaping () -> Void, domainDidChange: @escaping (InterviewDomainID) -> Void,
         contextDidChange: @escaping () throws -> Void, refreshApplication: @escaping () -> Void,
         feedback: @escaping (ActionFeedback) -> Void, clearFeedback: @escaping (String) -> Void,
         showError: @escaping (String) -> Void, selectionDidChange: @escaping () -> Void = {}) {
        self.interviewContextRepository = repository
        self.documentRepository = documents
        self.documentRecords = documentRecords
        self.makeBuilder = makeBuilder
        self.selectionWillChange = selectionWillChange
        self.selectionDidChange = selectionDidChange
        self.domainDidChange = domainDidChange
        self.contextDidChange = contextDidChange
        self.refreshApplication = refreshApplication
        self.feedback = feedback
        self.clearFeedback = clearFeedback
        self.showError = showError
    }

    private var documents: [DocumentRecord] { documentRecords() }
    var pendingTaskCount: Int { retiring.count + (worker == nil ? 0 : 1) }

    /// Old workers remain owned until their builder really exits. Callers can
    /// join them; setting a handle to nil is not proof of resource release.
    func invalidateBuild() {
        let id = UUID()
        retireBuild(nextID: id)
        publishInvalidation(id: id)
    }

    private func retireBuild(nextID: UUID) {
        let previousID = buildID, captured = worker
        buildID = nextID // Revoke publication before cancellation can reenter.
        worker = nil // An old cancellation callback cannot erase a new worker.
        if let captured {
            retiring[previousID] = captured
            captured.cancel()
        }
    }

    private func publishInvalidation(id: UUID) {
        guard buildID == id else { return }
        automaticContextReadiness = automaticContextBuildResult?.readiness ?? .noDocuments
        guard buildID == id else { return }
        clearFeedback(ActionID.buildInterviewContext)
    }

    private func acceptsBuild(_ id: UUID) -> Bool {
        !admissionClosed && buildID == id
    }

    func closeAdmission() {
        admissionClosed = true
        invalidateBuild()
    }

    func shutdown() async {
        closeAdmission()
        let pending = Array(retiring.values)
        for task in pending { await task.value }
    }

    private func didExit(_ id: UUID) {
        retiring.removeValue(forKey: id)
        if buildID == id { worker = nil }
    }

    @discardableResult
    func requestRebuild(useLocalQwen: Bool = true) -> Task<Void, Never>? {
        guard !admissionClosed else { return nil }
        let id = UUID()
        // Freeze the submission before any cancellation/reset notification can
        // synchronously choose another provider, material or current context.
        let input = documents
        let candidateIDs = Set(input.filter { $0.type != .jobDescription }.map(\.id))
        let previous = activeCandidateProfile.flatMap { profile in
            Set(profile.sourceDocumentIDs).isDisjoint(with: candidateIDs) ? nil : profile
        }
        let builderResult = Result { try builderOverride ?? makeBuilder(useLocalQwen) }
        retireBuild(nextID: id)
        guard acceptsBuild(id) else { return nil }
        switch builderResult {
        case .success(let builder):
            let task = Task { [weak self] in
                defer { self?.didExit(id) }
                do {
                    guard try self?.beginRebuild(documents: input, useLocalQwen: useLocalQwen, buildID: id) == true else { return }
                    // Do not retain the feature owner across the provider await.
                    // Explicit shutdown retains and joins it; deinit can cancel
                    // and a late result cannot write to a released application.
                    var result = try await builder.buildContext(from: input, previousConfirmedProfile: previous)
                    try self?.completeRebuild(&result, documents: input, buildID: id)
                } catch { self?.buildFailed(error, buildID: id) }
            }
            // Observers receive reset/loading only after the original worker
            // is registered. A nested newer request retires this exact handle.
            worker = task
            publishInvalidation(id: id)
            return acceptsBuild(id) ? task : nil
        case .failure(let error):
            publishInvalidation(id: id)
            guard acceptsBuild(id) else { return nil }
            automaticContextReadiness = .failed
            guard acceptsBuild(id) else { return nil }
            failAction(ActionID.buildInterviewContext, title: "Context build failed", message: error.localizedDescription)
            return nil
        }
    }

    func rebuild(useLocalQwen: Bool = true) async {
        guard !Task.isCancelled, let task = requestRebuild(useLocalQwen: useLocalQwen) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !admissionClosed, buildID == id else { throw CancellationError() }
    }

    private func beginRebuild(documents: [DocumentRecord], useLocalQwen: Bool, buildID: UUID) throws -> Bool {
        let actionID = ActionID.buildInterviewContext
        try requireCurrent(buildID)
        guard !documents.isEmpty else {
            do {
                try clearAutomaticContextForNoDocuments(buildID: buildID)
                completeAction(actionID, title: "Context cleared",
                    message: "Add a resume or opportunity document to build interview context.")
            } catch is CancellationError { throw CancellationError() }
            catch {
                try requireCurrent(buildID)
                automaticContextReadiness = .failed
                try requireCurrent(buildID)
                failAction(actionID, title: "Context reset failed", message: error.localizedDescription)
            }
            return false
        }
        beginAction(actionID, title: "Building interview context",
            message: useLocalQwen ? "Local Qwen is extracting evidence from untrusted document data." : "Extracting verified document evidence.")
        try requireCurrent(buildID)
        automaticContextReadiness = .extracting
        try requireCurrent(buildID)
        return true
    }

    private func completeRebuild(_ result: inout InterviewContextBuildResult, documents: [DocumentRecord], buildID: UUID) throws {
        try requireCurrent(buildID)
        try applyAutomaticContextBuildResult(&result, documents: documents, buildID: buildID)
        try requireCurrent(buildID)
        completeAction(ActionID.buildInterviewContext,
            title: result.readiness == .ready ? "Interview context ready" : "Context needs review",
            message: "\(result.evidenceSummary.candidateFactCount) candidate facts and \(result.evidenceSummary.opportunityRequirementCount) opportunity requirements are available.")
    }

    private func buildFailed(_ error: Error, buildID: UUID) {
        if error is CancellationError || Task.isCancelled {
            if self.buildID == buildID {
                automaticContextReadiness = automaticContextBuildResult?.readiness ?? .noDocuments
                guard self.buildID == buildID else { return }
                clearFeedback(ActionID.buildInterviewContext)
            }
            return
        }
        guard !Task.isCancelled, !admissionClosed, self.buildID == buildID else { return }
        automaticContextReadiness = .failed
        guard acceptsBuild(buildID) else { return }
        failAction(ActionID.buildInterviewContext, title: "Context build failed", message: error.localizedDescription)
    }

    func reload(sessionSnapshotID: String?) throws {
        candidateProfiles = try interviewContextRepository.candidateProfiles()
        opportunityContexts = try interviewContextRepository.opportunityContexts()
        var selection = try interviewContextRepository.loadSelection()
        var configurationOrigin = try interviewContextRepository.loadConfigurationOrigin()
        if configurationOrigin == nil,
           selection.candidateProfileID != nil || selection.opportunityContextID != nil {
            configurationOrigin = .legacyManualContext
            try interviewContextRepository.saveConfigurationOrigin(.legacyManualContext)
        }
        let selectableCandidates = candidateProfiles.filter { !ProductionContextPolicy.isSyntheticProfile($0) }
        let selectableOpportunities = opportunityContexts.filter { !ProductionContextPolicy.isSyntheticOpportunity($0) }
        let currentDocumentIDs = Set(documents.map(\.id))
        let linkedCandidates = selectableCandidates.filter { !Set($0.sourceDocumentIDs).isDisjoint(with: currentDocumentIDs) }
        let linkedOpportunities = selectableOpportunities.filter { !Set($0.sourceDocumentIDs).isDisjoint(with: currentDocumentIDs) }
        if !ProductionContextPolicy.isTestProcess,
           let selected = selection.candidateProfileID,
           candidateProfiles.first(where: { $0.id == selected }).map(ProductionContextPolicy.isSyntheticProfile) == true {
            selection.candidateProfileID = nil
        }
        if !ProductionContextPolicy.isTestProcess,
           let selected = selection.opportunityContextID,
           opportunityContexts.first(where: { $0.id == selected }).map(ProductionContextPolicy.isSyntheticOpportunity) == true {
            selection.opportunityContextID = nil
        }
        // A saved manual None is an explicit selection, not a missing default.
        if configurationOrigin != .legacyManualContext,
           selection.candidateProfileID == nil, linkedCandidates.count == 1, !documents.isEmpty {
            selection.candidateProfileID = linkedCandidates[0].id
        }
        if configurationOrigin != .legacyManualContext,
           selection.opportunityContextID == nil, linkedOpportunities.count == 1, !documents.isEmpty {
            selection.opportunityContextID = linkedOpportunities[0].id
        }
        activeCandidateProfileID = selection.candidateProfileID
        activeOpportunityContextID = selection.opportunityContextID
        activeInterviewDomainID = selection.domainProfileID
        contextConfigurationOrigin = configurationOrigin
        try interviewContextRepository.saveSelection(selection)
        if let snapshotID = sessionSnapshotID {
            activeContextSnapshot = try interviewContextRepository.snapshot(id: snapshotID)
        }
    }

    var currentInterviewContextSelection: InterviewContextSelection {
        InterviewContextSelection(
            candidateProfileID: activeCandidateProfileID,
            opportunityContextID: activeOpportunityContextID,
            domainProfileID: activeInterviewDomainID
        )
    }

    var contextReadiness: InterviewContextReadiness {
        let candidate = candidateProfiles.first { $0.id == activeCandidateProfileID }
        let opportunity = opportunityContexts.first { $0.id == activeOpportunityContextID }
        let candidateEvidence = candidate?.allEvidence ?? []
        let opportunityEvidence = opportunity?.allEvidence ?? []
        let uncertain = (candidateEvidence + opportunityEvidence).filter { $0.explicitness == .inferred }.count
        let status: ContextReadinessStatus
        if candidate == nil || candidateEvidence.isEmpty {
            status = .missing
        } else if uncertain > 0 {
            status = .needsReview
        } else {
            status = .ready
        }
        return InterviewContextReadiness(
            status: status,
            candidateFactCount: candidateEvidence.count,
            opportunityRequirementCount: opportunityEvidence.count,
            uncertainFactCount: uncertain,
            declaredGapCount: candidate?.declaredGaps.filter(\.isUsable).count ?? 0
        )
    }

    var productionCandidateProfiles: [CandidateProfile] {
        candidateProfiles.filter { !ProductionContextPolicy.isSyntheticProfile($0) }
    }

    var productionOpportunityContexts: [OpportunityContext] {
        opportunityContexts.filter { !ProductionContextPolicy.isSyntheticOpportunity($0) }
    }

    var activeCandidateProfile: CandidateProfile? {
        candidateProfiles.first { $0.id == activeCandidateProfileID }
    }

    var activeOpportunityContext: OpportunityContext? {
        opportunityContexts.first { $0.id == activeOpportunityContextID }
    }

    func selectCandidateProfile(_ id: String?) {
        guard !admissionClosed else { return }
        selectionWillChange()
        guard id == nil || candidateProfiles.contains(where: { $0.id == id }) else { return }
        if !ProductionContextPolicy.isTestProcess,
           let id,
           candidateProfiles.first(where: { $0.id == id }).map(ProductionContextPolicy.isSyntheticProfile) == true {
            return
        }
        invalidateBuild()
        activeCandidateProfileID = id
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func selectOpportunityContext(_ id: String?) {
        guard !admissionClosed else { return }
        selectionWillChange()
        guard id == nil || opportunityContexts.contains(where: { $0.id == id }) else { return }
        if !ProductionContextPolicy.isTestProcess,
           let id,
           opportunityContexts.first(where: { $0.id == id }).map(ProductionContextPolicy.isSyntheticOpportunity) == true {
            return
        }
        invalidateBuild()
        activeOpportunityContextID = id
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func selectInterviewDomain(_ id: InterviewDomainID) {
        guard !admissionClosed else { return }
        invalidateBuild()
        activeInterviewDomainID = id
        domainDidChange(id)
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func ingestDocumentIntoActiveContext(_ document: DocumentRecord) throws {
        guard !admissionClosed else { throw CancellationError() }
        invalidateBuild()
        let persistedChunks = try documentRepository.chunks(documentID: document.id)
        switch document.type {
        case .cv:
            let profile = try interviewContextRepository.upsertCandidateDocument(
                documentID: document.id,
                title: document.title,
                content: document.sanitizedContent ?? document.content,
                profileID: activeCandidateProfileID,
                persistedChunks: persistedChunks
            )
            activeCandidateProfileID = profile.id
        case .jobDescription:
            let opportunity = try interviewContextRepository.upsertOpportunityDocument(
                documentID: document.id,
                title: document.title,
                content: document.sanitizedContent ?? document.content,
                opportunityID: activeOpportunityContextID,
                persistedChunks: persistedChunks
            )
            activeOpportunityContextID = opportunity.id
        case .additionalNotes:
            break // Notes and generated drafts are not personal facts.
        }
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        contextConfigurationOrigin = .automaticDocuments
        try contextDidChange()
    }

    private func clearAutomaticContextForNoDocuments(buildID: UUID) throws {
        try requireCurrent(buildID)
        activeCandidateProfileID = nil
        try requireCurrent(buildID)
        activeOpportunityContextID = nil
        try requireCurrent(buildID)
        activeInterviewDomainID = .general
        try requireCurrent(buildID)
        domainDidChange(.general)
        try requireCurrent(buildID)
        automaticContextBuildResult = AutomaticInterviewContextBuilder.emptyResult
        try requireCurrent(buildID)
        automaticContextReadiness = .noDocuments
        try requireCurrent(buildID)
        contextConfigurationOrigin = .automaticDocuments
        try requireCurrent(buildID)
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        try requireCurrent(buildID)
        try contextDidChange()
        try requireCurrent(buildID)
        refreshApplication()
        try requireCurrent(buildID)
    }

    private func applyAutomaticContextBuildResult(_ result: inout InterviewContextBuildResult, documents: [DocumentRecord], buildID: UUID) throws {
        try requireCurrent(buildID)
        let previousOpportunity = activeOpportunityContext
        if let candidate = result.candidateProfile {
            try requireCurrent(buildID)
            try interviewContextRepository.saveCandidateProfile(candidate)
            try requireCurrent(buildID)
            activeCandidateProfileID = candidate.id
        } else {
            try requireCurrent(buildID)
            activeCandidateProfileID = nil
        }
        if var opportunity = result.opportunityContext {
            if let previousOpportunity,
               !Set(previousOpportunity.sourceDocumentIDs).isDisjoint(with: Set(opportunity.sourceDocumentIDs)) {
                opportunity = preservingReviewedOpportunityEvidence(previousOpportunity, in: opportunity)
                let unchanged = Set(previousOpportunity.sourceDocumentIDs) == Set(opportunity.sourceDocumentIDs) &&
                    Set(previousOpportunity.allEvidence) == Set(opportunity.allEvidence)
                if unchanged {
                    opportunity = previousOpportunity
                } else {
                    opportunity.id = previousOpportunity.id
                    opportunity.version = previousOpportunity.version + 1
                }
            }
            try requireCurrent(buildID)
            try interviewContextRepository.saveOpportunityContext(opportunity)
            try requireCurrent(buildID)
            activeOpportunityContextID = opportunity.id
            result.opportunityContext = opportunity
        } else {
            try requireCurrent(buildID)
            activeOpportunityContextID = nil
        }
        try requireCurrent(buildID)
        activeInterviewDomainID = result.inferredDomain.domainID
        try requireCurrent(buildID)
        domainDidChange(activeInterviewDomainID)

        try requireCurrent(buildID)
        for classification in result.classifications {
            guard let document = documents.first(where: { $0.id == classification.documentID }) else { continue }
            try requireCurrent(buildID)
            try interviewContextRepository.associateDocument(
                documentID: document.id,
                profileID: classification.type.isCandidateSource ? activeCandidateProfileID : nil,
                opportunityID: classification.type.isOpportunitySource ? activeOpportunityContextID : nil,
                classification: classification.type.documentClassification,
                contentHash: StructuredEvidenceExtractor().contentHash(document.sanitizedContent ?? document.content)
            )
        }
        try requireCurrent(buildID)
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        try requireCurrent(buildID)
        contextConfigurationOrigin = .automaticDocuments
        try requireCurrent(buildID)
        try contextDidChange()
        try requireCurrent(buildID)
        refreshApplication()
        try requireCurrent(buildID)
        automaticContextBuildResult = result
        try requireCurrent(buildID)
        automaticContextReadiness = result.readiness
    }

    private func preservingReviewedOpportunityEvidence(
        _ previous: OpportunityContext,
        in current: OpportunityContext
    ) -> OpportunityContext {
        var current = current
        let reviewed = (
            previous.responsibilities + previous.requiredSkills + previous.preferredSkills +
                previous.researchTopics + previous.evaluationCriteria
        ).filter {
            $0.hasReviewEdits
        }
        for old in reviewed {
            let keyPaths: [WritableKeyPath<OpportunityContext, [ProfileEvidence]>] = [
                \OpportunityContext.responsibilities,
                \OpportunityContext.requiredSkills,
                \OpportunityContext.preferredSkills,
                \OpportunityContext.researchTopics,
                \OpportunityContext.evaluationCriteria
            ]
            var replaced = false
            for keyPath in keyPaths {
                if let index = current[keyPath: keyPath].firstIndex(where: {
                    $0.sourceDocumentID == old.sourceDocumentID &&
                        ($0.sourceSpan ?? $0.statement) == (old.sourceSpan ?? old.statement)
                }) {
                    current[keyPath: keyPath][index] = old
                    replaced = true
                    break
                }
            }
            if !replaced { current.responsibilities.append(old) }
        }
        return current
    }

    func confirmProfileEvidence(_ evidenceID: String, scope: InterviewContextSelection? = nil) {
        updateProfileEvidence(evidenceID, explicitness: .userConfirmed, scope: scope)
    }

    func rejectProfileEvidence(_ evidenceID: String, scope: InterviewContextSelection? = nil) {
        updateProfileEvidence(evidenceID, explicitness: .userRejected, scope: scope)
    }

    func editFactConfirmation(_ evidenceID: String, value: FactConfirmation, scope submittedScope: InterviewContextSelection? = nil) {
        guard !admissionClosed, let scope = admittedCurationScope(submittedScope) else { return }
        invalidateBuild()
        do {
            try interviewContextRepository.updateFactConfirmation(evidenceID: evidenceID, value: value, scope: scope)
            AutomaticInterviewContextBuilder.clearExtractionCache()
            refreshApplication()
            try contextDidChange()
        } catch { showError(error.localizedDescription) }
    }

    func editProfileEvidence(_ evidenceID: String, statement: String, scope submittedScope: InterviewContextSelection? = nil) {
        guard !admissionClosed, let scope = admittedCurationScope(submittedScope) else { return }
        invalidateBuild()
        do {
            try interviewContextRepository.updateEvidenceStatement(evidenceID: evidenceID, statement: statement, scope: scope)
            refreshApplication()
            try contextDidChange()
        } catch {
            showError("Could not edit extracted evidence: \(error.localizedDescription)")
        }
    }

    func createCandidateProfile(named name: String) {
        guard !admissionClosed else { return }
        invalidateBuild()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = CandidateProfile(
            id: UUID().uuidString,
            displayName: clean.isEmpty ? "Candidate Profile" : clean,
            sourceDocumentIDs: [],
            education: [], experience: [], projects: [], skills: [], publications: [], achievements: [], declaredGaps: [], goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date()
        )
        do {
            try interviewContextRepository.saveCandidateProfile(profile)
            candidateProfiles = try interviewContextRepository.candidateProfiles()
            selectCandidateProfile(profile.id)
        } catch {
            showError("Could not create candidate profile: \(error.localizedDescription)")
        }
    }

    func createOpportunityContext(named name: String) {
        guard !admissionClosed else { return }
        invalidateBuild()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let opportunity = OpportunityContext(
            id: UUID().uuidString,
            title: clean.isEmpty ? "Target Opportunity" : clean,
            organisation: nil,
            opportunityType: .general,
            responsibilities: [], requiredSkills: [], preferredSkills: [], researchTopics: [], evaluationCriteria: [],
            sourceDocumentIDs: [],
            version: 1,
            updatedAt: Date()
        )
        do {
            try interviewContextRepository.saveOpportunityContext(opportunity)
            opportunityContexts = try interviewContextRepository.opportunityContexts()
            selectOpportunityContext(opportunity.id)
        } catch {
            showError("Could not create opportunity: \(error.localizedDescription)")
        }
    }

    func addDeclaredGap(_ statement: String) {
        let clean = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              var profile = candidateProfiles.first(where: { $0.id == activeCandidateProfileID }) else { return }
        guard !admissionClosed else { return }
        invalidateBuild()
        profile.declaredGaps.append(ProfileEvidence(
            id: UUID().uuidString,
            statement: clean,
            sourceDocumentID: nil,
            sourceChunkID: nil,
            sourceSpan: nil,
            confidence: 1,
            evidenceType: .declaredGap,
            explicitness: .userConfirmed
        ))
        profile.version += 1
        profile.updatedAt = Date()
        do {
            try interviewContextRepository.saveCandidateProfile(profile)
            refreshApplication()
            try contextDidChange()
        } catch {
            showError("Could not add declared gap: \(error.localizedDescription)")
        }
    }

    private func updateProfileEvidence(_ evidenceID: String, explicitness: EvidenceExplicitness, scope submittedScope: InterviewContextSelection? = nil) {
        guard !admissionClosed, let scope = admittedCurationScope(submittedScope) else { return }
        invalidateBuild()
        do {
            try interviewContextRepository.updateEvidenceExplicitness(evidenceID: evidenceID, explicitness: explicitness, scope: scope)
            refreshApplication()
            try contextDidChange()
        } catch {
            showError("Could not update extracted evidence: \(error.localizedDescription)")
        }
    }

    // Rows bind their displayed owner. A delayed submit from an old selection
    // cannot edit the current owner or a no-longer-selected profile.
    private func admittedCurationScope(_ submitted: InterviewContextSelection?) -> InterviewContextSelection? {
        let scope = submitted ?? currentInterviewContextSelection
        guard scope.candidateProfileID != nil || scope.opportunityContextID != nil,
              scope.candidateProfileID == nil || scope.candidateProfileID == activeCandidateProfileID,
              scope.opportunityContextID == nil || scope.opportunityContextID == activeOpportunityContextID else { return nil }
        return scope
    }

    private func persistContextSelectionAndRollSnapshot() {
        do {
            try interviewContextRepository.saveSelection(currentInterviewContextSelection)
            try interviewContextRepository.saveConfigurationOrigin(.legacyManualContext)
            try contextDidChange()
        } catch {
            showError("Could not update interview context: \(error.localizedDescription)")
        }
    }


    private func beginAction(_ id: String, title: String, message: String) {
        feedback(ActionFeedback(actionID: id, title: title, message: message, kind: .loading))
    }
    private func completeAction(_ id: String, title: String, message: String) {
        feedback(ActionFeedback(actionID: id, title: title, message: message, kind: .success, autoDismissAfter: 4))
    }
    private func failAction(_ id: String, title: String, message: String) {
        feedback(ActionFeedback(actionID: id, title: title, message: message, kind: .error))
    }

    deinit {
        worker?.cancel()
        retiring.values.forEach { $0.cancel() }
    }
}
