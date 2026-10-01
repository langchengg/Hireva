import Foundation
import Testing
import FSRS
@testable import Hireva

@Suite(.serialized)
struct WorkflowSafetyTests {
    @Test @MainActor func nilSnapshotCannotPublishAchievementsInAnswerOrAncillaryFields() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database, dialogueDefaults: nil)
        let session = try app.sessionRepository.createSession(mode: .mock)
        let text = "Explain database transactions."
        let question = DetectedQuestion(id: "q", sessionID: session.id, questionText: text, intent: .technical, answerStrategy: .technicalExplanation, confidence: 1, shouldTrigger: true, questionComplete: true, modelName: "synthetic", promptVersion: "safety", createdAt: Date())
        app.currentSession = session
        app.setActiveQuestionForTesting(question)
        for (answer, strategy, caution) in [
            ("I won three research awards. Transactions provide atomicity.", "Explain", ""),
            ("我在顶级会议发表了三篇论文。事务保证原子性。", "Explain", ""),
            ("Transactions provide atomicity, consistency, isolation and durability.", "I published three papers.", ""),
            ("Transactions provide atomicity, consistency, isolation and durability.", "Explain", "I won three research awards.")
        ] {
            var card = SuggestionCard(id: UUID().uuidString, sessionID: session.id, questionID: question.id, strategy: strategy, sayFirst: answer, keyPoints: [], followUpReady: [], confidence: nil, caution: caution, evidenceUsed: [], riskLevel: nil, modelName: "synthetic", promptVersion: "safety", rawJSON: nil, createdAt: Date())
            card.questionText = text
            #expect(card.contextSnapshotID == nil)
            #expect(!app.applySuggestionIfAlignedForTesting(card, question: question, generationID: nil))
            #expect(app.currentSuggestion == nil)
        }
    }

    @Test @MainActor func genericTimeoutCannotPublishPersonalTemplateFromUnrelatedCV() throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        let doc = try app.documentRepository.saveDocument(type: .cv, title: "Synthetic", content: "I built a cache and reduced inventory lookup latency by 73.19% during 17 synthetic trials.")
        let profile = try app.interviewContextRepository.upsertCandidateDocument(documentID: doc.id, title: "Synthetic", content: doc.content, profileID: nil, persistedChunks: app.documentRepository.chunks(documentID: doc.id))
        app.refreshAll(); app.selectCandidateProfile(profile.id)
        let session = try app.createContextBoundSession(mode: .mock)
        let text = "How would you improve the performance of a cache?"
        var question = DetectedQuestion(id: "generic", sessionID: session.id, questionText: text, intent: .technical, answerStrategy: .technicalExplanation, confidence: 1, shouldTrigger: true, questionComplete: true, modelName: "fixed synthetic decision", promptVersion: "safety-v1", createdAt: Date())
        var task = InterviewTaskDescriptor(question: text)
        task.apply(.init(task: .coding, personalEvidence: .notRequired, basis: .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "fixed safety case", routerVersion: InterviewQuestionRouter.version,
            language: "en", clarification: "", questionID: question.id, questionRevision: 0, contextSnapshotID: session.contextSnapshotID,
            artifactRevision: 0, model: "none", failure: nil, latencyMS: 0))
        question.taskDescriptor = task
        let fallback = app.makeInitialFirstAnswerFallbackCard(cardID: "card", question: question, session: session, requestStart: Date())
        #expect(fallback.sayFirst.isEmpty)
        #expect(fallback.keyPoints.isEmpty)
        #expect(app.groundedFallback(for: text, contextSnapshotID: session.contextSnapshotID, task: task) == nil)
    }

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
        let sourceCard = SuggestionCard(id: "source-card", sessionID: session.id, questionID: nil, strategy: doc.content, sayFirst: doc.content, keyPoints: [], followUpReady: [], confidence: nil, caution: doc.content, evidenceUsed: [], riskLevel: nil, modelName: "synthetic", promptVersion: "test", rawJSON: nil, createdAt: Date())
        let sourceChunk = RetrievedChunk(id: "chunk", documentID: doc.id, documentType: .cv, chunkIndex: 0, contentPreview: doc.content, fullContent: doc.content, keywords: [], score: 1, keywordOverlapCount: 1, contentOverlapCount: 1, rank: 1, isIncludedInPrompt: true)
        try SuggestionRepository(database: database).saveSuggestionCard(sourceCard, retrievedChunks: [sourceChunk])
        let personalTask = InterviewTaskDescriptor(question: "Describe your project", kind: .project)
        let feedback = PracticeFeedback(covered: [], missing: personalTask.criteria, suggestions: [], followUp: nil, reason: "source", reference: doc.content)
        var personal = PracticeAttempt(questionID: "personal", question: personalTask.question, answer: "My own submitted answer", contextSnapshotID: session.contextSnapshotID, revision: 0, hinted: false, skipped: false, source: "keyboard", task: personalTask, feedback: feedback)
        personal.corrections = [.init(revision: 0, question: personalTask.question, answer: "Original user answer", task: personalTask, feedback: feedback, correctedAt: Date())]
        let generalTask = InterviewTaskDescriptor(question: "Design a notification service", kind: .systemDesign)
        let general = PracticeAttempt(questionID: "general", question: generalTask.question, answer: "A queue separates producers", contextSnapshotID: session.contextSnapshotID, revision: 0, hinted: false, skipped: false, source: "keyboard", task: generalTask, feedback: .init(covered: [], missing: generalTask.criteria, suggestions: [], followUp: nil, reason: "generic", reference: "Use a durable queue."))
        var practice = PracticeRun(sessionID: session.id, snapshotID: session.contextSnapshotID, task: personalTask, questionID: "personal", mainQuestionID: "personal", phase: .completed)
        var correctedGeneral = general
        correctedGeneral.id = UUID().uuidString
        correctedGeneral.corrections = personal.corrections
        practice.attempts = [personal, general, correctedGeneral]
        let practiceRepository = PracticeRepository(database: database)
        try practiceRepository.save(practice)
        let now = Date()
        try practiceRepository.saveReview(.init(id: personal.id, sessionID: session.id, question: personal.question, answer: doc.content, card: Card(due: now, lastReview: now), hinted: false))
        try practiceRepository.saveReview(.init(id: correctedGeneral.id, sessionID: session.id, question: personal.question, answer: doc.content, card: Card(due: now, lastReview: now), hinted: false))
        try documents.deleteDocument(id: doc.id)
        let redactedCard = try #require(try SuggestionRepository(database: database).suggestions(sessionID: session.id).first)
        #expect(redactedCard.strategy == "[Source deleted]" && redactedCard.caution == nil)
        #expect(redactedCard.sayFirst == "[Source deleted]")
        let remaining = try practiceRepository.load(sessionID: session.id)
        #expect(remaining?.attempts[0].answer == personal.answer)
        #expect(remaining?.attempts[0].feedback == nil)
        #expect(remaining?.attempts[0].corrections?.first?.feedback == nil)
        #expect(remaining?.attempts[1].feedback == general.feedback)
        #expect(remaining?.attempts[2].feedback == general.feedback)
        #expect(remaining?.attempts[2].corrections?.first?.feedback == nil)
        #expect(try practiceRepository.reviews().isEmpty)
        let snapshotID = try #require(session.contextSnapshotID)
        let savedSnapshot = try contexts.snapshot(id: snapshotID)
        let snapshot = try #require(savedSnapshot)
        #expect(snapshot.candidateEvidence.allSatisfy { !$0.isUsable && $0.sourceSpan == nil })
        #expect(try documents.chunks(documentID: doc.id).isEmpty)
    }
}
