import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct WebSourcedInterviewContextTests {
    @Test
    func backendDocumentsAutoBuildBackendContext() async throws {
        let pack = try FixturePack.load("backend_engineer_001")
        let result = try await pack.buildContext()

        #expect(result.candidateProfile != nil)
        #expect(result.opportunityContext != nil)
        #expect(result.inferredDomain.domainID == .softwareEngineering)
        #expect(result.candidateProfile?.skills.contains { $0.statement.localizedCaseInsensitiveContains("Kotlin") } == true)
        #expect(result.opportunityContext?.evaluationCriteria.contains { $0.statement.localizedCaseInsensitiveContains("tail latency") } == true)
        try pack.requireGroundedProvenance(in: result)
    }

    @Test
    func dataScienceDocumentsAutoBuildDataScienceContext() async throws {
        let pack = try FixturePack.load("data_scientist_001")
        let result = try await pack.buildContext()

        #expect(result.inferredDomain.domainID == .dataScience)
        #expect(result.candidateProfile?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("forecast") } == true)
        #expect(result.opportunityContext?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("monitoring") } == true)
        try pack.requireGroundedProvenance(in: result)
    }

    @Test
    func productDocumentsAutoBuildProductContext() async throws {
        let pack = try FixturePack.load("product_manager_001")
        let result = try await pack.buildContext()

        #expect(result.inferredDomain.domainID == .productManagement)
        #expect(result.candidateProfile?.declaredGaps.contains { $0.statement.localizedCaseInsensitiveContains("no direct software implementation") } == true)
        #expect(result.candidateProfile?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("implemented the production code") } == false)
    }

    @Test
    func heldOutDocumentsRequireNoProductionRule() async throws {
        let pack = try FixturePack.load("cybersecurity_analyst_001")
        let result = try await pack.buildContext()

        #expect(result.inferredDomain.domainID == .cybersecurity)
        #expect(result.candidateProfile?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("security") } == true)
        #expect(result.candidateProfile?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("robotics") } == false)
    }

    @Test
    func completeBackendDialogueTriggersOnlyInterviewerQuestions() throws {
        try assertDialoguePolicy(packID: "backend_engineer_001")
    }

    @Test
    func completeDataDialogueTriggersOnlyInterviewerQuestions() throws {
        try assertDialoguePolicy(packID: "data_scientist_001")
    }

    @Test
    func sameQuestionProducesProfileSpecificAnswers() async throws {
        let packIDs = [
            "backend_engineer_001",
            "data_scientist_001",
            "product_manager_001",
            "cybersecurity_analyst_001",
        ]
        var answers: [String: String] = [:]
        var snapshotIDs = Set<String>()
        for packID in packIDs {
            let pack = try FixturePack.load(packID)
            let result = try await pack.buildContext()
            let snapshot = try result.snapshot(id: "snapshot-\(packID)")
            let answer = DynamicInterviewContextEngine().profileSafeFallback(
                question: "Why are you a strong fit for this role?",
                snapshot: snapshot
            )
            #expect(answer.status == .grounded)
            #expect(answer.unsupportedClaims.isEmpty)
            #expect(!answer.candidateEvidenceIDs.isEmpty)
            answers[packID] = answer.answer
            snapshotIDs.insert(answer.contextSnapshotID)
        }

        #expect(Set(answers.values).count == packIDs.count)
        #expect(snapshotIDs.count == packIDs.count)
        #expect(answers["backend_engineer_001"]?.localizedCaseInsensitiveContains("Kotlin") == true || answers["backend_engineer_001"]?.localizedCaseInsensitiveContains("API") == true)
        #expect(answers["data_scientist_001"]?.localizedCaseInsensitiveContains("forecast") == true || answers["data_scientist_001"]?.localizedCaseInsensitiveContains("model") == true)
        #expect(answers["product_manager_001"]?.localizedCaseInsensitiveContains("customer") == true || answers["product_manager_001"]?.localizedCaseInsensitiveContains("roadmap") == true)
        #expect(answers["cybersecurity_analyst_001"]?.localizedCaseInsensitiveContains("security") == true || answers["cybersecurity_analyst_001"]?.localizedCaseInsensitiveContains("incident") == true)
    }

    @Test
    func crossProfileLateCallbacksAreRejected() {
        let stale = GenerationIdentity(
            acceptedQuestionID: "backend-question",
            generationID: "backend-generation",
            sessionID: "backend-session",
            questionText: "Why are you a strong fit for this role?",
            promptPrimaryQuestion: "Why are you a strong fit for this role?",
            contextSnapshotID: "backend-snapshot"
        )
        let active = GenerationIdentity(
            acceptedQuestionID: "data-question",
            generationID: "data-generation",
            sessionID: "data-session",
            questionText: "Why are you a strong fit for this role?",
            promptPrimaryQuestion: "Why are you a strong fit for this role?",
            contextSnapshotID: "data-snapshot"
        )

        #expect(stale.mismatchReason(comparedTo: active) != nil)
        #expect(stale.contextSnapshotID != active.contextSnapshotID)
    }

    @Test
    func jobRequirementsNeverBecomeCandidateExperience() async throws {
        for packID in FixturePack.allIDs {
            let pack = try FixturePack.load(packID)
            let result = try await pack.buildContext()
            let candidate = try #require(result.candidateProfile)
            let opportunitySpans = Set(pack.expectedOpportunity.evidence.map { normalized($0.sourceSpan) })
            let candidateSpans = Set(candidate.allEvidence.compactMap(\.sourceSpan).map(normalized))
            #expect(candidateSpans.isDisjoint(with: opportunitySpans), "Opportunity evidence leaked into \(packID)")
            #expect(candidate.allEvidence.allSatisfy { $0.sourceDocumentID == pack.resumeDocumentID })
        }
    }

    @Test
    func promptInjectionDocumentDoesNotCreateUnsupportedFacts() async throws {
        let pack = try FixturePack.load("cybersecurity_analyst_001")
        let result = try await pack.buildContext()
        let candidateText = result.candidateProfile?.allEvidence.map(\.statement).joined(separator: " ") ?? ""

        #expect(!candidateText.localizedCaseInsensitiveContains("Google"))
        #expect(result.warnings.contains { $0.code == .promptInjectionIgnored })
    }

    @Test
    func noContextDoesNotHangGeneration() {
        let snapshot = InterviewContextSnapshot(
            id: "empty-context-snapshot",
            sessionID: "empty-context-session",
            candidateProfileID: nil,
            candidateProfileVersion: nil,
            opportunityContextID: nil,
            opportunityContextVersion: nil,
            domainProfileID: InterviewDomainID.general.rawValue,
            candidateEvidence: [],
            opportunityEvidence: [],
            createdAt: Date()
        )

        let result = DynamicInterviewContextEngine().profileSafeFallback(
            question: "Tell me about your most relevant experience.",
            snapshot: snapshot
        )
        #expect(result.status == .candidateContextMissing)
        #expect(result.groundingDecision == "candidate_context_missing")
        #expect(result.answer.isEmpty)
    }

    @Test
    func fixtureManifestsAndDialogueFirstAssetsAreComplete() throws {
        for packID in FixturePack.allIDs {
            let pack = try FixturePack.load(packID)
            #expect(pack.manifest.synthetic)
            #expect(!pack.manifest.containsRealPersonalData)
            #expect(pack.manifest.randomSeed == 20260712)
            #expect(pack.manifest.sources.allSatisfy { ["MIT", "CC BY 4.0"].contains($0.license) })
            #expect(pack.dialogue.turns.count == 22)
            #expect(pack.dialogue.turns.filter(\.shouldTriggerAnswer).count == 9)
            #expect(pack.dialogue.turns.filter { $0.speakerRole == "candidate" && !$0.shouldTriggerAnswer }.count >= 6)
            #expect(pack.dialogue.turns.contains { $0.compound == true })
            #expect(pack.dialogue.turns.contains { $0.rapidFollowUp == true })
            #expect(pack.dialogue.turns.contains { $0.expectedSuppressionReason == "candidate question to panel" })
        }
    }

    @Test
    func frozenSnapshotNeverReadsLaterLiveDocuments() {
        let legacy = RetrievedContext(
            cvChunks: [Self.chunk(id: "live-cv", type: .cv, content: "Future live CV fact")],
            jobDescriptionChunks: [Self.chunk(id: "live-jd", type: .jobDescription, content: "Future live JD requirement")]
        )
        let emptySnapshot = InterviewContextSnapshot(
            id: "frozen-empty-snapshot",
            sessionID: "frozen-session",
            candidateProfileID: nil,
            candidateProfileVersion: nil,
            opportunityContextID: nil,
            opportunityContextVersion: nil,
            domainProfileID: InterviewDomainID.general.rawValue,
            candidateEvidence: [],
            opportunityEvidence: [],
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let selected = SnapshotBoundContextPolicy.retrievedContext(
            snapshot: emptySnapshot,
            snapshotContext: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            legacyContext: legacy
        )
        let summaries = SnapshotBoundContextPolicy.summaries(
            snapshot: emptySnapshot,
            liveCVSummary: "Future live CV fact",
            liveJDSummary: "Future live JD requirement"
        )

        #expect(selected.isEmpty)
        #expect(summaries.cv.isEmpty)
        #expect(summaries.jd.isEmpty)
    }

    @Test @MainActor
    func deletingAllDocumentsClearsActiveContextAndRollsEmptySnapshot() async throws {
        let appState = AppState(
            database: try TestSupport.makeTemporaryDatabase(prefix: "WebContextDeleteAll"),
            dialogueDefaults: nil
        )
        let pack = try FixturePack.load("backend_engineer_001")
        appState.saveDocument(type: .cv, title: "Synthetic Resume", content: pack.resume)
        appState.saveDocument(type: .jobDescription, title: "Synthetic Job Description", content: pack.jobDescription)
        await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)
        let session = try appState.createContextBoundSession(mode: .mock, title: "Delete all context")
        appState.currentSession = session

        for document in appState.documents {
            appState.deleteDocument(document)
        }
        await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)

        #expect(appState.documents.isEmpty)
        #expect(appState.activeCandidateProfileID == nil)
        #expect(appState.activeOpportunityContextID == nil)
        #expect(appState.activeInterviewDomainID == .general)
        #expect(appState.automaticContextReadiness == .noDocuments)
        #expect(appState.activeContextSnapshot?.candidateProfileID == nil)
        #expect(appState.activeContextSnapshot?.opportunityContextID == nil)
        #expect(appState.currentSession?.contextSnapshotID == appState.activeContextSnapshot?.id)
    }

    @Test
    func verificationMocksCannotEnterProductionProcess() {
        #expect(!ProductionContextPolicy.verificationMocksEnabled(
            explicitOverride: true,
            environmentValue: "1",
            isTestProcess: false
        ))
        #expect(ProductionContextPolicy.verificationMocksEnabled(
            explicitOverride: true,
            environmentValue: nil,
            isTestProcess: true
        ))
    }

    @Test
    func opportunityRequirementsInAdditionalNotesStayOutOfCandidateEvidence() async throws {
        let content = """
        Required Skills
        Required: hands-on quantum cryptography and incident response.
        Responsibilities
        You will own security reviews and production risk assessments.
        Success Criteria
        The successful candidate improves detection coverage.
        """
        let document = DocumentRecord(
            id: "requirements-notes",
            type: .additionalNotes,
            title: "Role Requirements",
            content: content,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            sanitizedContent: content,
            sanitizedPreview: nil,
            sanitizationWarnings: nil
        )

        let classification = AutomaticInterviewContextBuilder.classify(document)
        let result = try await AutomaticInterviewContextBuilder().buildContext(
            from: [document],
            previousConfirmedProfile: nil
        )

        #expect(classification.type == .jobDescription)
        #expect(result.candidateProfile == nil)
        #expect(result.opportunityContext?.allEvidence.contains {
            $0.statement.localizedCaseInsensitiveContains("quantum cryptography")
        } == true)
    }

    @Test
    func evidenceProvenanceNeverPointsAtAnUnrelatedChunk() throws {
        let extraction = StructuredEvidenceExtractor().extract(
            documentID: "resume-document",
            classification: .resume,
            content: "Skills\nSwift concurrency",
            persistedChunks: [Self.chunk(
                id: "unrelated-chunk",
                type: .cv,
                content: "A different persisted fragment"
            )]
        )

        let evidence = try #require(extraction.candidateEvidence.first)
        #expect(evidence.sourceChunkID == nil)
    }

    @Test @MainActor
    func newestAutomaticContextRebuildOwnsTheActiveSelection() async throws {
        let backend = try await FixturePack.load("backend_engineer_001").buildContext()
        let data = try await FixturePack.load("data_scientist_001").buildContext()
        let builder = SequencedContextBuilder(first: backend, second: data)
        let appState = AppState(
            database: try TestSupport.makeTemporaryDatabase(prefix: "WebContextLatestBuild"),
            dialogueDefaults: nil
        )
        appState.saveDocument(
            type: .cv,
            title: "Synthetic Resume",
            content: try FixturePack.load("backend_engineer_001").resume
        )
        appState.automaticContextBuilderOverride = builder

        let first = Task { await appState.rebuildAutomaticInterviewContext(useLocalQwen: false) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { await appState.rebuildAutomaticInterviewContext(useLocalQwen: false) }
        await first.value
        await second.value

        #expect(appState.activeInterviewDomainID == .dataScience)
        #expect(appState.activeCandidateProfile?.allEvidence.contains { $0.statement.localizedCaseInsensitiveContains("forecast") } == true)
        #expect(!appState.isActionLoading(ActionID.buildInterviewContext))
    }

    @Test @MainActor
    func deletingDocumentsDuringContextBuildClearsLoadingState() async throws {
        let backendPack = try FixturePack.load("backend_engineer_001")
        let backend = try await backendPack.buildContext()
        let appState = AppState(
            database: try TestSupport.makeTemporaryDatabase(prefix: "WebContextDeleteDuringBuild"),
            dialogueDefaults: nil
        )
        appState.saveDocument(type: .cv, title: "Synthetic Resume", content: backendPack.resume)
        appState.automaticContextBuilderOverride = SequencedContextBuilder(first: backend, second: backend)

        let inFlightBuild = Task { await appState.rebuildAutomaticInterviewContext(useLocalQwen: false) }
        try await Task.sleep(for: .milliseconds(20))
        for document in appState.documents {
            appState.deleteDocument(document)
        }
        await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)
        await inFlightBuild.value

        #expect(appState.documents.isEmpty)
        #expect(appState.automaticContextReadiness == .noDocuments)
        #expect(!appState.isActionLoading(ActionID.buildInterviewContext))
    }

    private func assertDialoguePolicy(packID: String) throws {
        let pack = try FixturePack.load(packID)
        var state = DialogueRuntimeState.initial(for: .auto)
        for turn in pack.dialogue.turns {
            let speaker = try #require(SpeakerRole(rawValue: turn.speakerRole))
            let segment = TranscriptSegment(
                id: "\(packID)-turn-\(turn.turn)",
                sessionID: "\(packID)-session",
                source: .systemAudio,
                speaker: speaker,
                text: turn.text,
                asrSource: .localParakeetASR,
                asrFinalizationReason: "final_accepted"
            )
            let decision = InterviewDialogueTriggerPolicy.decideDialogueTrigger(
                segment: segment,
                sessionMode: .auto,
                currentState: state,
                answerPanelQuestions: true,
                suppressPresentation: true,
                suppressCandidateQuestions: true
            )
            #expect(decision.shouldEvaluateQuestion == turn.shouldTriggerAnswer, "Unexpected trigger at \(packID) turn \(turn.turn): \(decision.triggerReason) \(decision.suppressionReason)")
            if turn.speakerRole == "candidate" {
                #expect(!decision.shouldEvaluateQuestion)
            }
            state = state.applying(decision)
        }
    }

    private static func chunk(id: String, type: DocumentType, content: String) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "document-\(id)",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: [],
            sectionTitle: nil,
            wordCount: nil,
            metadataJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor SequencedContextBuilder: InterviewContextBuilding {
    private var callCount = 0
    private let first: InterviewContextBuildResult
    private let second: InterviewContextBuildResult

    init(first: InterviewContextBuildResult, second: InterviewContextBuildResult) {
        self.first = first
        self.second = second
    }

    func buildContext(
        from documents: [DocumentRecord],
        previousConfirmedProfile: CandidateProfile?
    ) async throws -> InterviewContextBuildResult {
        callCount += 1
        if callCount == 1 {
            try await Task.sleep(for: .milliseconds(120))
            return first
        }
        return second
    }
}

private struct FixturePack {
    static let allIDs = [
        "backend_engineer_001",
        "data_scientist_001",
        "product_manager_001",
        "cybersecurity_analyst_001",
    ]

    var id: String
    var resume: String
    var jobDescription: String
    var manifest: FixtureManifest
    var expectedCandidate: FixtureEvidenceEnvelope
    var expectedOpportunity: FixtureEvidenceEnvelope
    var expectedDomain: FixtureDomain
    var dialogue: FixtureDialogue

    var resumeDocumentID: String { "web-\(id)-resume" }
    var opportunityDocumentID: String { "web-\(id)-opportunity" }

    static func load(_ id: String) throws -> FixturePack {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("WebSourcedSyntheticContexts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        func text(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            try JSONDecoder().decode(type, from: Data(text(name).utf8))
        }
        return FixturePack(
            id: id,
            resume: try text("resume.md"),
            jobDescription: try text("job_description.md"),
            manifest: try decode(FixtureManifest.self, "source_manifest.json"),
            expectedCandidate: try decode(FixtureEvidenceEnvelope.self, "expected_candidate_evidence.json"),
            expectedOpportunity: try decode(FixtureEvidenceEnvelope.self, "expected_opportunity_evidence.json"),
            expectedDomain: try decode(FixtureDomain.self, "expected_domain.json"),
            dialogue: try decode(FixtureDialogue.self, "interview_dialogue.json")
        )
    }

    func buildContext() async throws -> InterviewContextBuildResult {
        try await AutomaticInterviewContextBuilder().buildContext(
            from: [
                DocumentRecord(
                    id: resumeDocumentID,
                    type: .cv,
                    title: "\(id) Synthetic Resume",
                    content: resume,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: 1),
                    sanitizedContent: resume,
                    sanitizedPreview: nil,
                    sanitizationWarnings: nil
                ),
                DocumentRecord(
                    id: opportunityDocumentID,
                    type: .jobDescription,
                    title: "\(id) Synthetic Job Description",
                    content: jobDescription,
                    createdAt: Date(timeIntervalSince1970: 2),
                    updatedAt: Date(timeIntervalSince1970: 2),
                    sanitizedContent: jobDescription,
                    sanitizedPreview: nil,
                    sanitizationWarnings: nil
                ),
            ],
            previousConfirmedProfile: nil
        )
    }

    func requireGroundedProvenance(in result: InterviewContextBuildResult) throws {
        let candidate = try #require(result.candidateProfile)
        let opportunity = try #require(result.opportunityContext)
        #expect(candidate.allEvidence.allSatisfy {
            $0.sourceDocumentID == resumeDocumentID && $0.sourceChunkID != nil && $0.sourceSpan?.isEmpty == false
        })
        #expect(opportunity.allEvidence.allSatisfy {
            $0.sourceDocumentID == opportunityDocumentID && $0.sourceChunkID != nil && $0.sourceSpan?.isEmpty == false
        })
        for expected in expectedCandidate.evidence {
            #expect(candidate.allEvidence.contains { $0.sourceSpan?.localizedCaseInsensitiveContains(expected.sourceSpan) == true }, "Missing candidate evidence \(expected.id)")
        }
        for expected in expectedOpportunity.evidence {
            #expect(opportunity.allEvidence.contains { $0.sourceSpan?.localizedCaseInsensitiveContains(expected.sourceSpan) == true }, "Missing opportunity evidence \(expected.id)")
        }
    }
}

private extension InterviewContextBuildResult {
    func snapshot(id: String) throws -> InterviewContextSnapshot {
        let candidate = try #require(candidateProfile)
        let opportunity = try #require(opportunityContext)
        return InterviewContextSnapshot(
            id: id,
            sessionID: "session-\(id)",
            candidateProfileID: candidate.id,
            candidateProfileVersion: candidate.version,
            opportunityContextID: opportunity.id,
            opportunityContextVersion: opportunity.version,
            domainProfileID: inferredDomain.domainID.rawValue,
            candidateEvidence: candidate.allEvidence,
            opportunityEvidence: opportunity.allEvidence,
            createdAt: Date(timeIntervalSince1970: 3)
        )
    }
}

private func normalized(_ value: String) -> String {
    value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

private struct FixtureManifest: Decodable {
    struct Source: Decodable { var license: String }
    var synthetic: Bool
    var containsRealPersonalData: Bool
    var randomSeed: Int
    var sources: [Source]
}

private struct FixtureEvidenceEnvelope: Decodable {
    var evidence: [FixtureEvidence]
}

private struct FixtureEvidence: Decodable {
    var id: String
    var sourceSpan: String
}

private struct FixtureDomain: Decodable {
    var domainID: String
}

private struct FixtureDialogue: Decodable {
    var turns: [FixtureTurn]
}

private struct FixtureTurn: Decodable {
    var turn: Int
    var speakerRole: String
    var phase: String
    var text: String
    var shouldTriggerAnswer: Bool
    var expectedSuppressionReason: String?
    var clarificationOfTurn: Int?
    var compound: Bool?
    var rapidFollowUp: Bool?
}
