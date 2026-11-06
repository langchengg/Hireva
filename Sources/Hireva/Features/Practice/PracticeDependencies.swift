import Foundation

/// Practice receives only the repositories and application policies it uses.
/// Configuration closures are read at operation boundaries; async evaluation
/// keeps the resulting provider, model and source evidence frozen.
@MainActor
struct PracticeDependencies {
    struct Context {
        let historyEnabled: Bool
        let selection: InterviewContextSelection
        let temporarySnapshotID: String?
        let requiresOnDeviceRecognition: Bool

        init(historyEnabled: Bool, selection: InterviewContextSelection,
            temporarySnapshotID: String?, requiresOnDeviceRecognition: Bool = false) {
            self.historyEnabled = historyEnabled
            self.selection = selection
            self.temporarySnapshotID = temporarySnapshotID
            self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        }
    }

    let repository: PracticeRepository
    let sessions: SessionRepository
    let questions: SuggestionRepository
    let contexts: InterviewContextRepository
    let persistenceConsent: PersistenceConsent
    let context: () throws -> Context
    let evaluationConfiguration: () throws -> (provider: any LocalLLMProvider, model: String)
    let selectedASRProvider: () -> ASRProviderID
    let isLiveCaptureActive: () -> Bool
    let prepareForPractice: () -> Void
    let requestAudioPermissions: (ASRProviderID) async throws -> Void
    let makeAudioProvider: (ASRProviderID) throws -> any ASRProvider
    let historyDidChange: (String?) -> Void
    let delayProvider: any DelayProvider
}
