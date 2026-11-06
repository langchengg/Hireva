import Foundation
import Combine
import SwiftUI

extension AppState {
    func saveDocument(type: DocumentType, title: String, content: String) {
        let actionID = ActionID.saveDocument(type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving \(type.title)", message: "Saving and rebuilding clean context chunks...")
        do {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 80 else {
                warnAction(actionID, title: "More text needed", message: "Paste at least 80 characters before saving \(type.title).")
                return
            }
            let saved = try documentsState.saveDocument(type: type, title: title, content: content)
            if saved.sanitizationWarnings?.isEmpty == false {
                warnAction(actionID, title: "Saved and cleaned", message: "LaTeX or formatting noise was cleaned for relevant context.")
            } else {
                let chunks = (try? documentRepository.chunks(type: type).count) ?? 0
                completeAction(actionID, title: "Saved and indexed", message: "\(type.title) saved. \(chunks) clean chunks are ready.")
            }
        } catch {
            let message = "Could not save \(type.title): \(error.localizedDescription)"
            failAction(actionID, title: "Save failed", message: message)
            showError(message)
        }
    }

    func deleteDocument(_ document: DocumentRecord) {
        persistenceConsent.invalidate()
        cancelMaterialImport()
        practiceController.cancel()
        let actionID = ActionID.clearDocument(document.type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Clearing \(document.type.title)", message: "Removing the saved document and refreshing context status...")
        interviewContextState.invalidateBuild()
        liveRAGPrefetch.cancelAndClear()
        cancelActiveGenerationForContextChange()
        AutomaticInterviewContextBuilder.clearExtractionCache()
        do {
            try documentsState.deleteDocument(document)
            if let id = practiceController.run?.sessionID { practiceController.restore(sessionID: id) }
            practiceController.refreshReviews()
            if let id = selectedSessionID { loadSessionDetails(sessionID: id) }
            refreshAll()
            scheduleAutomaticContextRebuild()
            completeAction(actionID, title: "Document cleared", message: "\(document.type.title) was removed.")
        } catch {
            let message = "Could not delete document: \(error.localizedDescription)"
            failAction(actionID, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func cancelMaterialImport() { documentsState.cancelImport() }
    func closeMaterialImportAdmission() { documentsState.closeImportAdmission() }
    func shutdownMaterialImports() async { await documentsState.shutdown() }

    // Compatibility actions retain global feedback/context coordination;
    // DocumentsState is the only document/import authority.
    func importPlainTextDocument(from url: URL, as type: DocumentType) {
        documentsState.importDocument(from: url, as: type)
    }

    func reprocessDocument(_ document: DocumentRecord) {
        documentsState.reprocessDocument(document)
    }
}
