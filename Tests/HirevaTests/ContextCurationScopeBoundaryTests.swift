import Foundation
import Testing
@testable import Hireva

@MainActor
struct ContextCurationScopeBoundaryTests {
    enum Change: CaseIterable { case statement, confirmation, rejection }

    @Test(.timeLimit(.minutes(1)), arguments: Change.allCases, [false, true])
    func identicalSourceEvidenceChangesOnlyItsDisplayedOwner(change: Change, opportunityRow: Bool) async throws {
        try await withFixture { (fixture: Fixture) async throws -> Void in
            let scope = InterviewContextSelection(
                candidateProfileID: opportunityRow ? nil : fixture.candidate.id,
                opportunityContextID: opportunityRow ? fixture.opportunity.id : nil,
                domainProfileID: .general)
            apply(change, to: fixture.app.interviewContextState, scope: scope)
            let candidate = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.candidate.id))
            let opportunity = try #require(try fixture.app.interviewContextRepository.opportunityContext(id: fixture.opportunity.id))
            let changed = opportunityRow ? opportunity.reviewEvidence : candidate.reviewEvidence
            let row = try #require(changed.first { $0.id == Self.evidenceID })
            switch change {
            case .statement:
                #expect(row.statement == Self.editedStatement)
                #expect(row.explicitness == .inferred)
                #expect(row.confirmation == nil)
            case .confirmation:
                #expect(row.confirmation == Self.boundary)
                #expect(row.explicitness == .inferred)
                #expect(row.statement == Self.evidence.statement)
            case .rejection:
                #expect(row.explicitness == .userRejected)
                #expect(!(opportunityRow ? opportunity.allEvidence : candidate.allEvidence).contains { $0.id == Self.evidenceID })
            }
            #expect(row.sourceSpan == Self.evidence.sourceSpan)
            #expect(row.sourceDocumentID == Self.evidence.sourceDocumentID)
            if opportunityRow {
                #expect(candidate == fixture.candidate)
                #expect(opportunity.version == fixture.opportunity.version + 1)
            } else {
                #expect(opportunity == fixture.opportunity)
                #expect(candidate.version == fixture.candidate.version + 1)
            }
            #expect(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.otherCandidate.id) == fixture.otherCandidate)
            #expect(try fixture.app.interviewContextRepository.opportunityContext(id: fixture.otherOpportunity.id) == fixture.otherOpportunity)
            #expect(try fixture.app.interviewContextRepository.snapshot(id: fixture.historical.id) == fixture.historical)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func oldRowSubmissionDoesNotEditNewSelectionCreateSnapshotOrCancelItsBuild() async throws {
        try await withFixture { (fixture: Fixture) async throws -> Void in
            let oldScope = InterviewContextSelection(candidateProfileID: fixture.candidate.id,
                opportunityContextID: nil, domainProfileID: .general)
            fixture.app.selectCandidateProfile(fixture.otherCandidate.id)
            let worker = try #require(fixture.app.interviewContextState.requestRebuild(useLocalQwen: false))
            try await fixture.builder.waitUntilStarted()
            let buildID = fixture.app.automaticContextBuildID
            let snapshotID = fixture.app.currentSession?.contextSnapshotID
            let snapshots = try fixture.app.interviewContextRepository.snapshots(sessionID: fixture.session.id)
            let pending = fixture.app.interviewContextState.pendingTaskCount
            let source = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.candidate.id))
            let selected = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.otherCandidate.id))
            for change in Change.allCases { apply(change, to: fixture.app.interviewContextState, scope: oldScope) }
            #expect(!worker.isCancelled)
            #expect(fixture.app.automaticContextBuildID == buildID)
            #expect(fixture.app.interviewContextState.pendingTaskCount == pending)
            #expect(fixture.app.currentSession?.contextSnapshotID == snapshotID)
            #expect(try fixture.app.interviewContextRepository.snapshots(sessionID: fixture.session.id) == snapshots)
            #expect(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.candidate.id) == source)
            #expect(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.otherCandidate.id) == selected)
            fixture.app.interviewContextState.invalidateBuild()
            await fixture.builder.release()
            await worker.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitlyEmptyOwnerScopeCannotFallBackToAnySelectedOrHistoricalRow() async throws {
        try await withFixture { (fixture: Fixture) async throws -> Void in
            let empty = InterviewContextSelection(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general)
            let snapshots = try fixture.app.interviewContextRepository.snapshots(sessionID: fixture.session.id)
            let buildID = fixture.app.automaticContextBuildID
            let pending = fixture.app.interviewContextState.pendingTaskCount
            for change in Change.allCases { apply(change, to: fixture.app.interviewContextState, scope: empty) }
            #expect(fixture.app.automaticContextBuildID == buildID)
            #expect(fixture.app.interviewContextState.pendingTaskCount == pending)
            #expect(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.candidate.id) == fixture.candidate)
            #expect(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.otherCandidate.id) == fixture.otherCandidate)
            #expect(try fixture.app.interviewContextRepository.opportunityContext(id: fixture.opportunity.id) == fixture.opportunity)
            #expect(try fixture.app.interviewContextRepository.opportunityContext(id: fixture.otherOpportunity.id) == fixture.otherOpportunity)
            #expect(try fixture.app.interviewContextRepository.snapshots(sessionID: fixture.session.id) == snapshots)
        }
    }

    private static let evidenceID = "synthetic-same-source-evidence"
    private static let editedStatement = "Synthetic corrected source contribution remains planned."
    private static let evidence = ProfileEvidence(id: evidenceID,
        statement: "Synthetic source contribution is recorded for this review fixture.",
        sourceDocumentID: "synthetic-shared-document", sourceChunkID: nil,
        sourceSpan: "Synthetic source contribution is recorded for this review fixture.",
        confidence: 1, evidenceType: .project, explicitness: .userConfirmed)
    private static var boundary: FactConfirmation {
        var value = FactConfirmation(); value.status = "planned"; value.environment = "simulation"
        value.conditions = "Synthetic review conditions only."; return value
    }
    private func apply(_ change: Change, to owner: InterviewContextState, scope: InterviewContextSelection) {
        switch change {
        case .statement: owner.editProfileEvidence(Self.evidenceID, statement: Self.editedStatement, scope: scope)
        case .confirmation: owner.editFactConfirmation(Self.evidenceID, value: Self.boundary, scope: scope)
        case .rejection: owner.rejectProfileEvidence(Self.evidenceID, scope: scope)
        }
    }

    private struct Fixture {
        let app: AppState
        let builder: ScopeBoundaryBuilder
        let session: InterviewSession
        let candidate: CandidateProfile
        let otherCandidate: CandidateProfile
        let opportunity: OpportunityContext
        let otherOpportunity: OpportunityContext
        let historical: InterviewContextSnapshot
    }
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let database = try await TestSupport.makeInMemoryDatabase()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let builder = ScopeBoundaryBuilder()
        app.automaticContextBuilderOverride = builder
        do {
            _ = try app.documentRepository.saveDocument(type: .cv, title: "Synthetic review source",
                content: "Synthetic source contribution is recorded for this review fixture.")
            let candidate = CandidateProfile(id: "synthetic-scope-candidate", displayName: "Synthetic selected profile", sourceDocumentIDs: [],
                education: [], experience: [], projects: [Self.evidence], skills: [], publications: [], achievements: [], declaredGaps: [], goals: [],
                generatedSummary: nil, version: 1, updatedAt: Date(timeIntervalSince1970: 1))
            var otherCandidate = candidate; otherCandidate.id = "synthetic-scope-other-candidate"
            otherCandidate.updatedAt = Date(timeIntervalSince1970: 2)
            var targetEvidence = Self.evidence; targetEvidence.evidenceType = .evaluationCriterion
            let opportunity = OpportunityContext(id: "synthetic-scope-opportunity", title: "Synthetic selected opportunity", organisation: nil,
                opportunityType: .general, responsibilities: [], requiredSkills: [], preferredSkills: [], researchTopics: [], evaluationCriteria: [targetEvidence],
                sourceDocumentIDs: [], version: 1, updatedAt: Date(timeIntervalSince1970: 1))
            var otherOpportunity = opportunity; otherOpportunity.id = "synthetic-scope-other-opportunity"
            otherOpportunity.updatedAt = Date(timeIntervalSince1970: 2)
            try app.interviewContextRepository.saveCandidateProfile(candidate)
            try app.interviewContextRepository.saveCandidateProfile(otherCandidate)
            try app.interviewContextRepository.saveOpportunityContext(opportunity)
            try app.interviewContextRepository.saveOpportunityContext(otherOpportunity)
            app.refreshAll(); app.selectCandidateProfile(candidate.id); app.selectOpportunityContext(opportunity.id)
            let session = try app.createContextBoundSession(mode: .mock); app.currentSession = session
            let historicalID = try #require(session.contextSnapshotID)
            let historical = try #require(try app.interviewContextRepository.snapshot(id: historicalID))
            try await body(.init(app: app, builder: builder, session: session, candidate: candidate,
                otherCandidate: otherCandidate, opportunity: opportunity, otherOpportunity: otherOpportunity, historical: historical))
            await builder.release(); await app.shutdownForTesting(); try database.close()
        } catch {
            await builder.release(); await app.shutdownForTesting(); try? database.close(); throw error
        }
    }
}

private actor ScopeBoundaryBuilder: InterviewContextBuilding {
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async throws {
        _ = try await TestEventWaitTrace(label: "curation_scope.builder").nextEvent(in: started.stream, event: "registered")
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func buildContext(from documents: [DocumentRecord], previousConfirmedProfile: CandidateProfile?) async throws -> InterviewContextBuildResult {
        started.continuation.yield(()); started.continuation.finish()
        if !released { await withCheckedContinuation { waiter = $0 } }
        return AutomaticInterviewContextBuilder.emptyResult
    }
}
