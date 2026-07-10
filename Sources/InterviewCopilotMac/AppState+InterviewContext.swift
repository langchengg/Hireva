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

    func selectCandidateProfile(_ id: String?) {
        guard id == nil || candidateProfiles.contains(where: { $0.id == id }) else { return }
        activeCandidateProfileID = id
        persistContextSelectionAndRollSnapshot()
    }

    func selectOpportunityContext(_ id: String?) {
        guard id == nil || opportunityContexts.contains(where: { $0.id == id }) else { return }
        activeOpportunityContextID = id
        persistContextSelectionAndRollSnapshot()
    }

    func selectInterviewDomain(_ id: InterviewDomainID) {
        activeInterviewDomainID = id
        interviewContextMode = id == .roboticsResearch ? .phdRobotics : .general
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
        try rollContextSnapshotForCurrentSession()
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
            try rollContextSnapshotForCurrentSession()
        } catch {
            showError("Could not update interview context: \(error.localizedDescription)")
        }
    }

    private func rollContextSnapshotForCurrentSession() throws {
        guard var session = currentSession else { return }
        if activeGenerationController != nil {
            cancelActiveGenerationForStop()
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
