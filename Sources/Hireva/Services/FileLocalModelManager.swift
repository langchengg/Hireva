import CryptoKit
import Darwin
import Dispatch
import Foundation
import os

private final class LocalModelOperationGate: Sendable {
    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State: Sendable {
        var activeKeys: Set<String> = []
        var waiters: [String: [Waiter]] = [:]
    }
    private enum Admission { case acquired, queued, cancelled }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func acquire(_ key: String, didQueue: (@Sendable () -> Void)? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let admission = state.withLock { state -> Admission in
                    // onCancel may have run before registration. Check the
                    // calling Task again inside the registration boundary.
                    guard !Task.isCancelled else { return .cancelled }
                    if state.activeKeys.insert(key).inserted { return .acquired }
                    state.waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                    return .queued
                }
                // Resuming a continuation or running an observer can reenter
                // callers. Neither happens while this queue lock is held.
                switch admission {
                case .acquired: continuation.resume()
                case .queued: didQueue?()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancelWaiting(id, for: key)
        }
        // Once granted, cancellation leaves ownership with the caller. The
        // caller checks cancellation inside its release-protected do/catch.
    }

    func pendingWaiterCount(_ key: String) -> Int {
        state.withLock { $0.waiters[key]?.count ?? 0 }
    }

    private func cancelWaiting(_ id: UUID, for key: String) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard var queued = state.waiters[key], let index = queued.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let cancelled = queued.remove(at: index)
            state.waiters[key] = queued.isEmpty ? nil : queued
            return cancelled.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    func release(_ key: String) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard var queued = state.waiters[key], !queued.isEmpty else {
                state.activeKeys.remove(key)
                state.waiters[key] = nil
                return nil
            }
            let next = queued.removeFirst()
            state.waiters[key] = queued.isEmpty ? nil : queued
            return next.continuation
        }
        continuation?.resume()
    }
}

private final class TrustedModelRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let trustedHosts: Set<String>

    init(trustedHosts: [String]) {
        self.trustedHosts = Set(trustedHosts.map { $0.lowercased() })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.isTrusted(request.url, trustedHosts: trustedHosts) ? request : nil)
    }

    static func isTrusted(_ url: URL?, trustedHosts: Set<String>) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else {
            return false
        }
        return trustedHosts.isEmpty || trustedHosts.contains(host)
    }
}

private final class ExclusiveModelFileLock {
    private let descriptor: Int32

    init(url: URL, modelName: String, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LocalModelManagerError.downloadFailed("Could not open the local model operation lock.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LocalModelManagerError.modelInUse(modelName)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

final class FileLocalModelManager: LocalModelManager, Sendable {
    private static let operationGate = LocalModelOperationGate()

    private enum DownloadProducerScope {
        @TaskLocal static var id: UUID? = nil
    }
    private struct OwnedArchiveCommand: Sendable {
        let owner: ModelArchiveTarProcess
        let operationKey: String
    }
    private struct DownloadProducerRecord: Sendable {
        let task: Task<Void, Never>
        // This same record keeps an incompletely stopped command and its
        // temporary files alive after producer Task exit. It retains the
        // operation key until actual process/reader cleanup has finished.
        var archiveCommand: OwnedArchiveCommand?
        var pendingTemporaryURLs: [URL] = []
        // A hint for async reaping, not proof of Task exit. Only task.value
        // permits removal of this record from the authoritative registry.
        var readyToJoin = false
    }
    private struct DownloadProducerState: Sendable {
        var admissionClosed = false
        var records: [UUID: DownloadProducerRecord] = [:]
    }
    private let downloadProducers = OSAllocatedUnfairLock(initialState: DownloadProducerState())

    private enum InstalledValidationError: Error {
        case missing(String)
    }

    private let rootDirectory: URL
    // The shared default is thread-safe for these delegate-free synchronous
    // filesystem operations. Do not store an unproven cross-executor instance.
    private var fileManager: FileManager { .default }
    private let modelSmokeValidator: @Sendable (LocalModelDescriptor, URL) async throws -> Void
    private let operationDidQueue: (@Sendable () -> Void)?
    private let tarProcessFactory: @Sendable ([String]) -> Process
    // Nil in application assembly; observes this exact retained archive owner.
    private let archiveReadWillBeginForTesting: (@Sendable () -> Void)?
    private let archiveCleanupWillBeginForTesting: (@Sendable () async -> Void)?
    private let archiveCleanupRequestDidRegisterForTesting: (@Sendable (Bool) -> Void)?
    private let inMemoryStatuses = OSAllocatedUnfairLock(initialState: [String: LocalModelStatus]())

    init(
        rootDirectory: URL = AppPaths.localModelsDirectory,
        modelSmokeValidator: @escaping @Sendable (LocalModelDescriptor, URL) async throws -> Void = { model, directory in
            try await FileLocalModelManager.defaultModelSmokeValidator(model, directory)
        },
        operationDidQueue: (@Sendable () -> Void)? = nil,
        tarProcessFactory: @escaping @Sendable ([String]) -> Process = { arguments in
            FileLocalModelManager.makeTarProcess(arguments)
        },
        archiveReadWillBeginForTesting: (@Sendable () -> Void)? = nil,
        archiveCleanupWillBeginForTesting: (@Sendable () async -> Void)? = nil,
        archiveCleanupRequestDidRegisterForTesting: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.rootDirectory = Self.resolvedRootDirectory(rootDirectory, fileManager: .default)
        self.modelSmokeValidator = modelSmokeValidator
        self.operationDidQueue = operationDidQueue
        self.tarProcessFactory = tarProcessFactory
        self.archiveReadWillBeginForTesting = archiveReadWillBeginForTesting
        self.archiveCleanupWillBeginForTesting = archiveCleanupWillBeginForTesting
        self.archiveCleanupRequestDidRegisterForTesting = archiveCleanupRequestDidRegisterForTesting
    }

    private static func resolvedRootDirectory(_ rootDirectory: URL, fileManager: FileManager) -> URL {
        var existingAncestor = rootDirectory.standardizedFileURL
        var missingComponents: [String] = []
        while existingAncestor.path != "/", !fileManager.fileExists(atPath: existingAncestor.path) {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }

        var resolvedRoot = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolvedRoot.appendPathComponent(component, isDirectory: true)
        }
        return resolvedRoot.standardizedFileURL
    }

    func fileURL(for model: LocalModelDescriptor) -> URL {
        rootDirectory.appendingPathComponent(model.storageRelativePath, isDirectory: !model.requiredFiles.isEmpty)
    }

    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus {
        await reapCompletedDownloadProducers()
        let key = operationKey(for: model)
        if let active = activeStatus(for: key) {
            return active
        }

        do {
            try await Self.operationGate.acquire(key, didQueue: operationDidQueue)
        } catch {
            return .failed(error.localizedDescription)
        }
        let status: LocalModelStatus
        do {
            try Task.checkCancellation()
            let destinationURL = try validatedDestinationURL(for: model)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try await migrateLegacyInstallIfAvailable(for: model, to: destinationURL)
            }
            status = installedStatus(model, at: destinationURL)
        } catch {
            status = .failed(error.localizedDescription)
        }
        Self.operationGate.release(key)
        return status
    }

    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool {
        await reapCompletedDownloadProducers()
        let key = operationKey(for: model)
        try await Self.operationGate.acquire(key, didQueue: operationDidQueue)
        do {
            try Task.checkCancellation()
            let destinationURL = try validatedDestinationURL(for: model)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try await migrateLegacyInstallIfAvailable(for: model, to: destinationURL)
            }
            guard fileManager.fileExists(atPath: destinationURL.path) else {
                Self.operationGate.release(key)
                return false
            }
            try validateInstalledModel(model, at: destinationURL)
            Self.operationGate.release(key)
            return true
        } catch is InstalledValidationError {
            Self.operationGate.release(key)
            return false
        } catch let error as LocalModelManagerError {
            Self.operationGate.release(key)
            switch error {
            case .sizeMismatch, .checksumMismatch, .unsafeArchiveEntry, .downloadFailed:
                return false
            default:
                throw error
            }
        } catch {
            Self.operationGate.release(key)
            throw error
        }
    }

    func deleteModel(_ model: LocalModelDescriptor) async throws {
        await reapCompletedDownloadProducers()
        let key = operationKey(for: model)
        try await Self.operationGate.acquire(key, didQueue: operationDidQueue)
        do {
            try Task.checkCancellation()
            let destinationURL = try validatedDestinationURL(for: model)
            let rollbackURL = try rollbackURL(for: destinationURL)
            try validateManagedModelPaths(model, at: destinationURL)
            try validateManagedModelPaths(model, at: rollbackURL)
            let legacyURLs = try model.legacyStorageRelativePaths.map(validatedURL(relativePath:))
            for legacyURL in legacyURLs {
                try validateManagedModelPaths(model, at: legacyURL)
                try validateManagedPath(legacyMigrationMarkerURL(in: legacyURL))
            }
            let modelLock = try acquireExclusiveModelLock(for: model)
            defer { withExtendedLifetime(modelLock) {} }
            for url in [destinationURL, rollbackURL] where fileManager.fileExists(atPath: url.path) {
                try removeManagedItem(at: url)
            }
            for legacyURL in legacyURLs where fileManager.fileExists(atPath: legacyURL.path) {
                let containsDestination = isStrictDescendant(destinationURL, of: legacyURL)
                let isUnversionedInstall = (try? validateInstalledModel(model, at: legacyURL)) != nil
                if !containsDestination || isUnversionedInstall {
                    try removeManagedItem(at: legacyURL)
                    continue
                }

                let markerURL = legacyMigrationMarkerURL(in: legacyURL)
                if fileManager.fileExists(atPath: markerURL.path) {
                    try removeLegacyManifestFiles(for: model, at: legacyURL)
                    try removeManagedItem(at: markerURL)
                }
                try removeDirectoryIfEmpty(legacyURL)
            }
            setActiveStatus(nil, for: key)
            Self.operationGate.release(key)
        } catch {
            Self.operationGate.release(key)
            throw error
        }
    }

    func rollbackModel(_ model: LocalModelDescriptor) async throws {
        await reapCompletedDownloadProducers()
        let key = operationKey(for: model)
        try await Self.operationGate.acquire(key, didQueue: operationDidQueue)
        do {
            try Task.checkCancellation()
            let destinationURL = try validatedDestinationURL(for: model)
            let rollbackURL = try rollbackURL(for: destinationURL)
            try validateManagedModelPaths(model, at: destinationURL)
            try validateManagedModelPaths(model, at: rollbackURL)
            guard fileManager.fileExists(atPath: rollbackURL.path) else {
                throw LocalModelManagerError.rollbackUnavailable(model.displayName)
            }
            try validateInstalledModel(model, at: rollbackURL)
            let modelLock = try acquireExclusiveModelLock(for: model)
            defer { withExtendedLifetime(modelLock) {} }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try atomicSwap(destinationURL, rollbackURL)
            } else {
                try moveManagedItem(at: rollbackURL, to: destinationURL)
            }
            setActiveStatus(nil, for: key)
            Self.operationGate.release(key)
        } catch {
            Self.operationGate.release(key)
            throw error
        }
    }

    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        modelDownloadStream(model)
    }

    func repairModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        modelDownloadStream(model)
    }

    /// Inspection of the actual model-key queue; no second waiter registry.
    func pendingOperationWaiterCount(for model: LocalModelDescriptor) async -> Int {
        Self.operationGate.pendingWaiterCount(operationKey(for: model))
    }

    var pendingDownloadProducerCount: Int {
        downloadProducers.withLock { $0.records.count }
    }

    func closeDownloadAdmission() {
        let tasks = downloadProducers.withLock { state -> [Task<Void, Never>] in
            guard !state.admissionClosed else { return [] }
            state.admissionClosed = true
            return state.records.values.map(\.task)
        }
        // Cancellation can invoke arbitrary handlers. It must happen after
        // unlocking, including when a handler reenters this manager.
        tasks.forEach { $0.cancel() }
    }

    func finishStoppingDownloadProducers() async -> Bool {
        // A producer or inherited child cannot wait for its own producer exit.
        // Report incomplete cleanup instead of claiming a clean self-join.
        guard DownloadProducerScope.id == nil else { return false }
        while true {
            let snapshot = downloadProducers.withLock { state -> [(UUID, Task<Void, Never>)]? in
                guard state.admissionClosed else { return nil }
                return state.records.map { ($0.key, $0.value.task) }
            }
            guard let snapshot else { return false }
            guard !snapshot.isEmpty else { return true }
            for (id, task) in snapshot {
                await task.value
                guard await finishAndRemoveJoinedDownloadProducer(id) else { return false }
            }
        }
    }

    private func reapCompletedDownloadProducers() async {
        let currentID = DownloadProducerScope.id
        let snapshot = downloadProducers.withLock { state in
            state.records.compactMap { id, record -> (UUID, Task<Void, Never>)? in
                guard record.readyToJoin, id != currentID else { return nil }
                return (id, record.task)
            }
        }
        for (id, task) in snapshot {
            await task.value
            _ = await finishAndRemoveJoinedDownloadProducer(id)
        }
    }

    private func markDownloadProducerReadyToJoin(_ id: UUID) {
        downloadProducers.withLock { state in
            guard var record = state.records[id] else { return }
            record.readyToJoin = true
            state.records[id] = record
        }
    }

    private func finishAndRemoveJoinedDownloadProducer(_ id: UUID) async -> Bool {
        let record = downloadProducers.withLock { $0.records[id] }
        guard let record else { return true }
        if let command = record.archiveCommand {
            guard await command.owner.finishStopping() else { return false }
            for url in record.pendingTemporaryURLs {
                do { try removeManagedItemIfPresent(at: url) }
                catch {
                    // Concurrent drains can observe the same joined record.
                    // A file removed by the other drain is already clean.
                    let error = error as NSError
                    guard error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError else {
                        setActiveStatus(.failed("Archive temporary-file cleanup failed: \(error.localizedDescription)"),
                            for: command.operationKey)
                        return false
                    }
                }
            }
        }
        // Only the caller that actually removes the joined record can release
        // its retained operation key. No lock is held across the awaits above.
        let removed = downloadProducers.withLock { $0.records.removeValue(forKey: id) }
        if let command = removed?.archiveCommand {
            setActiveStatus(nil, for: command.operationKey)
            Self.operationGate.release(command.operationKey)
        }
        return true
    }

    private func cleanupDownloadTemporaryURL(_ url: URL) {
        let retained = downloadProducers.withLock { state -> Bool in
            guard let id = DownloadProducerScope.id, var record = state.records[id],
                  record.archiveCommand != nil else { return false }
            record.pendingTemporaryURLs.append(url)
            state.records[id] = record
            return true
        }
        if !retained { try? removeManagedItemIfPresent(at: url) }
    }

    private func modelDownloadStream(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            // Registration and admission share one synchronous lock boundary.
            // The Task may run immediately, but its exit marker takes the same
            // lock and cannot outrun installation of its real handle.
            let task = downloadProducers.withLock { state -> Task<Void, Never>? in
                guard !state.admissionClosed else { return nil }
                let task = Task { [self] in
                    await DownloadProducerScope.$id.withValue(id) {
                        defer { markDownloadProducerReadyToJoin(id) }
                        await reapCompletedDownloadProducers()
                        let key = operationKey(for: model)
                        var ownsOperation = false
                        do {
                            try await Self.operationGate.acquire(key, didQueue: operationDidQueue)
                            ownsOperation = true
                            try Task.checkCancellation()
                            try await installDownloadedModel(model, statusKey: key, continuation: continuation)
                            setActiveStatus(nil, for: key)
                            continuation.yield(.completed(modelID: model.id, totalBytes: model.sizeBytes))
                            Self.operationGate.release(key)
                            continuation.finish()
                        } catch {
                            // A cancelled queued producer never acquired the
                            // key and cannot release another operation's key.
                            if ownsOperation {
                                let commandRetained = downloadProducers.withLock { $0.records[id]?.archiveCommand != nil }
                                if commandRetained {
                                    setActiveStatus(.failed(error.localizedDescription), for: key)
                                } else {
                                    setActiveStatus(nil, for: key)
                                    Self.operationGate.release(key)
                                }
                            }
                            continuation.finish(throwing: error)
                        }
                    }
                }
                state.records[id] = DownloadProducerRecord(task: task)
                return task
            }
            guard let task else {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    private func installDownloadedModel(
        _ model: LocalModelDescriptor,
        statusKey: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        guard let sourceURL = model.downloadURL else {
            throw LocalModelManagerError.missingDownloadURL(model.displayName)
        }
        try validateDownloadURL(sourceURL, for: model)
        let destinationURL = try validatedDestinationURL(for: model)
        _ = try rollbackURL(for: destinationURL)
        try createManagedDirectory(at: rootDirectory)
        try createManagedDirectory(at: destinationURL.deletingLastPathComponent())

        if isArchiveDownload(sourceURL) {
            let archiveURL = try uniqueSiblingURL(of: destinationURL, label: "archive")
            defer { cleanupDownloadTemporaryURL(archiveURL) }
            try await transferFile(
                from: sourceURL,
                to: archiveURL,
                model: model,
                statusKey: statusKey,
                continuation: continuation
            )
            try validateArchive(archiveURL, for: model)
            try await preflightArchive(archiveURL, for: model, statusKey: statusKey)

            let extractionRoot = try uniqueSiblingURL(of: destinationURL, label: "staging")
            defer { cleanupDownloadTemporaryURL(extractionRoot) }
            try createManagedDirectory(at: extractionRoot)
            try validateManagedPath(archiveURL)
            try validateManagedPath(extractionRoot)
            try await runTar(["-xf", archiveURL.path, "-C", extractionRoot.path], operation: "extraction", statusKey: statusKey)
            try validateExtractedTree(at: extractionRoot)

            let stagedModelURL = try extractedModelDirectory(in: extractionRoot, for: model)
            try validateInstalledModel(model, at: stagedModelURL)
            try await modelSmokeValidator(model, stagedModelURL)
            // A validator may finish after its consumer revoked the download.
            // Reject that result before replacing any installed files.
            try Task.checkCancellation()
            let modelLock = try acquireExclusiveModelLock(for: model)
            defer { withExtendedLifetime(modelLock) {} }
            try atomicInstall(stagedModelURL, at: destinationURL, for: model)
        } else {
            let stagedFileURL = try uniqueSiblingURL(of: destinationURL, label: "staging")
            defer { try? removeManagedItemIfPresent(at: stagedFileURL) }
            try await transferFile(
                from: sourceURL,
                to: stagedFileURL,
                model: model,
                statusKey: statusKey,
                continuation: continuation
            )
            try validateStandaloneFile(stagedFileURL, for: model)
            try await modelSmokeValidator(model, stagedFileURL)
            try Task.checkCancellation()
            let modelLock = try acquireExclusiveModelLock(for: model)
            defer { withExtendedLifetime(modelLock) {} }
            try atomicInstall(stagedFileURL, at: destinationURL, for: model)
        }

        try validateInstalledModel(model, at: destinationURL)
    }

    private func transferFile(
        from sourceURL: URL,
        to destinationURL: URL,
        model: LocalModelDescriptor,
        statusKey: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        if sourceURL.isFileURL {
            try await copyLocalFile(
                from: sourceURL,
                to: destinationURL,
                model: model,
                statusKey: statusKey,
                continuation: continuation
            )
        } else {
            try await downloadRemoteFile(
                from: sourceURL,
                to: destinationURL,
                model: model,
                statusKey: statusKey,
                continuation: continuation
            )
        }
    }

    private func copyLocalFile(
        from sourceURL: URL,
        to destinationURL: URL,
        model: LocalModelDescriptor,
        statusKey: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        try validateManagedPath(destinationURL)
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw LocalModelManagerError.downloadFailed("Could not create the model staging file.")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        let startedAt = Date()
        var downloaded: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            downloaded += Int64(data.count)
            reportProgress(
                modelID: model.id,
                statusKey: statusKey,
                downloaded: downloaded,
                total: totalBytes,
                startedAt: startedAt,
                continuation: continuation
            )
        }
    }

    private func downloadRemoteFile(
        from sourceURL: URL,
        to destinationURL: URL,
        model: LocalModelDescriptor,
        statusKey: String,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        let redirectDelegate = TrustedModelRedirectDelegate(trustedHosts: model.trustedDownloadHosts)
        let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: sourceURL)
        guard TrustedModelRedirectDelegate.isTrusted(
            response.url,
            trustedHosts: Set(model.trustedDownloadHosts.map { $0.lowercased() })
        ) else {
            throw LocalModelManagerError.untrustedDownloadURL(response.url?.absoluteString ?? sourceURL.absoluteString)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LocalModelManagerError.downloadFailed("Download failed with HTTP \(http.statusCode).")
        }
        let totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : model.sizeBytes
        try validateManagedPath(destinationURL)
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw LocalModelManagerError.downloadFailed("Could not create the model staging file.")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        let startedAt = Date()
        var downloaded: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try output.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                reportProgress(
                    modelID: model.id,
                    statusKey: statusKey,
                    downloaded: downloaded,
                    total: totalBytes,
                    startedAt: startedAt,
                    continuation: continuation
                )
            }
        }
        if !buffer.isEmpty {
            try output.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
            reportProgress(
                modelID: model.id,
                statusKey: statusKey,
                downloaded: downloaded,
                total: totalBytes,
                startedAt: startedAt,
                continuation: continuation
            )
        }
    }

    private func validateDownloadURL(_ url: URL, for model: LocalModelDescriptor) throws {
        guard !url.isFileURL else { return }
        let trustedHosts = Set(model.trustedDownloadHosts.map { $0.lowercased() })
        guard TrustedModelRedirectDelegate.isTrusted(url, trustedHosts: trustedHosts) else {
            throw LocalModelManagerError.untrustedDownloadURL(url.absoluteString)
        }
    }

    private func validateArchive(_ archiveURL: URL, for model: LocalModelDescriptor) throws {
        let actualBytes = try fileSize(at: archiveURL)
        if let expectedBytes = model.sizeBytes, actualBytes != expectedBytes {
            throw LocalModelManagerError.sizeMismatch(
                path: archiveURL.lastPathComponent,
                expected: expectedBytes,
                actual: actualBytes
            )
        }
        if let expectedHash = model.checksum,
           try sha256(of: archiveURL) != expectedHash.lowercased() {
            throw LocalModelManagerError.checksumMismatch(path: archiveURL.lastPathComponent)
        }
    }

    private func preflightArchive(_ archiveURL: URL, for model: LocalModelDescriptor, statusKey: String) async throws {
        let listing = try await runTar(["-tf", archiveURL.path], operation: "preflight", statusKey: statusKey)
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else {
            throw LocalModelManagerError.downloadFailed("Model archive is empty.")
        }
        var normalizedEntries = Set<String>()
        for entry in entries {
            try validateRelativePath(entry, allowTrailingSlash: true)
            let normalizedEntry = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard normalizedEntries.insert(normalizedEntry).inserted else {
                throw LocalModelManagerError.unsafeArchiveEntry("duplicate entry \(entry)")
            }
            if let archiveRoot = model.archiveRootDirectory {
                guard normalizedEntry == archiveRoot || normalizedEntry.hasPrefix("\(archiveRoot)/") else {
                    throw LocalModelManagerError.unsafeArchiveEntry(entry)
                }
            }
        }

        let verboseListing = try await runTar(["-tvf", archiveURL.path], operation: "type preflight", statusKey: statusKey)
        for line in verboseListing.split(whereSeparator: \.isNewline) {
            guard let type = line.first, type == "-" || type == "d" else {
                throw LocalModelManagerError.unsafeArchiveEntry(String(line))
            }
        }
    }

    private static func makeTarProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        return process
    }

    @discardableResult
    private func runTar(_ arguments: [String], operation: String, statusKey: String) async throws -> String {
        try Task.checkCancellation()
        // Every archive command runs inside the already registered producer.
        // Do not start a process without that authoritative lifetime record.
        guard let id = DownloadProducerScope.id,
              downloadProducers.withLock({ $0.records[id] != nil }) else {
            throw LocalModelManagerError.downloadFailed("Archive command has no owning download producer.")
        }
        let owner = ModelArchiveTarProcess(process: tarProcessFactory(arguments), operation: operation,
            readWillBegin: archiveReadWillBeginForTesting,
            cleanupWillBegin: archiveCleanupWillBeginForTesting,
            cleanupRequestDidRegister: archiveCleanupRequestDidRegisterForTesting)
        downloadProducers.withLock { state in
            // The current producer cannot be removed before its real Task
            // exits. Archive commands are sequential within that producer.
            precondition(state.records[id] != nil && state.records[id]?.archiveCommand == nil)
            state.records[id]?.archiveCommand = OwnedArchiveCommand(owner: owner, operationKey: statusKey)
        }
        do {
            let result = try await owner.run()
            downloadProducers.withLock { $0.records[id]?.archiveCommand = nil }
            return result
        } catch {
            if owner.isFullyStopped {
                downloadProducers.withLock { $0.records[id]?.archiveCommand = nil }
            }
            // Incomplete cleanup keeps the command, temporary files, and key
            // in this same record. A later drain retries before removal.
            throw error
        }
    }

    private func validateExtractedTree(at rootURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw LocalModelManagerError.downloadFailed("Could not inspect the extracted model archive.")
        }
        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw LocalModelManagerError.unsafeArchiveEntry(itemURL.path)
            }
            guard isContained(itemURL, in: rootURL) else {
                throw LocalModelManagerError.unsafeArchiveEntry(itemURL.path)
            }
        }
    }

    private func extractedModelDirectory(in extractionRoot: URL, for model: LocalModelDescriptor) throws -> URL {
        if let archiveRoot = model.archiveRootDirectory {
            try validateRelativePath(archiveRoot)
            let expectedURL = extractionRoot.appendingPathComponent(archiveRoot, isDirectory: true)
            guard isContained(expectedURL, in: extractionRoot), fileManager.fileExists(atPath: expectedURL.path) else {
                throw LocalModelManagerError.downloadFailed("Model archive did not contain \(archiveRoot).")
            }
            return expectedURL
        }
        if requiredFilesExist(for: model, at: extractionRoot) {
            return extractionRoot
        }
        let items = try fileManager.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let directory = items.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && requiredFilesExist(for: model, at: $0)
        }) {
            return directory
        }
        throw LocalModelManagerError.downloadFailed("Extracted archive did not contain the required model files.")
    }

    private func validateStandaloneFile(_ fileURL: URL, for model: LocalModelDescriptor) throws {
        try validateManagedPath(fileURL)
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw LocalModelManagerError.unsafeArchiveEntry(fileURL.path)
        }
        let actualBytes = try fileSize(at: fileURL)
        guard actualBytes > 0 else {
            throw LocalModelManagerError.downloadFailed("Downloaded model file is empty.")
        }
        if let expectedHash = model.checksum {
            if let expectedBytes = model.sizeBytes, actualBytes != expectedBytes {
                throw LocalModelManagerError.sizeMismatch(path: fileURL.lastPathComponent, expected: expectedBytes, actual: actualBytes)
            }
            if try sha256(of: fileURL) != expectedHash.lowercased() {
                throw LocalModelManagerError.checksumMismatch(path: fileURL.lastPathComponent)
            }
        }
    }

    private func validateInstalledModel(_ model: LocalModelDescriptor, at rootURL: URL) throws {
        try validateManagedModelPaths(model, at: rootURL)
        if model.requiredFiles.isEmpty {
            guard fileManager.fileExists(atPath: rootURL.path) else {
                throw InstalledValidationError.missing(rootURL.path)
            }
            try validateStandaloneFile(rootURL, for: model)
            return
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InstalledValidationError.missing(rootURL.path)
        }
        let rootValues = try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw LocalModelManagerError.unsafeArchiveEntry(rootURL.path)
        }

        for requirement in model.requiredFiles {
            try validateRelativePath(requirement.relativePath)
            let fileURL = rootURL.appendingPathComponent(requirement.relativePath, isDirectory: false)
            guard isContained(fileURL, in: rootURL), fileManager.fileExists(atPath: fileURL.path) else {
                throw InstalledValidationError.missing(requirement.relativePath)
            }
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw LocalModelManagerError.unsafeArchiveEntry(requirement.relativePath)
            }
            let actualBytes = try fileSize(at: fileURL)
            if let exactBytes = requirement.exactBytes, actualBytes != exactBytes {
                throw LocalModelManagerError.sizeMismatch(
                    path: requirement.relativePath,
                    expected: exactBytes,
                    actual: actualBytes
                )
            }
            if let minimumBytes = requirement.minimumBytes, actualBytes < minimumBytes {
                throw LocalModelManagerError.downloadFailed(
                    "\(requirement.relativePath) is incomplete: \(actualBytes) bytes, expected at least \(minimumBytes)."
                )
            }
            if let expectedHash = requirement.sha256,
               try sha256(of: fileURL) != expectedHash.lowercased() {
                throw LocalModelManagerError.checksumMismatch(path: requirement.relativePath)
            }
        }

        if model.requiredFiles.allSatisfy({ $0.exactBytes != nil && $0.sha256 != nil }) {
            let expectedPaths = Set(model.requiredFiles.map(\.relativePath))
            let actualPaths = try regularFilePaths(in: rootURL)
            guard actualPaths == expectedPaths else {
                let unexpected = actualPaths.subtracting(expectedPaths).sorted().first
                let missing = expectedPaths.subtracting(actualPaths).sorted().first
                throw LocalModelManagerError.unsafeArchiveEntry(unexpected ?? missing ?? "manifest mismatch")
            }
        }
    }

    private func atomicInstall(_ stagedURL: URL, at destinationURL: URL, for model: LocalModelDescriptor) throws {
        try validateManagedPath(stagedURL)
        try validateManagedPath(destinationURL)
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try moveManagedItem(at: stagedURL, to: destinationURL)
            return
        }

        let rollbackURL = try rollbackURL(for: destinationURL)
        let retiredRollbackURL = try uniqueSiblingURL(of: destinationURL, label: "retired-rollback")
        let hadRollback = fileManager.fileExists(atPath: rollbackURL.path)
        if hadRollback {
            try moveManagedItem(at: rollbackURL, to: retiredRollbackURL)
        }

        var didSwap = false
        do {
            try atomicSwap(stagedURL, destinationURL)
            didSwap = true

            if (try? validateInstalledModel(model, at: stagedURL)) != nil {
                try moveManagedItem(at: stagedURL, to: rollbackURL)
                if hadRollback {
                    try removeManagedItem(at: retiredRollbackURL)
                }
            } else {
                try removeManagedItem(at: stagedURL)
                if hadRollback {
                    try moveManagedItem(at: retiredRollbackURL, to: rollbackURL)
                }
            }
        } catch {
            if didSwap,
               fileManager.fileExists(atPath: stagedURL.path),
               fileManager.fileExists(atPath: destinationURL.path) {
                try? atomicSwap(stagedURL, destinationURL)
            }
            if hadRollback,
               fileManager.fileExists(atPath: retiredRollbackURL.path),
               !fileManager.fileExists(atPath: rollbackURL.path) {
                try? moveManagedItem(at: retiredRollbackURL, to: rollbackURL)
            }
            throw error
        }
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        try validateManagedPath(first)
        try validateManagedPath(second)
        let result: Int32 = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath -> Int32 in
                guard let firstPath, let secondPath else { return -1 }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw LocalModelManagerError.downloadFailed(
                "Atomic model swap failed: \(String(cString: strerror(errno)))"
            )
        }
    }

    private func migrateLegacyInstallIfAvailable(for model: LocalModelDescriptor, to destinationURL: URL) async throws {
        try validateManagedModelPaths(model, at: destinationURL)
        _ = try rollbackURL(for: destinationURL)
        for relativePath in model.legacyStorageRelativePaths {
            let legacyURL = try validatedURL(relativePath: relativePath)
            guard fileManager.fileExists(atPath: legacyURL.path) else { continue }
            try validateInstalledModel(model, at: legacyURL)
            let modelLock = try acquireExclusiveModelLock(for: model)
            defer { withExtendedLifetime(modelLock) {} }
            if isStrictDescendant(destinationURL, of: legacyURL) {
                try await modelSmokeValidator(model, legacyURL)
                try Task.checkCancellation()
                try migrateNestedLegacyInstall(model, from: legacyURL, to: destinationURL)
                return
            }
            let stagingURL = try validatedManagedURL(rootDirectory.appendingPathComponent(
                ".legacy-migration.\(UUID().uuidString)",
                isDirectory: true
            ))
            defer { try? removeManagedItemIfPresent(at: stagingURL) }
            try copyManagedItem(at: legacyURL, to: stagingURL)
            try validateInstalledModel(model, at: stagingURL)
            try await modelSmokeValidator(model, stagingURL)
            try Task.checkCancellation()
            try createManagedDirectory(at: destinationURL.deletingLastPathComponent())
            try atomicInstall(stagingURL, at: destinationURL, for: model)
            return
        }
    }

    private func migrateNestedLegacyInstall(
        _ model: LocalModelDescriptor,
        from legacyURL: URL,
        to destinationURL: URL
    ) throws {
        let movedLegacyURL = try uniqueSiblingURL(of: legacyURL, label: "legacy-migration")
        var movedLegacy = false
        do {
            try moveManagedItem(at: legacyURL, to: movedLegacyURL)
            movedLegacy = true
            try createManagedDirectory(at: legacyURL)
            try moveManagedItem(at: movedLegacyURL, to: destinationURL)
            movedLegacy = false
            try validateInstalledModel(model, at: destinationURL)
            try writeLegacyMigrationMarker(for: model, in: legacyURL)
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? removeManagedItemIfPresent(at: legacyURL)
                try? moveManagedItem(at: destinationURL, to: legacyURL)
            } else if movedLegacy {
                try? removeManagedItemIfPresent(at: legacyURL)
                try? moveManagedItem(at: movedLegacyURL, to: legacyURL)
            }
            throw error
        }
    }

    private func writeLegacyMigrationMarker(for model: LocalModelDescriptor, in parentURL: URL) throws {
        let hashes = Dictionary(uniqueKeysWithValues: model.requiredFiles.compactMap { requirement in
            requirement.sha256.map { (requirement.relativePath, $0) }
        })
        let marker: [String: Any] = [
            "modelID": model.id,
            "version": model.version ?? "unversioned",
            "destination": model.storageRelativePath,
            "verifiedFileHashes": hashes
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        let markerURL = legacyMigrationMarkerURL(in: parentURL)
        try validateManagedPath(markerURL)
        try data.write(to: markerURL, options: .atomic)
    }

    private func legacyMigrationMarkerURL(in parentURL: URL) -> URL {
        parentURL.appendingPathComponent(".legacy-migration.json", isDirectory: false)
    }

    private func acquireExclusiveModelLock(for model: LocalModelDescriptor) throws -> ExclusiveModelFileLock {
        let lockDirectory: URL
        if let namespace = model.storageNamespace, !namespace.isEmpty {
            lockDirectory = try validatedURL(relativePath: namespace)
        } else {
            lockDirectory = rootDirectory
        }
        let lockURL = lockDirectory.appendingPathComponent(".\(model.id).use.lock", isDirectory: false)
        try validateManagedPath(lockURL)
        return try ExclusiveModelFileLock(
            url: lockURL,
            modelName: model.displayName,
            fileManager: fileManager
        )
    }

    private func isStrictDescendant(_ candidate: URL, of parent: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/")
    }

    private func removeLegacyManifestFiles(for model: LocalModelDescriptor, at legacyURL: URL) throws {
        var parentDirectories = Set<URL>()
        for requirement in model.requiredFiles {
            let fileURL = legacyURL.appendingPathComponent(requirement.relativePath, isDirectory: false)
            guard isContained(fileURL, in: legacyURL) else {
                throw LocalModelManagerError.invalidRelativePath(requirement.relativePath)
            }
            try validateManagedPath(fileURL)
            if fileManager.fileExists(atPath: fileURL.path) {
                try removeManagedItem(at: fileURL)
            }

            var directoryURL = fileURL.deletingLastPathComponent()
            while directoryURL.standardizedFileURL != legacyURL.standardizedFileURL {
                parentDirectories.insert(directoryURL)
                directoryURL.deleteLastPathComponent()
            }
        }

        for directoryURL in parentDirectories.sorted(by: { $0.path.count > $1.path.count })
        where fileManager.fileExists(atPath: directoryURL.path) {
            try removeDirectoryIfEmpty(directoryURL)
        }
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL) throws {
        try validateManagedPath(directoryURL)
        let entries = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        if entries.isEmpty {
            try removeManagedItem(at: directoryURL)
        }
    }

    private static func defaultModelSmokeValidator(_ model: LocalModelDescriptor, _ modelURL: URL) async throws {
        guard model.id == LocalModelDescriptor.defaultParakeetASR.id else { return }
        guard await ParakeetSidecarRuntimeClient().probeModel(at: modelURL) else {
            throw LocalModelManagerError.downloadFailed(
                "Parakeet runtime rejected the verified model during its smoke check."
            )
        }
    }

    private func installedStatus(_ model: LocalModelDescriptor, at rootURL: URL) -> LocalModelStatus {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return .notInstalled
        }
        if !model.requiredFiles.isEmpty, !requiredFilesExist(for: model, at: rootURL) {
            return .notInstalled
        }
        do {
            try validateInstalledModel(model, at: rootURL)
            return .installed
        } catch is InstalledValidationError {
            return .notInstalled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func requiredFilesExist(for model: LocalModelDescriptor, at rootURL: URL) -> Bool {
        guard !model.requiredFiles.isEmpty else { return fileManager.fileExists(atPath: rootURL.path) }
        return model.requiredFiles.allSatisfy { requirement in
            guard (try? validateRelativePath(requirement.relativePath)) != nil else { return false }
            return fileManager.fileExists(atPath: rootURL.appendingPathComponent(requirement.relativePath).path)
        }
    }

    private func regularFilePaths(in rootURL: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw LocalModelManagerError.downloadFailed("Could not enumerate installed model files.")
        }
        let prefix = rootURL.standardizedFileURL.path + "/"
        var paths = Set<String>()
        for case let itemURL as URL in enumerator {
            try validateManagedPath(itemURL)
            let values = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw LocalModelManagerError.unsafeArchiveEntry(itemURL.path)
            }
            guard values.isRegularFile == true else { continue }
            let path = itemURL.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw LocalModelManagerError.unsafeArchiveEntry(itemURL.path)
            }
            paths.insert(String(path.dropFirst(prefix.count)))
        }
        return paths
    }

    private func validatedDestinationURL(for model: LocalModelDescriptor) throws -> URL {
        if let version = model.version {
            try validateRelativePath(model.id)
            try validateRelativePath(version)
            if let storageNamespace = model.storageNamespace {
                try validateRelativePath(storageNamespace)
            }
            guard model.storageRelativePath == model.canonicalStorageRelativePath else {
                throw LocalModelManagerError.invalidRelativePath(model.storageRelativePath)
            }
        }
        for requirement in model.requiredFiles {
            try validateRelativePath(requirement.relativePath)
        }
        if let archiveRootDirectory = model.archiveRootDirectory {
            try validateRelativePath(archiveRootDirectory)
        }
        return try validatedURL(relativePath: model.storageRelativePath)
    }

    private func validatedURL(relativePath: String) throws -> URL {
        try validateRelativePath(relativePath)
        let candidate = rootDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard isContained(candidate, in: rootDirectory) else {
            throw LocalModelManagerError.invalidRelativePath(relativePath)
        }
        return try validatedManagedURL(candidate)
    }

    private func validateRelativePath(_ path: String, allowTrailingSlash: Bool = false) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            throw LocalModelManagerError.unsafeArchiveEntry(path)
        }
        let normalized = allowTrailingSlash && path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalModelManagerError.unsafeArchiveEntry(path)
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func validatedManagedURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard isContained(candidate, in: rootDirectory) else {
            throw LocalModelManagerError.invalidRelativePath(candidate.path)
        }
        try validateManagedPath(candidate)
        return candidate
    }

    private func validateManagedModelPaths(_ model: LocalModelDescriptor, at modelURL: URL) throws {
        try validateManagedPath(modelURL)
        for requirement in model.requiredFiles {
            try validateRelativePath(requirement.relativePath)
            let fileURL = modelURL.appendingPathComponent(requirement.relativePath, isDirectory: false)
            guard isContained(fileURL, in: modelURL) else {
                throw LocalModelManagerError.invalidRelativePath(requirement.relativePath)
            }
            try validateManagedPath(fileURL)
        }
    }

    private func validateManagedPath(_ url: URL) throws {
        let candidate = url.standardizedFileURL
        guard isContained(candidate, in: rootDirectory) else {
            throw LocalModelManagerError.invalidRelativePath(candidate.path)
        }
        if try isSymbolicLink(at: rootDirectory) {
            throw LocalModelManagerError.invalidRelativePath(candidate.path)
        }

        var current = rootDirectory
        for component in candidate.pathComponents.dropFirst(rootDirectory.pathComponents.count) {
            current.appendPathComponent(component)
            if try isSymbolicLink(at: current) {
                throw LocalModelManagerError.invalidRelativePath(candidate.path)
            }
        }
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        var itemStatus = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &itemStatus)
        }
        if result == 0 {
            return itemStatus.st_mode & S_IFMT == S_IFLNK
        }

        let inspectionError = errno
        if inspectionError == ENOENT || inspectionError == ENOTDIR {
            return false
        }
        throw LocalModelManagerError.downloadFailed(
            "Could not inspect local model path \(url.path): \(String(cString: strerror(inspectionError)))"
        )
    }

    private func createManagedDirectory(at url: URL) throws {
        try validateManagedPath(url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func copyManagedItem(at sourceURL: URL, to destinationURL: URL) throws {
        try validateManagedPath(sourceURL)
        try validateManagedPath(destinationURL)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func moveManagedItem(at sourceURL: URL, to destinationURL: URL) throws {
        try validateManagedPath(sourceURL)
        try validateManagedPath(destinationURL)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func removeManagedItem(at url: URL) throws {
        try validateManagedPath(url)
        try fileManager.removeItem(at: url)
    }

    private func removeManagedItemIfPresent(at url: URL) throws {
        try validateManagedPath(url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func rollbackURL(for destinationURL: URL) throws -> URL {
        try validatedManagedURL(destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).rollback", isDirectory: destinationURL.hasDirectoryPath)
        )
    }

    private func uniqueSiblingURL(of destinationURL: URL, label: String) throws -> URL {
        try validatedManagedURL(destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(label).\(UUID().uuidString)")
        )
    }

    private func isArchiveDownload(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".tar.bz2") || path.hasSuffix(".tbz2") || path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz")
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func reportProgress(
        modelID: String,
        statusKey: String,
        downloaded: Int64,
        total: Int64?,
        startedAt: Date,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let progress = total.map { max(0, min(1, Double(downloaded) / Double($0))) } ?? 0
        let speed = Double(downloaded) / elapsed
        setActiveStatus(
            .downloading(
                progress: progress,
                downloadedBytes: downloaded,
                totalBytes: total,
                speedBytesPerSecond: speed
            ),
            for: statusKey
        )
        continuation.yield(
            ModelDownloadProgress(
                modelID: modelID,
                progress: progress,
                downloadedBytes: downloaded,
                totalBytes: total,
                speedBytesPerSecond: speed,
                statusMessage: "Downloading"
            )
        )
    }

    private func operationKey(for model: LocalModelDescriptor) -> String {
        rootDirectory.appendingPathComponent(model.storageRelativePath).standardizedFileURL.path
    }

    private func activeStatus(for key: String) -> LocalModelStatus? {
        inMemoryStatuses.withLock { $0[key] }
    }

    private func setActiveStatus(_ status: LocalModelStatus?, for key: String) {
        inMemoryStatuses.withLock { $0[key] = status }
    }
}

/// One archive command owns its Process, bounded merged output, and reader.
/// Cleanup completion requires both actual exit observation and reader closure.
private final class ModelArchiveTarProcess: Sendable {
    private enum Event: Sendable { case bytes(Data), outputClosed, exited(Int32) }
    private enum ReaderPhase: Sendable, Equatable { case unattached, active, stopping, stopped }
    private enum Completion: Sendable { case exit, reader }
    private struct CleanupWork: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }
    private struct State: Sendable {
        var cleanup: CleanupWork?
        var started = false
        var exitObserved = false
        var reader: ReaderPhase = .unattached
        var exitWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
        var readerWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private enum Failure: LocalizedError {
        case outputLimit, eventOverflow, incompleteOutput, readerSetup, cleanupIncomplete(Int32)
        var errorDescription: String? {
            switch self {
            case .outputLimit: return "Archive output exceeded 1048576 bytes"
            case .eventOverflow: return "Archive output event buffer overflow"
            case .incompleteOutput: return "Archive command ended before exit and pipe drain"
            case .readerSetup: return "Could not configure the bounded archive pipe reader"
            case .cleanupIncomplete(let pid): return "Archive process cleanup incomplete pid=\(pid)"
            }
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let process: Process
    private let output = Pipe()
    private let events = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
    private let operation: String
    private let readerSource: any DispatchSourceRead
    private let readWillBegin: (@Sendable () -> Void)?
    private let cleanupWillBegin: (@Sendable () async -> Void)?
    private let cleanupRequestDidRegister: (@Sendable (Bool) -> Void)?

    init(process: Process, operation: String,
         readWillBegin: (@Sendable () -> Void)? = nil,
         cleanupWillBegin: (@Sendable () async -> Void)? = nil,
         cleanupRequestDidRegister: (@Sendable (Bool) -> Void)? = nil) {
        self.process = process
        self.operation = operation
        self.readWillBegin = readWillBegin
        self.cleanupWillBegin = cleanupWillBegin
        self.cleanupRequestDidRegister = cleanupRequestDidRegister
        process.standardOutput = output
        process.standardError = output
        readerSource = DispatchSource.makeReadSource(fileDescriptor: output.fileHandleForReading.fileDescriptor,
            queue: DispatchQueue(label: "Hireva.ModelArchiveReader.\(UUID().uuidString)"))
        readerSource.setEventHandler { [self] in readAvailableOutput() }
        readerSource.setCancelHandler { [self] in
            // Dispatch guarantees this runs after the last event handler and
            // after it released references to the monitored descriptor.
            try? output.fileHandleForReading.close()
            markCompleted(.reader)
            emit(.outputClosed)
        }
    }

    var isFullyStopped: Bool {
        state.withLock { (!$0.started || $0.exitObserved) && $0.reader == .stopped }
    }

    func run() async throws -> String {
        var collected = Data()
        var exitStatus: Int32?
        var pipeClosed = false
        var failure: Error?
        await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                process.terminationHandler = { [self] exited in
                    markCompleted(.exit)
                    emit(.exited(exited.terminationStatus))
                }
                do { try process.run() }
                catch {
                    throw LocalModelManagerError.downloadFailed(
                        "Failed to start model \(operation): \(error.localizedDescription)")
                }
                state.withLock { $0.started = true }
                // The child has its own duplicated write descriptor. Closing
                // the parent's writer ensures actual child EOF is observable.
                try? output.fileHandleForWriting.close()
                try attachReader()
                for try await event in events.stream {
                    try Task.checkCancellation()
                    switch event {
                    case .bytes(let bytes):
                        guard bytes.count <= 1_048_576 - collected.count else { throw Failure.outputLimit }
                        collected.append(bytes)
                    case .outputClosed: pipeClosed = true
                    case .exited(let status): exitStatus = status
                    }
                    if pipeClosed, exitStatus != nil { break }
                }
                try Task.checkCancellation()
                guard pipeClosed, exitStatus != nil else { throw Failure.incompleteOutput }
            } catch { failure = error }
        } onCancel: {
            // Only wake this invocation. Its retained cleanup awaits the exact
            // process and reader; cancellation does not dispose of their owner.
            events.continuation.finish(throwing: CancellationError())
        }
        let stopped = await finishStopping()
        guard stopped else { throw Failure.cleanupIncomplete(process.processIdentifier) }
        if Task.isCancelled || failure.map({ $0 is CancellationError }) == true { throw CancellationError() }
        if let failure { throw failure }
        guard let exitStatus, exitStatus == 0 else {
            let message = String(data: collected, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalModelManagerError.downloadFailed(
                "Model \(operation) failed with exit \(exitStatus ?? -1): \(message ?? "unknown tar error")")
        }
        guard let text = String(data: collected, encoding: .utf8) else {
            throw LocalModelManagerError.downloadFailed("Model \(operation) emitted invalid UTF-8.")
        }
        return text
    }

    /// The retained local cleanup Task does not inherit caller cancellation.
    /// Every child timer is cancelled and joined; no cleanup Task is abandoned.
    func finishStopping() async -> Bool {
        // Concurrent drains borrow one exact attempt. Its body, not its first
        // waiter, retires the handle before publishing the result. A failed
        // completed attempt therefore remains recoverable by a later request.
        let registered = state.withLock { state -> (task: Task<Bool, Never>, joined: Bool) in
            if let cleanup = state.cleanup { return (cleanup.task, true) }
            let id = UUID()
            let task = Task { [self] in
                await cleanupWillBegin?()
                let stopped = await stopAndDrain()
                self.state.withLock { state in
                    if state.cleanup?.id == id { state.cleanup = nil }
                }
                return stopped
            }
            state.cleanup = CleanupWork(id: id, task: task)
            return (task, false)
        }
        cleanupRequestDidRegister?(registered.joined)
        return await registered.task.value
    }

    private func stopAndDrain() async -> Bool {
        if state.withLock({ $0.started }) {
            if process.isRunning { process.terminate() }
            if !(await waitFor(.exit, nanoseconds: 500_000_000)), process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = await waitFor(.exit, nanoseconds: 500_000_000)
            }
        } else {
            try? output.fileHandleForWriting.close()
        }
        stopReader()
        let readerStopped = await waitFor(.reader, nanoseconds: 500_000_000)
        let exited = state.withLock { !$0.started || $0.exitObserved }
        guard exited, readerStopped else { return false }
        process.terminationHandler = nil
        readerSource.setEventHandler(handler: nil)
        readerSource.setCancelHandler(handler: nil)
        events.continuation.finish()
        return true
    }

    private func attachReader() throws {
        let handle = output.fileHandleForReading
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.readerSetup
        }
        state.withLock { $0.reader = .active }
        readerSource.activate()
    }

    private func readAvailableOutput() {
        readWillBegin?()
        // The source uses a private serial queue. Each event reads at most one
        // nonblocking chunk, preserving order without queuing extra work.
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(output.fileHandleForReading.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 { emit(.bytes(Data(buffer.prefix(count)))); return }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        if count < 0 {
            events.continuation.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        state.withLock { $0.reader = .stopping }
        readerSource.cancel()
    }

    private func stopReader() {
        let activate = state.withLock { state -> Bool? in
            switch state.reader {
            case .unattached: state.reader = .stopping; return true
            case .active: state.reader = .stopping; return false
            case .stopping, .stopped: return nil
            }
        }
        guard let activate else { return }
        // Only the cancel handler closes the descriptor. Cancellation waits
        // for a running event callback before invoking that handler.
        if activate { readerSource.activate() }
        readerSource.cancel()
    }

    private func emit(_ event: Event) {
        if case .dropped = events.continuation.yield(event) {
            events.continuation.finish(throwing: Failure.eventOverflow)
        }
    }

    private func markCompleted(_ completion: Completion) {
        let waiting = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            switch completion {
            case .exit:
                state.exitObserved = true
                let waiting = Array(state.exitWaiters.values)
                state.exitWaiters.removeAll()
                return waiting
            case .reader:
                state.reader = .stopped
                let waiting = Array(state.readerWaiters.values)
                state.readerWaiters.removeAll()
                return waiting
            }
        }
        for continuation in waiting { continuation.yield(()); continuation.finish() }
    }

    private func waitFor(_ completion: Completion, nanoseconds: UInt64) async -> Bool {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let done = state.withLock { state -> Bool in
            switch completion {
            case .exit:
                if !state.started || state.exitObserved { return true }
                state.exitWaiters[id] = pair.continuation
            case .reader:
                if state.reader == .stopped { return true }
                state.readerWaiters[id] = pair.continuation
            }
            return false
        }
        if done { pair.continuation.finish(); return true }
        let state = state
        pair.continuation.onTermination = { _ in
            state.withLock { state in
                switch completion {
                case .exit: _ = state.exitWaiters.removeValue(forKey: id)
                case .reader: _ = state.readerWaiters.removeValue(forKey: id)
                }
            }
        }
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
                pair.continuation.finish()
            } catch is CancellationError {} catch { pair.continuation.finish() }
        }
        var iterator = pair.stream.makeAsyncIterator()
        _ = await iterator.next()
        deadline.cancel()
        await deadline.value
        pair.continuation.finish()
        return state.withLock { state in
            switch completion {
            case .exit: return !state.started || state.exitObserved
            case .reader: return state.reader == .stopped
            }
        }
    }
}
