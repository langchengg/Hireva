import Foundation
import Testing
@testable import Hireva

// Synthetic source and boundaries only. The real App entry, repository,
// session snapshot creation and JSON round trip remain under test.
@MainActor
struct OpportunityFactConfirmationBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func opportunityBoundaryDraftIsSavedWithoutChangingItsHistoricalSnapshot() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            let evidence = ProfileEvidence(id: "synthetic-opportunity-boundary-evidence",
                statement: "The synthetic role requires evaluation in a simulated environment.",
                sourceDocumentID: nil, sourceChunkID: nil,
                sourceSpan: "The synthetic role requires evaluation in a simulated environment.",
                confidence: 1, evidenceType: .evaluationCriterion, explicitness: .userConfirmed)
            let opportunity = OpportunityContext(id: "synthetic-opportunity-boundary-owner",
                title: "Synthetic opportunity boundary fixture", organisation: nil,
                opportunityType: .general, responsibilities: [], requiredSkills: [],
                preferredSkills: [], researchTopics: [], evaluationCriteria: [evidence],
                sourceDocumentIDs: [], version: 1, updatedAt: Date(timeIntervalSince1970: 1))
            try app.interviewContextRepository.saveOpportunityContext(opportunity)
            app.refreshAll()
            app.selectCandidateProfile(nil)
            app.selectOpportunityContext(opportunity.id)
            #expect(app.activeCandidateProfileID == nil)
            #expect(app.activeOpportunityContextID == opportunity.id)
            let session = try app.createContextBoundSession(mode: .mock)
            app.currentSession = session
            let historicalID = try #require(session.contextSnapshotID)
            let historical = try #require(try app.interviewContextRepository.snapshot(id: historicalID))
            #expect(historical.opportunityEvidence == [evidence])
            var boundary = FactConfirmation()
            boundary.status = "planned"
            boundary.environment = "simulation"
            boundary.conditions = "Synthetic scope; no observed completed experiment."
            app.editFactConfirmation(evidence.id, value: boundary)
            let saved = try #require(try app.interviewContextRepository.opportunityContext(id: opportunity.id))
            let draft = try #require(saved.reviewEvidence.first { $0.id == evidence.id })
            #expect(draft.confirmation == boundary)
            #expect(draft.explicitness == .inferred)
            #expect(draft.statement == evidence.statement)
            #expect(draft.sourceSpan == evidence.sourceSpan)
            #expect(saved.version == opportunity.version + 1)
            #expect(!saved.allEvidence.contains { $0.id == evidence.id })
            #expect(try app.interviewContextRepository.snapshot(id: historicalID) == historical)
            #expect(app.currentSession?.contextSnapshotID != historicalID)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }
}
