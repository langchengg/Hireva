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
            let saved = try documentRepository.saveDocument(type: type, title: title, content: content)
            if ProductionContextPolicy.isTestProcess {
                try ingestDocumentIntoActiveContext(saved)
            }
            refreshAll()
            scheduleAutomaticContextRebuild()
            triggerEmbeddingGeneration(for: type)
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
        let actionID = ActionID.clearDocument(document.type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Clearing \(document.type.title)", message: "Removing the saved document and refreshing context status...")
        do {
            try documentRepository.deleteDocument(id: document.id)
            refreshAll()
            scheduleAutomaticContextRebuild()
            completeAction(actionID, title: "Document cleared", message: "\(document.type.title) was removed.")
        } catch {
            let message = "Could not delete document: \(error.localizedDescription)"
            failAction(actionID, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func importPlainTextDocument(from url: URL, as type: DocumentType) {
        let allowedExtensions = ["txt", "md", "markdown"]
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            showError("Only plain-text and Markdown files are supported. Paste PDF or DOCX text into the editor.")
            return
        }
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                showError("The selected file is not UTF-8 plain text.")
                return
            }
            saveDocument(type: type, title: url.deletingPathExtension().lastPathComponent, content: content)
        } catch {
            showError("Could not read the selected document: \(error.localizedDescription)")
        }
    }
}
