import Foundation
import Combine

/// Owns document index jobs through actual exit. Immutable requests are audit
/// snapshots, while job records are the only mutable publication authority.
@MainActor
final class DocumentEmbeddingState: ObservableObject {
    enum RebuildPhase: Equatable {
        case idle, running, cancelled
        case ready(Int)
        case partial(ready: Int, failed: Int, message: String)
        case failed(String)
    }
    enum Update { case phase, progress, coverage }
    // Combine's default nonisolated witness uses this notification-only storage.
    // The Void pulse owns no business fact; publish runs after facts are committed.
    @Published private var observationPulse: Void = ()
    private let notifications = PassthroughSubject<Update, Never>()
    var updates: AnyPublisher<Update, Never> { notifications.eraseToAnyPublisher() }
    // Store the fact before notifying synchronous observers. Notifications carry
    // only the changed field; an observer reads the current authoritative value.
    private(set) var phase: RebuildPhase = .idle { didSet { publish(.phase) } }
    private(set) var progress = 0.0 { didSet { publish(.progress) } }
    private(set) var coverage: EmbeddingCoverage? { didSet { publish(.coverage) } }
    private func publish(_ update: Update) {
        observationPulse = ()
        notifications.send(update)
    }

    private enum Kind: Equatable, Sendable {
        case automatic(String), rebuild, cleanIndex
        var usesProvider: Bool { self != .cleanIndex }
    }
    private struct Job: Sendable {
        let id: UUID
        let kind: Kind
        let configuration: AppSettings
        let configurationEpoch: UUID
        let documentIDs: Set<String>
        let task: Task<Void, Never>
        var current = true
    }
    private var jobs: [UUID: Job] = [:]
    private var configurationEpoch = UUID()
    private var admissionClosed = false
    private let repository: DocumentRepository
    private let configuration: () -> AppSettings
    private let resolveProvider: (AppSettings) -> (any EmbeddingProvider)?
    private let feedback: (ActionFeedback) -> Void
    private let changed: () -> Void
    private let showError: (String) -> Void

    init(repository: DocumentRepository,
         configuration: @escaping () -> AppSettings = { .default },
         resolveProvider: @escaping (AppSettings) -> (any EmbeddingProvider)? = { _ in nil },
         feedback: @escaping (ActionFeedback) -> Void = { _ in },
         changed: @escaping () -> Void = {},
         showError: @escaping (String) -> Void = { _ in }) {
        self.repository = repository
        self.configuration = configuration
        self.resolveProvider = resolveProvider
        self.feedback = feedback
        self.changed = changed
        self.showError = showError
    }

    // Cancellation is a final fallback. Application shutdown retains the owner
    // and joins the exact registered tasks; deinit cannot await resource exit.
    deinit { jobs.values.forEach { $0.task.cancel() } }

    var isRebuilding: Bool { phase == .running }
    var rebuildTask: Task<Void, Never>? {
        jobs.values.first { $0.current && $0.kind == .rebuild }?.task
    }
    var pendingTaskCount: Int { jobs.count }
    var activeTaskCount: Int { jobs.values.filter { $0.current }.count }
    var retiringTaskCount: Int { jobs.values.filter { !$0.current }.count }
    private var currentRebuildID: UUID? {
        jobs.values.first { $0.current && $0.kind == .rebuild }?.id
    }
    var statusText: String {
        switch phase {
        case .idle: return "Not rebuilt"
        case .running: return "Rebuilding embeddings…"
        case .cancelled: return "Embedding rebuild cancelled."
        case .ready: return "Embedding rebuild complete."
        case .partial(let ready, let failed, _): return "Partial embeddings: \(ready) ready, \(failed) failed."
        case .failed: return "Embedding rebuild failed."
        }
    }
    var lastError: String? {
        switch phase {
        case .failed(let message), .partial(_, _, let message): return message
        default: return nil
        }
    }

    func reloadCoverage() throws {
        let settings = configuration()
        coverage = try repository.embeddingCoverage(currentProvider: Self.providerID(for: settings),
            currentModel: settings.embeddingModelName)
    }

    /// Applied settings have one authority in SettingsState. Only their relevant
    /// intent revokes this owner's epoch; the stored request stays immutable.
    func configurationDidChange(previous: AppSettings, current: AppSettings) {
        guard !admissionClosed else { return }
        if !Self.sameProviderConfiguration(previous, current) {
            configurationEpoch = UUID()
            retire(where: { $0.kind.usesProvider })
        } else if previous.autoGenerateEmbeddingsOnDocumentSave && !current.autoGenerateEmbeddingsOnDocumentSave {
            retire { if case .automatic = $0.kind { return true }; return false }
        }
    }
    func credentialWillChange(account: String) {
        retire { $0.kind.usesProvider && $0.configuration.embeddingApiKeyAccount == account }
    }
    func sourceWillChange(documentID: String) {
        retire { $0.documentIDs.contains(documentID) }
    }
    func allSourcesWillChange() { retire { _ in true } }

    @discardableResult
    func generateAutomatically(type: DocumentType) -> Task<Void, Never>? {
        guard !admissionClosed else { return nil }
        let settings = configuration()
        guard settings.autoGenerateEmbeddingsOnDocumentSave,
              let provider = resolveProvider(settings) else { return nil }
        do {
            // Freeze before dimension discovery, which may itself make a request.
            let sources = try repository.embeddingSources(type: type)
            guard !sources.isEmpty else { return nil }
            let ids = Set(sources.map { $0.chunk.documentID })
            retire { $0.kind.usesProvider && !$0.documentIDs.isDisjoint(with: ids) }
            guard !admissionClosed else { return nil }
            return launch(kind: .automatic(type.rawValue), sources: sources, settings: settings, provider: provider)
        } catch {
            showError("Background embedding generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func rebuildAll() -> Task<Void, Never>? {
        guard !admissionClosed, !isRebuilding, rebuildTask == nil else { return nil }
        let settings = configuration()
        guard let provider = resolveProvider(settings) else {
            phase = .idle
            guard !admissionClosed else { return nil }
            progress = 1
            guard !admissionClosed else { return nil }
            try? reloadCoverage()
            guard !admissionClosed else { return nil }
            emit(.info, "Keyword search ready", "Embedding provider not configured; keyword context is ready.")
            return nil
        }
        do {
            let sources = try repository.embeddingSources()
            guard !sources.isEmpty else {
                phase = .idle
                guard !admissionClosed else { return nil }
                progress = 1
                guard !admissionClosed else { return nil }
                emit(.warning, "No chunks to embed", "Save documents or rebuild the clean context index first.")
                return nil
            }
            retire { $0.kind.usesProvider }
            guard !admissionClosed else { return nil }
            let task = launch(kind: .rebuild, sources: sources, settings: settings, provider: provider)
            guard let id = currentRebuildID else { return task }
            phase = .running
            guard accepts(id) else { return task }
            progress = 0
            guard accepts(id) else { return task }
            emit(.loading, "Rebuilding embeddings", "Preparing clean context chunks for cloud embeddings...")
            return task
        } catch {
            phase = .failed(error.localizedDescription)
            guard !admissionClosed else { return nil }
            emit(.error, "Embedding rebuild failed", error.localizedDescription)
            return nil
        }
    }

    func cancelRebuild() { retire { $0.kind == .rebuild } }

    /// The existing clean-index operation is a concrete document job too. It
    /// shares source invalidation and cannot run after the owner closes admission.
    @discardableResult
    func rebuildCleanIndex(willChangeSources: @escaping () -> Void) -> Task<Void, Never>? {
        guard !admissionClosed, !jobs.values.contains(where: { $0.current && $0.kind == .cleanIndex }) else { return nil }
        do {
            let ids = Set(try repository.documents().map(\.id))
            allSourcesWillChange()
            guard !admissionClosed else { return nil }
            let id = UUID(), settings = configuration()
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.didExit(id) }
                guard self.accepts(id) else { return }
                do {
                    willChangeSources()
                    guard self.accepts(id) else { return }
                    let result = try self.repository.rebuildCleanRAGIndex()
                    guard self.accepts(id) else { return }
                    try self.reloadCoverage()
                    guard self.accepts(id) else { return }
                    self.changed()
                    guard self.accepts(id) else { return }
                    if settings.enableVectorRAG {
                        self.emit(.success, "Clean index rebuilt", "\(result.chunksRebuilt) clean chunks ready. Updating embeddings next...", actionID: ActionID.rebuildCleanRAG)
                        guard self.accepts(id), self.configurationEpoch == self.jobs[id]?.configurationEpoch else { return }
                        self.rebuildAll()
                    } else {
                        let polluted = try self.repository.latexPollutedChunkCount()
                        self.emit(.success, "Clean index rebuilt", "\(result.chunksRebuilt) clean chunks ready. \(polluted) LaTeX warnings remain.", actionID: ActionID.rebuildCleanRAG)
                    }
                } catch {
                    guard self.accepts(id) else { return }
                    let message = "Failed to rebuild clean RAG index: \(error.localizedDescription)"
                    self.emit(.error, "Rebuild failed", "Existing index preserved. \(message)", actionID: ActionID.rebuildCleanRAG)
                    guard self.accepts(id) else { return }
                    self.showError(message)
                }
            }
            jobs[id] = Job(id: id, kind: .cleanIndex, configuration: settings,
                configurationEpoch: configurationEpoch, documentIDs: ids, task: task)
            emit(.loading, "Rebuilding clean index", "Sanitizing documents and rebuilding chunks...", actionID: ActionID.rebuildCleanRAG)
            return task
        } catch {
            emit(.error, "Rebuild failed", error.localizedDescription, actionID: ActionID.rebuildCleanRAG)
            return nil
        }
    }

    func closeAdmission() {
        admissionClosed = true
        configurationEpoch = UUID()
        allSourcesWillChange()
    }
    func shutdown() async {
        closeAdmission()
        // Closing admission prevents new registrations. Retired jobs stay in
        // the same registry until their real task defer removes the record.
        let pending = jobs.values.map(\.task)
        for task in pending { await task.value }
    }

    private func launch(kind: Kind, sources: [DocumentRepository.EmbeddingSource],
                        settings: AppSettings, provider: any EmbeddingProvider) -> Task<Void, Never> {
        let id = UUID(), epoch = configurationEpoch
        let providerID = provider.providerID, modelName = provider.modelName
        let repository = repository
        let task = Task { [weak self] in
            defer { self?.didExit(id) }
            guard self?.accepts(id) == true else { return }
            do {
                let dimension = try await provider.dimension
                guard self?.accepts(id) == true else { return }
                guard dimension > 0 else { throw EmbeddingProviderError.invalidEmbeddingResponse("Dimension must be positive.") }
                var ready = 0, failed = 0
                var failure = "Source changed before its embedding could be saved."
                for (index, source) in sources.enumerated() {
                    guard self?.accepts(id) == true else { return }
                    let chunk = source.chunk
                    let hash = repository.calculateContentHash(content: chunk.content, sectionTitle: chunk.sectionTitle,
                        provider: providerID, modelName: modelName, dimension: dimension)
                    do {
                        guard try repository.embeddingSourceIsCurrent(source) else {
                            failed += 1
                            guard self?.accepts(id) == true else { return }
                            if kind == .rebuild { self?.progress = Double(index + 1) / Double(sources.count) }
                            continue
                        }
                        if chunk.embeddingContentHash == hash && chunk.embedding != nil {
                            ready += 1
                        } else {
                            let vector = try await provider.embed(text: chunk.content)
                            guard self?.accepts(id) == true else { return }
                            guard vector.count == dimension else { throw EmbeddingProviderError.dimensionMismatch(expected: dimension, actual: vector.count) }
                            // No await separates identity validation from this
                            // transactional document/chunk/content-version test.
                            if try repository.updateChunkEmbeddingIfUnchanged(source: source, embedding: vector,
                                model: modelName, provider: providerID, dimension: dimension, contentHash: hash) {
                                ready += 1
                            } else { failed += 1 }
                        }
                    } catch {
                        guard self?.accepts(id) == true else { return }
                        failed += 1; failure = error.localizedDescription
                    }
                    guard self?.accepts(id) == true else { return }
                    if kind == .rebuild { self?.progress = Double(index + 1) / Double(sources.count) }
                }
                guard self?.accepts(id) == true else { return }
                try self?.reloadCoverage()
                guard self?.accepts(id) == true else { return }
                self?.changed()
                guard self?.accepts(id) == true else { return }
                if kind == .rebuild {
                    if failed == 0 {
                        self?.phase = .ready(ready)
                        guard self?.accepts(id) == true else { return }
                        self?.emit(.success, "Embeddings rebuilt", "\(sources.count) chunks checked for cloud embeddings.")
                    } else if ready > 0 {
                        self?.phase = .partial(ready: ready, failed: failed, message: failure)
                        guard self?.accepts(id) == true else { return }
                        self?.emit(.warning, "Embeddings partly rebuilt", "\(ready) chunks ready; \(failed) failed. Keyword context remains available.")
                    } else {
                        self?.phase = .failed(failure)
                        guard self?.accepts(id) == true else { return }
                        self?.emit(.error, "Embedding rebuild failed", "No embeddings were accepted. \(failure)")
                    }
                } else if failed > 0 {
                    self?.showError("Background embedding generation failed: \(failure)")
                }
            } catch {
                guard self?.accepts(id) == true else { return }
                if kind == .rebuild {
                    self?.phase = .failed(error.localizedDescription)
                    guard self?.accepts(id) == true else { return }
                    self?.emit(.error, "Embedding rebuild failed", "Failed to rebuild embeddings: \(error.localizedDescription)")
                } else { self?.showError("Background embedding generation failed: \(error.localizedDescription)") }
            }
        }
        jobs[id] = Job(id: id, kind: kind, configuration: settings, configurationEpoch: epoch,
            documentIDs: Set(sources.map { $0.chunk.documentID }), task: task)
        return task
    }

    private func accepts(_ id: UUID) -> Bool {
        // A synchronous observer can replace a cancelled job from that old task.
        // Admission belongs to the registered task, not its caller’s cancellation.
        guard !admissionClosed, let job = jobs[id], job.current, !job.task.isCancelled else { return false }
        return !job.kind.usesProvider || job.configurationEpoch == configurationEpoch
    }
    private func didExit(_ id: UUID) {
        let job = jobs.removeValue(forKey: id)
        // A returned internal Task handle may be cancelled by an explicit
        // caller. Its actual exit still clears this owner's loading phase.
        if job?.current == true, job?.kind == .rebuild, Task.isCancelled, phase == .running {
            phase = .cancelled
            if currentRebuildID == nil {
                emit(.warning, "Embedding rebuild cancelled", "Existing context remains available.")
            }
        }
    }
    private func retire(where matches: (Job) -> Bool) {
        let pending = jobs.values.filter { $0.current && matches($0) }
        // All identities become retired before Task.cancel invokes handlers or
        // feedback observers can start replacement work.
        for job in pending { jobs[job.id]?.current = false }
        if pending.contains(where: { $0.kind == .rebuild }) {
            phase = .cancelled
            if currentRebuildID == nil {
                emit(.warning, "Embedding rebuild cancelled", "Existing context remains available.")
            }
        }
        if pending.contains(where: { $0.kind == .cleanIndex }) {
            emit(.warning, "Clean index cancelled", "Existing context remains available.", actionID: ActionID.rebuildCleanRAG)
        }
        for job in pending { job.task.cancel() }
    }
    private func emit(_ kind: ActionFeedbackKind, _ title: String, _ message: String,
                      actionID: String = ActionID.rebuildEmbeddings) {
        feedback(ActionFeedback(actionID: actionID, title: title, message: message, kind: kind,
            autoDismissAfter: kind == .loading || kind == .error ? nil : (kind == .warning ? 6 : 4)))
    }
    nonisolated static func providerID(for settings: AppSettings) -> String {
        switch settings.embeddingProviderKind {
        case .openAICompatibleCloud: return "cloudOpenAICompatible"
        case .customCloud: return "cloudCustom"
        case .mock: return "controlled-mock"
        case .disabled: return "disabled"
        case .localOllama: return "legacyLocalProviderDisabled"
        }
    }
    nonisolated private static func sameProviderConfiguration(_ left: AppSettings, _ right: AppSettings) -> Bool {
        left.embeddingProviderKind == right.embeddingProviderKind && left.embeddingBaseURL == right.embeddingBaseURL &&
        left.embeddingModelName == right.embeddingModelName && left.embeddingApiKeyAccount == right.embeddingApiKeyAccount &&
        left.embeddingDimension == right.embeddingDimension && left.embeddingTimeoutSeconds == right.embeddingTimeoutSeconds &&
        left.enableVectorRAG == right.enableVectorRAG
    }
}
