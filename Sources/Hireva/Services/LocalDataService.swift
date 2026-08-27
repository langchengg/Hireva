import Foundation

final class LocalDataService {
    let documents: DocumentRepository
    let sessions: SessionRepository
    let transcripts: TranscriptRepository
    let suggestions: SuggestionRepository
    let recaps: RecapRepository
    private let keychainService: KeychainService?

    init(
        documents: DocumentRepository,
        sessions: SessionRepository,
        transcripts: TranscriptRepository,
        suggestions: SuggestionRepository,
        recaps: RecapRepository,
        keychainService: KeychainService? = nil
    ) {
        self.documents = documents
        self.sessions = sessions
        self.transcripts = transcripts
        self.suggestions = suggestions
        self.recaps = recaps
        self.keychainService = keychainService
    }

    func deleteAllLocalData(includeAPIKey: Bool) throws {
        try sessions.deleteAllSessions()
        try documents.deleteAllDocuments()
        if includeAPIKey {
            try keychainService?.deleteAPIKey()
        }
    }
}
