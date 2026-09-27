import Foundation
import Testing
import FSRS
@testable import Hireva

@Suite(.serialized)
struct PracticeWorkflowTests {
    @Test @MainActor func realAttemptsHintsFollowupsAndPrivacy() async throws {
        let db = try AppDatabase(inMemory: true)
        let app = AppState(database: db, dialogueDefaults: nil)
        let controller = app.practiceController
        let kind = InterviewTaskKind.systemDesign
        let task = InterviewTaskDescriptor(question: "Design a queue", kind: kind)
        app.localLLMProviderOverride = FeedbackProvider(feedback: .init(covered: [.init(criterion: task.criteria[0], quote: "Requirements")], missing: Array(task.criteria.dropFirst()), suggestions: ["Explain delivery semantics"], followUp: "How would you avoid lost messages?", reason: "Reliability was not covered", reference: "Clarify delivery guarantees before selecting storage."))
        controller.start(kind: kind, question: task.question, language: "en", criteria: task.criteria, maxFollowUps: 99)
        #expect(controller.run?.phase == .asking)
        #expect(controller.run?.maxFollowUps == 2)
        #expect(controller.run?.attempts.isEmpty == true)
        controller.beginAnswer()
        controller.submit()
        #expect(controller.run?.attempts.isEmpty == true)
        controller.run?.draft = "Requirements include reliable message delivery."
        controller.submit()
        for _ in 0..<100 where controller.run?.phase == .evaluating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.run?.phase == .completed)
        #expect(controller.run?.attempts.count == 1)
        #expect(controller.run?.attempts[0].hinted == false)
        controller.followUp()
        #expect(controller.run?.phase == .followUp)
        #expect(controller.run?.task.criteria == [task.criteria[1]])
        #expect(controller.run?.questionID != controller.run?.mainQuestionID)
        controller.beginAnswer(); controller.hint()
        controller.run?.draft = "Requirements include reliable message delivery."
        controller.submit()
        for _ in 0..<100 where controller.run?.phase == .evaluating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.run?.attempts.last?.hinted == true)
        let sessionID = try #require(controller.run?.sessionID)
        let saved = try PracticeRepository(database: db).load(sessionID: sessionID)
        #expect(saved?.attempts.count == 2)
        controller.redo(); controller.pause(); controller.restore(sessionID: sessionID)
        #expect(controller.run?.attempts.count == 2)
        #expect(controller.run?.phase == .paused)
        controller.resume()
        #expect(controller.run?.phase == .answering)
        let material = try MaterialExtractionService.extract(data: Data("Synthetic problem version one".utf8), filename: "task.txt")
        controller.attach(material)
        controller.beginAnswer()
        controller.run?.draft = "Requirements include reliable message delivery."
        controller.submit()
        for _ in 0..<100 where controller.run?.phase == .evaluating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.run?.attempts.last?.hinted == true)
        #expect(controller.run?.attempts.last?.attachment?.sha256 == material.sha256)
        #expect(controller.run?.attempts.last?.task?.criteria == [task.criteria[1]])
        let replacement = try MaterialExtractionService.extract(data: Data("Synthetic problem version two".utf8), filename: "task.txt")
        controller.attach(replacement)
        #expect(controller.run?.attempts.last?.attachment?.sha256 == material.sha256)
        try app.sessionRepository.deleteSession(id: sessionID)
        #expect(try PracticeRepository(database: db).load(sessionID: sessionID) == nil)
        controller.run = nil
        var settings = app.settings
        settings.saveTranscriptsLocally = false
        app.saveSettings(settings)
        controller.start(kind: .coding, question: "Find a pair", language: "en", criteria: [], maxFollowUps: 0)
        let privateID = try #require(controller.run?.sessionID)
        controller.beginAnswer(); controller.run?.draft = "private canary"; controller.pause()
        #expect(try PracticeRepository(database: db).load(sessionID: privateID) == nil)
        settings.saveTranscriptsLocally = true
        app.saveSettings(settings)
        controller.persist()
        #expect(try PracticeRepository(database: db).load(sessionID: privateID) == nil)
        #expect(controller.run?.historyAllowed == false)
        controller.cancel()
        await app.shutdownForTesting()
        try db.close()
    }
    @Test func inventedQuotesAndOffRubricFeedbackFail() throws {
        let task = InterviewTaskDescriptor(question: "Design a service", kind: .systemDesign)
        let feedback = PracticeFeedback(covered: [.init(criterion: task.criteria[0], quote: "I never said this")], missing: [], suggestions: [], followUp: nil, reason: "", reference: "")
        #expect(throws: (any Error).self) { try feedback.validated(answer: "Actual answer", task: task, evidence: []) }
    }
    @Test @MainActor func leavingCompletedPracticeCancelsOwnedMaterialImport() async throws {
        let db = try AppDatabase(inMemory: true)
        let app = AppState(database: db, dialogueDefaults: nil)
        let controller = app.practiceController
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hireva-synthetic-\(UUID().uuidString).txt")
        try Data("Synthetic question material".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        controller.start(kind: .coding, question: "Explain a stack", language: "en", criteria: [], maxFollowUps: 0)
        controller.beginAnswer()
        controller.submit(skipped: true)
        #expect(controller.run?.phase == .completed)
        let revision = controller.run?.revision
        controller.importMaterial(from: url)
        #expect(controller.importingMaterial)
        let token = controller.ownershipToken
        // The live-start path calls pause even if the completed Practice view is visible.
        controller.pause()
        #expect(!controller.importingMaterial)
        #expect(controller.ownershipToken != token)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.run?.phase == .completed)
        #expect(controller.run?.revision == revision)
        #expect(controller.run?.attachment == nil)
        #expect(controller.error == nil)
        let completedID = try #require(controller.run?.sessionID)
        controller.start(kind: .data, question: "Count rows", language: "en", criteria: [], maxFollowUps: 0)
        #expect(try PracticeRepository(database: db).load(sessionID: completedID)?.phase == .completed)
        await app.shutdownForTesting()
        try db.close()
    }
    @Test func revokedPersistenceTicketStaysRevokedAfterReenable() throws {
        let consent = PersistenceConsent()
        let ticket = consent.ticket()
        consent.update(enabled: false); consent.update(enabled: true)
        var wrote = false
        #expect(throws: (any Error).self) { try consent.write(ticket: ticket) { wrote = true } }
        #expect(!wrote)
        try consent.write(ticket: consent.ticket()) { wrote = true }
        #expect(wrote)
    }
    // Adapted golden vector from swift-fsrs v4.1.0 Tests/FSRSTests/FSRSTests.swift.
    // MIT, Copyright 2023 Ben Smiley; full license in packaged ThirdPartyNotices.
    // This checks algorithm integration, not independent interview quality.
    @Test func upstreamFSRSGoldenVectorAndCodableRoundTrip() throws {
        var scheduler = FSRS()
        scheduler.p.w = [1.0171,1.8296,4.4145,10.9355,5.0965,1.3322,1.017,0,1.6243,0.1369,1.0321,2.1866,0.0661,0.336,1.7766,0.1693,2.9244]
        var now = Date(timeIntervalSince1970: 1669681800)
        var card = Card(due: now, lastReview: now)
        var intervals: [Double] = []
        for rating: Rating in [.good,.good,.good,.good,.good,.good,.again,.again,.good,.good,.good,.good,.good] {
            let next = try #require(scheduler.repeat(card: card, now: now)[rating])
            card = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(next.card))
            intervals.append(card.scheduledDays)
            now = card.due
        }
        #expect(intervals == [0,4,15,49,143,379,0,0,15,37,85,184,376])
    }
}

private struct FeedbackProvider: LocalLLMProvider {
    let feedback: PracticeFeedback
    var id: String { "synthetic" }
    var displayName: String { "Synthetic" }
    func healthCheck(modelName: String) async -> LocalLLMHealth { .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil) }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
        var coverage: [String: String?] = [:]
        for line in (payload["rubric"] ?? "").components(separatedBy: .newlines) {
            let pair = line.components(separatedBy: ": ")
            guard pair.count >= 2 else { continue }
            let criterion = pair.dropFirst().joined(separator: ": ")
            coverage[pair[0]] = .some(feedback.covered.first { $0.criterion == criterion }?.quote)
        }
        let wire = PracticeEvaluationPayload(coverage: coverage, suggestion: feedback.suggestions.joined(separator: "\n"), followUp: feedback.followUp, reason: feedback.reason, reference: feedback.reference)
        let text = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        return AsyncThrowingStream { $0.yield(.init(text: text, source: .localQwen, modelName: "synthetic")); $0.finish() }
    }
}
