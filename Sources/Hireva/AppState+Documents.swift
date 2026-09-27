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
            practiceController.cancel()
            cancelActiveGenerationForContextChange()
            precomputeDebounceTask?.cancel()
            precomputedRAGCache.removeAll()
            AutomaticInterviewContextBuilder.clearExtractionCache()
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
        persistenceConsent.invalidate()
        cancelMaterialImport()
        practiceController.cancel()
        let actionID = ActionID.clearDocument(document.type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Clearing \(document.type.title)", message: "Removing the saved document and refreshing context status...")
        automaticContextBuildTask?.cancel()
        automaticContextBuildID = UUID()
        precomputeDebounceTask?.cancel()
        precomputedRAGCache.removeAll()
        cancelActiveGenerationForContextChange()
        AutomaticInterviewContextBuilder.clearExtractionCache()
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

    func cancelMaterialImport() {
        materialImportID = UUID()
        materialImportTask?.cancel()
        materialImportTask = nil
        materialImportStatus = "Import cancelled"
    }

    // Compatibility entry point used by the existing native Documents importer.
    func importPlainTextDocument(from url: URL, as type: DocumentType) {
        cancelMaterialImport()
        let id = UUID()
        materialImportID = id
        materialImportStatus = "Extracting locally…"
        materialImportTask = Task { [weak self] in
            defer { if self?.materialImportID == id { self?.materialImportTask = nil } }
            do {
                let (material, data) = try await MaterialExtractionService.extractCancellable(url: url)
                guard let self, !Task.isCancelled, self.materialImportID == id else { return }
                _ = try self.documentRepository.saveDocument(type: type, title: url.deletingPathExtension().lastPathComponent, content: material.text, material: material, originalData: data)
                self.practiceController.cancel()
                self.cancelActiveGenerationForContextChange()
                self.precomputeDebounceTask?.cancel()
                self.precomputedRAGCache.removeAll()
                AutomaticInterviewContextBuilder.clearExtractionCache()
                self.refreshAll()
                self.scheduleAutomaticContextRebuild(useLocalQwen: false)
                self.materialImportStatus = "Imported and indexed \(material.sections.count) source locations. " + material.warnings.joined(separator: " ")
            } catch {
                guard let self, !Task.isCancelled, self.materialImportID == id else { return }
                self.materialImportStatus = "Import failed: \(error.localizedDescription). Select the file again to retry."
            }
        }
    }

    func reprocessDocument(_ document: DocumentRecord) {
        guard let source = try? documentRepository.source(documentID: document.id) else { return }
        cancelMaterialImport()
        let id = UUID(); materialImportID = id
        materialImportStatus = "Reprocessing locally…"
        materialImportTask = Task { [weak self] in
            defer { if self?.materialImportID == id { self?.materialImportTask = nil } }
            do {
                let material = try await MaterialExtractionService.extractCancellable(data: source.data, filename: source.material.filename)
                guard let self, !Task.isCancelled, self.materialImportID == id,
                      (try self.documentRepository.source(documentID: document.id))?.material.sha256 == source.material.sha256 else { return }
                self.practiceController.cancel()
                self.cancelActiveGenerationForContextChange()
                self.precomputeDebounceTask?.cancel()
                self.precomputedRAGCache.removeAll()
                AutomaticInterviewContextBuilder.clearExtractionCache()
                _ = try self.documentRepository.saveDocument(type: document.type, title: document.title, content: material.text, material: material, originalData: source.data)
                self.refreshAll()
                self.scheduleAutomaticContextRebuild(useLocalQwen: false)
                self.materialImportStatus = "Reprocessed from saved original; review extraction before confirming facts."
            } catch {
                guard let self, !Task.isCancelled, self.materialImportID == id else { return }
                self.materialImportStatus = "Reprocessing failed: \(error.localizedDescription)"
            }
        }
    }
}
