import Foundation

final class FileLocalModelManager: LocalModelManager {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let statusLock = NSLock()
    private var inMemoryStatuses: [String: LocalModelStatus] = [:]

    init(
        rootDirectory: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("LocalModels", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func fileURL(for model: LocalModelDescriptor) -> URL {
        rootDirectory.appendingPathComponent(model.storageRelativePath, isDirectory: false)
    }

    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus {
        if let active = activeStatus(for: model.id) {
            return active
        }
        let url = fileURL(for: model)
        if !model.requiredFiles.isEmpty {
            return directoryModelStatus(model, rootURL: url)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return .notInstalled
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > 0 {
                return .installed
            }
            return .failed("Model file is empty.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool {
        if model.checksum != nil {
            throw LocalModelManagerError.checksumUnsupported
        }
        return await modelStatus(model).isReady
    }

    func deleteModel(_ model: LocalModelDescriptor) async throws {
        let url = fileURL(for: model)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        setActiveStatus(nil, for: model.id)
    }

    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let sourceURL = model.downloadURL else {
                        throw LocalModelManagerError.missingDownloadURL(model.displayName)
                    }
                    let destinationURL = fileURL(for: model)
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )

                    if sourceURL.isFileURL {
                        try await copyLocalFile(
                            from: sourceURL,
                            to: destinationURL,
                            model: model,
                            continuation: continuation
                        )
                    } else {
                        try await downloadRemoteFile(
                            from: sourceURL,
                            to: destinationURL,
                            model: model,
                            continuation: continuation
                        )
                    }

                    setActiveStatus(.installed, for: model.id)
                    continuation.yield(.completed(modelID: model.id, totalBytes: model.sizeBytes))
                    continuation.finish()
                } catch {
                    setActiveStatus(.failed(error.localizedDescription), for: model.id)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func copyLocalFile(
        from sourceURL: URL,
        to destinationURL: URL,
        model: LocalModelDescriptor,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
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
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LocalModelManagerError.downloadFailed("Download failed with HTTP \(http.statusCode).")
        }
        let totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : model.sizeBytes
        fileManager.createFile(atPath: destinationURL.path, contents: nil)
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
                downloaded: downloaded,
                total: totalBytes,
                startedAt: startedAt,
                continuation: continuation
            )
        }
    }

    private func reportProgress(
        modelID: String,
        downloaded: Int64,
        total: Int64?,
        startedAt: Date,
        continuation: AsyncThrowingStream<ModelDownloadProgress, Error>.Continuation
    ) {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let progress = total.map { max(0, min(1, Double(downloaded) / Double($0))) } ?? 0
        let speed = Double(downloaded) / elapsed
        let status = LocalModelStatus.downloading(
            progress: progress,
            downloadedBytes: downloaded,
            totalBytes: total,
            speedBytesPerSecond: speed
        )
        setActiveStatus(status, for: modelID)
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

    private func activeStatus(for modelID: String) -> LocalModelStatus? {
        statusLock.lock()
        defer { statusLock.unlock() }
        return inMemoryStatuses[modelID]
    }

    private func directoryModelStatus(_ model: LocalModelDescriptor, rootURL: URL) -> LocalModelStatus {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notInstalled
        }

        for requirement in model.requiredFiles {
            let fileURL = rootURL.appendingPathComponent(requirement.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return .notInstalled
            }

            guard let minimumBytes = requirement.minimumBytes else { continue }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                if actualBytes < minimumBytes {
                    return .failed("\(requirement.relativePath) is incomplete: \(actualBytes) bytes, expected at least \(minimumBytes).")
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        return .installed
    }

    private func setActiveStatus(_ status: LocalModelStatus?, for modelID: String) {
        statusLock.lock()
        defer { statusLock.unlock() }
        inMemoryStatuses[modelID] = status
    }
}
