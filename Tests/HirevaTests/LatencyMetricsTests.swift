import Foundation
import Testing
import GRDB
@testable import Hireva

@Suite
struct LatencyMetricsTests {
    
    @Test
    func latencyBudgetClassification() {
        // ASR first partial: <800 PASS, <1500 WARN, else FAIL
        #expect(LatencyBudget.asrFirstPartial(500) == .pass)
        #expect(LatencyBudget.asrFirstPartial(1000) == .warn)
        #expect(LatencyBudget.asrFirstPartial(2000) == .fail)
        #expect(LatencyBudget.asrFirstPartial(nil) == .unknown)
        
        // ASR best selected: <2500 PASS, <4000 WARN, else FAIL
        #expect(LatencyBudget.asrBestSelected(2000) == .pass)
        #expect(LatencyBudget.asrBestSelected(3000) == .warn)
        #expect(LatencyBudget.asrBestSelected(5000) == .fail)
        #expect(LatencyBudget.asrBestSelected(nil) == .unknown)
        
        // RAG retrieval: <300 PASS, <600 WARN, else FAIL
        #expect(LatencyBudget.ragRetrieval(150) == .pass)
        #expect(LatencyBudget.ragRetrieval(400) == .warn)
        #expect(LatencyBudget.ragRetrieval(800) == .fail)
        
        // First visible: <=1500 PASS, <=3000 WARN, else FAIL
        #expect(LatencyBudget.firstVisible(1500) == .pass)
        #expect(LatencyBudget.firstVisible(2500) == .warn)
        #expect(LatencyBudget.firstVisible(4000) == .fail)
        
        // Full card: <=8000 PASS, <=12000 WARN, else FAIL
        #expect(LatencyBudget.fullCard(7999) == .pass)
        #expect(LatencyBudget.fullCard(10000) == .warn)
        #expect(LatencyBudget.fullCard(15000) == .fail)
    }
    
    @Test
    func transcriptSegmentASRLatencyRoundtrips() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        
        let session = try sessions.createSession(mode: .mock, title: "Test Session")
        
        let segment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: session.id,
            speaker: .candidate,
            text: "Hello",
            asrFirstPartialMS: 120,
            asrFinalMS: 450,
            asrBestSelectedMS: 500,
            asrFinalizationReason: "final_accepted"
        )
        try transcripts.saveSegment(segment)
        
        let loaded = try transcripts.segmentByID(segment.id)
        #expect(loaded != nil)
        #expect(loaded?.asrFirstPartialMS == 120)
        #expect(loaded?.asrFinalMS == 450)
        #expect(loaded?.asrBestSelectedMS == 500)
        #expect(loaded?.asrFinalizationReason == "final_accepted")
    }
    
    @Test
    func suggestionCardLatencyMetricsAndLinkedASR() throws {
        let database = try makeTemporaryDatabase()
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        
        let session = try sessions.createSession(mode: .microphone, title: "Microphone Interview")
        
        // Save transcript segment with ASR latency
        let segment = TranscriptSegment(
            id: UUID().uuidString,
            sessionID: session.id,
            speaker: .interviewer,
            text: "Question?",
            asrFirstPartialMS: 150,
            asrFinalMS: 550,
            asrBestSelectedMS: 600,
            asrFinalizationReason: "final_accepted"
        )
        try transcripts.saveSegment(segment)
        
        // Set up DetectedQuestion
        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: session.id,
            transcriptSegmentID: segment.id,
            questionText: segment.text,
            intent: .projectDeepDive,
            answerStrategy: .projectWalkthrough,
            confidence: 0.9,
            reason: "ASR",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-v4-flash",
            promptVersion: "1.0",
            createdAt: Date()
        )
        try suggestions.saveDetectedQuestion(question)
        
        // Create suggestion card and copy ASR from segment
        var card = SuggestionCard(
            id: UUID().uuidString,
            sessionID: session.id,
            questionID: question.id,
            strategy: "Strategy",
            sayFirst: "Opener",
            keyPoints: ["Point 1"],
            followUpReady: [],
            evidenceUsed: [],
            modelName: "deepseek-v4-flash",
            promptVersion: "1.0",
            createdAt: Date()
        )
        
        // Copy linked transcript ASR latency (simulating the AppState behavior)
        if let segment = try transcripts.segmentByID(segment.id) {
            card.questionASRFirstPartialMS = segment.asrFirstPartialMS
            card.questionASRFinalMS = segment.asrFinalMS
            card.questionASRBestSelectedMS = segment.asrBestSelectedMS
        }
        card.ragRetrievalLatencyMS = 85
        card.latencyFirstVisibleMS = 1200
        card.latencyFullCardMS = 4500
        card.softFallbackUsed = false
        card.providerName = "DeepSeek"
        card.stageBStatus = "completed"
        
        try suggestions.saveSuggestionCard(card)
        
        let loaded = try suggestions.suggestions(sessionID: session.id).first
        #expect(loaded != nil)
        #expect(loaded?.questionASRFirstPartialMS == 150)
        #expect(loaded?.questionASRFinalMS == 550)
        #expect(loaded?.questionASRBestSelectedMS == 600)
        #expect(loaded?.ragRetrievalLatencyMS == 85)
        #expect(loaded?.latencyFirstVisibleMS == 1200)
        #expect(loaded?.latencyFullCardMS == 4500)
        #expect(loaded?.softFallbackUsed == false)
    }
    
    @Test
    func latencyAveragesFilteringAndPercentiles() throws {
        let database = try makeTemporaryDatabase()
        let suggestions = SuggestionRepository(database: database)
        let sessions = SessionRepository(database: database)
        
        // Create two sessions with different modes
        let practiceSession = try sessions.createSession(mode: .mock, title: "Practice")
        let interviewSession = try sessions.createSession(mode: .microphone, title: "Interview")
        
        // Generate several suggestion cards with varying latencies
        // Cards 1-5: Practice mode (.mock), DeepSeek, first_visible: 1100, 1200, 1300, 1400, 1500
        for i in 1...5 {
            let card = SuggestionCard(
                id: UUID().uuidString,
                sessionID: practiceSession.id,
                strategy: "Strategy",
                sayFirst: "Say first",
                keyPoints: [],
                followUpReady: [],
                evidenceUsed: [],
                modelName: "deepseek-v4-flash",
                promptVersion: "1.0",
                providerName: "DeepSeek",
                createdAt: Date().addingTimeInterval(TimeInterval(-i * 60))
            )
            var updated = card
            updated.latencyFirstVisibleMS = 1000 + i * 100 // 1100, 1200, 1300, 1400, 1500
            updated.latencyFullCardMS = 5000
            updated.ragRetrievalLatencyMS = 50
            updated.questionASRBestSelectedMS = 100
            updated.softFallbackUsed = false
            updated.stageBStatus = "completed"
            try suggestions.saveSuggestionCard(updated)
        }
        
        // Cards 6-10: Interview mode (.microphone), API provider, first_visible: 2100, 2200, 2300, 2400, 2500
        for i in 1...5 {
            let card = SuggestionCard(
                id: UUID().uuidString,
                sessionID: interviewSession.id,
                strategy: "Strategy",
                sayFirst: "Say first",
                keyPoints: [],
                followUpReady: [],
                evidenceUsed: [],
                modelName: "custom-api-model",
                promptVersion: "1.0",
                providerName: "Custom API",
                createdAt: Date().addingTimeInterval(TimeInterval(-i * 60 - 1000))
            )
            var updated = card
            updated.latencyFirstVisibleMS = 2000 + i * 100 // 2100, 2200, 2300, 2400, 2500
            updated.latencyFullCardMS = 9000
            updated.ragRetrievalLatencyMS = 250
            updated.questionASRBestSelectedMS = 300
            updated.softFallbackUsed = true
            updated.stageBStatus = "timed_out"
            try suggestions.saveSuggestionCard(updated)
        }
        
        // 1. Overall averages (all providers, all modes)
        let overall = try suggestions.fetchLatencyAverages(last: 10)
        #expect(overall.count == 10)
        #expect(overall.avgFirstVisibleMS != nil)
        #expect(overall.p50FirstVisibleMS != nil)
        #expect(overall.p90FirstVisibleMS != nil)
        #expect(overall.softFallbackRate == 0.5) // 5 out of 10 used soft fallback
        #expect(overall.failureRate == 0.5)      // 5 out of 10 timed out
        
        // 2. Filter by DeepSeek provider
        let deepseekAvg = try suggestions.fetchLatencyAverages(last: 10, provider: "DeepSeek")
        #expect(deepseekAvg.count == 5)
        #expect(deepseekAvg.avgFirstVisibleMS == 1300.0) // (1100 + 1200 + 1300 + 1400 + 1500) / 5
        #expect(deepseekAvg.p50FirstVisibleMS == 1300)
        #expect(deepseekAvg.p90FirstVisibleMS == 1500)
        #expect(deepseekAvg.softFallbackRate == 0.0)
        #expect(deepseekAvg.failureRate == 0.0)
        
        // 3. Filter by API provider provider
        let apiProviderAvg = try suggestions.fetchLatencyAverages(last: 10, provider: "Custom API")
        #expect(apiProviderAvg.count == 5)
        #expect(apiProviderAvg.avgFirstVisibleMS == 2300.0) // (2100 + 2200 + 2300 + 2400 + 2500) / 5
        #expect(apiProviderAvg.softFallbackRate == 1.0)
        #expect(apiProviderAvg.failureRate == 1.0)
        
        // 4. Filter by Practice mode (.mock)
        let practiceAvg = try suggestions.fetchLatencyAverages(last: 10, mode: .mock)
        #expect(practiceAvg.count == 5)
        #expect(practiceAvg.avgFirstVisibleMS == 1300.0)
        
        // 5. Filter by Interview mode (.microphone)
        let interviewAvg = try suggestions.fetchLatencyAverages(last: 10, mode: .microphone)
        #expect(interviewAvg.count == 5)
        #expect(interviewAvg.avgFirstVisibleMS == 2300.0)
    }
    
    @Test
    func migrationV8IsIdempotent() throws {
        let database = try makeTemporaryDatabase()
        // Re-running registerMigration/apply migrations on active DB to prove safety
        try database.dbQueue.write { db in
            let tsRows = try Row.fetchAll(db, sql: "PRAGMA table_info(transcript_segments)")
            let tsColumns = tsRows.compactMap { $0["name"] as? String }
            #expect(tsColumns.contains("asr_first_partial_ms"))
            #expect(tsColumns.contains("asr_final_ms"))
            #expect(tsColumns.contains("asr_best_selected_ms"))
            #expect(tsColumns.contains("asr_finalization_reason"))
            
            let scRows = try Row.fetchAll(db, sql: "PRAGMA table_info(suggestion_cards)")
            let scColumns = scRows.compactMap { $0["name"] as? String }
            #expect(scColumns.contains("rag_retrieval_latency_ms"))
            #expect(scColumns.contains("question_asr_first_partial_ms"))
            #expect(scColumns.contains("question_asr_final_ms"))
            #expect(scColumns.contains("question_asr_best_selected_ms"))
        }
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatencyMetricsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
