import Foundation

extension AppState {
    func groundedFallback(
        for question: String,
        contextSnapshotID: String?,
        task: InterviewTaskDescriptor? = nil
    ) -> (result: GroundedFallbackResult, snapshot: InterviewContextSnapshot)? {
        guard PromptContextBuilder.usesProfileContext(
            task ?? InterviewTaskDescriptor(question: question)
        ) else { return nil }
        guard let contextSnapshotID,
              let snapshot = try? interviewContextRepository.snapshot(id: contextSnapshotID) else {
            return nil
        }
        let result = DynamicInterviewContextEngine().profileSafeFallback(question: question, snapshot: snapshot)
        guard result.status == .grounded, result.unsupportedClaims.isEmpty else { return nil }
        return (result, snapshot)
    }

    var currentInterviewContextSelection: InterviewContextSelection { interviewContextState.currentInterviewContextSelection }
    var contextReadiness: InterviewContextReadiness { interviewContextState.contextReadiness }
    var productionCandidateProfiles: [CandidateProfile] { interviewContextState.productionCandidateProfiles }
    var productionOpportunityContexts: [OpportunityContext] { interviewContextState.productionOpportunityContexts }
    var activeCandidateProfile: CandidateProfile? { interviewContextState.activeCandidateProfile }
    var activeOpportunityContext: OpportunityContext? { interviewContextState.activeOpportunityContext }

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
        try interviewContextState.ingestDocumentIntoActiveContext(document)
    }
    func scheduleAutomaticContextRebuild(useLocalQwen: Bool = true) {
        guard !ProductionContextPolicy.isTestProcess else {
            interviewContextState.invalidateBuild()
            return
        }
        interviewContextState.requestRebuild(useLocalQwen: useLocalQwen)
    }
    func rebuildAutomaticInterviewContext(useLocalQwen: Bool = true) async {
        await interviewContextState.rebuild(useLocalQwen: useLocalQwen)
    }
    func selectCandidateProfile(_ id: String?) { interviewContextState.selectCandidateProfile(id) }
    func selectOpportunityContext(_ id: String?) { interviewContextState.selectOpportunityContext(id) }
    func selectInterviewDomain(_ id: InterviewDomainID) { interviewContextState.selectInterviewDomain(id) }
    func confirmProfileEvidence(_ evidenceID: String) { interviewContextState.confirmProfileEvidence(evidenceID) }
    func rejectProfileEvidence(_ evidenceID: String) { interviewContextState.rejectProfileEvidence(evidenceID) }
    func editFactConfirmation(_ evidenceID: String, value: FactConfirmation) { interviewContextState.editFactConfirmation(evidenceID, value: value) }
    func editProfileEvidence(_ evidenceID: String, statement: String) { interviewContextState.editProfileEvidence(evidenceID, statement: statement) }
    func createCandidateProfile(named name: String) { interviewContextState.createCandidateProfile(named: name) }
    func createOpportunityContext(named name: String) { interviewContextState.createOpportunityContext(named: name) }
    func addDeclaredGap(_ statement: String) { interviewContextState.addDeclaredGap(statement) }

    func rollContextSnapshotForCurrentSession() throws {
        guard let existingSession = currentSession else { return }
        // Selection revokes pending work even for an unsaved temporary session.
        // Repository availability controls snapshot persistence, not revocation.
        if activeGenerationController != nil ||
            generationCoordinator.activeRequest != nil ||
            activeAITask != nil ||
            isActionLoading(ActionID.generateAnswer) ||
            isActionLoading(ActionID.manualGenerate) ||
            isActionLoading(ActionID.floatingRegenerate) {
            guard cancelActiveGenerationForContextChange() else { return }
        }
        liveRAGPrefetch.cancelAndClear()
        guard currentSession?.id == existingSession.id,
              var session = try sessionRepository.session(id: existingSession.id),
              session.endedAt == nil else { return }
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
