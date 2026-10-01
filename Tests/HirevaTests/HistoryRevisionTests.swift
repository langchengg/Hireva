import Foundation
import Testing
import GRDB
import FSRS
@testable import Hireva

@Suite(.serialized)
struct HistoryRevisionTests {
    @Test func populatedV20MigrationCorrectionRollbackReopenAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hireva-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let old = try AppDatabase(path: url, migrationTarget: "v20_frozen_question_task")
        let session = try SessionRepository(database: old).createSession(mode: .mock)
        let other = try SessionRepository(database: old).createSession(mode: .mock)
        let segment = TranscriptSegment(id: "source", sessionID: session.id, source: .systemAudio, speaker: .unknown, text: "How does a retrieve policy work?")
        try TranscriptRepository(database: old).saveSegment(segment)
        let task = InterviewTaskDescriptor(question: "Explain retry policy", kind: .generalKnowledge)
        let attempt = PracticeAttempt(questionID: "q", question: task.question, answer: "The retrieve policy waits before repeating a failed request.", revision: 0, hinted: false, skipped: false, source: "synthetic", task: task, feedback: .init(covered: [], missing: task.criteria, suggestions: ["Check the terminology"], followUp: nil, reason: "Unclear term", reference: "Retries need a bound."))
        var run = PracticeRun(sessionID: session.id, task: task, questionID: "q", mainQuestionID: "q", phase: .completed)
        run.attempts = [attempt]
        run.attachment = try MaterialExtractionService.extract(data: Data("Synthetic attachment canary".utf8), filename: "question.txt")
        try PracticeRepository(database: old).save(run)
        let now = Date()
        try PracticeRepository(database: old).saveReview(.init(id: attempt.id, sessionID: session.id, question: task.question, answer: "Old feedback", card: Card(due: now, lastReview: now), hinted: false))
        try old.close()

        // Force a transactional migration failure, verify no partially committed
        // ALTER remains, then retry the actual migration against populated v20.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE history_corrections (synthetic_conflict TEXT)") }
        #expect(throws: (any Error).self) { _ = try AppDatabase(path: url) }
        let columns = try queue.read { try $0.columns(in: "interview_sessions").map(\.name) }
        #expect(!columns.contains("content_revision"))
        try queue.write { try $0.execute(sql: "DROP TABLE history_corrections") }
        try queue.close()
        let migrated = try AppDatabase(path: url)
        let revisions = HistoryCorrectionRepository(database: migrated)
        try revisions.save(segment: segment, text: "How does a retry policy work?", speaker: .interviewer, startsQuestion: true, question: "Explain a retry policy")
        try revisions.save(segment: segment, text: "How does a retry policy work?", speaker: .interviewer, startsQuestion: true, question: "Explain a retry policy")
        #expect(try revisions.revisions(sessionID: session.id).count == 1)
        #expect(try TranscriptRepository(database: migrated).segments(sessionID: session.id).first?.text == segment.text)
        let corrected = try revisions.effectiveTranscript([segment], sessionID: session.id)
        #expect(corrected.first?.speaker == .interviewer)
        #expect(corrected.first?.text.contains("retry") == true)
        var clarification = segment
        clarification.id = "clarification"; clarification.speaker = .interviewer
        #expect(RecapGenerationService.sourceUnits(transcript: corrected + [clarification]).count == 2)
        #expect(RecapGenerationService.sourceUnits(transcript: corrected + [clarification], suppressedQuestionBoundaries: [clarification.id]).count == 1)
        let repository = PracticeRepository(database: migrated)
        try repository.correctAttempt(sessionID: session.id, attemptID: attempt.id, question: task.question, answer: "The retry policy waits before repeating a failed request.")
        let stored = try repository.load(sessionID: session.id)
        let updated = try #require(stored)
        #expect(updated.attempts.count == 1)
        #expect(updated.attempts[0].corrections?.first?.answer == attempt.answer)
        #expect(updated.attempts[0].corrections?.first?.feedback == attempt.feedback)
        #expect(updated.attempts[0].corrections?.first?.hinted == false)
        #expect(updated.attempts[0].feedback == nil)
        #expect(updated.attempts[0].hinted)
        #expect(updated.attachment?.text == run.attachment?.text)
        #expect(try repository.reviews().first?.needsReevaluation == true)
        #expect(try repository.reviews().first?.log.isEmpty == true)
        try migrated.close()
        let reopened = try AppDatabase(path: url)
        #expect(try HistoryCorrectionRepository(database: reopened).revisions(sessionID: session.id).count == 1)
        #expect(try PracticeRepository(database: reopened).load(sessionID: session.id)?.attempts.first?.hinted == true)
        try SessionRepository(database: reopened).deleteSession(id: session.id)
        #expect(try HistoryCorrectionRepository(database: reopened).revisions(sessionID: session.id).isEmpty)
        #expect(try PracticeRepository(database: reopened).reviews().isEmpty)
        #expect(try PracticeRepository(database: reopened).load(sessionID: session.id) == nil)
        #expect(try SessionRepository(database: reopened).session(id: other.id) != nil)
        #expect(throws: (any Error).self) { try HistoryCorrectionRepository(database: reopened).save(segment: segment, text: "late", speaker: .candidate, startsQuestion: false, question: "") }
        try reopened.close()
    }

    @Test func confirmedBoundariesConstrainClaimsAndRemainUnconfirmedOnEdit() throws {
        var facts = FactConfirmation()
        facts.ownership = "team"; facts.environment = "simulation"; facts.scope = "baseline"; facts.status = "completed"
        facts.metric = "20%"; facts.conditions = "on 12 simulated trials"
        let evidence = ProfileEvidence(id: "fact", statement: "Our team reduced policy latency by 20% on 12 simulated trials.", sourceDocumentID: "doc", sourceChunkID: "chunk", sourceSpan: "Original team experiment", confidence: 1, evidenceType: .project, explicitness: .userConfirmed, confirmation: facts)
        let validator = AnswerClaimValidator()
        for falseClaim in ["I independently reduced policy latency by 20% on 12 simulated trials.", "Our team reduced policy latency by 20% in production.", "Our team reduced policy latency by 20%."] {
            #expect(!validator.validate(answer: falseClaim, candidateEvidence: [evidence], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
        #expect(validator.validate(answer: evidence.statement, candidateEvidence: [evidence], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        #expect(evidence.statementForPrompt.contains(facts.conditions))
    }

    @Test func noCVAllowsTechnicalAssumptionsButNotConditionalPersonalTerms() {
        let validator = AnswerClaimValidator()
        for text in ["I am assuming eventual consistency.", "I need to clarify peak traffic before choosing a design.", "我需要先明确峰值流量。"] {
            #expect(validator.validate(answer: text, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
        for text in ["I would prefer a salary of £80,000.", "I would need visa sponsorship.", "我会在下月入职。", "I am a qualified engineer.", "I'm certified in Kubernetes.", "I’m certified in Kubernetes.", "You published three papers.", "I have no evidence, but I built a production system.", "I do not have any evidence; I am a certified engineer.", "I don't have records, although I graduated from Oxford.", "我没有证据，但我毕业于牛津大学。", "The payment service was a system I developed."] {
            #expect(!validator.validate(answer: text, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
        for text in ["I won three research awards.", "我在顶级会议发表了三篇论文。", "我的论文被会议接收。"] {
            #expect(!validator.validate(answer: text, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
        for statement in ["I have not published three papers.", "I plan to publish three papers."] {
            let evidence = ProfileEvidence(id: "source", statement: statement, sourceDocumentID: "synthetic", sourceChunkID: nil, sourceSpan: statement, confidence: 1, evidenceType: .publication, explicitness: .explicit)
            #expect(!validator.validate(answer: "I published three papers.", candidateEvidence: [evidence], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        }
    }

    @Test func correctingParentInvalidatesDependentFeedbackWithoutErasingRatings() throws {
        let db = try AppDatabase(inMemory: true)
        defer { try? db.close() }
        let session = try SessionRepository(database: db).createSession(mode: .mock)
        let task = InterviewTaskDescriptor(question: "Explain retry policy", kind: .generalKnowledge)
        let feedback = PracticeFeedback(covered: [], missing: [], suggestions: [], followUp: nil, reason: "Synthetic feedback", reference: "Bound the retries.")
        let main = PracticeAttempt(questionID: "main", question: task.question, answer: "Retrieve failed requests.", revision: 0, hinted: false, skipped: false, source: "keyboard", task: task, feedback: feedback)
        let child = PracticeAttempt(questionID: "follow", parentQuestionID: "main", question: "Why that bound?", answer: "To avoid overload.", revision: 0, hinted: false, skipped: false, source: "keyboard", task: task, feedback: feedback)
        let unrelated = PracticeAttempt(questionID: "other", question: "Explain a stack", answer: "LIFO.", revision: 0, hinted: false, skipped: false, source: "keyboard", task: task, feedback: feedback)
        var run = PracticeRun(sessionID: session.id, task: task, questionID: "follow", mainQuestionID: "main", phase: .completed)
        run.attempts = [main, child, unrelated]
        let repo = PracticeRepository(database: db)
        try repo.save(run)
        let now = Date()
        let card = KnowledgeReviewCard(id: child.id, sessionID: session.id, question: child.question, answer: "Old feedback", card: Card(due: now, lastReview: now), hinted: false)
        try repo.saveReview(card)
        try repo.correctAttempt(sessionID: session.id, attemptID: main.id, question: main.question, answer: "Retry failed requests.")
        let revised = try #require(try repo.load(sessionID: session.id))
        #expect(revised.attempts[1].revision == 1)
        #expect(revised.attempts[1].feedback == nil && revised.attempts[1].hinted)
        #expect(revised.attempts[1].corrections?.first?.feedback == feedback)
        #expect(revised.attempts[2] == unrelated)
        let review = try #require(try repo.reviews().first)
        #expect(review.needsReevaluation == true && review.card == card.card && review.log == card.log)
        try repo.correctAttempt(sessionID: session.id, attemptID: main.id, question: main.question, answer: "Retry failed requests.")
        #expect(try repo.load(sessionID: session.id)?.attempts[1].revision == 1)
    }

    @Test func missingSourceClarificationDoesNotBecomeAnUnsupportedAchievement() throws {
        let question = "Describe a specific time you personally resolved a database outage, including your actions and the outcome."
        let answer = InterviewQuestionDecision.missingPersonalEvidenceNotice(language: "en")
        let decision = InterviewQuestionDecision(task: .behavioral, personalEvidence: .required, basis: .candidateRecord, relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "test", routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "", questionID: "q", questionRevision: 0, contextSnapshotID: nil, artifactRevision: 0, model: "fixture", failure: nil, latencyMS: 0)
        #expect(AnswerClaimValidator().validate(answer: answer, candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(questionText: question, answerText: answer, decision: decision).verdict == .aligned)
        #expect(!AnswerClaimValidator().validate(answer: answer + " I resolved a production outage and reduced latency by 80%.", candidateEvidence: [], opportunityEvidence: [], domainKnowledge: []).unsupportedClaims.isEmpty)
    }

    @Test func chineseIngressUsesSystemWordBoundariesAndRejectsPartialNarrative() throws {
        let questions = ["解释数据库事务以及隔离级别的作用。", "如果消息乱序到达，你会如何恢复顺序？", "请比较这两种树的插入复杂度。"]
        for text in questions {
            #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: text).accepted)
            #expect(QuestionCandidatePipeline.extract(from: text, isFinal: false).isEmpty)
        }
        let explanation = "事务通过原子性、一致性、隔离性和持久性保证数据操作的完整性；隔离级别限制并发事务可见的数据，避免脏读、不可重复读和幻读。"
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(questionText: questions[0], answerText: explanation).verdict == .aligned)
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(questionText: questions[0], answerText: "苹果树需要根据季节浇水，冬天减少水量，夏天根据土壤湿度调整灌溉。").verdict == .mismatched)
        for text in ["谢谢你，今天就到这里。", "我解释了这个模块为什么需要缓存。", "如果我们然后", "解释这个问题…"] {
            #expect(QuestionCandidatePipeline.extract(from: text).isEmpty)
        }
        let source = questions[0] + questions[1]
        let candidates = QuestionCandidatePipeline.extract(from: source)
        #expect(candidates.count == 2)
        for candidate in candidates {
            let span = (source as NSString).substring(with: NSRange(location: candidate.sourceStartUTF16, length: candidate.sourceEndUTF16 - candidate.sourceStartUTF16))
            #expect(span.contains(candidate.text))
        }
    }

    @Test func strictDecisionDecoderRejectsMissingFieldsAndInventedEnums() throws {
        for output in ["{}", "{\"task\":\"coding\"}", "task: coding", "{\"task\":\"coding\",\"personalEvidence\":\"false\",\"basis\":\"generalKnowledge\",\"relation\":\"independent\",\"clarification\":\"\"}"] {
            #expect(throws: (any Error).self) { try InterviewQuestionRouter.Wire.decode(output) }
        }
    }

    @Test func missingParentDoesNotEraseExplicitPersonalDependency() async throws {
        let output = #"{"task":"behavioral","personalEvidence":"required","basis":"candidateRecord","relation":"followUp","clarification":""}"#
        let decision = try await InterviewQuestionRouter.resolve(.init(
            question: "What did you learn from that?", questionID: "synthetic-reference"),
            provider: FixedDecisionProvider(output: output), model: "synthetic")
        #expect(decision.personalEvidence == .required)
        #expect(decision.basis == .candidateRecord)
        #expect(decision.parentQuestionID == nil)
        #expect(!decision.clarification.isEmpty)
        #expect(decision.modelRequests == 1)
    }
}

private struct FixedDecisionProvider: LocalLLMProvider {
    let output: String
    var id: String { "synthetic-decision" }
    var displayName: String { id }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        AsyncThrowingStream { $0.yield(.init(text: output, source: .localQwen, modelName: "synthetic")); $0.finish() }
    }
}
