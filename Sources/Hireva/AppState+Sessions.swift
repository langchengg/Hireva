import Foundation
import Combine
import SwiftUI
import AppKit

extension AppState {
    func loadSessionDetails(sessionID: String) {
        do {
            try historyState.loadSessionDetails(sessionID: sessionID)
        } catch {
            showError("Could not load session: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ session: InterviewSession) {
        guard currentSession?.id != session.id || !primaryHomeActionShouldStop else {
            showError("Stop this live session before deleting it.")
            return
        }
        persistenceConsent.invalidate()
        guard !isActionLoading(ActionID.sessionDelete) else { return }
        beginAction(ActionID.sessionDelete, title: "Deleting session", message: "Removing \(session.title)...")
        if practiceController.run?.sessionID == session.id {
            practiceController.cancel()
            practiceController.run = nil
        }
        practiceController.reviews.removeAll { $0.sessionID == session.id }
        if recapSessionID == session.id {
            historyState.cancelRecap(sessionID: session.id)
            clearActionFeedback(ActionID.sessionRecap)
        }
        do {
            try sessionRepository.deleteSession(id: session.id)
            if currentSession?.id == session.id {
                // A Manual entry can still be publishing before activation;
                // successful deletion revokes its existing request authority.
                // Historical deletion never cancels an unrelated live request.
                cancelActiveGenerationForContextChange()
                if currentSession?.id == session.id {
                    currentSession = nil
                    if currentSession == nil { activeContextSnapshot = nil }
                }
            }
            if selectedSessionID == session.id {
                historyState.clearSelection()
            }
            refreshAll()
            completeAction(ActionID.sessionDelete, title: "Session deleted", message: "\(session.title) was removed.")
        } catch {
            let message = "Could not delete session: \(error.localizedDescription)"
            failAction(ActionID.sessionDelete, title: "Delete failed", message: message)
            showError(message)
        }
    }

    func deleteAllLocalData(includeAPIKey: Bool) {
        persistenceConsent.invalidate()
        cancelMaterialImport()
        AutomaticInterviewContextBuilder.clearExtractionCache()
        guard !isActionLoading(ActionID.clearLocalData) else { return }
        documentsState.embeddings.allSourcesWillChange()
        beginAction(ActionID.clearLocalData, title: "Clearing local data", message: "Stopping capture and deleting local app data...")
        pausePreparationForLive()
        practiceController.cancel()
        practiceController.run = nil
        practiceController.reviews = []
        practiceController.error = nil
        automaticContextBuildResult = nil
        automaticContextReadiness = .noDocuments
        activeCandidateProfileID = nil
        activeOpportunityContextID = nil
        activeContextSnapshot = nil
        stopListening()
        do {
            if includeAPIKey {
                for account in providerConfigurations.compactMap(\.apiKeyAccount) {
                    try? keychainService.deleteAPIKey(account: account)
                }
            }
            try localDataService.deleteAllLocalData(includeAPIKey: includeAPIKey)
            try clearRuntimeTranscriptTrace()
            clearLiveSession()
            refreshAll()
            completeAction(ActionID.clearLocalData, title: "Local data cleared", message: includeAPIKey ? "Documents, sessions, transcripts, diagnostic traces, and saved keys were cleared." : "Documents, sessions, transcripts, and diagnostic traces were cleared.")
        } catch {
            let message = "Could not delete local data: \(error.localizedDescription)"
            failAction(ActionID.clearLocalData, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func generateRecap(for session: InterviewSession) {
        guard let session = try? sessionRepository.session(id: session.id) else { return }
        guard settings.saveTranscriptsLocally, !primaryHomeActionShouldStop else {
            showError("Stop live capture and enable local history before generating a saved recap.")
            return
        }
        guard !isActionLoading(ActionID.sessionRecap) else { return }
        // The selected mode is policy. Inputs and the provider configuration
        // are submitted now; the feature owner never rereads AppState later.
        let localOnly = selectedAnswerProviderMode == .localQwenPrimary
        let configuration = localOnly ? activeRecapProvider : (try? llmRouter.recapConfiguration())
        let provider = localLLMProviderOverride ?? OllamaQwenProvider()
        let model = selectedQwenModelName
        let settingsOwner = settingsState
        do {
            try historyState.requestRecap(sessionID: session.id, providerConfiguration: configuration,
                routingProvider: provider, routingModel: model, localOnly: localOnly,
                persistenceAllowed: { [weak settingsOwner] in settingsOwner?.settings.saveTranscriptsLocally ?? false },
                onFeedback: { [weak self] feedback in
                    guard let self else { return }
                    self.publishActionFeedback(feedback)
                },
                onError: { [weak self] message in self?.showError(message) },
                didPublish: { [weak self] response in
                    self?.updateDiagnostics {
                        $0.lastAPILatencyMS = response.latencyMS
                        $0.apiCallCount += 1
                    }
                })
        } catch {
            let message = userFacing(error)
            failAction(ActionID.sessionRecap, title: "Recap failed", message: message)
            showError(message)
        }
    }

    func correctPracticeAttempt(sessionID: String, attemptID: String, question: String, answer: String) {
        guard settings.saveTranscriptsLocally, !primaryHomeActionShouldStop else { return }
        persistenceConsent.invalidate()
        if practiceController.run?.sessionID == sessionID { practiceController.pause() }
        historyState.cancelRecap()
        clearActionFeedback(ActionID.sessionRecap)
        do {
            try PracticeRepository(database: database).correctAttempt(sessionID: sessionID, attemptID: attemptID, question: question, answer: answer)
            if practiceController.run?.sessionID == sessionID { practiceController.restore(sessionID: sessionID) }
            practiceController.refreshReviews()
            refreshAll(); loadSessionDetails(sessionID: sessionID)
        } catch { showError(error.localizedDescription) }
    }

    func saveTranscriptCorrection(_ segment: TranscriptSegment, text: String, speaker: SpeakerRole, startsQuestion: Bool, question: String) {
        guard settings.saveTranscriptsLocally, !primaryHomeActionShouldStop else { showError("Stop capture and enable history before correcting saved text."); return }
        persistenceConsent.invalidate()
        historyState.cancelRecap()
        clearActionFeedback(ActionID.sessionRecap)
        do {
            try HistoryCorrectionRepository(database: database).save(segment: segment, text: text, speaker: speaker, startsQuestion: startsQuestion, question: question)
            refreshAll(); loadSessionDetails(sessionID: segment.sessionID)
        } catch { showError(error.localizedDescription) }
    }

    func exportSelectedRecap() {
        guard let recap = selectedSessionRecap,
              let session = sessions.first(where: { $0.id == recap.sessionID }) else {
            warnAction(ActionID.sessionExport, title: "Nothing to export", message: "Generate a recap before exporting.")
            return
        }
        guard !isActionLoading(ActionID.sessionExport) else { return }
        beginAction(ActionID.sessionExport, title: "Exporting recap", message: "Writing Markdown file...")
        do {
            let url = try recapRepository.exportMarkdown(recap: recap, sessionTitle: session.title)
            connectionResult = "Exported recap to \(url.path)."
            completeAction(ActionID.sessionExport, title: "Recap exported", message: url.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let message = "Could not export recap: \(error.localizedDescription)"
            failAction(ActionID.sessionExport, title: "Export failed", message: message)
            showError(message)
        }
    }

    func exportSessionJSON(_ session: InterviewSession) {
        guard !isActionLoading(ActionID.sessionExport) else { return }
        beginAction(ActionID.sessionExport, title: "Exporting session", message: "Writing JSON to local Exports…")
        do {
            // Reuse the existing Markdown export location and reveal workflow.
            // A fresh filename avoids replacing a previous user export.
            try AppPaths.ensureDirectoriesExist()
            let url = AppPaths.exportsDirectory.appendingPathComponent("hireva-session-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let practice = try PracticeRepository(database: database).load(sessionID: session.id) {
                try encoder.encode(practice).write(to: url, options: .atomic)
            } else {
                struct Export: Encodable {
                    var session: InterviewSession
                    var originalTranscript: [TranscriptSegment]
                    var effectiveTranscript: [TranscriptSegment]
                    var corrections: [HistoryCorrection]
                    var recaps: [RecapReport]
                }
                let original = try transcriptRepository.segments(sessionID: session.id)
                let corrections = HistoryCorrectionRepository(database: database)
                try encoder.encode(Export(session: session, originalTranscript: original,
                    effectiveTranscript: corrections.effectiveTranscript(original, sessionID: session.id),
                    corrections: corrections.revisions(sessionID: session.id),
                    recaps: recapRepository.versions(sessionID: session.id))).write(to: url, options: .atomic)
            }
            completeAction(ActionID.sessionExport, title: "Session exported", message: url.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            failAction(ActionID.sessionExport, title: "Export failed", message: error.localizedDescription)
            showError(error.localizedDescription)
        }
    }

    func selectSection(_ section: AppSection) {
        selectedSection = section
    }

    func showFloatingAssistant() {
        beginAction(ActionID.showFloatingPanel, title: "Opening floating panel", message: "Bringing the answer card to the front...")
        FloatingAssistantPanelController.shared.show(appState: self)
        isFloatingAssistantVisible = true
        completeAction(ActionID.showFloatingPanel, title: "Floating panel visible", message: "The answer card is ready.")
    }

    func hideFloatingAssistant() {
        FloatingAssistantPanelController.shared.hide()
        isFloatingAssistantVisible = false
        infoAction(ActionID.showFloatingPanel, title: "Floating panel hidden", message: "Use Show Floating Panel to bring it back.")
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func showError(_ message: String) {
        errorMessage = message
        updateDiagnostics { $0.lastError = message }
    }

    func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
