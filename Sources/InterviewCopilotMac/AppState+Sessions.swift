import Foundation
import Combine
import SwiftUI
import AppKit

extension AppState {
    func loadSessionDetails(sessionID: String) {
        selectedSessionID = sessionID
        do {
            selectedSessionTranscript = try transcriptRepository.segments(sessionID: sessionID)
            selectedSessionSuggestions = try suggestionRepository.suggestions(sessionID: sessionID)
            selectedSessionRecap = try recapRepository.recap(sessionID: sessionID)
            
            var chunksDict: [String: [RetrievedChunk]] = [:]
            for card in selectedSessionSuggestions {
                chunksDict[card.id] = (try? suggestionRepository.retrievedChunks(suggestionCardID: card.id)) ?? []
            }
            historicalSuggestionChunks = chunksDict
        } catch {
            showError("Could not load session: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ session: InterviewSession) {
        guard !isActionLoading(ActionID.sessionDelete) else { return }
        beginAction(ActionID.sessionDelete, title: "Deleting session", message: "Removing \(session.title)...")
        do {
            try sessionRepository.deleteSession(id: session.id)
            if selectedSessionID == session.id {
                selectedSessionID = nil
                selectedSessionTranscript = []
                selectedSessionSuggestions = []
                selectedSessionRecap = nil
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
        guard !isActionLoading(ActionID.clearLocalData) else { return }
        beginAction(ActionID.clearLocalData, title: "Clearing local data", message: "Stopping capture and deleting local app data...")
        stopListening()
        do {
            if includeAPIKey {
                for account in providerConfigurations.compactMap(\.apiKeyAccount) {
                    try? keychainService.deleteAPIKey(account: account)
                }
            }
            try localDataService.deleteAllLocalData(includeAPIKey: includeAPIKey)
            clearLiveSession()
            refreshAll()
            completeAction(ActionID.clearLocalData, title: "Local data cleared", message: includeAPIKey ? "Documents, sessions, transcripts, and saved keys were cleared." : "Documents, sessions, and transcripts were cleared.")
        } catch {
            let message = "Could not delete local data: \(error.localizedDescription)"
            failAction(ActionID.clearLocalData, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func generateRecap(for session: InterviewSession) {
        guard !isActionLoading(ActionID.sessionRecap) else { return }
        beginAction(ActionID.sessionRecap, title: "Generating recap", message: "Summarizing transcript and relevant context...")
        isGeneratingRecap = true
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try transcriptRepository.segments(sessionID: session.id)
                let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                    question: transcript.map(\.text).joined(separator: "\n"),
                    intent: .unclear,
                    maxCVWords: 1_500,
                    maxJDWords: 1_000
                )
                self.lastRetrievalTrace = trace
                let result = try await recapGenerationService.generate(
                    session: session,
                    transcript: transcript,
                    context: context,
                    model: activeRecapProvider?.model
                )
                guard !Task.isCancelled else { return }
                try recapRepository.saveRecap(result.recap)
                selectedSessionRecap = result.recap
                updateDiagnostics {
                    $0.lastAPILatencyMS = result.response.latencyMS
                    $0.apiCallCount += 1
                }
                completeAction(ActionID.sessionRecap, title: "Recap ready", message: "Session recap is visible.")
            } catch {
                guard !Task.isCancelled else { return }
                let message = userFacing(error)
                failAction(ActionID.sessionRecap, title: "Recap failed", message: message)
                showError(message)
            }
            isGeneratingRecap = false
        }
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
