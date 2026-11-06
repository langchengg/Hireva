import Foundation
import Combine

/// Owns document projections and every import worker through actual exit.
/// Application coordination arrives as two narrow, synchronous callbacks.
@MainActor
final class DocumentsState: ObservableObject {
    typealias URLExtraction = (URL) async throws -> (ExtractedMaterial, Data)
    typealias DataExtraction = (Data, String) async throws -> ExtractedMaterial
    enum SaveOrigin { case typed, fileImport, reprocess, cleanIndex }
    let embeddings: DocumentEmbeddingState

    enum Update { case documents, importStatus }
    // Combine's default nonisolated witness uses this notification-only storage.
    // The Void pulse owns no business fact; publish runs after facts are committed.
    @Published private var observationPulse: Void = ()
    private let notifications = PassthroughSubject<Update, Never>()
    var updates: AnyPublisher<Update, Never> { notifications.eraseToAnyPublisher() }
    // Synchronous callbacks read committed owner facts, never a willSet value.
    private(set) var documents: [DocumentRecord] = [] { didSet { publish(.documents) } }
    private(set) var importStatus = "" { didSet { publish(.importStatus) } }
    private func publish(_ update: Update) {
        observationPulse = ()
        notifications.send(update)
    }
    private(set) var importID = UUID()
    private(set) var importTask: Task<Void, Never>?
    private var retiringImports: [UUID: Task<Void, Never>] = [:]
    private var admissionClosed = false
    private let repository: DocumentRepository
    private let extractURL: URLExtraction
    private let extractData: DataExtraction
    private let willSave: (SaveOrigin) -> Void
    private let didSave: (DocumentRecord, SaveOrigin) throws -> Void

    init(repository: DocumentRepository,
         extractURL: @escaping URLExtraction = { try await MaterialExtractionService.extractCancellable(url: $0) },
         extractData: @escaping DataExtraction = { try await MaterialExtractionService.extractCancellable(data: $0, filename: $1) },
         willSave: @escaping (SaveOrigin) -> Void = { _ in },
         didSave: @escaping (DocumentRecord, SaveOrigin) throws -> Void = { _, _ in },
         embeddings: DocumentEmbeddingState? = nil) {
        self.repository = repository
        self.embeddings = embeddings ?? DocumentEmbeddingState(repository: repository)
        self.extractURL = extractURL
        self.extractData = extractData
        self.willSave = willSave
        self.didSave = didSave
    }

    deinit {
        importTask?.cancel()
        retiringImports.values.forEach { $0.cancel() }
    }

    var hasCV: Bool { hasMeaningfulDocument(.cv) }
    var hasJD: Bool { hasMeaningfulDocument(.jobDescription) }
    var pendingImportTaskCount: Int { retiringImports.count + (importTask == nil ? 0 : 1) }
    var retiringImportTaskCount: Int { retiringImports.count }

    func reload() throws {
        documents = try repository.documents()
        try embeddings.reloadCoverage()
    }
    func source(documentID: String) throws -> (material: ExtractedMaterial, data: Data)? {
        try repository.source(documentID: documentID)
    }
    func chunkCount(type: DocumentType) -> Int { (try? repository.chunks(type: type).count) ?? 0 }

    @discardableResult
    func saveDocument(type: DocumentType, title: String, content: String) throws -> DocumentRecord {
        guard !admissionClosed else { throw CancellationError() }
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 else {
            throw MaterialError.invalid("Paste at least 80 characters before saving \(type.title).")
        }
        if importTask != nil { cancelImport() }
        sourceWillChange(type: type, origin: .typed)
        guard !admissionClosed else { throw CancellationError() }
        let saved = try repository.saveDocument(type: type, title: title, content: content)
        // Freeze the stored representation, including SQLite's timestamp coding.
        // A notification can synchronously save a newer revision while reload runs.
        let storedVersion = try repository.document(type: type)
        try reload()
        guard !admissionClosed, try repository.document(type: type) == storedVersion else { return saved }
        try didSave(saved, .typed)
        return saved
    }

    func deleteDocument(_ document: DocumentRecord) throws {
        guard !admissionClosed else { throw CancellationError() }
        cancelImport()
        embeddings.sourceWillChange(documentID: document.id)
        guard !admissionClosed else { throw CancellationError() }
        try repository.deleteDocument(id: document.id)
        try reload()
    }

    func cancelImport() {
        let id = UUID()
        retireImport(nextID: id)
        guard importID == id else { return }
        importStatus = "Import cancelled" // Last effect; a newer submission owns later status.
    }

    private func retireImport(nextID: UUID) {
        let retiredID = importID, captured = importTask
        importID = nextID // Invalidate the old request before its cancellation callbacks.
        importTask = nil // A callback cannot have its newer registration erased.
        if let captured {
            retiringImports[retiredID] = captured
            captured.cancel()
        }
    }

    func closeImportAdmission() {
        admissionClosed = true
        cancelImport()
    }

    func closeAdmission() {
        closeImportAdmission()
        embeddings.closeAdmission()
    }

    @discardableResult
    func rebuildCleanIndex() -> Task<Void, Never>? {
        embeddings.rebuildCleanIndex(willChangeSources: { [willSave] in willSave(.cleanIndex) })
    }

    /// Publication is invalidated synchronously; cancellation alone does not
    /// establish that the native extractor has released its resources.
    func shutdown() async {
        closeAdmission()
        let pending = Array(retiringImports.values)
        for task in pending { await task.value }
        await embeddings.shutdown()
    }

    func importDocument(from url: URL, as type: DocumentType) {
        guard !admissionClosed else { return }
        let id = UUID() // Freeze this submission before any synchronous notification.
        retireImport(nextID: id)
        guard acceptsImport(id) else { return }
        importStatus = "Import cancelled"
        guard acceptsImport(id) else { return }
        importStatus = "Extracting locally…"
        guard acceptsImport(id) else { return }
        let extract = extractURL
        importTask = Task { [weak self] in
            defer { self?.importDidExit(id: id) }
            do {
                guard self?.acceptsImport(id) == true else { return }
                let (material, data) = try await extract(url)
                guard let self, !Task.isCancelled, self.importID == id, !self.admissionClosed else { return }
                self.sourceWillChange(type: type, origin: .fileImport)
                guard self.acceptsImport(id) else { return }
                let saved = try self.repository.saveDocument(type: type,
                    title: url.deletingPathExtension().lastPathComponent,
                    content: material.text, material: material, originalData: data)
                try self.reload()
                guard self.acceptsImport(id) else { return }
                try self.didSave(saved, .fileImport)
                guard self.acceptsImport(id) else { return }
                self.importStatus = "Imported and indexed \(material.sections.count) source locations. " + material.warnings.joined(separator: " ")
            } catch {
                guard let self, !Task.isCancelled, self.importID == id, !self.admissionClosed else { return }
                self.importStatus = "Import failed: \(error.localizedDescription). Select the file again to retry."
            }
        }
    }

    func reprocessDocument(_ document: DocumentRecord) {
        guard !admissionClosed, let source = try? repository.source(documentID: document.id) else { return }
        let id = UUID() // Freeze this submission before any synchronous notification.
        retireImport(nextID: id)
        guard acceptsImport(id) else { return }
        importStatus = "Import cancelled"
        guard acceptsImport(id) else { return }
        importStatus = "Reprocessing locally…"
        guard acceptsImport(id) else { return }
        let extract = extractData
        importTask = Task { [weak self] in
            defer { self?.importDidExit(id: id) }
            do {
                guard self?.acceptsImport(id) == true else { return }
                let material = try await extract(source.data, source.material.filename)
                guard let self, !Task.isCancelled, self.importID == id, !self.admissionClosed,
                      (try self.repository.source(documentID: document.id))?.material.sha256 == source.material.sha256 else { return }
                self.sourceWillChange(type: document.type, origin: .reprocess)
                guard self.acceptsImport(id),
                      (try self.repository.source(documentID: document.id))?.material.sha256 == source.material.sha256 else { return }
                let saved = try self.repository.saveDocument(type: document.type, title: document.title,
                    content: material.text, material: material, originalData: source.data)
                try self.reload()
                guard self.acceptsImport(id) else { return }
                try self.didSave(saved, .reprocess)
                guard self.acceptsImport(id) else { return }
                self.importStatus = "Reprocessed from saved original; review extraction before confirming facts."
            } catch {
                guard let self, !Task.isCancelled, self.importID == id, !self.admissionClosed else { return }
                self.importStatus = "Reprocessing failed: \(error.localizedDescription)"
            }
        }
    }

    private func sourceWillChange(type: DocumentType, origin: SaveOrigin) {
        if let document = try? repository.document(type: type) {
            embeddings.sourceWillChange(documentID: document.id)
        }
        guard !admissionClosed else { return }
        willSave(origin)
    }

    private func acceptsImport(_ id: UUID) -> Bool {
        // Before registration, admission is the new identity alone. A synchronous
        // callback may create it from the old, now-cancelled worker. Once registered,
        // cancellation belongs to that exact worker, never to its caller.
        !admissionClosed && importID == id && importTask?.isCancelled != true
    }

    private func importDidExit(id: UUID) {
        retiringImports.removeValue(forKey: id)
        if importID == id { importTask = nil }
    }

    private func hasMeaningfulDocument(_ type: DocumentType) -> Bool {
        (documents.first { $0.type == type }?.content.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) >= 80
    }
}
