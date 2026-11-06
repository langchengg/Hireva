import Combine
import Foundation
import Testing
@testable import Hireva

@Suite("History state ownership", .serialized)
@MainActor
struct HistoryStateTests {
    @Test
    func loadsOriginalRecordsAndFrozenSourcesFromRealRepositories() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let state = makeState(database)
        let session = try SessionRepository(database: database).createSession(mode: .mock, title: "Synthetic history")
        let segment = TranscriptSegment(id: "history-source", sessionID: session.id, source: .systemAudio, speaker: .unknown, text: "Original synthetic transcription.")
        try TranscriptRepository(database: database).saveSegment(segment)
        try HistoryCorrectionRepository(database: database).save(segment: segment, text: "Corrected synthetic transcription.", speaker: .interviewer, startsQuestion: false, question: "")
        let card = SuggestionCard(id: "history-card", sessionID: session.id, questionID: nil, strategy: "Synthetic", sayFirst: "Synthetic saved answer.", keyPoints: [], followUpReady: [], confidence: nil, caution: nil, evidenceUsed: [], riskLevel: nil, modelName: "fixture", promptVersion: "fixture", rawJSON: nil, createdAt: Date())
        let chunk = RetrievedChunk(id: "frozen-chunk", documentID: "synthetic-document", documentType: .cv, chunkIndex: 0, contentPreview: "Synthetic frozen evidence.", fullContent: "Synthetic frozen evidence.", keywords: [], score: 1, keywordOverlapCount: 0, contentOverlapCount: 0, rank: 1, isIncludedInPrompt: true, sectionTitle: nil, wordCount: 3)
        try SuggestionRepository(database: database).saveSuggestionCard(card, retrievedChunks: [chunk])
        let recap = RecapReport(id: "history-recap", sessionID: session.id, markdown: "Synthetic recap.", modelName: "fixture", promptVersion: "fixture", createdAt: Date(), contentRevision: 0)
        try RecapRepository(database: database).saveRecap(recap)

        try state.refreshSessions()
        try state.loadSessionDetails(sessionID: session.id)

        #expect(state.sessions.map(\.id) == [session.id])
        #expect(state.selectedSessionID == session.id)
        #expect(state.selectedSessionTranscript.map(\.text) == [segment.text])
        #expect(state.selectedSessionSuggestions.map(\.id) == [card.id])
        #expect(state.selectedSessionRecap?.markdown == recap.markdown)
        #expect(state.historicalSuggestionChunks[card.id]?.map(\.fullContent) == [chunk.fullContent])
        #expect(try HistoryCorrectionRepository(database: database).revisions(sessionID: session.id).count == 1)
    }

    @Test
    func switchingToEmptySessionClearsPreviousRecordsAndSources() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let state = makeState(database)
        let repository = SessionRepository(database: database)
        let first = try repository.createSession(mode: .mock)
        let second = try repository.createSession(mode: .mock)
        try TranscriptRepository(database: database).saveSegment(.init(id: "first-source", sessionID: first.id, speaker: .unknown, text: "Synthetic first session."))
        try state.loadSessionDetails(sessionID: first.id)
        state.historicalSuggestionChunks = ["old-card": []]
        state.selectedSessionRecap = .init(id: "old-recap", sessionID: first.id, markdown: "Old synthetic recap.", modelName: "fixture", promptVersion: "fixture", createdAt: Date())

        try state.loadSessionDetails(sessionID: second.id)

        #expect(state.selectedSessionID == second.id)
        #expect(state.selectedSessionTranscript.isEmpty)
        #expect(state.selectedSessionSuggestions.isEmpty)
        #expect(state.selectedSessionRecap == nil)
        #expect(state.historicalSuggestionChunks.isEmpty)
    }

    @Test
    func failedRepositoryReadPreservesPreviousCompleteSelection() throws {
        let database = try AppDatabase(inMemory: true)
        let state = makeState(database)
        let session = try SessionRepository(database: database).createSession(mode: .mock)
        try TranscriptRepository(database: database).saveSegment(.init(id: "selected-source", sessionID: session.id, speaker: .unknown, text: "Synthetic retained record."))
        try state.loadSessionDetails(sessionID: session.id)
        try database.close()

        #expect(throws: (any Error).self) {
            try state.loadSessionDetails(sessionID: "unreadable-session")
        }
        #expect(state.selectedSessionID == session.id)
        #expect(state.selectedSessionTranscript.map(\.text) == ["Synthetic retained record."])
    }

    @Test
    func compatibilityWritesAndDirectObserversUseTheSameOwner() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        var changes = 0
        let observation = app.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        app.selectedSessionID = "legacy-selection"
        #expect(app.historyState.selectedSessionID == "legacy-selection")
        app.historyState.selectedSessionID = "feature-selection"
        #expect(app.selectedSessionID == "feature-selection")
        #expect(app.isGeneratingRecap == app.historyState.isGeneratingRecap)
        #expect(changes >= 2)

        var publishedSelections: [String?] = []
        let directObserver = app.historyState.$selectedSessionID.sink { publishedSelections.append($0) }
        defer { directObserver.cancel() }
        app.selectedSessionID = "current-selection"
        #expect(publishedSelections == ["feature-selection", "current-selection"])
    }

    @Test
    func deletingSelectedSessionClearsOwnerWithoutAHistoryViewMounted() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let repository = SessionRepository(database: database)
        let session = try repository.createSession(mode: .mock)
        try TranscriptRepository(database: database).saveSegment(.init(id: "deleted-source", sessionID: session.id, speaker: .unknown, text: "Synthetic deleted record."))
        let app = AppState(database: database)
        app.loadSessionDetails(sessionID: session.id)
        app.historyState.historicalSuggestionChunks = ["deleted-card": []]

        app.deleteSession(session)

        #expect(try repository.session(id: session.id) == nil)
        #expect(app.historyState.selectedSessionID == nil)
        #expect(app.historyState.selectedSessionTranscript.isEmpty)
        #expect(app.historyState.historicalSuggestionChunks.isEmpty)
        #expect(app.sessions.isEmpty)
    }

    private func makeState(_ database: AppDatabase) -> HistoryState {
        let router = LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [:])
        return HistoryState(sessions: SessionRepository(database: database), transcripts: TranscriptRepository(database: database),
            suggestions: SuggestionRepository(database: database), recaps: RecapRepository(database: database),
            corrections: HistoryCorrectionRepository(database: database), practice: PracticeRepository(database: database),
            recapService: RecapGenerationService(llmRouter: router), consent: PersistenceConsent())
    }
}
