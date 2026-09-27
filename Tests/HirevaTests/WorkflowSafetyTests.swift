import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct WorkflowSafetyTests {
    @Test @MainActor func preparationAndHistoricalDeletionDoNotCancelLiveGeneration() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, dialogueDefaults: nil)
        let active = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        app.activeAITask = active
        app.liveState = .listening
        app.startListening(mode: .microphone)
        app.submitMockQuestion("Synthetic injection must not enter a live session")
        #expect(app.currentSession == nil)
        #expect(!active.isCancelled)
        app.pausePreparationForLive()
        #expect(!active.isCancelled)
        let oldSession = try app.sessionRepository.createSession(mode: .mock)
        app.deleteSession(oldSession)
        #expect(!active.isCancelled)
        #expect(try app.sessionRepository.session(id: oldSession.id) == nil)
        active.cancel()
        await app.shutdownForTesting()
        try database.close()
    }
    @Test func personalConditionsAndQualificationsRequireEvidence() {
        for answer in ["I can start next Monday.", "I prefer working remotely.", "My salary expectation is 80000 pounds.", "我期望月薪三万元。", "我毕业于曼彻斯特大学。"] {
            let result = AnswerClaimValidator().validate(answer: answer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: [])
            #expect(!result.unsupportedClaims.isEmpty)
        }
        let general = AnswerClaimValidator().validate(answer: "A queue decouples producers and consumers.", candidateEvidence: [], opportunityEvidence: [], domainKnowledge: [])
        #expect(general.groundingDecision == "no_personal_fact_detected")
        #expect(general.unsupportedClaims.isEmpty)
    }
    @Test func routingSeparatesDesignAndStoryStructures() {
        #expect(IntentRouter.answerIntent(for: "Explain a system architecture for a notification service") == .systemDesign)
        #expect(IntentRouter.transcriptClassification(for: "Introduce yourself").strategy == .directAnswer)
        #expect(IntentRouter.transcriptClassification(for: "What would your first 30 days look like?").strategy == .directAnswer)
        #expect(!InterviewTaskDescriptor.requiresPersonalEvidence("Explain a hash table"))
        #expect(!InterviewTaskDescriptor(question: "Explain your algorithm and its complexity").requiresPersonalEvidence)
        #expect(!InterviewTaskDescriptor(question: "你的算法复杂度是什么？").requiresPersonalEvidence)
        #expect(InterviewTaskDescriptor.requiresPersonalEvidence("Explain your project and your contribution"))
        #expect(IntentRouter.answerIntent(for: "How does your hospital workflow research complement your retail analytics experience?") == .projectComparison)
        #expect(IntentRouter.answerIntent(for: "Compare transformer and regression model performance") == .decoderComparison)
    }
    @Test func recapRejectsFabricatedQuotesWrongUnitAndUnknownSpeakers() throws {
        let source = TranscriptSegment(id: "candidate", sessionID: "session", source: .microphone, speaker: .candidate, text: "I would first clarify the reliability target.")
        let valid = RecapUnitFeedback(observations: [.init(segmentID: source.id, quote: "clarify the reliability target", feedback: "Explain the delivery guarantee.")])
        #expect(try valid.validatedMarkdown(sources: [source]).contains("Source [candidate]"))
        for invalid in [
            RecapUnitFeedback(observations: [.init(segmentID: source.id, quote: "I deployed ten systems", feedback: "invented")]),
            RecapUnitFeedback(observations: [.init(segmentID: "another-unit", quote: "clarify", feedback: "wrong unit")])
        ] { #expect(throws: (any Error).self) { try invalid.validatedMarkdown(sources: [source]) } }
        var unknown = source; unknown.speaker = .unknown
        #expect(throws: (any Error).self) { try valid.validatedMarkdown(sources: [unknown]) }
    }
    @Test func personalPracticeReferenceIsWithheldWithoutFactsInAnyVoice() throws {
        let task = InterviewTaskDescriptor(question: "Discuss work arrangements", kind: .arrangements)
        for invented in ["You are available Monday.", "Available immediately for £80000.", "可以明天入职。"] {
            let feedback = PracticeFeedback(covered: [], missing: task.criteria, suggestions: [], followUp: nil, reason: "Missing confirmed facts", reference: invented)
            let checked = try feedback.validated(answer: "Please clarify the work schedule.", task: task, evidence: [])
            #expect(checked.reference != invented)
            #expect(checked.reference.contains("confirmed source facts"))
        }
    }
    @Test func inferredNotesAndChineseClaimsAreNotFacts() {
        var evidence = ProfileEvidence(id: "e", statement: "I reduced latency by 30%", sourceDocumentID: "synthetic", sourceChunkID: nil, sourceSpan: nil, confidence: 0.9, evidenceType: .achievement, explicitness: .explicit)
        evidence.explicitness = .inferred
        #expect(!evidence.isUsable)
        #expect(!DocumentClassification.interviewNotes.isCandidateSource)
        let decision = AnswerClaimValidator().validate(answer: "我曾独立完成了系统并降低了延迟30%。", candidateEvidence: [], opportunityEvidence: [], domainKnowledge: [])
        #expect(!decision.unsupportedClaims.isEmpty)
        #expect(AnswerClaimValidator().validate(answer: "我会先澄清输入和边界条件。", candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
    }
    @Test func editingRequiresSeparateConfirmation() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let repository = InterviewContextRepository(database: database)
        let profile = try repository.upsertCandidateDocument(documentID: "test", title: "Synthetic", content: "Projects\nBuilt a Swift service with unit tests and documented all limitations.", profileID: nil, persistedChunks: [])
        let original = try #require(profile.allEvidence.first)
        try repository.updateEvidenceStatement(evidenceID: original.id, statement: "An unconfirmed correction")
        let editedProfile = try repository.candidateProfile(id: profile.id)
        let raw = (editedProfile?.projects ?? []) + (editedProfile?.experience ?? []) + (editedProfile?.skills ?? [])
        let edited = try #require(raw.first { $0.id == original.id })
        #expect(edited.explicitness == .inferred)
        #expect(edited.sourceSpan == original.sourceSpan)
        #expect(!edited.isUsable)
    }
    @Test func deletingSourceErasesHistoricalEvidenceCopies() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let documents = DocumentRepository(database: database)
        let contexts = InterviewContextRepository(database: database)
        let doc = try documents.saveDocument(type: .cv, title: "Synthetic", content: "Synthetic deletion canary: built a local Swift application with tests and documented technical limitations.")
        let profile = try contexts.upsertCandidateDocument(documentID: doc.id, title: "Synthetic", content: doc.content, profileID: nil, persistedChunks: documents.chunks(documentID: doc.id))
        let session = try SessionRepository(database: database).createSession(mode: .mock, contextSelection: .init(candidateProfileID: profile.id, opportunityContextID: nil, domainProfileID: .general))
        try documents.deleteDocument(id: doc.id)
        let snapshotID = try #require(session.contextSnapshotID)
        let savedSnapshot = try contexts.snapshot(id: snapshotID)
        let snapshot = try #require(savedSnapshot)
        #expect(snapshot.candidateEvidence.allSatisfy { !$0.isUsable && $0.sourceSpan == nil })
        #expect(try documents.chunks(documentID: doc.id).isEmpty)
    }
}
