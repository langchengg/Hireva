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
            recapTask?.cancel()
            recapTask = nil
            recapSessionID = nil
            isGeneratingRecap = false
            clearActionFeedback(ActionID.sessionRecap)
        }
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
        persistenceConsent.invalidate()
        cancelMaterialImport()
        AutomaticInterviewContextBuilder.clearExtractionCache()
        guard !isActionLoading(ActionID.clearLocalData) else { return }
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
        guard settings.saveTranscriptsLocally, !primaryHomeActionShouldStop else {
            showError("Stop live capture and enable local history before generating a saved recap.")
            return
        }
        guard !isActionLoading(ActionID.sessionRecap) else { return }
        if let practice = try? PracticeRepository(database: database).load(sessionID: session.id) {
            let recap = RecapReport(id: "practice-recap-" + session.id, sessionID: session.id, markdown: RecapGenerationService.practiceMarkdown(practice), modelName: "Validated practice feedback", promptVersion: practice.task.rubricVersion, isLocal: true, createdAt: Date())
            do {
                try recapRepository.saveRecap(recap)
                selectedSessionRecap = recap
                completeAction(ActionID.sessionRecap, title: "Recap ready", message: "All attempts included with source quotes and coverage.")
            } catch { showError(error.localizedDescription) }
            return
        }
        beginAction(ActionID.sessionRecap, title: "Generating recap", message: "Processing all saved text units; unknown speakers are not graded...")
        isGeneratingRecap = true
        recapTask?.cancel()
        recapSessionID = session.id
        let consentTicket = persistenceConsent.ticket()
        recapTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, self.recapSessionID == session.id {
                    self.recapTask = nil
                    self.recapSessionID = nil
                    self.isGeneratingRecap = false
                }
            }
            do {
                let transcript = try transcriptRepository.segments(sessionID: session.id)
                let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [])
                let result = try await recapGenerationService.generate(
                    session: session,
                    transcript: transcript,
                    context: context,
                    questions: try suggestionRepository.questions(sessionID: session.id),
                    model: activeRecapProvider?.model
                )
                guard !Task.isCancelled else { return }
                guard settings.saveTranscriptsLocally, try sessionRepository.session(id: session.id) != nil else { return }
                try persistenceConsent.write(ticket: consentTicket) { try recapRepository.saveRecap(result.recap) }
                if selectedSessionID == session.id { selectedSessionRecap = result.recap }
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
                struct Export: Encodable { var session: InterviewSession; var transcript: [TranscriptSegment]; var recap: RecapReport? }
                try encoder.encode(Export(session: session, transcript: transcriptRepository.segments(sessionID: session.id), recap: recapRepository.recap(sessionID: session.id))).write(to: url, options: .atomic)
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
