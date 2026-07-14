import CryptoKit
import Darwin
import Foundation

private actor LocalModelOperationGate {
    private var activeKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if activeKeys.insert(key).inserted {
            return
        }

        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        guard var queued = waiters[key], !queued.isEmpty else {
            activeKeys.remove(key)
            waiters[key] = nil
            return
        }

        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

private final class TrustedModelRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

final class FileLocalModelManager: LocalModelManager {
    private static let operationGate = LocalModelOperationGate()

    private enum InstalledValidationError: Error {
        case missing(String)
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let modelSmokeValidator: (LocalModelDescriptor, URL) async throws -> Void
    private let statusLock = NSLock()
    private var inMemoryStatuses: [String: LocalModelStatus] = [:]

    init(
        rootDirectory: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("LocalModels", isDirectory: true),
        fileManager: FileManager = .default,
        modelSmokeValidator: @escaping (LocalModelDescriptor, URL) async throws -> Void = FileLocalModelManager.defaultModelSmokeValidator
    ) {
        self.rootDirectory = Self.resolvedRootDirectory(rootDirectory, fileManager: fileManager)
        self.fileManager = fileManager
        self.modelSmokeValidator = modelSmokeValidator
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
        let key = operationKey(for: model)
        if let active = activeStatus(for: key) {
            return active
        }

        await Self.operationGate.acquire(key)
        let status: LocalModelStatus
        do {
            let destinationURL = try validatedDestinationURL(for: model)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try await migrateLegacyInstallIfAvailable(for: model, to: destinationURL)
            }
            status = installedStatus(model, at: destinationURL)
        } catch {
            status = .failed(error.localizedDescription)
        }
        await Self.operationGate.release(key)
        return status
    }

    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool {
        let key = operationKey(for: model)
        await Self.operationGate.acquire(key)
        do {
            let destinationURL = try validatedDestinationURL(for: model)
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try await migrateLegacyInstallIfAvailable(for: model, to: destinationURL)
            }
            guard fileManager.fileExists(atPath: destinationURL.path) else {
                await Self.operationGate.release(key)
                return false
            }
            try validateInstalledModel(model, at: destinationURL)
            await Self.operationGate.release(key)
            return true
        } catch is InstalledValidationError {
            await Self.operationGate.release(key)
            return false
        } catch let error as LocalModelManagerError {
            await Self.operationGate.release(key)
            switch error {
            case .sizeMismatch, .checksumMismatch, .unsafeArchiveEntry, .downloadFailed:
                return false
            default:
                throw error
            }
        } catch {
            await Self.operationGate.release(key)
            throw error
        }
    }

    func deleteModel(_ model: LocalModelDescriptor) async throws {
        let key = operationKey(for: model)
        await Self.operationGate.acquire(key)
        do {
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
            await Self.operationGate.release(key)
        } catch {
            await Self.operationGate.release(key)
            throw error
        }
    }

    func rollbackModel(_ model: LocalModelDescriptor) async throws {
        let key = operationKey(for: model)
        await Self.operationGate.acquire(key)
        do {
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
            await Self.operationGate.release(key)
        } catch {
            await Self.operationGate.release(key)
            throw error
        }
    }

    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        modelDownloadStream(model)
    }

    func repairModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        modelDownloadStream(model)
    }

    private func modelDownloadStream(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let key = operationKey(for: model)
                await Self.operationGate.acquire(key)
                do {
                    try Task.checkCancellation()
                    try await installDownloadedModel(model, statusKey: key, continuation: continuation)
                    setActiveStatus(nil, for: key)
                    continuation.yield(.completed(modelID: model.id, totalBytes: model.sizeBytes))
                    await Self.operationGate.release(key)
                    continuation.finish()
                } catch {
                    setActiveStatus(nil, for: key)
                    await Self.operationGate.release(key)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
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
            defer { try? removeManagedItemIfPresent(at: archiveURL) }
            try await transferFile(
                from: sourceURL,
                to: archiveURL,
                model: model,
                statusKey: statusKey,
                continuation: continuation
            )
            try validateArchive(archiveURL, for: model)
            try preflightArchive(archiveURL, for: model)

            let extractionRoot = try uniqueSiblingURL(of: destinationURL, label: "staging")
            defer { try? removeManagedItemIfPresent(at: extractionRoot) }
            try createManagedDirectory(at: extractionRoot)
            try validateManagedPath(archiveURL)
            try validateManagedPath(extractionRoot)
            try runTar(["-xf", archiveURL.path, "-C", extractionRoot.path], operation: "extraction")
            try validateExtractedTree(at: extractionRoot)

            let stagedModelURL = try extractedModelDirectory(in: extractionRoot, for: model)
            try validateInstalledModel(model, at: stagedModelURL)
            try await modelSmokeValidator(model, stagedModelURL)
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

    private func preflightArchive(_ archiveURL: URL, for model: LocalModelDescriptor) throws {
        let listing = try runTar(["-tf", archiveURL.path], operation: "preflight")
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

        let verboseListing = try runTar(["-tvf", archiveURL.path], operation: "type preflight")
        for line in verboseListing.split(whereSeparator: \.isNewline) {
            guard let type = line.first, type == "-" || type == "d" else {
                throw LocalModelManagerError.unsafeArchiveEntry(String(line))
            }
        }
    }

    @discardableResult
    private func runTar(_ arguments: [String], operation: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw LocalModelManagerError.downloadFailed("Failed to start model \(operation): \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalModelManagerError.downloadFailed(
                "Model \(operation) failed with exit \(process.terminationStatus): \(message ?? "unknown tar error")"
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalModelManagerError.downloadFailed("Model \(operation) emitted invalid UTF-8.")
        }
        return text
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
        statusLock.lock()
        defer { statusLock.unlock() }
        return inMemoryStatuses[key]
    }

    private func setActiveStatus(_ status: LocalModelStatus?, for key: String) {
        statusLock.lock()
        defer { statusLock.unlock() }
        inMemoryStatuses[key] = status
    }
}
