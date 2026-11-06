import Foundation
import Combine

/// Owns setup checks and model-operation tasks. A cancelled task remains in
/// its actual registry until exit; current lane IDs alone permit publication.
@MainActor
final class LocalModelsSetupViewModel: ObservableObject {
    @Published private(set) var transcriptionStatus: LocalModelStatus = .notInstalled
    @Published private(set) var transcriptionProgress: ModelDownloadProgress?
    @Published private(set) var qwenHealth = LocalLLMHealth(
        ollamaRunning: false, selectedModel: LocalModelDescriptor.defaultQwenLocalLLM.id,
        modelInstalled: false, providerSource: .ollamaQwen, lastError: nil)
    @Published private(set) var qwenProgress: ModelDownloadProgress?
    @Published private(set) var parakeetRuntimeAvailable = false
    @Published var lastError: String?

    struct RefreshSnapshot: Equatable, Sendable {
        let id: UUID
        let qwenModel: String
        let transcriptionStatus: LocalModelStatus
        let qwenHealth: LocalLLMHealth
        let runtimeAvailable: Bool
        fileprivate let transcriptionEpoch: UUID
        fileprivate let qwenEpoch: UUID
    }
    enum Operation: Equatable, Sendable {
        case downloadTranscription, deleteTranscription, pullQwen, installRecommended
    }
    private struct OwnedOperation {
        let id: UUID
        let operation: Operation
        let parentID: UUID?
        let qwenModel: String?
        let task: Task<Void, Never>
    }
    private struct RefreshOperation {
        let parentID: UUID?
        let task: Task<RefreshSnapshot?, Never>
    }

    let transcriptionModel: LocalModelDescriptor
    private let modelManager: any LocalModelManager
    private let qwenProvider: any LocalLLMProvider
    private let parakeetRuntimeClient: any ParakeetRuntimeClient
    private var latestRefreshID: UUID? { willSet { objectWillChange.send() } }
    private var transcriptionID: UUID? { willSet { objectWillChange.send() } }
    private var qwenID: UUID? { willSet { objectWillChange.send() } }
    private var installID: UUID? { willSet { objectWillChange.send() } }
    private var transcriptionEpoch = UUID()
    private var qwenEpoch = UUID()
    private var ownedOperations: [UUID: OwnedOperation] = [:] { willSet { objectWillChange.send() } }
    private var refreshOperations: [UUID: RefreshOperation] = [:] { willSet { objectWillChange.send() } }
    private var admissionClosed = false

    var isRefreshing: Bool { latestRefreshID.map { refreshOperations[$0] != nil } ?? false }
    var isDownloadingTranscription: Bool { transcriptionID.flatMap { ownedOperations[$0] }?.operation == .downloadTranscription }
    var isPullingQwen: Bool { qwenID.flatMap { ownedOperations[$0] } != nil }
    var isInstallingRecommended: Bool { installID.flatMap { ownedOperations[$0] } != nil }
    var pendingOperationTaskCount: Int { ownedOperations.count + refreshOperations.count }

    init(transcriptionModel: LocalModelDescriptor = .defaultParakeetASR,
         modelManager: any LocalModelManager = FileLocalModelManager(),
         qwenProvider: any LocalLLMProvider = OllamaQwenProvider(),
         parakeetRuntimeClient: (any ParakeetRuntimeClient)? = nil) {
        self.transcriptionModel = transcriptionModel
        self.modelManager = modelManager
        self.qwenProvider = qwenProvider
        self.parakeetRuntimeClient = parakeetRuntimeClient ?? ParakeetSidecarRuntimeClient()
    }
    deinit {
        ownedOperations.values.forEach { $0.task.cancel() }
        refreshOperations.values.forEach { $0.task.cancel() }
    }

    func operationTasks(for operation: Operation) -> [Task<Void, Never>] {
        ownedOperations.values.filter { $0.operation == operation }.map(\.task)
    }
    func waitForPendingOperations() async {
        while !ownedOperations.isEmpty || !refreshOperations.isEmpty {
            let operations = ownedOperations.values.map(\.task)
            let checks = refreshOperations.values.map(\.task)
            for task in operations { await task.value }
            for task in checks { _ = await task.value }
        }
    }
    func closeAdmission() {
        guard !admissionClosed else { return }
        admissionClosed = true
        // Revoke every current identity before cooperative cancellation.
        latestRefreshID = nil; transcriptionID = nil; qwenID = nil; installID = nil
        transcriptionEpoch = UUID(); qwenEpoch = UUID()
        modelManager.closeDownloadAdmission()
        ownedOperations.values.forEach { $0.task.cancel() }
        refreshOperations.values.forEach { $0.task.cancel() }
    }
    @discardableResult
    func shutdown() async -> Bool {
        closeAdmission()
        await waitForPendingOperations()
        return await modelManager.finishStoppingDownloadProducers()
    }

    /// Settings owns the selected model. Assembly invokes this when the
    /// selected model changes. Settings separately invalidates migration tickets
    /// on every explicit model/provider action, even a repeated same value.
    func selectedQwenModelDidChange(to modelName: String) {
        cancelRecommended()
        invalidateRefresh()
        qwenEpoch = UUID()
        let task = qwenID.flatMap { ownedOperations[$0]?.task }
        qwenID = nil
        task?.cancel()
        if qwenHealth.selectedModel != modelName {
            qwenHealth = LocalLLMHealth(ollamaRunning: qwenHealth.ollamaRunning,
                selectedModel: modelName, modelInstalled: false,
                providerSource: .ollamaQwen, lastError: nil)
        }
    }
    func cancelRecommended() {
        guard let id = installID else { return }
        installID = nil
        for job in ownedOperations.values where job.parentID == id {
            if transcriptionID == job.id { transcriptionID = nil; transcriptionEpoch = UUID() }
            if qwenID == job.id { qwenID = nil; qwenEpoch = UUID() }
        }
        for (checkID, check) in refreshOperations where check.parentID == id {
            if latestRefreshID == checkID { latestRefreshID = nil }
            check.task.cancel()
        }
        // Borrowed independent jobs have parentID nil; cancellation never
        // changes their identity or sends them cancellation.
        ownedOperations.values.filter { $0.parentID == id }.forEach { $0.task.cancel() }
        ownedOperations[id]?.task.cancel()
    }

    // Existing content/diagnostics callers need no migration result. Both
    // entry points execute the same owned refresh operation.
    func refresh(qwenModel: String) async {
        _ = await refreshSnapshot(qwenModel: qwenModel)
    }
    func refreshSnapshot(qwenModel: String) async -> RefreshSnapshot? {
        await refresh(qwenModel: qwenModel, parentID: nil)
    }
    func requestRefresh(qwenModel: String) {
        _ = startRefresh(qwenModel: qwenModel, parentID: nil)
    }
    func isCurrent(_ snapshot: RefreshSnapshot) -> Bool {
        !admissionClosed && latestRefreshID == snapshot.id &&
            transcriptionEpoch == snapshot.transcriptionEpoch && qwenEpoch == snapshot.qwenEpoch
    }
    private func refresh(qwenModel: String, parentID: UUID?) async -> RefreshSnapshot? {
        guard let task = startRefresh(qwenModel: qwenModel, parentID: parentID) else { return nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func startRefresh(qwenModel: String, parentID: UUID?) -> Task<RefreshSnapshot?, Never>? {
        guard !admissionClosed, !Task.isCancelled else { return nil }
        invalidateRefresh()
        let id = UUID()
        let asrEpoch = transcriptionEpoch
        let llmEpoch = qwenEpoch
        latestRefreshID = id
        let task = Task { [self] () -> RefreshSnapshot? in
            defer { refreshOperations[id] = nil }
            @MainActor func accepted() -> Bool {
                !admissionClosed && !Task.isCancelled && latestRefreshID == id &&
                    transcriptionEpoch == asrEpoch && qwenEpoch == llmEpoch &&
                    (parentID == nil || installID == parentID)
            }
            guard accepted() else { return nil }
            let status = await modelManager.modelStatus(transcriptionModel)
            guard accepted() else { return nil }
            if transcriptionID == nil { transcriptionStatus = status }
            guard accepted() else { return nil }
            let health = await qwenProvider.healthCheck(modelName: qwenModel)
            guard accepted() else { return nil }
            if qwenID == nil { qwenHealth = health }
            guard accepted() else { return nil }
            let available = await parakeetRuntimeClient.isRuntimeAvailable()
            guard accepted() else { return nil }
            let snapshot = RefreshSnapshot(id: id, qwenModel: qwenModel, transcriptionStatus: status,
                qwenHealth: health, runtimeAvailable: available,
                transcriptionEpoch: asrEpoch, qwenEpoch: llmEpoch)
            // Progress belongs to its active operation; a readiness refresh
            // must not replace its visible status while that operation runs.
            parakeetRuntimeAvailable = available
            return snapshot
        }
        refreshOperations[id] = RefreshOperation(parentID: parentID, task: task)
        return task
    }
    private func invalidateRefresh() {
        let task = latestRefreshID.flatMap { refreshOperations[$0]?.task }
        latestRefreshID = nil
        task?.cancel()
    }

    func downloadTranscriptionModel() { _ = startTranscriptionDownload(parentID: nil) }
    private func startTranscriptionDownload(parentID: UUID?) -> OwnedOperation? {
        guard !admissionClosed, !Task.isCancelled else { return nil }
        if let current = transcriptionID.flatMap({ ownedOperations[$0] }) {
            guard current.operation == .downloadTranscription else {
                lastError = "Wait for transcription model deletion before downloading."
                return nil
            }
            return current
        }
        invalidateRefresh()
        let id = UUID()
        transcriptionEpoch = UUID(); transcriptionID = id
        lastError = nil
        let task = Task { [self] in
            defer { finish(id: id) }
            guard acceptsTranscription(id) else { return }
            do {
                for try await progress in modelManager.downloadModel(transcriptionModel) {
                    guard acceptsTranscription(id) else { return }
                    transcriptionProgress = progress
                    transcriptionStatus = .downloading(progress: progress.progress,
                        downloadedBytes: progress.downloadedBytes, totalBytes: progress.totalBytes,
                        speedBytesPerSecond: progress.speedBytesPerSecond)
                }
                guard acceptsTranscription(id) else { return }
                let status = await modelManager.modelStatus(transcriptionModel)
                guard acceptsTranscription(id) else { return }
                transcriptionStatus = status
            } catch {
                guard acceptsTranscription(id) else { return }
                lastError = error.localizedDescription
                transcriptionStatus = .failed(error.localizedDescription)
            }
        }
        let job = OwnedOperation(id: id, operation: .downloadTranscription, parentID: parentID, qwenModel: nil, task: task)
        ownedOperations[id] = job
        return job
    }

    func deleteTranscriptionModel() {
        guard !admissionClosed else { return }
        cancelRecommended()
        invalidateRefresh()
        let prior = ownedOperations.values.filter {
            $0.operation == .downloadTranscription || $0.operation == .deleteTranscription
        }
        transcriptionEpoch = UUID(); transcriptionID = nil
        prior.forEach { $0.task.cancel() }
        let id = UUID()
        transcriptionID = id
        let task = Task { [self] in
            defer { finish(id: id) }
            for job in prior { await job.task.value }
            guard acceptsTranscription(id) else { return }
            do {
                try await modelManager.deleteModel(transcriptionModel)
                guard acceptsTranscription(id) else { return }
                let status = await modelManager.modelStatus(transcriptionModel)
                guard acceptsTranscription(id) else { return }
                transcriptionProgress = nil
                transcriptionStatus = status
            } catch {
                guard acceptsTranscription(id) else { return }
                lastError = error.localizedDescription
            }
        }
        ownedOperations[id] = OwnedOperation(id: id, operation: .deleteTranscription, parentID: nil, qwenModel: nil, task: task)
    }

    func pullQwen(modelName: String) { _ = startQwenPull(modelName: modelName, parentID: nil) }
    private func startQwenPull(modelName: String, parentID: UUID?) -> OwnedOperation? {
        guard !admissionClosed, !Task.isCancelled else { return nil }
        if let current = qwenID.flatMap({ ownedOperations[$0] }) {
            guard current.qwenModel == modelName else {
                lastError = "A different Qwen model is already being pulled. Wait for it to finish before starting \(modelName)."
                return nil
            }
            return current
        }
        invalidateRefresh()
        let id = UUID()
        qwenEpoch = UUID(); qwenID = id
        lastError = nil; qwenProgress = nil
        if qwenHealth.selectedModel != modelName {
            qwenHealth = LocalLLMHealth(ollamaRunning: qwenHealth.ollamaRunning,
                selectedModel: modelName, modelInstalled: false,
                providerSource: .ollamaQwen, lastError: nil)
        }
        let task = Task { [self] in
            defer { finish(id: id) }
            guard acceptsQwen(id) else { return }
            do {
                for try await progress in qwenProvider.pullModel(modelName) {
                    guard acceptsQwen(id) else { return }
                    qwenProgress = progress
                }
                guard acceptsQwen(id) else { return }
                let health = await qwenProvider.healthCheck(modelName: modelName)
                guard acceptsQwen(id) else { return }
                qwenHealth = health
            } catch {
                guard acceptsQwen(id) else { return }
                lastError = error.localizedDescription
            }
        }
        let job = OwnedOperation(id: id, operation: .pullQwen, parentID: parentID, qwenModel: modelName, task: task)
        ownedOperations[id] = job
        return job
    }

    func installRecommended(qwenModel: String) {
        guard !admissionClosed, installID == nil else { return }
        let id = UUID()
        installID = id; lastError = nil
        let task = Task { [self] in
            defer { finish(id: id) }
            guard let snapshot = await refresh(qwenModel: qwenModel, parentID: id),
                  acceptsInstall(id) else { return }
            var children: [OwnedOperation] = []
            if let existing = transcriptionID.flatMap({ ownedOperations[$0] }), existing.operation == .downloadTranscription {
                children.append(existing)
            } else if !snapshot.transcriptionStatus.isReady,
                      let child = startTranscriptionDownload(parentID: id) { children.append(child) }
            if let existing = qwenID.flatMap({ ownedOperations[$0] }) {
                if existing.qwenModel == qwenModel { children.append(existing) }
                else { lastError = "A different Qwen model is already being pulled. Wait for it to finish before starting \(qwenModel)." }
            } else if snapshot.qwenHealth.ollamaRunning && !snapshot.qwenHealth.modelInstalled {
                if let child = startQwenPull(modelName: qwenModel, parentID: id) { children.append(child) }
            } else if !snapshot.qwenHealth.ollamaRunning {
                lastError = "Ollama is not running. Start Ollama, then pull \(qwenModel)."
            }
            // The started children run concurrently. This parent joins their
            // actual exits; cancellation never propagates to borrowed jobs.
            for child in children { await child.task.value }
        }
        ownedOperations[id] = OwnedOperation(id: id, operation: .installRecommended, parentID: nil, qwenModel: qwenModel, task: task)
    }
    private func acceptsInstall(_ id: UUID) -> Bool { !admissionClosed && !Task.isCancelled && installID == id }
    private func acceptsTranscription(_ id: UUID) -> Bool { !admissionClosed && !Task.isCancelled && transcriptionID == id }
    private func acceptsQwen(_ id: UUID) -> Bool { !admissionClosed && !Task.isCancelled && qwenID == id }
    private func finish(id: UUID) {
        ownedOperations[id] = nil
        if transcriptionID == id { transcriptionID = nil }
        if qwenID == id { qwenID = nil }
        if installID == id { installID = nil }
    }

    func modelPath(for model: LocalModelDescriptor) -> URL { modelManager.fileURL(for: model) }
    func canEnableParakeet() -> Bool { transcriptionStatus.isReady && parakeetRuntimeAvailable }
    var parakeetRuntimeStatusText: String { parakeetRuntimeAvailable ? "Runtime Ready" : "Runtime Unavailable" }
}
