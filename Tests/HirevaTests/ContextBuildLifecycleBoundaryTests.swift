import Foundation
import Testing
@testable import Hireva

// All inputs are declared synthetic. The fake supplies a frozen response only;
// selection, revision, publication and persistence use the real AppState paths.
@MainActor
struct ContextBuildLifecycleBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["candidate", "opportunity", "both"])
    func explicitNoneSelectionSurvivesRefreshAndNewSession(clear: String) async throws {
        try await withLinkedContext { app, candidate, opportunity in
            app.selectCandidateProfile(candidate.id)
            app.selectOpportunityContext(opportunity.id)
            #expect(ASRConfig.opportunityTerms(app.activeOpportunityContext) == ["deduplication"])
            let clearCandidate = clear != "opportunity", clearOpportunity = clear != "candidate"
            if clearOpportunity { app.selectOpportunityContext(nil) }
            if clearCandidate { app.selectCandidateProfile(nil) }
            app.refreshAll()
            app.refreshAll()
            #expect(app.activeOpportunityContextID == (clearOpportunity ? nil : opportunity.id))
            #expect(app.activeCandidateProfileID == (clearCandidate ? nil : candidate.id))
            #expect(app.contextConfigurationOrigin == .legacyManualContext)
            #expect(ASRConfig.opportunityTerms(app.activeOpportunityContext) == (clearOpportunity ? [] : ["deduplication"]))
            let selection = try app.interviewContextRepository.loadSelection()
            #expect(selection.candidateProfileID == (clearCandidate ? nil : candidate.id))
            #expect(selection.opportunityContextID == (clearOpportunity ? nil : opportunity.id))
            let session = try app.createContextBoundSession(mode: .mock)
            let snapshot = try #require(app.activeContextSnapshot)
            #expect(snapshot.sessionID == session.id)
            #expect(snapshot.candidateProfileID == (clearCandidate ? nil : candidate.id))
            #expect(snapshot.opportunityContextID == (clearOpportunity ? nil : opportunity.id))
            #expect(snapshot.opportunityEvidence.isEmpty == clearOpportunity)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["unconfigured", "automatic", "legacy-partial"])
    func initialDocumentSelectionAndLegacyPartialSelectionKeepTheirOwnMeaning(origin: String) async throws {
        try await withLinkedContext { app, candidate, opportunity in
            try app.interviewContextRepository.saveSelection(.init(
                candidateProfileID: origin == "legacy-partial" ? candidate.id : nil,
                opportunityContextID: nil, domainProfileID: .general))
            if origin == "automatic" {
                try app.interviewContextRepository.saveConfigurationOrigin(.automaticDocuments)
            }
            app.refreshAll()
            #expect(app.activeCandidateProfileID == candidate.id)
            #expect(app.activeOpportunityContextID == (origin == "legacy-partial" ? nil : opportunity.id))
            if origin == "legacy-partial" {
                #expect(app.contextConfigurationOrigin == .legacyManualContext)
                #expect(ASRConfig.opportunityTerms(app.activeOpportunityContext).isEmpty)
            }
        }
    }

    private func withLinkedContext(_ body: @MainActor (AppState, CandidateProfile, OpportunityContext) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        do {
            let cv = try app.documentRepository.saveDocument(type: .cv, title: "Controlled candidate document",
                content: "Isolated synthetic input: I tested database transaction boundaries in a learning prototype.")
            let jd = try app.documentRepository.saveDocument(type: .jobDescription, title: "Controlled opportunity document",
                content: "Isolated synthetic role requiring notification delivery and deduplication.")
            let candidate = CandidateProfile(id: UUID().uuidString, displayName: "Controlled candidate",
                sourceDocumentIDs: [cv.id], education: [], experience: [], projects: [], skills: [], publications: [],
                achievements: [], declaredGaps: [], goals: [], generatedSummary: nil, version: 1, updatedAt: .now)
            let opportunity = OpportunityContext(id: UUID().uuidString, title: "Controlled opportunity", opportunityType: .job,
                responsibilities: [], requiredSkills: [.init(id: UUID().uuidString, statement: "deduplication",
                    sourceDocumentID: jd.id, confidence: 1, evidenceType: .requiredSkill, explicitness: .explicit)],
                preferredSkills: [], researchTopics: [], evaluationCriteria: [], sourceDocumentIDs: [jd.id],
                version: 1, updatedAt: .now)
            try app.interviewContextRepository.saveCandidateProfile(candidate)
            try app.interviewContextRepository.saveOpportunityContext(opportunity)
            app.refreshAll()
            try await body(app, candidate, opportunity)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func laterManualContextMutationRejectsTheAlreadyStartedBuild(order: Int) async throws {
        // Twenty controlled executions, five mutation kinds repeated four times.
        // Each fresh fixture has its own unchanged deadline; these cases remain serial.
        do {
            let mutation = Mutation.allCases[order % Mutation.allCases.count]
            try await withFixture { fixture in
                let builder = HeldContextBuilder(result: fixture.lateResult)
                fixture.app.automaticContextBuilderOverride = builder
                let request = Task { await fixture.app.rebuildAutomaticInterviewContext(useLocalQwen: false) }
                do {
                    try await builder.waitUntilStarted(label: "context.mutation.\(order)")
                    let startedWorker = fixture.app.automaticContextBuildTask
                    let startedBuildID = fixture.app.automaticContextBuildID
                    var revisedConfirmation = FactConfirmation()
                    revisedConfirmation.status = "planned"
                    revisedConfirmation.contribution = "Synthetic future plan; no completed deployment."
                    switch mutation {
                    case .candidateSelection:
                        fixture.app.selectCandidateProfile(fixture.manualProfile.id)
                    case .domainSelection:
                        fixture.app.selectInterviewDomain(.finance)
                    case .statementRevision:
                        fixture.app.editProfileEvidence(fixture.evidenceID,
                            statement: "Synthetic corrected contribution retained after the delayed build.")
                    case .confirmationRevision:
                        fixture.app.editFactConfirmation(fixture.evidenceID, value: revisedConfirmation)
                    case .rejection:
                        fixture.app.rejectProfileEvidence(fixture.evidenceID)
                    }
                    let primaryBeforeRelease = try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id)
                    let otherBeforeRelease = try fixture.app.interviewContextRepository.candidateProfile(id: fixture.manualProfile.id)
                    let trace: [String: Any] = [
                        "event": "manualMutationBeforeBuilderRelease", "order": order,
                        "mutation": String(describing: mutation),
                        "primaryVersion": primaryBeforeRelease?.version ?? -1,
                        "otherVersion": otherBeforeRelease?.version ?? -1,
                        "startedWorkerCancelled": startedWorker?.isCancelled ?? false,
                        "buildIdentityInvalidated": fixture.app.automaticContextBuildID != startedBuildID
                    ]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: trace, options: .sortedKeys), as: UTF8.self))
                    await builder.release()
                    await request.value
                    switch mutation {
                    case .candidateSelection:
                        #expect(fixture.app.activeCandidateProfileID == fixture.manualProfile.id)
                        #expect(try fixture.app.interviewContextRepository.loadSelection().candidateProfileID == fixture.manualProfile.id)
                        #expect(fixture.app.contextConfigurationOrigin == .legacyManualContext)
                    case .domainSelection:
                        #expect(fixture.app.activeInterviewDomainID == .finance)
                        #expect(try fixture.app.interviewContextRepository.loadSelection().domainProfileID == .finance)
                    case .statementRevision:
                        let saved = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
                        let evidence = try #require(saved.reviewEvidence.first { $0.id == fixture.evidenceID })
                        #expect(evidence.statement == "Synthetic corrected contribution retained after the delayed build.")
                        #expect(evidence.explicitness == .inferred)
                    case .confirmationRevision:
                        let saved = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
                        let evidence = try #require(saved.reviewEvidence.first { $0.id == fixture.evidenceID })
                        #expect(evidence.confirmation == revisedConfirmation)
                        #expect(evidence.explicitness == .inferred)
                    case .rejection:
                        let saved = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
                        let evidence = try #require(saved.reviewEvidence.first { $0.id == fixture.evidenceID })
                        #expect(evidence.explicitness == .userRejected)
                        #expect(!saved.allEvidence.contains { $0.id == fixture.evidenceID })
                    }
                    #expect(!fixture.app.isActionLoading(ActionID.buildInterviewContext))
                } catch {
                    await builder.release()
                    request.cancel()
                    await request.value
                    throw error
                }
                // Also release/join when nonthrowing #expect records an issue.
                await builder.release()
                request.cancel()
                await request.value
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func directRebuildRegistersTheRealWorkerAndLivePauseCancelsIt() async throws {
        try await withFixture { fixture in
            let builder = HeldContextBuilder(result: fixture.lateResult)
            fixture.app.automaticContextBuilderOverride = builder
            let request = Task { await fixture.app.rebuildAutomaticInterviewContext(useLocalQwen: false) }
            do {
                try await builder.waitUntilStarted(label: "context.actual_worker_registration")
                let ownedWorker = fixture.app.automaticContextBuildTask
                #expect(ownedWorker != nil)
                fixture.app.pausePreparationForLive()
                #expect(ownedWorker?.isCancelled == true)
                await builder.release()
                await request.value
                let saved = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
                #expect(saved.version == fixture.originalProfile.version)
                #expect(!fixture.app.isActionLoading(ActionID.buildInterviewContext))
            } catch {
                await builder.release()
                request.cancel()
                await request.value
                throw error
            }
            await builder.release()
            request.cancel()
            await request.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func directRebuildCannotOpenWorkAfterApplicationShutdown() async throws {
        try await withFixture { fixture in
            let builder = HeldContextBuilder(result: fixture.lateResult)
            fixture.app.automaticContextBuilderOverride = builder
            await fixture.app.shutdownForTesting()
            let before = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
            let readiness = fixture.app.automaticContextReadiness
            await builder.release() // A red-path unexpected invocation must not hang the suite.
            await fixture.app.rebuildAutomaticInterviewContext(useLocalQwen: false)
            let calls = await builder.callCount
            #expect(calls == 0)
            let after = try #require(try fixture.app.interviewContextRepository.candidateProfile(id: fixture.originalProfile.id))
            #expect(after == before)
            #expect(fixture.app.automaticContextReadiness == readiness)
            #expect(!fixture.app.isActionLoading(ActionID.buildInterviewContext))
        }
    }

    private enum Mutation: CaseIterable {
        case candidateSelection, domainSelection, statementRevision, confirmationRevision, rejection
    }

    private struct Fixture {
        let app: AppState
        let database: AppDatabase
        let originalProfile: CandidateProfile
        let manualProfile: CandidateProfile
        let evidenceID: String
        let lateResult: InterviewContextBuildResult
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        do {
            let document = try app.documentRepository.saveDocument(type: .cv,
                title: "Synthetic context lifecycle document",
                content: "Synthetic candidate: I implemented database transactions in an isolated rehearsal project. This fixture describes no real person or actual user material.")
            let evidenceID = "context-original-evidence"
            let evidence = ProfileEvidence(id: evidenceID,
                statement: "Synthetic original contribution before the held build.",
                sourceDocumentID: document.id, sourceChunkID: nil,
                sourceSpan: "I implemented database transactions in an isolated rehearsal project.",
                confidence: 1, evidenceType: .project, explicitness: .userConfirmed)
            let original = makeProfile(id: "context-original-profile", documentID: document.id, evidence: evidence)
            var manual = original
            manual.id = "context-selected-later-profile"
            manual.displayName = "Synthetic later selected profile"
            try app.interviewContextRepository.saveCandidateProfile(original)
            try app.interviewContextRepository.saveCandidateProfile(manual)
            app.refreshAll()
            app.selectCandidateProfile(original.id)
            var result = AutomaticInterviewContextBuilder.emptyResult
            var lateProfile = original
            lateProfile.version += 50
            result.candidateProfile = lateProfile
            result.readiness = .ready
            result.inferredDomain = InferredInterviewDomain(domainID: .softwareEngineering,
                displayName: "Software Engineering", confidence: 1, evidenceIDs: [evidenceID], alternatives: [])
            result.classifications = [.init(documentID: document.id, type: .resume, confidence: 1,
                reason: "Synthetic frozen build response")]
            result.evidenceSummary = .init(candidateFactCount: 1, opportunityRequirementCount: 0,
                uncertainFactCount: 0, conflictCount: 0,
                candidateSourceTitles: [document.title], opportunitySourceTitles: [])
            let fixture = Fixture(app: app, database: database, originalProfile: original,
                manualProfile: manual, evidenceID: evidenceID, lateResult: result)
            try await body(fixture)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private func makeProfile(id: String, documentID: String, evidence: ProfileEvidence) -> CandidateProfile {
        .init(id: id, displayName: "Synthetic original profile", sourceDocumentIDs: [documentID],
            education: [], experience: [], projects: [evidence], skills: [], publications: [],
            achievements: [], declaredGaps: [], goals: [], generatedSummary: nil,
            version: 1, updatedAt: Date(timeIntervalSince1970: 1))
    }
}

private actor HeldContextBuilder: InterviewContextBuilding {
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let result: InterviewContextBuildResult
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(result: InterviewContextBuildResult) { self.result = result }

    nonisolated func waitUntilStarted(label: String) async throws {
        _ = try await TestEventWaitTrace(label: label).nextEvent(in: entered.stream, event: "builder.started")
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func buildContext(from documents: [DocumentRecord], previousConfirmedProfile: CandidateProfile?) async throws -> InterviewContextBuildResult {
        callCount += 1
        entered.continuation.yield(())
        // Deliberately noncooperative: identity/DB checks cannot rely on the
        // fake stopping itself. Every fixture releases and joins this latch.
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseContinuation = continuation }
        }
        return result
    }
}
