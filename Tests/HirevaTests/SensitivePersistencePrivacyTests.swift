import Foundation
import GRDB
import Testing
@testable import Hireva

// All values in this suite are synthetic canaries and are not credentials or personal data.
@Suite(.serialized)
struct SensitivePersistencePrivacyTests {
    private static let migrationID = "v17_discard_raw_provider_context"
    private static let sensitiveCanaries = [
        "PROVIDER_PAYLOAD_CANARY_4C6E",
        "TRANSCRIPT_CANARY_SYNTHETIC_INTERVIEW_17A2",
        "CV_CANARY_SYNTHETIC_PROFILE_52B1",
        "JD_CANARY_SYNTHETIC_ROLE_8D03",
        "API_KEY_CANARY_NOT_A_SECRET_0F91",
        "/private/var/tmp/HIREVA_PATH_CANARY_6A20/provider-response.json"
    ]

    private static var sensitivePayload: String {
        sensitiveCanaries.joined(separator: " | ")
    }

    @Test
    func repositoryDiscardsRawProviderAndPromptContextFieldsBeforeSQLiteWrite() throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Synthetic privacy canary")
        let question = makeQuestion(sessionID: session.id, rawJSON: Self.sensitivePayload)
        let card = makeCard(
            sessionID: session.id,
            questionID: question.id,
            rawJSON: Self.sensitivePayload,
            promptContextPreview: Self.sensitivePayload
        )

        try suggestions.saveDetectedQuestion(question)
        try suggestions.saveSuggestionCard(card)

        let stored = try forbiddenColumns(database: database, questionID: question.id, cardID: card.id)
        #expect(stored == [nil, nil, nil])
        for canary in Self.sensitiveCanaries {
            #expect(!stored.compactMap { $0 }.joined(separator: " ").contains(canary))
        }

        let reloadedQuestion = try #require(suggestions.questions(sessionID: session.id).first)
        let reloadedCard = try #require(suggestions.suggestions(sessionID: session.id).first)
        #expect(reloadedQuestion.rawJSON == nil)
        #expect(reloadedCard.rawJSON == nil)
        #expect(reloadedCard.promptContextPreview == nil)
    }

    @Test
    func migrationClearsLegacyValuesAndCanBeReappliedWithoutChangingTheResult() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaSensitiveMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("privacy.sqlite")
        let questionID = "legacy-sensitive-question"
        let cardID = "legacy-sensitive-card"

        do {
            let database = try AppDatabase(path: databaseURL)
            defer { try? database.close() }
            let sessions = SessionRepository(database: database)
            let suggestions = SuggestionRepository(database: database)
            let session = try sessions.createSession(mode: .mock, title: "Synthetic legacy privacy canary")
            try suggestions.saveDetectedQuestion(makeQuestion(sessionID: session.id, id: questionID))
            try suggestions.saveSuggestionCard(makeCard(sessionID: session.id, questionID: questionID, id: cardID))

            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE detected_questions SET raw_json = ? WHERE id = ?",
                    arguments: [Self.sensitivePayload, questionID]
                )
                try db.execute(
                    sql: "UPDATE suggestion_cards SET raw_json = ?, prompt_context_preview = ? WHERE id = ?",
                    arguments: [Self.sensitivePayload, Self.sensitivePayload, cardID]
                )
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [Self.migrationID]
                )
            }
            #expect(try forbiddenColumns(database: database, questionID: questionID, cardID: cardID) == [
                Self.sensitivePayload,
                Self.sensitivePayload,
                Self.sensitivePayload
            ])
        }

        do {
            let database = try AppDatabase(path: databaseURL)
            defer { try? database.close() }
            #expect(try forbiddenColumns(database: database, questionID: questionID, cardID: cardID) == [nil, nil, nil])
            #expect(try migrationCount(database: database) == 1)

            // Re-run the migration against already-cleared rows to prove the SQL is idempotent.
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [Self.migrationID]
                )
            }
        }

        do {
            let database = try AppDatabase(path: databaseURL)
            defer { try? database.close() }
            #expect(try forbiddenColumns(database: database, questionID: questionID, cardID: cardID) == [nil, nil, nil])
            #expect(try migrationCount(database: database) == 1)
        }
    }

    @Test
    func generationServicesKeepRawProviderAndContextCanariesOutOfDomainModels() async throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        let client = SensitiveCanaryLLMClient(payload: Self.sensitivePayload)
        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])
        let questionService = QuestionDetectionService(llmRouter: router)

        let detection = try await questionService.detect(
            transcriptContext: "Interviewer: How did you validate the synthetic event processor?",
            sessionID: "synthetic-service-session",
            transcriptSegmentID: "synthetic-segment"
        )
        #expect(detection.question.rawJSON == nil)

        let suggestionService = SuggestionGenerationService(llmRouter: router)
        let card = try await suggestionService.generate(
            question: detection.question,
            context: makeSensitiveContext(),
            transcriptContext: "Synthetic transcript context. \(Self.sensitivePayload)",
            sessionID: "synthetic-service-session"
        ).card
        #expect(card.rawJSON == nil)
        #expect(card.promptContextPreview == nil)
    }

    @Test
    func detectorFallbackPersistsOnlyStableFailureClassification() async throws {
        let database = try makeTemporaryDatabase()
        defer { try? database.close() }
        let settings = SettingsRepository(database: database)
        try settings.ensureDefaultProviderConfigurations()
        let client = SensitiveCanaryLLMClient(
            payload: Self.sensitivePayload,
            failure: LLMProviderError.networkFailure(
                providerName: Self.sensitivePayload,
                message: Self.sensitivePayload
            )
        )
        let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])

        let result = try await QuestionDetectionService(llmRouter: router).detect(
            transcriptContext: "Interviewer: Why did the synthetic validation catch the fault?",
            sessionID: "synthetic-fallback-session",
            transcriptSegmentID: "synthetic-fallback-segment"
        )

        #expect(result.question.reason == "Local fallback used after question detector failure (network_failure, local_heuristic_match).")
        #expect(result.question.rawJSON == nil)
        #expect(result.response.rawResponse == nil)
        for canary in Self.sensitiveCanaries {
            #expect(result.question.reason?.contains(canary) == false)
        }
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaSensitivePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try AppDatabase(path: root.appendingPathComponent("privacy.sqlite"))
    }

    private func makeQuestion(
        sessionID: String,
        id: String = "sensitive-question",
        rawJSON: String? = nil
    ) -> DetectedQuestion {
        DetectedQuestion(
            id: id,
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: "How did you validate the synthetic event processor?",
            intent: .technical,
            answerStrategy: .technicalExplanation,
            confidence: 0.95,
            reason: "Synthetic complete technical question.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "synthetic-provider-model",
            promptVersion: "synthetic-prompt-v1",
            providerKind: .deepSeek,
            providerName: "Synthetic Provider",
            providerBaseURL: "https://provider.invalid",
            latencyMS: 1,
            isLocal: false,
            rawJSON: rawJSON,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeCard(
        sessionID: String,
        questionID: String,
        id: String = "sensitive-card",
        rawJSON: String? = nil,
        promptContextPreview: String? = nil
    ) -> SuggestionCard {
        SuggestionCard(
            id: id,
            sessionID: sessionID,
            questionID: questionID,
            strategy: "Synthetic validation strategy",
            sayFirst: "I validated the synthetic processor with deterministic fault injection.",
            keyPoints: ["Used synthetic fixtures", "Verified deterministic recovery"],
            followUpReady: ["I can describe the synthetic validation sequence."],
            confidence: 0.9,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: "synthetic-provider-model",
            promptVersion: "synthetic-prompt-v1",
            providerKind: .deepSeek,
            providerName: "Synthetic Provider",
            providerBaseURL: "https://provider.invalid",
            latencyMS: 1,
            isLocal: false,
            rawJSON: rawJSON,
            createdAt: Date(timeIntervalSince1970: 1_001),
            questionText: "How did you validate the synthetic event processor?",
            promptQuestionText: "How did you validate the synthetic event processor?",
            promptPrimaryQuestion: "How did you validate the synthetic event processor?",
            promptTokenEstimate: 42,
            promptContextPreview: promptContextPreview,
            stageBCompleted: true,
            stageBStatus: "completed"
        )
    }

    private func forbiddenColumns(
        database: AppDatabase,
        questionID: String,
        cardID: String
    ) throws -> [String?] {
        try database.dbQueue.read { db in
            guard let questionRow = try Row.fetchOne(
                db,
                sql: "SELECT raw_json FROM detected_questions WHERE id = ?",
                arguments: [questionID]
            ) else {
                throw SensitivePersistenceTestError.missingQuestionRow
            }
            guard let cardRow = try Row.fetchOne(
                db,
                sql: "SELECT raw_json, prompt_context_preview FROM suggestion_cards WHERE id = ?",
                arguments: [cardID]
            ) else {
                throw SensitivePersistenceTestError.missingCardRow
            }
            return [
                questionRow["raw_json"] as String?,
                cardRow["raw_json"] as String?,
                cardRow["prompt_context_preview"] as String?
            ]
        }
    }

    private func migrationCount(database: AppDatabase) throws -> Int {
        try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: [Self.migrationID]
            ) ?? 0
        }
    }

    private func makeSensitiveContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [makeChunk(id: "sensitive-cv", type: .cv, content: Self.sensitivePayload)],
            jobDescriptionChunks: [makeChunk(id: "sensitive-jd", type: .jobDescription, content: Self.sensitivePayload)]
        )
    }

    private func makeChunk(id: String, type: DocumentType, content: String) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "\(id)-document",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: ["synthetic", "canary"],
            sectionTitle: "Synthetic evidence",
            wordCount: content.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date(timeIntervalSince1970: 999)
        )
    }
}

private enum SensitivePersistenceTestError: Error {
    case missingQuestionRow
    case missingCardRow
}

private final class SensitiveCanaryLLMClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let payload: String
    private let failure: Error?

    init(payload: String, failure: Error? = nil) {
        self.payload = payload
        self.failure = failure
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Synthetic provider ready", latencyMS: 1, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        if let failure {
            throw failure
        }

        let content: String
        if messages.contains(where: { $0.content.contains("Decide whether the interviewer has asked") }) {
            content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": "How did you validate the synthetic event processor?",
              "intent": "technical",
              "answer_strategy": "technical_explanation",
              "confidence": 0.95,
              "reason": "Synthetic provider classification.",
              "provider_debug": "\(payload)"
            }
            """
        } else {
            content = """
            {
              "strategy": "Synthetic validation strategy",
              "say_first": "I validated the synthetic processor with deterministic fault injection.",
              "key_points": ["Used synthetic fixtures", "Verified deterministic recovery"],
              "follow_up_ready": ["I can describe the synthetic validation sequence."],
              "confidence": 0.9,
              "caution": null,
              "evidence_used": [],
              "risk_level": "low",
              "provider_debug": "\(payload)"
            }
            """
        }

        return LLMChatResult(
            content: content,
            modelName: "synthetic-provider-model",
            providerKind: .deepSeek,
            providerName: "Synthetic Provider",
            baseURL: "https://provider.invalid",
            latencyMS: 1,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}
