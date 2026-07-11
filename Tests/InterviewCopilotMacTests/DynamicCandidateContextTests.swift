import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct DynamicCandidateContextTests {
    @Test
    func syntheticProfileFixturesArePackagedAndDomainDistinct() throws {
        let names = [
            "robotics_phd_candidate_profile",
            "backend_candidate_profile",
            "data_scientist_candidate_profile",
            "product_manager_candidate_profile",
            "cybersecurity_candidate_profile",
            "biomedical_candidate_profile"
        ]
        var payloads: [String: String] = [:]
        for name in names {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
            let data = try Data(contentsOf: url)
            _ = try JSONSerialization.jsonObject(with: data)
            payloads[name] = String(decoding: data, as: UTF8.self)
        }

        #expect(payloads["backend_candidate_profile"]?.localizedCaseInsensitiveContains("Kafka") == true)
        #expect(payloads["backend_candidate_profile"]?.localizedCaseInsensitiveContains("tactile") == false)
        #expect(payloads["robotics_phd_candidate_profile"]?.localizedCaseInsensitiveContains("Kubernetes") == false)
        #expect(payloads["cybersecurity_candidate_profile"]?.localizedCaseInsensitiveContains("incident") == true)
        #expect(payloads["biomedical_candidate_profile"]?.localizedCaseInsensitiveContains("assay") == true)
    }

    @Test
    func newDatabaseHasNoCandidateSpecificDefault() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextEmpty")
        let repository = InterviewContextRepository(database: database)

        #expect(try repository.candidateProfiles().isEmpty)
        #expect(try repository.opportunityContexts().isEmpty)
    }

    @Test
    func profileEvidenceRoundTripsWithProvenanceAndReviewState() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextEvidence")
        let repository = InterviewContextRepository(database: database)
        let profile = SyntheticContextFixtures.backendProfile()
        try repository.saveCandidateProfile(profile)

        let loaded = try repository.candidateProfile(id: profile.id)
        let saved = try #require(loaded)
        #expect(saved.version == 1)
        #expect(saved.allEvidence.count == profile.allEvidence.count)
        #expect(saved.projects.first?.sourceDocumentID == "document-backend-project")
        #expect(saved.projects.first?.sourceChunkID == "backend-project")
        #expect(saved.projects.first?.explicitness == .explicit)

        let inferred = try #require(saved.skills.first(where: { $0.explicitness == .inferred }))
        try repository.updateEvidenceExplicitness(
            evidenceID: inferred.id,
            explicitness: .userConfirmed
        )
        #expect(try repository.candidateProfile(id: profile.id)?.skills.first(where: { $0.id == inferred.id })?.explicitness == .userConfirmed)
    }

    @Test
    func snapshotFreezesProfileAndOpportunityVersions() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextSnapshot")
        let repository = InterviewContextRepository(database: database)
        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Snapshot")
        let profile = SyntheticContextFixtures.roboticsProfile()
        let opportunity = SyntheticContextFixtures.roboticsOpportunity()
        try repository.saveCandidateProfile(profile)
        try repository.saveOpportunityContext(opportunity)

        let snapshot = try repository.createSnapshot(
            sessionID: session.id,
            candidateProfileID: profile.id,
            opportunityContextID: opportunity.id,
            domainProfileID: InterviewDomainID.roboticsResearch.rawValue
        )

        var changedProfile = profile
        changedProfile.version = 2
        changedProfile.projects.append(SyntheticContextFixtures.evidence(
            "A later profile edit",
            type: .project,
            source: "later-edit"
        ))
        try repository.saveCandidateProfile(changedProfile)

        let loaded = try repository.snapshot(id: snapshot.id)
        let stored = try #require(loaded)
        #expect(stored.candidateProfileVersion == 1)
        #expect(stored.opportunityContextVersion == 1)
        #expect(stored.candidateEvidence.count == profile.allEvidence.count)
        #expect(stored.candidateEvidence.contains(where: { $0.statement == "A later profile edit" }) == false)
    }

    @Test
    func switchingProfileCreatesNewSnapshotAndRejectsOldIdentity() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextSwitch")
        let repository = InterviewContextRepository(database: database)
        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Switch")
        let robotics = SyntheticContextFixtures.roboticsProfile()
        let backend = SyntheticContextFixtures.backendProfile()
        try repository.saveCandidateProfile(robotics)
        try repository.saveCandidateProfile(backend)

        let first = try repository.createSnapshot(
            sessionID: session.id,
            candidateProfileID: robotics.id,
            opportunityContextID: nil,
            domainProfileID: InterviewDomainID.roboticsResearch.rawValue
        )
        let second = try repository.createSnapshot(
            sessionID: session.id,
            candidateProfileID: backend.id,
            opportunityContextID: nil,
            domainProfileID: InterviewDomainID.softwareEngineering.rawValue
        )

        #expect(first.id != second.id)
        let old = GenerationIdentity(
            acceptedQuestionID: "question-a",
            generationID: "generation-a",
            sessionID: session.id,
            questionText: "Tell me about a difficult project.",
            promptPrimaryQuestion: "Tell me about a difficult project.",
            contextSnapshotID: first.id
        )
        let current = GenerationIdentity(
            acceptedQuestionID: "question-a",
            generationID: "generation-a",
            sessionID: session.id,
            questionText: "Tell me about a difficult project.",
            promptPrimaryQuestion: "Tell me about a difficult project.",
            contextSnapshotID: second.id
        )
        #expect(old.mismatchReason(comparedTo: current) == "context_snapshot_id_mismatch")
    }

    @Test @MainActor
    func switchingProfileCancelsActiveGenerationAndClearsLoadingUI() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextActiveSwitch")
        let appState = AppState(database: database)
        let robotics = SyntheticContextFixtures.roboticsProfile()
        let backend = SyntheticContextFixtures.backendProfile()
        try appState.interviewContextRepository.saveCandidateProfile(robotics)
        try appState.interviewContextRepository.saveCandidateProfile(backend)
        appState.refreshAll()
        appState.selectCandidateProfile(robotics.id)
        let session = try appState.createContextBoundSession(mode: .mock, title: "Active switch")
        appState.currentSession = session
        let question = DetectedQuestion(
            id: "active-switch-question",
            sessionID: session.id,
            questionText: "Tell me about a difficult project.",
            intent: .behavioral,
            answerStrategy: .directAnswer,
            confidence: 1,
            reason: "test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test-v1",
            isLocal: true,
            createdAt: Date()
        )
        appState.activateGeneration(
            question: question,
            generationID: "active-switch-generation",
            triggerPath: .manualGenerate,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )
        appState.beginAction(
            ActionID.generateAnswer,
            title: "Generating",
            message: "Waiting for provider"
        )
        appState.activeAITask = Task { try? await Task.sleep(for: .seconds(30)) }

        appState.selectCandidateProfile(backend.id)

        #expect(appState.activeGenerationController == nil)
        #expect(appState.activeAITask == nil)
        #expect(appState.generationUIState == .idle)
        #expect(!appState.isActionLoading(ActionID.generateAnswer))
        #expect(appState.currentSuggestion == nil)
        #expect(appState.activeContextSnapshot?.candidateProfileID == backend.id)
    }

    @Test
    func legacyStaticFallbackCannotInventCandidateExperience() {
        let question = DetectedQuestion(
            id: "static-fallback-question",
            sessionID: "static-fallback-session",
            transcriptSegmentID: nil,
            questionText: "Tell me about the most difficult project you worked on.",
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.9,
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )

        let fallback = ProjectGroundedFallbackPolicy.fallbackAnswer(for: question)
        #expect(fallback.sayFirst.isEmpty)
        #expect(fallback.keyPoints.isEmpty)
    }

    @Test
    func snapshotFallbackUsesOnlyFrozenCandidateEvidence() {
        let profile = SyntheticContextFixtures.backendProfile()
        let snapshot = InterviewContextSnapshot(
            id: "snapshot-fallback",
            sessionID: "snapshot-session",
            candidateProfileID: profile.id,
            candidateProfileVersion: profile.version,
            opportunityContextID: nil,
            opportunityContextVersion: nil,
            domainProfileID: InterviewDomainID.softwareEngineering.rawValue,
            candidateEvidence: profile.allEvidence,
            opportunityEvidence: [],
            createdAt: Date()
        )

        let result = DynamicInterviewContextEngine().profileSafeFallback(
            question: "Tell me about the most difficult project you worked on.",
            snapshot: snapshot
        )

        #expect(result.status == .grounded)
        #expect(result.answer.localizedCaseInsensitiveContains("microservice"))
        #expect(result.answer.localizedCaseInsensitiveContains("robot") == false)
        #expect(result.contextSnapshotID == snapshot.id)
        #expect(!result.candidateEvidenceIDs.isEmpty)
    }

    @Test
    func sameQuestionRetrievesMateriallyDifferentProfileEvidence() throws {
        let question = "Tell me about the most technically difficult project you worked on."
        let engine = DynamicInterviewContextEngine()
        let profiles = [
            SyntheticContextFixtures.roboticsProfile(),
            SyntheticContextFixtures.backendProfile(),
            SyntheticContextFixtures.dataScienceProfile(),
            SyntheticContextFixtures.productProfile()
        ]

        let answers = profiles.map { profile in
            engine.profileSafeFallback(
                question: question,
                domainProfile: .profile(for: SyntheticContextFixtures.domain(for: profile.id)),
                candidateProfile: profile,
                opportunityContext: nil,
                contextSnapshotID: "snapshot-\(profile.id)"
            )
        }

        #expect(answers.allSatisfy { $0.status == .grounded })
        #expect(Set(answers.map(\.answer)).count == profiles.count)
        #expect(answers[0].answer.localizedCaseInsensitiveContains("grasp"))
        #expect(answers[1].answer.localizedCaseInsensitiveContains("microservice"))
        #expect(answers[2].answer.localizedCaseInsensitiveContains("forecast"))
        #expect(answers[3].answer.localizedCaseInsensitiveContains("roadmap"))
    }

    @Test
    func backendProfileNeverReceivesRoboticsPersonalClaims() throws {
        let engine = DynamicInterviewContextEngine()
        let profile = SyntheticContextFixtures.backendProfile()
        let result = engine.profileSafeFallback(
            question: "How does your experience prepare you for this role?",
            domainProfile: .profile(for: .softwareEngineering),
            candidateProfile: profile,
            opportunityContext: SyntheticContextFixtures.backendOpportunity(),
            contextSnapshotID: "backend-snapshot"
        )

        #expect(result.answer.localizedCaseInsensitiveContains("microservice"))
        #expect(result.answer.localizedCaseInsensitiveContains("Kafka"))
        #expect(result.answer.localizedCaseInsensitiveContains("ROS2") == false)
        #expect(result.answer.localizedCaseInsensitiveContains("tactile") == false)
        #expect(result.answer.localizedCaseInsensitiveContains("grasp") == false)
        #expect(result.unsupportedClaims.isEmpty)
    }

    @Test
    func roboticsProfileNeverReceivesBackendPersonalClaims() throws {
        let engine = DynamicInterviewContextEngine()
        let result = engine.profileSafeFallback(
            question: "How does your experience prepare you for this research project?",
            domainProfile: .profile(for: .roboticsResearch),
            candidateProfile: SyntheticContextFixtures.roboticsProfile(),
            opportunityContext: SyntheticContextFixtures.roboticsOpportunity(),
            contextSnapshotID: "robotics-snapshot"
        )

        #expect(result.answer.localizedCaseInsensitiveContains("grasp"))
        #expect(result.answer.localizedCaseInsensitiveContains("Kafka") == false)
        #expect(result.answer.localizedCaseInsensitiveContains("Kubernetes") == false)
        #expect(result.unsupportedClaims.isEmpty)
    }

    @Test
    func missingSkillEvidenceDoesNotBecomeAClaimedGap() throws {
        let engine = DynamicInterviewContextEngine()
        let result = engine.profileSafeFallback(
            question: "What experience do you have with tactile sensing?",
            domainProfile: .profile(for: .roboticsResearch),
            candidateProfile: SyntheticContextFixtures.backendProfile(),
            opportunityContext: nil,
            contextSnapshotID: "backend-gap-snapshot"
        )

        #expect(result.status == .candidateEvidenceInsufficient)
        #expect(result.answer.localizedCaseInsensitiveContains("selected profile does not document"))
        #expect(result.answer.localizedCaseInsensitiveContains("I have no tactile") == false)
        #expect(result.unsupportedClaims.isEmpty)
    }

    @Test
    func opportunityRequirementsCannotBecomeCandidateAchievements() {
        let validator = AnswerClaimValidator()
        let opportunity = SyntheticContextFixtures.backendOpportunity()
        let decision = validator.validate(
            answer: "I led a Kubernetes migration that improved throughput by 40 percent.",
            candidateEvidence: [SyntheticContextFixtures.evidence("Built Java microservices", type: .experience)],
            opportunityEvidence: opportunity.allEvidence,
            domainKnowledge: []
        )

        #expect(decision.unsupportedClaims.count == 1)
        #expect(decision.supportingCandidateEvidenceIDs.isEmpty)
    }

    @Test
    func domainKnowledgeCannotBecomePersonalAchievement() {
        let validator = AnswerClaimValidator()
        let decision = validator.validate(
            answer: "I implemented tactile slip detection on a real robot.",
            candidateEvidence: [],
            opportunityEvidence: [],
            domainKnowledge: ["Tactile sensing can provide force, contact, slip, and pressure feedback."]
        )

        #expect(decision.unsupportedClaims.count == 1)
        #expect(decision.supportingCandidateEvidenceIDs.isEmpty)
    }

    @Test
    func relatedProjectEvidenceDoesNotSupportInventedObservedEvent() {
        let validator = AnswerClaimValidator()
        let decision = validator.validate(
            answer: "I observed object slips during recent vision-guided grasping experiments.",
            candidateEvidence: [
                SyntheticContextFixtures.evidence(
                    "Developed vision-guided grasping experiments",
                    type: .project
                )
            ],
            opportunityEvidence: [],
            domainKnowledge: []
        )

        #expect(decision.unsupportedClaims.count == 1)
        #expect(decision.supportingCandidateEvidenceIDs.isEmpty)
    }

    @Test
    func noProfileProducesContextMissingInsteadOfFabricatedStory() {
        let result = DynamicInterviewContextEngine().profileSafeFallback(
            question: "Why are you a strong fit?",
            domainProfile: .profile(for: .general),
            candidateProfile: nil,
            opportunityContext: SyntheticContextFixtures.backendOpportunity(),
            contextSnapshotID: "missing-profile-snapshot"
        )

        #expect(result.status == .candidateContextMissing)
        #expect(result.answer.isEmpty)
        #expect(result.groundingDecision == "candidate_context_missing")
    }

    @Test
    func sameCandidateAdaptsAnswerToDifferentOpportunityRequirements() {
        let engine = DynamicInterviewContextEngine()
        let profile = SyntheticContextFixtures.backendProfile()
        let opportunities = [
            SyntheticContextFixtures.opportunity(
                id: "api-role",
                title: "Backend Engineer",
                requirement: "Improve distributed API performance and service reliability"
            ),
            SyntheticContextFixtures.opportunity(
                id: "platform-role",
                title: "Data Platform Engineer",
                requirement: "Operate Kafka and Kubernetes data infrastructure"
            ),
            SyntheticContextFixtures.opportunity(
                id: "manager-role",
                title: "Engineering Manager",
                requirement: "Lead delivery planning and cross-team technical decisions"
            )
        ]

        let answers = opportunities.map { opportunity in
            engine.profileSafeFallback(
                question: "Why are you a strong fit?",
                domainProfile: .profile(for: .softwareEngineering),
                candidateProfile: profile,
                opportunityContext: opportunity,
                contextSnapshotID: "snapshot-\(opportunity.id)"
            )
        }

        #expect(Set(answers.map(\.answer)).count == opportunities.count)
        #expect(answers[0].answer.localizedCaseInsensitiveContains("API performance"))
        #expect(answers[1].answer.localizedCaseInsensitiveContains("Kafka"))
        #expect(answers[2].answer.localizedCaseInsensitiveContains("delivery planning"))
        #expect(answers.allSatisfy { $0.unsupportedClaims.isEmpty })
    }

    @Test
    func concurrentSessionsKeepSnapshotsAndFallbackEvidenceIsolated() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextConcurrent")
        let contexts = InterviewContextRepository(database: database)
        let sessions = SessionRepository(database: database)
        let robotics = SyntheticContextFixtures.roboticsProfile()
        let backend = SyntheticContextFixtures.backendProfile()
        try contexts.saveCandidateProfile(robotics)
        try contexts.saveCandidateProfile(backend)

        let sessionA = try sessions.createSession(
            mode: .mock,
            title: "Robotics session",
            contextSelection: InterviewContextSelection(
                candidateProfileID: robotics.id,
                opportunityContextID: nil,
                domainProfileID: .roboticsResearch
            )
        )
        let sessionB = try sessions.createSession(
            mode: .mock,
            title: "Backend session",
            contextSelection: InterviewContextSelection(
                candidateProfileID: backend.id,
                opportunityContextID: nil,
                domainProfileID: .softwareEngineering
            )
        )
        let snapshotAID = try #require(sessionA.contextSnapshotID)
        let snapshotBID = try #require(sessionB.contextSnapshotID)
        let snapshotA = try #require(try contexts.snapshot(id: snapshotAID))
        let snapshotB = try #require(try contexts.snapshot(id: snapshotBID))
        let engine = DynamicInterviewContextEngine()
        let question = "Tell me about the most technically difficult project you worked on."
        let answerA = engine.profileSafeFallback(question: question, snapshot: snapshotA)
        let answerB = engine.profileSafeFallback(question: question, snapshot: snapshotB)

        #expect(snapshotA.id != snapshotB.id)
        #expect(snapshotA.sessionID == sessionA.id)
        #expect(snapshotB.sessionID == sessionB.id)
        #expect(answerA.answer.localizedCaseInsensitiveContains("grasp"))
        #expect(answerA.answer.localizedCaseInsensitiveContains("Kafka") == false)
        #expect(answerB.answer.localizedCaseInsensitiveContains("microservice"))
        #expect(answerB.answer.localizedCaseInsensitiveContains("ROS2") == false)

        let identityA = GenerationIdentity(
            acceptedQuestionID: "question-a",
            generationID: "generation-a",
            sessionID: sessionA.id,
            questionText: question,
            promptPrimaryQuestion: question,
            contextSnapshotID: snapshotA.id
        )
        let identityB = GenerationIdentity(
            acceptedQuestionID: "question-a",
            generationID: "generation-a",
            sessionID: sessionB.id,
            questionText: question,
            promptPrimaryQuestion: question,
            contextSnapshotID: snapshotB.id
        )
        #expect(identityA.mismatchReason(comparedTo: identityB) == "session_id_mismatch")
    }

    @Test
    func heldOutProfilesGeneraliseWithoutDomainSpecificProductionRules() {
        let engine = DynamicInterviewContextEngine()
        let heldOut = [
            SyntheticContextFixtures.cybersecurityProfile(),
            SyntheticContextFixtures.biomedicalProfile()
        ]

        let results = heldOut.map { profile in
            engine.profileSafeFallback(
                question: "Describe a difficult technical problem.",
                domainProfile: .profile(for: .general),
                candidateProfile: profile,
                opportunityContext: nil,
                contextSnapshotID: "held-out-\(profile.id)"
            )
        }

        #expect(results[0].answer.localizedCaseInsensitiveContains("incident"))
        #expect(results[1].answer.localizedCaseInsensitiveContains("assay"))
        #expect(results.allSatisfy { $0.unsupportedClaims.isEmpty })
        #expect(results.allSatisfy { !$0.answer.localizedCaseInsensitiveContains("ROS2") })
        #expect(results.allSatisfy { !$0.answer.localizedCaseInsensitiveContains("Kafka") })
    }

    @Test
    func structuredExtractionSeparatesCandidateFactsFromOpportunityRequirements() {
        let extractor = StructuredEvidenceExtractor()
        let resume = extractor.extract(
            documentID: "resume-document",
            classification: .resume,
            content: """
            Education
            MSc in Computer Science.
            Projects
            Built a fault-tolerant event processing service with Kafka.
            Skills
            Java, PostgreSQL, Kubernetes.
            Development area
            Limited hands-on mobile development experience.
            """
        )
        let opportunity = extractor.extract(
            documentID: "job-document",
            classification: .jobDescription,
            content: """
            Senior Platform Engineer
            Required skills: Go, Kubernetes, distributed systems.
            Responsibilities: improve API reliability and production observability.
            """
        )

        #expect(resume.candidateEvidence.contains(where: { $0.evidenceType == .education }))
        #expect(resume.candidateEvidence.contains(where: { $0.evidenceType == .project }))
        #expect(resume.candidateEvidence.contains(where: { $0.evidenceType == .declaredGap }))
        #expect(resume.opportunityEvidence.isEmpty)
        #expect(opportunity.candidateEvidence.isEmpty)
        #expect(opportunity.opportunityEvidence.contains(where: { $0.evidenceType == .requiredSkill }))
        #expect(opportunity.opportunityEvidence.contains(where: { $0.evidenceType == .responsibility }))
        #expect(resume.candidateEvidence.allSatisfy { $0.sourceDocumentID == "resume-document" })
        #expect(resume.candidateEvidence.allSatisfy { $0.sourceChunkID != nil && $0.sourceSpan != nil })
    }

    @Test
    func extractionCacheKeyUsesDocumentHashAndOwnerVersion() {
        let extractor = StructuredEvidenceExtractor()
        let first = extractor.cacheKey(
            content: "Built a generic service.",
            classification: .resume,
            ownerVersion: 1
        )
        let same = extractor.cacheKey(
            content: "Built a generic service.",
            classification: .resume,
            ownerVersion: 1
        )
        let newVersion = extractor.cacheKey(
            content: "Built a generic service.",
            classification: .resume,
            ownerVersion: 2
        )

        #expect(first == same)
        #expect(first != newVersion)
    }

    @Test
    func sessionCreationBindsExactlyOneImmutableContextSnapshot() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextSession")
        let contexts = InterviewContextRepository(database: database)
        let sessions = SessionRepository(database: database)
        let profile = SyntheticContextFixtures.backendProfile()
        let opportunity = SyntheticContextFixtures.backendOpportunity()
        try contexts.saveCandidateProfile(profile)
        try contexts.saveOpportunityContext(opportunity)

        let session = try sessions.createSession(
            mode: .mock,
            title: "Bound session",
            contextSelection: InterviewContextSelection(
                candidateProfileID: profile.id,
                opportunityContextID: opportunity.id,
                domainProfileID: .softwareEngineering
            )
        )

        let snapshotID = try #require(session.contextSnapshotID)
        let stored = try #require(try contexts.snapshot(id: snapshotID))
        #expect(stored.sessionID == session.id)
        #expect(stored.candidateProfileID == profile.id)
        #expect(stored.opportunityContextID == opportunity.id)
        #expect(try contexts.snapshots(sessionID: session.id).count == 1)
    }

    @Test
    func suggestionPersistenceRetainsContextAndEvidenceProvenance() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextSuggestion")
        let contexts = InterviewContextRepository(database: database)
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let profile = SyntheticContextFixtures.backendProfile()
        try contexts.saveCandidateProfile(profile)
        let session = try sessions.createSession(
            mode: .mock,
            title: "Provenance",
            contextSelection: InterviewContextSelection(
                candidateProfileID: profile.id,
                opportunityContextID: nil,
                domainProfileID: .softwareEngineering
            )
        )
        let snapshotID = try #require(session.contextSnapshotID)
        var card = SuggestionCard(
            id: "dynamic-card",
            sessionID: session.id,
            questionID: nil,
            strategy: "Evidence-first",
            sayFirst: "My selected evidence describes distributed services.",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "test",
            promptVersion: "test",
            rawJSON: nil,
            createdAt: Date()
        )
        card.contextSnapshotID = snapshotID
        card.candidateProfileID = profile.id
        card.candidateProfileVersion = profile.version
        card.domainProfileID = InterviewDomainID.softwareEngineering.rawValue
        card.candidateEvidenceIDs = profile.allEvidence.prefix(2).map(\.id)
        card.opportunityEvidenceIDs = []
        card.groundingDecision = "supported_by_candidate_evidence"
        card.unsupportedClaimCount = 0
        card.contextIsolationStatus = "matched"

        try suggestions.saveSuggestionCard(card)

        let stored = try #require(try suggestions.suggestions(sessionID: session.id).first)
        #expect(stored.contextSnapshotID == snapshotID)
        #expect(stored.candidateProfileID == profile.id)
        #expect(stored.candidateEvidenceIDs == card.candidateEvidenceIDs)
        #expect(stored.groundingDecision == "supported_by_candidate_evidence")
        #expect(stored.unsupportedClaimCount == 0)
    }

    @Test @MainActor
    func appStateDocumentIngestionCreatesSelectableProfilesWithoutPersonalDefaults() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextAppState")
        let appState = AppState(database: database, dialogueDefaults: nil)
        #expect(appState.candidateProfiles.isEmpty)
        #expect(appState.activeCandidateProfileID == nil)

        appState.saveDocument(
            type: .cv,
            title: "Backend Resume",
            content: String(repeating: "Projects\nBuilt reliable Java microservices with Kafka and PostgreSQL.\n", count: 3)
        )
        #expect(appState.candidateProfiles.count == 1)
        #expect(appState.activeCandidateProfileID == appState.candidateProfiles.first?.id)
        #expect(appState.candidateProfiles.first?.projects.contains(where: { $0.statement.localizedCaseInsensitiveContains("Kafka") }) == true)
        let persistedChunkIDs = Set(try DocumentRepository(database: database).chunks(type: .cv).map(\.id))
        let evidenceChunkIDs = Set(appState.candidateProfiles.first?.allEvidence.compactMap(\.sourceChunkID) ?? [])
        #expect(!evidenceChunkIDs.isEmpty)
        #expect(evidenceChunkIDs.isSubset(of: persistedChunkIDs))

        appState.saveDocument(
            type: .jobDescription,
            title: "Platform Role",
            content: String(repeating: "Required skills\nKubernetes and distributed systems.\nResponsibilities\nImprove API reliability.\n", count: 3)
        )
        #expect(appState.opportunityContexts.count == 1)
        #expect(appState.activeOpportunityContextID == appState.opportunityContexts.first?.id)
        #expect(appState.contextReadiness.status == .ready)
    }

    @Test @MainActor
    func appStateProfileSwitchCreatesNewSessionSnapshot() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextAppStateSwitch")
        let contexts = InterviewContextRepository(database: database)
        let robotics = SyntheticContextFixtures.roboticsProfile()
        let backend = SyntheticContextFixtures.backendProfile()
        try contexts.saveCandidateProfile(robotics)
        try contexts.saveCandidateProfile(backend)
        let appState = AppState(database: database, dialogueDefaults: nil)
        appState.selectCandidateProfile(robotics.id)
        appState.selectInterviewDomain(.roboticsResearch)
        let session = try appState.createContextBoundSession(mode: .mock, title: "Switch")
        let firstSnapshotID = try #require(session.contextSnapshotID)
        appState.currentSession = session

        appState.selectCandidateProfile(backend.id)
        appState.selectInterviewDomain(.softwareEngineering)

        let secondSnapshotID = try #require(appState.currentSession?.contextSnapshotID)
        #expect(firstSnapshotID != secondSnapshotID)
        #expect(try contexts.snapshots(sessionID: session.id).count == 3)
        #expect(appState.activeContextSnapshot?.candidateProfileID == backend.id)
    }

    @Test @MainActor
    func displayBoundaryRejectsUnsupportedPersonalClaimsFromProvider() throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "DynamicContextDisplayGuard")
        let contexts = InterviewContextRepository(database: database)
        let profile = SyntheticContextFixtures.backendProfile()
        try contexts.saveCandidateProfile(profile)
        let appState = AppState(database: database, dialogueDefaults: nil)
        appState.selectCandidateProfile(profile.id)
        appState.selectInterviewDomain(.softwareEngineering)
        let session = try appState.createContextBoundSession(mode: .mock, title: "Guard")
        let snapshotID = try #require(session.contextSnapshotID)
        let question = DetectedQuestion(
            id: "guard-question",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "Tell me about the most difficult project you worked on.",
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.9,
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
        appState.setActiveQuestionForTesting(question)

        func card(answer: String, id: String) -> SuggestionCard {
            var value = SuggestionCard(
                id: id,
                sessionID: session.id,
                questionID: question.id,
                strategy: "test",
                sayFirst: answer,
                keyPoints: [],
                followUpReady: [],
                confidence: 0.9,
                caution: nil,
                evidenceUsed: [],
                riskLevel: .low,
                modelName: "test",
                promptVersion: "test",
                rawJSON: nil,
                createdAt: Date()
            )
            value.questionText = question.questionText
            value.promptQuestionText = question.questionText
            value.promptPrimaryQuestion = question.questionText
            value.contextSnapshotID = snapshotID
            return value
        }

        let unsupported = card(
            answer: "I implemented tactile control on a physical robot and improved grasp success by 40 percent.",
            id: "unsupported-card"
        )
        #expect(appState.applySuggestionIfAlignedForTesting(unsupported, question: question, generationID: nil) == false)

        let supported = card(
            answer: "I reduced API latency by redesigning a distributed microservice data path.",
            id: "supported-card"
        )
        let supportedAccepted = appState.applySuggestionIfAlignedForTesting(supported, question: question, generationID: nil)
        #expect(supportedAccepted, "Display guard error: \(appState.lastAlignmentError)")
        #expect(appState.currentSuggestion?.groundingDecision == "supported_by_candidate_evidence")
        #expect(appState.currentSuggestion?.unsupportedClaimCount == 0)
        #expect(appState.currentSuggestion?.contextSnapshotID == snapshotID)
    }

    @Test
    func generationIdentityRejectsAContextSnapshotMismatch() {
        let old = GenerationIdentity(
            acceptedQuestionID: "question",
            generationID: "generation",
            sessionID: "session",
            questionText: "Why are you a fit?",
            promptPrimaryQuestion: "Why are you a fit?",
            contextSnapshotID: "snapshot-a"
        )
        let current = GenerationIdentity(
            acceptedQuestionID: "question",
            generationID: "generation",
            sessionID: "session",
            questionText: "Why are you a fit?",
            promptPrimaryQuestion: "Why are you a fit?",
            contextSnapshotID: "snapshot-b"
        )

        #expect(old.mismatchReason(comparedTo: current) == "context_snapshot_id_mismatch")
    }

    @Test
    func generationExecutionContextCarriesTheImmutableProfileSnapshot() {
        let profile = SyntheticContextFixtures.backendProfile()
        let opportunity = SyntheticContextFixtures.backendOpportunity()
        let snapshot = InterviewContextSnapshot(
            id: "execution-snapshot",
            sessionID: "execution-session",
            candidateProfileID: profile.id,
            candidateProfileVersion: profile.version,
            opportunityContextID: opportunity.id,
            opportunityContextVersion: opportunity.version,
            domainProfileID: InterviewDomainID.softwareEngineering.rawValue,
            candidateEvidence: profile.allEvidence,
            opportunityEvidence: opportunity.allEvidence,
            createdAt: Date()
        )
        let session = InterviewSession(
            id: snapshot.sessionID,
            title: "Execution",
            company: nil,
            role: nil,
            startedAt: Date(),
            endedAt: nil,
            mode: .mock,
            createdAt: Date(),
            contextSnapshotID: snapshot.id
        )
        let question = DetectedQuestion(
            id: "execution-question",
            sessionID: session.id,
            transcriptSegmentID: nil,
            questionText: "How does your experience prepare you for this role?",
            intent: .companyFit,
            answerStrategy: .directAnswer,
            confidence: 0.9,
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
        let retrieved = DynamicInterviewContextEngine().retrieveContext(question: question.questionText, snapshot: snapshot)
        let execution = GenerationExecutionContext.make(
            session: session,
            question: question,
            generationID: "execution-generation",
            triggerPath: .manualGenerate,
            provider: nil,
            retrievedContext: retrieved.context,
            transcriptSnapshot: question.questionText,
            cvSummary: "",
            jdSummary: "",
            startedAt: Date(),
            source: nil,
            speaker: nil,
            stage: .firstAnswer,
            interviewContextSnapshot: snapshot
        )

        #expect(execution.contextSnapshotID == snapshot.id)
        #expect(execution.identity.contextSnapshotID == snapshot.id)
        #expect(execution.promptSnapshot.contextSnapshotID == snapshot.id)
        #expect(execution.promptSnapshot.candidateProfileID == profile.id)
        #expect(execution.promptSnapshot.opportunityContextID == opportunity.id)
        #expect(!execution.promptSnapshot.candidateEvidenceIDs.isEmpty)
        #expect(Set(execution.promptSnapshot.candidateEvidenceIDs).isSubset(of: Set(retrieved.candidateEvidenceIDs)))
        #expect(!execution.promptSnapshot.opportunityEvidenceIDs.isEmpty)
        #expect(Set(execution.promptSnapshot.opportunityEvidenceIDs).isSubset(of: Set(retrieved.opportunityEvidenceIDs)))
    }
}

private enum SyntheticContextFixtures {
    static func evidence(
        _ statement: String,
        type: EvidenceType,
        source: String = UUID().uuidString,
        explicitness: EvidenceExplicitness = .explicit
    ) -> ProfileEvidence {
        ProfileEvidence(
            id: "evidence-\(source)",
            statement: statement,
            sourceDocumentID: "document-\(source)",
            sourceChunkID: source,
            sourceSpan: statement,
            confidence: 0.95,
            evidenceType: type,
            explicitness: explicitness
        )
    }

    static func roboticsProfile() -> CandidateProfile {
        CandidateProfile(
            id: "robotics-profile",
            displayName: "Synthetic Robotics Candidate",
            sourceDocumentIDs: ["robotics-resume"],
            education: [evidence("Completed degrees in computer science and robotics", type: .education, source: "robotics-education")],
            experience: [evidence("Integrated robot perception and control through ROS2", type: .experience, source: "robotics-experience")],
            projects: [evidence("Built a language-guided grasping project with geometric reranking", type: .project, source: "robotics-project")],
            skills: [evidence("Uses ROS2 for robot-system integration", type: .skill, source: "robotics-skill")],
            publications: [],
            achievements: [],
            declaredGaps: [evidence("Tactile sensing experience is reading-based rather than hands-on", type: .declaredGap, source: "robotics-gap")],
            goals: [evidence("Develop tactile tool-manipulation research", type: .goal, source: "robotics-goal")],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    static func backendProfile() -> CandidateProfile {
        CandidateProfile(
            id: "backend-profile",
            displayName: "Synthetic Backend Candidate",
            sourceDocumentIDs: ["backend-resume"],
            education: [],
            experience: [evidence("Built distributed Java and Kotlin microservices using PostgreSQL and Kafka", type: .experience, source: "backend-experience")],
            projects: [evidence("Reduced API latency by redesigning a distributed microservice data path", type: .project, source: "backend-project")],
            skills: [
                evidence("Operates services with Kafka and Kubernetes", type: .skill, source: "backend-skill"),
                evidence("Designs reliable distributed APIs", type: .skill, source: "backend-inferred", explicitness: .inferred)
            ],
            publications: [],
            achievements: [],
            declaredGaps: [evidence("No robotics experience is declared", type: .declaredGap, source: "backend-gap")],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    static func dataScienceProfile() -> CandidateProfile {
        CandidateProfile(
            id: "data-profile",
            displayName: "Synthetic Data Candidate",
            sourceDocumentIDs: ["data-resume"],
            education: [],
            experience: [evidence("Designed forecasting experiments in Python and communicated results to stakeholders", type: .experience, source: "data-experience")],
            projects: [evidence("Built a forecasting model with production monitoring and drift checks", type: .project, source: "data-project")],
            skills: [evidence("Uses experiment design and model monitoring", type: .skill, source: "data-skill")],
            publications: [],
            achievements: [],
            declaredGaps: [evidence("No robot manipulation work is declared", type: .declaredGap, source: "data-gap")],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 3)
        )
    }

    static func productProfile() -> CandidateProfile {
        CandidateProfile(
            id: "product-profile",
            displayName: "Synthetic Product Candidate",
            sourceDocumentIDs: ["product-resume"],
            education: [],
            experience: [evidence("Led customer discovery and stakeholder alignment for product launches", type: .experience, source: "product-experience")],
            projects: [evidence("Resolved a roadmap conflict by using customer evidence and KPI analysis", type: .project, source: "product-project")],
            skills: [evidence("Owns roadmap prioritisation and product metrics", type: .skill, source: "product-skill")],
            publications: [],
            achievements: [],
            declaredGaps: [evidence("Does not claim software implementation ownership", type: .declaredGap, source: "product-gap")],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 4)
        )
    }

    static func cybersecurityProfile() -> CandidateProfile {
        CandidateProfile(
            id: "cybersecurity-profile",
            displayName: "Synthetic Security Candidate",
            sourceDocumentIDs: ["security-resume"],
            education: [],
            experience: [evidence("Investigated security incidents and improved detection playbooks", type: .experience, source: "security-experience")],
            projects: [evidence("Correlated endpoint and identity logs during a difficult incident investigation", type: .project, source: "security-project")],
            skills: [evidence("Uses threat modelling and incident response", type: .skill, source: "security-skill")],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 5)
        )
    }

    static func biomedicalProfile() -> CandidateProfile {
        CandidateProfile(
            id: "biomedical-profile",
            displayName: "Synthetic Biomedical Candidate",
            sourceDocumentIDs: ["biomedical-resume"],
            education: [],
            experience: [evidence("Designed reproducible biomedical experiments", type: .experience, source: "biomedical-experience")],
            projects: [evidence("Debugged assay variability by separating sample preparation and instrument effects", type: .project, source: "biomedical-project")],
            skills: [evidence("Uses statistical analysis and assay validation", type: .skill, source: "biomedical-skill")],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 6)
        )
    }

    static func roboticsOpportunity() -> OpportunityContext {
        OpportunityContext(
            id: "robotics-opportunity",
            title: "Robotics PhD",
            organisation: "Synthetic Lab",
            opportunityType: .phdProject,
            responsibilities: [evidence("Research tactile tool manipulation", type: .responsibility, source: "robotics-responsibility")],
            requiredSkills: [evidence("Robot perception and manipulation", type: .requiredSkill, source: "robotics-required")],
            preferredSkills: [],
            researchTopics: [evidence("Tactile sensing for tool manipulation", type: .researchTopic, source: "robotics-topic")],
            evaluationCriteria: [evidence("Evidence-based research methodology", type: .evaluationCriterion, source: "robotics-evaluation")],
            sourceDocumentIDs: ["robotics-jd"],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    static func backendOpportunity() -> OpportunityContext {
        OpportunityContext(
            id: "backend-opportunity",
            title: "Senior Backend Engineer",
            organisation: "Synthetic Company",
            opportunityType: .job,
            responsibilities: [evidence("Build reliable distributed services", type: .responsibility, source: "backend-responsibility")],
            requiredSkills: [evidence("Kubernetes operations and API performance", type: .requiredSkill, source: "backend-required")],
            preferredSkills: [],
            researchTopics: [],
            evaluationCriteria: [evidence("System design and reliability", type: .evaluationCriterion, source: "backend-evaluation")],
            sourceDocumentIDs: ["backend-jd"],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 11)
        )
    }

    static func opportunity(id: String, title: String, requirement: String) -> OpportunityContext {
        OpportunityContext(
            id: id,
            title: title,
            organisation: "Synthetic Organisation",
            opportunityType: .job,
            responsibilities: [evidence(requirement, type: .responsibility, source: "\(id)-responsibility")],
            requiredSkills: [],
            preferredSkills: [],
            researchTopics: [],
            evaluationCriteria: [],
            sourceDocumentIDs: ["\(id)-description"],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }

    static func domain(for profileID: String) -> InterviewDomainID {
        switch profileID {
        case "robotics-profile": return .roboticsResearch
        case "backend-profile": return .softwareEngineering
        case "data-profile": return .dataScience
        case "product-profile": return .productManagement
        default: return .general
        }
    }
}
