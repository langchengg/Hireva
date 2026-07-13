import Foundation

final class LocalDataService {
    let documents: DocumentRepository
    let sessions: SessionRepository
    let transcripts: TranscriptRepository
    let suggestions: SuggestionRepository
    let recaps: RecapRepository
    let settings: SettingsRepository
    private let keychainService: KeychainService?

    init(
        documents: DocumentRepository,
        sessions: SessionRepository,
        transcripts: TranscriptRepository,
        suggestions: SuggestionRepository,
        recaps: RecapRepository,
        settings: SettingsRepository,
        keychainService: KeychainService? = nil
    ) {
        self.documents = documents
        self.sessions = sessions
        self.transcripts = transcripts
        self.suggestions = suggestions
        self.recaps = recaps
        self.settings = settings
        self.keychainService = keychainService
    }

    func deleteAllLocalData(includeAPIKey: Bool) throws {
        try sessions.deleteAllSessions()
        try documents.deleteAllDocuments()
        try settings.deleteAllSettings()
        if includeAPIKey {
            try keychainService?.deleteAPIKey()
        }
    }
}
