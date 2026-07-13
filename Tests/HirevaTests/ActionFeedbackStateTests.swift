import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct ActionFeedbackStateTests {
    @Test
    func actionFeedbackLifecycleSetsLoadingAndTerminalStates() throws {
        let appState = try makeAppState()

        appState.beginAction(ActionID.startInterview, title: "Starting audio", message: "Starting capture...")

        #expect(appState.isActionLoading(ActionID.startInterview))
        #expect(appState.latestActionFeedback(for: ActionID.startInterview)?.kind == .loading)
        #expect(appState.activeActionFeedbacks.filter { $0.actionID == ActionID.startInterview }.count == 1)

        appState.completeAction(ActionID.startInterview, title: "Listening started", message: "System capture is active.", autoDismissAfter: nil)

        #expect(!appState.isActionLoading(ActionID.startInterview))
        #expect(appState.latestActionFeedback(for: ActionID.startInterview)?.kind == .success)

        appState.failAction(ActionID.startInterview, title: "Could not start", message: "Check permissions.", autoDismissAfter: nil)

        #expect(!appState.isActionLoading(ActionID.startInterview))
        #expect(appState.latestActionFeedback(for: ActionID.startInterview)?.kind == .error)
        #expect(appState.diagnostics.lastError == "Check permissions.")
    }

    @Test
    func duplicateActionGuardLeavesExistingLoadingFeedbackUntouched() throws {
        let appState = try makeAppState()
        let actionID = ActionID.saveDocument(.cv)

        appState.beginAction(actionID, title: "Saving CV / Resume", message: "First click is in progress.")
        appState.saveDocument(type: .cv, title: "CV / Resume", content: "too short")

        let feedback = try #require(appState.latestActionFeedback(for: actionID))
        #expect(appState.isActionLoading(actionID))
        #expect(feedback.kind == .loading)
        #expect(feedback.message == "First click is in progress.")
        #expect(appState.activeActionFeedbacks.filter { $0.actionID == actionID }.count == 1)
    }

    @Test
    func saveKeyFeedbackDoesNotExposeRawKey() throws {
        let appState = try makeAppState()
        let rawKey = "sk-test-raw-secret-987654"

        appState.saveAPIKey(rawKey)

        let feedback = try #require(appState.latestActionFeedback(for: ActionID.providerSaveKey))
        #expect(feedback.kind == .success)
        #expect(!feedback.title.contains(rawKey))
        #expect(!feedback.message.contains(rawKey))
        #expect(!(appState.connectionResult ?? "").contains(rawKey))
        #expect(appState.keychainMaskedKey != rawKey)
        #expect(appState.keychainMaskedKey.hasSuffix("7654"))
    }

    @Test
    func saveDocumentReportsShortInputAndRAGRebuildProgress() async throws {
        let appState = try makeAppState()

        appState.saveDocument(type: .cv, title: "CV / Resume", content: "short")
        let shortFeedback = try #require(appState.latestActionFeedback(for: ActionID.saveDocument(.cv)))
        #expect(shortFeedback.kind == .warning)
        #expect(!appState.isActionLoading(ActionID.saveDocument(.cv)))

        _ = try appState.documentRepository.saveDocument(
            type: .cv,
            title: "CV / Resume",
            content: longText("\\documentclass{resume}\\begin{document} Built a macOS interview assistant with audio capture, speech recognition, and careful product polish.\\end{document}")
        )
        _ = try appState.documentRepository.saveDocument(
            type: .jobDescription,
            title: "Job Description",
            content: longText("The role needs product-minded macOS engineering, SwiftUI design, reliable audio capture, and pragmatic debugging during interviews.")
        )
        appState.refreshAll()

        appState.rebuildCleanRAGIndex()

        #expect(appState.isActionLoading(ActionID.rebuildCleanRAG))
        let completed = await waitForActionToFinish(appState, actionID: ActionID.rebuildCleanRAG)
        #expect(completed)

        let rebuildFeedback = try #require(appState.latestActionFeedback(for: ActionID.rebuildCleanRAG))
        #expect(rebuildFeedback.kind == .success || rebuildFeedback.kind == .warning)
        #expect(rebuildFeedback.message.contains("clean chunks"))
        #expect(try appState.documentRepository.latexPollutedChunkCount() == 0)
    }

    @Test
    func floatingCopyFeedbackUsesLocalSuccessState() throws {
        let appState = try makeAppState()

        appState.beginAction(ActionID.floatingCopy, title: "Copying answer", message: "Copying to clipboard...")
        appState.completeAction(ActionID.floatingCopy, title: "Copied", message: "Answer copied to clipboard.", autoDismissAfter: nil)

        let feedback = try #require(appState.latestActionFeedback(for: ActionID.floatingCopy))
        #expect(!appState.isActionLoading(ActionID.floatingCopy))
        #expect(feedback.kind == .success)
        #expect(feedback.title == "Copied")
    }

    @Test
    func readinessActionsHaveStableFeedbackIDs() {
        for action in ReadinessAction.allCases {
            #expect(ActionID.readiness(action).contains(action.rawValue))
        }
    }

    @Test
    func clearLocalDataFeedbackDoesNotExposeRawKey() throws {
        let appState = try makeAppState()
        let rawKey = "sk-clear-local-secret-4321"
        appState.saveAPIKey(rawKey)

        appState.deleteAllLocalData(includeAPIKey: false)

        let feedback = try #require(appState.latestActionFeedback(for: ActionID.clearLocalData))
        #expect(feedback.kind == .success)
        #expect(!feedback.title.contains(rawKey))
        #expect(!feedback.message.contains(rawKey))
        #expect(appState.keychainDeepSeekKeyExists)
    }

    private func makeAppState() throws -> AppState {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ActionFeedbackState")
        let settingsRepository = SettingsRepository(database: database)
        let keychainStore = InMemoryMockKeychainStore()
        let keychainService = KeychainService(store: keychainStore)
        let router = LLMRouter(settingsRepository: settingsRepository, apiKeyStore: keychainService)
        return AppState(database: database, llmRouter: router, keychainService: keychainService)
    }

    private func waitForActionToFinish(_ appState: AppState, actionID: String) async -> Bool {
        for _ in 0..<100 {
            if !appState.isActionLoading(actionID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func longText(_ seed: String) -> String {
        Array(repeating: seed, count: 10).joined(separator: " ")
    }
}
