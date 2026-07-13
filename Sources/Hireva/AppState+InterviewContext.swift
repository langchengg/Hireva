import Foundation

extension AppState {
    func groundedFallback(
        for question: String,
        contextSnapshotID: String?
    ) -> (result: GroundedFallbackResult, snapshot: InterviewContextSnapshot)? {
        guard let contextSnapshotID,
              let snapshot = try? interviewContextRepository.snapshot(id: contextSnapshotID) else {
            return nil
        }
        return (
            DynamicInterviewContextEngine().profileSafeFallback(question: question, snapshot: snapshot),
            snapshot
        )
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
        guard id == nil || candidateProfiles.contains(where: { $0.id == id }) else { return }
        if !ProductionContextPolicy.isTestProcess,
           let id,
           candidateProfiles.first(where: { $0.id == id }).map(ProductionContextPolicy.isSyntheticProfile) == true {
            return
        }
        activeCandidateProfileID = id
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func selectOpportunityContext(_ id: String?) {
        guard id == nil || opportunityContexts.contains(where: { $0.id == id }) else { return }
        if !ProductionContextPolicy.isTestProcess,
           let id,
           opportunityContexts.first(where: { $0.id == id }).map(ProductionContextPolicy.isSyntheticOpportunity) == true {
            return
        }
        activeOpportunityContextID = id
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func selectInterviewDomain(_ id: InterviewDomainID) {
        activeInterviewDomainID = id
        interviewContextMode = id == .roboticsResearch ? .phdRobotics : .general
        contextConfigurationOrigin = .legacyManualContext
        persistContextSelectionAndRollSnapshot()
    }

    func createContextBoundSession(mode: InterviewMode, title: String? = nil) throws -> InterviewSession {
        let session = try sessionRepository.createSession(
            mode: mode,
            title: title,
            contextSelection: currentInterviewContextSelection
        )
        if let snapshotID = session.contextSnapshotID {
            activeContextSnapshot = try interviewContextRepository.snapshot(id: snapshotID)
        }
        return session
    }

    @discardableResult
    func ensureContextSnapshot(for session: InterviewSession) throws -> InterviewSession {
        if let snapshotID = session.contextSnapshotID,
           let snapshot = try interviewContextRepository.snapshot(id: snapshotID) {
            activeContextSnapshot = snapshot
            return session
        }
        let snapshot = try interviewContextRepository.createSnapshot(
            sessionID: session.id,
            candidateProfileID: activeCandidateProfileID,
            opportunityContextID: activeOpportunityContextID,
            domainProfileID: activeInterviewDomainID.rawValue
        )
        try sessionRepository.attachContextSnapshot(sessionID: session.id, snapshotID: snapshot.id)
        var bound = session
        bound.contextSnapshotID = snapshot.id
        activeContextSnapshot = snapshot
        if currentSession?.id == bound.id {
            currentSession = bound
        }
        return bound
    }

    func ingestDocumentIntoActiveContext(_ document: DocumentRecord) throws {
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
            let profile = try interviewContextRepository.upsertCandidateDocument(
                documentID: document.id,
                title: activeCandidateProfileID.flatMap { id in candidateProfiles.first(where: { $0.id == id })?.displayName } ?? "Candidate Profile",
                content: document.sanitizedContent ?? document.content,
                profileID: activeCandidateProfileID,
                persistedChunks: persistedChunks
            )
            activeCandidateProfileID = profile.id
        }
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        contextConfigurationOrigin = .automaticDocuments
        try rollContextSnapshotForCurrentSession()
    }

    func scheduleAutomaticContextRebuild(useLocalQwen: Bool = true) {
        automaticContextBuildTask?.cancel()
        guard !ProductionContextPolicy.isTestProcess else { return }
        let buildID = UUID()
        automaticContextBuildID = buildID
        automaticContextBuildTask = Task { [weak self] in
            guard let self else { return }
            await self.performAutomaticInterviewContextRebuild(useLocalQwen: useLocalQwen, buildID: buildID)
        }
    }

    func rebuildAutomaticInterviewContext(useLocalQwen: Bool = true) async {
        let buildID = UUID()
        automaticContextBuildID = buildID
        await performAutomaticInterviewContextRebuild(useLocalQwen: useLocalQwen, buildID: buildID)
    }

    private func performAutomaticInterviewContextRebuild(useLocalQwen: Bool, buildID: UUID) async {
        let actionID = ActionID.buildInterviewContext
        guard automaticContextBuildID == buildID else { return }
        guard !documents.isEmpty else {
            do {
                try clearAutomaticContextForNoDocuments()
                completeAction(
                    actionID,
                    title: "Context cleared",
                    message: "Add a resume or opportunity document to build interview context."
                )
            } catch {
                automaticContextReadiness = .failed
                failAction(actionID, title: "Context reset failed", message: error.localizedDescription)
            }
            return
        }
        beginAction(
            actionID,
            title: "Building interview context",
            message: useLocalQwen ? "Local Qwen is extracting evidence from untrusted document data." : "Extracting verified document evidence."
        )
        automaticContextReadiness = .extracting
        let extractor: (any AutomaticDocumentEvidenceExtracting)? = useLocalQwen
            ? LocalQwenDocumentEvidenceExtractor(
                provider: localLLMProviderOverride ?? OllamaQwenProvider(),
                modelName: selectedQwenModelName
            )
            : nil
        let builder: any InterviewContextBuilding = automaticContextBuilderOverride ?? AutomaticInterviewContextBuilder(
            evidenceExtractor: extractor,
            chunkProvider: { [documentRepository] documentID in
                try documentRepository.chunks(documentID: documentID)
            },
            cacheNamespace: useLocalQwen ? "local-qwen-\(selectedQwenModelName)" : "verified-local-v1"
        )
        do {
            let candidateDocumentIDs = Set(documents.filter { $0.type != .jobDescription }.map(\.id))
            let previousProfile = activeCandidateProfile.flatMap { profile in
                Set(profile.sourceDocumentIDs).isDisjoint(with: candidateDocumentIDs) ? nil : profile
            }
            var result = try await builder.buildContext(
                from: documents,
                previousConfirmedProfile: previousProfile
            )
            try Task.checkCancellation()
            guard automaticContextBuildID == buildID else { throw CancellationError() }
            try applyAutomaticContextBuildResult(&result)
            completeAction(
                actionID,
                title: result.readiness == .ready ? "Interview context ready" : "Context needs review",
                message: "\(result.evidenceSummary.candidateFactCount) candidate facts and \(result.evidenceSummary.opportunityRequirementCount) opportunity requirements are available."
            )
        } catch is CancellationError {
            if automaticContextBuildID == buildID {
                actionLoadingStates[actionID] = false
            }
        } catch {
            guard automaticContextBuildID == buildID else { return }
            automaticContextReadiness = .failed
            failAction(actionID, title: "Context build failed", message: error.localizedDescription)
        }
    }

    private func clearAutomaticContextForNoDocuments() throws {
        activeCandidateProfileID = nil
        activeOpportunityContextID = nil
        activeInterviewDomainID = .general
        interviewContextMode = .general
        automaticContextBuildResult = AutomaticInterviewContextBuilder.emptyResult
        automaticContextReadiness = .noDocuments
        contextConfigurationOrigin = .automaticDocuments
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        try rollContextSnapshotForCurrentSession()
        refreshAll()
    }

    private func applyAutomaticContextBuildResult(_ result: inout InterviewContextBuildResult) throws {
        let previousOpportunity = activeOpportunityContext
        if let candidate = result.candidateProfile {
            try interviewContextRepository.saveCandidateProfile(candidate)
            activeCandidateProfileID = candidate.id
        } else {
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
            try interviewContextRepository.saveOpportunityContext(opportunity)
            activeOpportunityContextID = opportunity.id
            result.opportunityContext = opportunity
        } else {
            activeOpportunityContextID = nil
        }
        activeInterviewDomainID = result.inferredDomain.domainID
        interviewContextMode = activeInterviewDomainID == .roboticsResearch ? .phdRobotics : .general

        for classification in result.classifications {
            guard let document = documents.first(where: { $0.id == classification.documentID }) else { continue }
            try interviewContextRepository.associateDocument(
                documentID: document.id,
                profileID: classification.type.isCandidateSource ? activeCandidateProfileID : nil,
                opportunityID: classification.type.isOpportunitySource ? activeOpportunityContextID : nil,
                classification: classification.type.documentClassification,
                contentHash: StructuredEvidenceExtractor().contentHash(document.sanitizedContent ?? document.content)
            )
        }
        try interviewContextRepository.saveSelection(currentInterviewContextSelection)
        try interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
        contextConfigurationOrigin = .automaticDocuments
        try rollContextSnapshotForCurrentSession()
        refreshAll()
        automaticContextBuildResult = result
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
            $0.explicitness == .userConfirmed || $0.explicitness == .userRejected
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

    func confirmProfileEvidence(_ evidenceID: String) {
        updateProfileEvidence(evidenceID, explicitness: .userConfirmed)
    }

    func rejectProfileEvidence(_ evidenceID: String) {
        updateProfileEvidence(evidenceID, explicitness: .userRejected)
    }

    func editProfileEvidence(_ evidenceID: String, statement: String) {
        do {
            try interviewContextRepository.updateEvidenceStatement(evidenceID: evidenceID, statement: statement)
            refreshAll()
            try rollContextSnapshotForCurrentSession()
        } catch {
            showError("Could not edit extracted evidence: \(error.localizedDescription)")
        }
    }

    func createCandidateProfile(named name: String) {
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
            refreshAll()
            try rollContextSnapshotForCurrentSession()
        } catch {
            showError("Could not add declared gap: \(error.localizedDescription)")
        }
    }

    private func updateProfileEvidence(_ evidenceID: String, explicitness: EvidenceExplicitness) {
        do {
            try interviewContextRepository.updateEvidenceExplicitness(evidenceID: evidenceID, explicitness: explicitness)
            refreshAll()
            try rollContextSnapshotForCurrentSession()
        } catch {
            showError("Could not update extracted evidence: \(error.localizedDescription)")
        }
    }

    private func persistContextSelectionAndRollSnapshot() {
        do {
            try interviewContextRepository.saveSelection(currentInterviewContextSelection)
            try interviewContextRepository.saveConfigurationOrigin(.legacyManualContext)
            try rollContextSnapshotForCurrentSession()
        } catch {
            showError("Could not update interview context: \(error.localizedDescription)")
        }
    }

    private func rollContextSnapshotForCurrentSession() throws {
        guard var session = currentSession else { return }
        if activeGenerationController != nil ||
            activeAITask != nil ||
            isActionLoading(ActionID.generateAnswer) ||
            isActionLoading(ActionID.manualGenerate) ||
            isActionLoading(ActionID.floatingRegenerate) {
            cancelActiveGenerationForContextChange()
        }
        precomputeDebounceTask?.cancel()
        precomputeDebounceTask = nil
        precomputedRAGCache.removeAll()
        let snapshot = try interviewContextRepository.createSnapshot(
            sessionID: session.id,
            candidateProfileID: activeCandidateProfileID,
            opportunityContextID: activeOpportunityContextID,
            domainProfileID: activeInterviewDomainID.rawValue
        )
        try sessionRepository.attachContextSnapshot(sessionID: session.id, snapshotID: snapshot.id)
        session.contextSnapshotID = snapshot.id
        currentSession = session
        activeContextSnapshot = snapshot
    }
}
