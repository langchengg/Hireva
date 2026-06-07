import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
struct RepositoryTests {
    @Test
    func documentRepositoryPersistsDocumentsChunksAndOnboardingGate() throws {
        let database = try makeTemporaryDatabase()
        let repository = DocumentRepository(database: database)

        #expect(try !repository.isOnboardingComplete())

        _ = try repository.saveDocument(
            type: .cv,
            title: "Resume",
            content: String(repeating: "Swift robotics machine learning leadership ", count: 10)
        )
        #expect(try !repository.isOnboardingComplete())

        _ = try repository.saveDocument(
            type: .jobDescription,
            title: "ML Engineer JD",
            content: String(repeating: "Build production AI applications with Swift macOS and reliable APIs ", count: 10)
        )

        #expect(try repository.isOnboardingComplete())
        #expect(try repository.documents().count == 2)
        #expect(try !repository.chunks(type: .cv).isEmpty)
    }

    @Test
    func sessionTranscriptSuggestionAndRecapCRUD() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let recaps = RecapRepository(database: database)

        let session = try sessions.createSession(mode: .mock, title: "Mock Interview")
        let segment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: session.id,
            speaker: .unknown,
            text: "Can you walk me through your robotics project?",
            startTime: nil,
            endTime: nil,
            createdAt: Date()
        )
        try transcripts.saveSegment(segment)

        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: session.id,
            transcriptSegmentID: segment.id,
            questionText: segment.text,
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.91,
            reason: "Direct project walkthrough prompt.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-v4-flash",
            promptVersion: PromptLibrary.questionDetector.versionTag,
            rawJSON: #"{"should_trigger":true}"#,
            createdAt: Date()
        )
        try suggestions.saveDetectedQuestion(question)

        let card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: session.id,
            questionID: question.id,
            strategy: "Project walkthrough",
            sayFirst: "I worked on a grounded robotics project.",
            keyPoints: ["Problem", "Method", "Contribution"],
            followUpReady: ["How did you evaluate it?"],
            confidence: 0.9,
            caution: "Avoid overclaiming.",
            evidenceUsed: ["robotics project"],
            riskLevel: .low,
            modelName: "deepseek-v4-flash",
            promptVersion: PromptLibrary.suggestionGenerator.versionTag,
            rawJSON: #"{"strategy":"Project walkthrough"}"#,
            createdAt: Date()
        )
        try suggestions.saveSuggestionCard(card)

        let recap = RecapReport(
            id: UUID().uuidString,
            sessionID: session.id,
            markdown: "# Interview Recap",
            modelName: "deepseek-v4-pro",
            promptVersion: PromptLibrary.recap.versionTag,
            createdAt: Date()
        )
        try recaps.saveRecap(recap)

        #expect(try transcripts.segments(sessionID: session.id).count == 1)
        #expect(try suggestions.questions(sessionID: session.id).first?.modelName == "deepseek-v4-flash")
        #expect(try suggestions.suggestions(sessionID: session.id).first?.evidenceUsed == ["robotics project"])
        #expect(try recaps.recap(sessionID: session.id)?.markdown == "# Interview Recap")

        try sessions.deleteSession(id: session.id)
        #expect(try sessions.session(id: session.id) == nil)
        #expect(try transcripts.segments(sessionID: session.id).isEmpty)
    }

    @Test
    func suggestionRepositoryUpsertsSoftFallbackThenStageBUpdate() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Idempotent Suggestions")
        let question = try saveQuestion(sessionID: session.id, repository: suggestions)

        var fallback = makeCard(id: "canonical-card", sessionID: session.id, questionID: question.id)
        fallback.sayFirst = "I can start with the strongest relevant project."
        fallback.sayFirstSource = "rag_template_soft_fallback"
        fallback.stageBCompleted = false
        fallback.stageBStatus = "skipped"
        try suggestions.saveSuggestionCard(fallback, retrievedChunks: [makeChunk(id: "chunk-a")])

        var stageB = fallback
        stageB.strategy = "Project walkthrough"
        stageB.sayFirst = "I worked on a robotics project where I connected perception to action."
        stageB.keyPoints = ["Problem", "Method", "Impact"]
        stageB.sayFirstSource = "deepseek_stream"
        stageB.stageBCompleted = true
        stageB.stageBStatus = "completed"
        try suggestions.saveSuggestionCard(stageB, retrievedChunks: [makeChunk(id: "chunk-b")])

        let saved = try suggestions.suggestions(sessionID: session.id)
        #expect(saved.count == 1)
        #expect(saved.first?.id == "canonical-card")
        #expect(saved.first?.stageBCompleted == true)
        #expect(saved.first?.keyPoints == ["Problem", "Method", "Impact"])

        let chunks = try suggestions.retrievedChunks(suggestionCardID: "canonical-card")
        #expect(chunks.count == 1)
        #expect(chunks.first?.id == "chunk-b")
    }

    @Test
    func suggestionRepositoryUpsertsStageAThenStageBUpdate() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Stage A to Stage B")
        let question = try saveQuestion(sessionID: session.id, repository: suggestions)

        var stageA = makeCard(id: "stream-card", sessionID: session.id, questionID: question.id)
        stageA.strategy = "Quick Opener"
        stageA.sayFirst = "I built this by focusing on reliability first."
        stageA.keyPoints = []
        stageA.sayFirstSource = "deepseek_stream"
        stageA.stageBCompleted = false
        stageA.stageBStatus = "skipped"
        try suggestions.saveSuggestionCard(stageA)

        var stageB = stageA
        stageB.strategy = "Technical explanation"
        stageB.keyPoints = ["Architecture", "Tradeoffs"]
        stageB.stageBCompleted = true
        stageB.stageBStatus = "completed"
        try suggestions.saveSuggestionCard(stageB)

        let saved = try suggestions.suggestions(sessionID: session.id)
        #expect(saved.count == 1)
        #expect(saved.first?.strategy == "Technical explanation")
        #expect(saved.first?.sayFirst == "I built this by focusing on reliability first.")
        #expect(saved.first?.stageBStatus == "completed")
    }

    @Test
    func suggestionRepositoryLateDeepSeekReplacementUpdatesSameCard() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let session = try sessions.createSession(mode: .mock, title: "Late Replacement")
        let question = try saveQuestion(sessionID: session.id, repository: suggestions)

        var fallback = makeCard(id: "replacement-card", sessionID: session.id, questionID: question.id)
        fallback.sayFirst = "I can speak to the most relevant project from my background."
        fallback.sayFirstSource = "rag_template_soft_fallback"
        fallback.finalVisibleSource = "rag_template_soft_fallback"
        try suggestions.saveSuggestionCard(fallback, retrievedChunks: [makeChunk(id: "fallback-source")])

        var replacement = fallback
        replacement.sayFirst = "I worked on a robotics project that connected language-conditioned goals to grasp selection."
        replacement.sayFirstSource = "deepseek_stream"
        replacement.finalVisibleSource = "deepseek_stream"
        try suggestions.saveSuggestionCard(replacement, retrievedChunks: [makeChunk(id: "deepseek-source")])

        let saved = try suggestions.suggestions(sessionID: session.id)
        #expect(saved.count == 1)
        #expect(saved.first?.sayFirst == replacement.sayFirst)
        #expect(saved.first?.finalVisibleSource == "deepseek_stream")

        let chunks = try suggestions.retrievedChunks(suggestionCardID: "replacement-card")
        #expect(chunks.map(\.id) == ["deepseek-source"])
    }

    @Test
    func documentRepositoryRebuildCleanRAGIndexSanitizesLegacyChunks() throws {
        let database = try makeTemporaryDatabase()
        let repository = DocumentRepository(database: database)
        let documentID = UUID().uuidString
        let now = DateCoding.string(from: Date())
        let legacyLatex = #"""
        \documentclass{resume}
        \usepackage[left=0.4in]{geometry}
        \begin{document}
        \section{Projects}
        \textbf{Robotics Project} Built a language-conditioned robotic grasping pipeline.
        \end{document}
        """#

        try database.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO documents (id, type, title, content, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [documentID, DocumentType.cv.rawValue, "Legacy Resume", legacyLatex, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO document_chunks (id, document_id, document_type, chunk_index, content, keywords, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, documentID, DocumentType.cv.rawValue, 0, legacyLatex, "documentclass,usepackage,geometry", now]
            )
        }

        let result = try repository.rebuildCleanRAGIndex()
        let chunks = try repository.chunks(type: .cv)
        let pollutedCount = try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM document_chunks
                WHERE content LIKE '%documentclass%'
                   OR content LIKE '%usepackage%'
                   OR content LIKE '%geometry%'
                   OR content LIKE '%begin{document}%'
                """
            ) ?? 0
        }

        #expect(result.documentsRebuilt == 1)
        #expect(result.chunksRebuilt > 0)
        #expect(pollutedCount == 0)
        #expect(chunks.contains { $0.content.contains("Robotics Project") })
        #expect(chunks.allSatisfy { !$0.content.contains("documentclass") && !$0.content.contains("usepackage") && !$0.content.contains("geometry") })
        #expect(try repository.document(type: .cv)?.content == legacyLatex.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewCopilotMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    private func saveQuestion(sessionID: String, repository: SuggestionRepository) throws -> DetectedQuestion {
        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: sessionID,
            transcriptSegmentID: nil,
            questionText: "Can you walk me through your robotics project?",
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.91,
            reason: "Direct project walkthrough prompt.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test-model",
            promptVersion: PromptLibrary.questionDetector.versionTag,
            rawJSON: #"{"should_trigger":true}"#,
            createdAt: Date()
        )
        try repository.saveDetectedQuestion(question)
        return question
    }

    private func makeCard(id: String, sessionID: String, questionID: String) -> SuggestionCard {
        SuggestionCard(
            id: id,
            sessionID: sessionID,
            questionID: questionID,
            strategy: "Fallback",
            sayFirst: "I can answer this from my project experience.",
            keyPoints: ["Project"],
            followUpReady: ["How did you evaluate it?"],
            confidence: 0.8,
            caution: "Keep it concise.",
            evidenceUsed: ["chunk-a"],
            riskLevel: .low,
            modelName: "test-model",
            promptVersion: PromptLibrary.suggestionGenerator.versionTag,
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "https://api.deepseek.com",
            latencyMS: 100,
            isLocal: false,
            rawJSON: #"{"strategy":"Fallback"}"#,
            createdAt: Date(),
            sayFirstSource: "rag_template_soft_fallback",
            stageATimedOut: false,
            stageBCompleted: false,
            stageBStatus: "skipped",
            latencyFirstTokenMS: nil,
            latencyFirstVisibleMS: 1500,
            latencyFullCardMS: nil,
            softFallbackUsed: true,
            softFallbackLatencyMS: 1500,
            deepseekFirstTokenMS: nil,
            deepseekFirstVisibleMS: nil,
            finalVisibleSource: "rag_template_soft_fallback"
        )
    }

    private func makeChunk(id: String) -> RetrievedChunk {
        RetrievedChunk(
            id: id,
            documentID: "document-\(id)",
            documentType: .cv,
            chunkIndex: 0,
            contentPreview: "Robotics project evidence",
            fullContent: "Robotics project evidence without formatting commands.",
            keywords: ["robotics", "project"],
            score: 1.0,
            keywordOverlapCount: 1,
            contentOverlapCount: 1,
            rank: 1,
            isIncludedInPrompt: true,
            sectionTitle: "Projects",
            wordCount: 6,
            semanticScore: 0.9,
            keywordScoreNormalized: 0.8,
            finalHybridScore: 0.87,
            retrievalMode: "hybrid"
        )
    }
}
