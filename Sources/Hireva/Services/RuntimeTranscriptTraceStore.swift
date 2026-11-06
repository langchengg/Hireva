import Foundation
import os

final class RuntimeTranscriptTraceStore: Sendable {
    static let shared = RuntimeTranscriptTraceStore()
    static let maxTraceFileSize = 25 * 1_024 * 1_024
    static let maxTraceFiles = 5

    private let queue = DispatchQueue(
        label: "com.langcheng.Hireva.runtime-transcript-trace",
        qos: .utility
    )
    // File-family IO remains serial. Only copied privacy-mode metadata enters
    // this checked lock, never a FileHandle, IO callback or suspended operation.
    private let preparedModes = OSAllocatedUnfairLock(initialState: [String: DiagnosticTraceMode]())
    static let maxPendingWriteCount = 256
    static let maxPendingWriteBytes = 1_024 * 1_024
    private let pendingWriteLimit: Int
    private let pendingByteLimit: Int
    private let compatibilityAdmission: WriteAdmission
    #if DEBUG
    private let beforeAppendForTesting: (@Sendable (URL) -> Void)?
    // Observational checkpoint used only when the later owned drain suspends.
    private let ownedDrainWaitingForTesting: (@Sendable () -> Void)?

    init(maxPendingWriteCount: Int = RuntimeTranscriptTraceStore.maxPendingWriteCount,
         maxPendingWriteBytes: Int = RuntimeTranscriptTraceStore.maxPendingWriteBytes,
         beforeAppendForTesting: (@Sendable (URL) -> Void)? = nil,
         ownedDrainWaitingForTesting: (@Sendable () -> Void)? = nil) {
        precondition(maxPendingWriteCount > 0 && maxPendingWriteBytes > 0)
        pendingWriteLimit = maxPendingWriteCount
        pendingByteLimit = maxPendingWriteBytes
        compatibilityAdmission = WriteAdmission(countLimit: maxPendingWriteCount, byteLimit: maxPendingWriteBytes)
        self.beforeAppendForTesting = beforeAppendForTesting
        self.ownedDrainWaitingForTesting = ownedDrainWaitingForTesting
    }

    // The RED fixture's store is private. This asynchronous barrier joins its
    // real queued file operations on success, failure and owning cancellation.
    func finishPendingOperationsForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    #else
    init(maxPendingWriteCount: Int = RuntimeTranscriptTraceStore.maxPendingWriteCount,
         maxPendingWriteBytes: Int = RuntimeTranscriptTraceStore.maxPendingWriteBytes) {
        precondition(maxPendingWriteCount > 0 && maxPendingWriteBytes > 0)
        pendingWriteLimit = maxPendingWriteCount
        pendingByteLimit = maxPendingWriteBytes
        compatibilityAdmission = WriteAdmission(countLimit: maxPendingWriteCount, byteLimit: maxPendingWriteBytes)
    }
    #endif

    enum AppendDisposition: Equatable, Sendable {
        case admitted, disabled, overflow, sealed
    }

    struct WriteSnapshot: Equatable, Sendable {
        var pendingWriteCount = 0
        var pendingByteCount = 0
        var peakPendingWriteCount = 0
        var peakPendingByteCount = 0
        var completedWriteCount = 0
        var failedWriteCount = 0
        var overflowRejectedCount = 0
        var sealedRejectedCount = 0
        var isSealed = false
    }

    /// A Diagnostics instance owns this concrete admission/drain capability.
    /// Mutable URL selection is frozen per append, not consulted by the worker.
    /// Sealing this capability does not close any other writer or the shared IO.
    final class Writer: Sendable {
        private let store: RuntimeTranscriptTraceStore
        private let admission: WriteAdmission
        fileprivate init(store: RuntimeTranscriptTraceStore, admission: WriteAdmission) {
            self.store = store
            self.admission = admission
        }
        var snapshot: WriteSnapshot { admission.snapshot }
        @discardableResult
        func append(line: String?, to url: URL, mode: DiagnosticTraceMode) -> AppendDisposition {
            store.enqueue(line: line, to: url, mode: mode, admission: admission)
        }
        func seal() { admission.seal() }
        func drain() async {
            #if DEBUG
            await admission.drain(onWaiting: store.ownedDrainWaitingForTesting)
            #else
            await admission.drain()
            #endif
        }
        func sealAndDrain() async {
            seal() // Revoke admission synchronously before the first await.
            await drain()
        }
    }

    func makeWriter() -> Writer {
        Writer(store: self, admission: WriteAdmission(countLimit: pendingWriteLimit, byteLimit: pendingByteLimit))
    }

    // Direct legacy callers share one bounded compatibility admission, then use
    // exactly the same IO implementation as each owned Diagnostics writer.
    var compatibilityWriteSnapshot: WriteSnapshot { compatibilityAdmission.snapshot }
    @discardableResult
    func append(line: String, to url: URL) -> AppendDisposition {
        append(line: line, to: url, mode: .fullText)
    }
    @discardableResult
    func append(line: String?, to url: URL, mode: DiagnosticTraceMode) -> AppendDisposition {
        enqueue(line: line, to: url, mode: mode, admission: compatibilityAdmission)
    }

    private func enqueue(line: String?, to url: URL, mode: DiagnosticTraceMode,
                         admission: WriteAdmission) -> AppendDisposition {
        guard mode != .off, let line else { return .disabled }
        let (bytes, overflow) = line.utf8.count.addingReportingOverflow(1)
        let disposition = admission.reserve(byteCount: overflow ? nil : bytes)
        guard disposition == .admitted else { return disposition }
        // Reserve the full UTF-8 payload before allocating retained Data. Bounds
        // include the admitted in-flight write until its FileHandle has exited.
        var encoded = Data(line.utf8)
        encoded.append(0x0A)
        let data = encoded
        queue.async {
            #if DEBUG
            self.beforeAppendForTesting?(url)
            #endif
            var failed = false
            do {
                try self.append(data: data, to: url)
            } catch {
                failed = true
                print("[RuntimeTranscriptTraceStore] Write failed: code=\((error as NSError).code)")
            }
            admission.finish(byteCount: bytes, failed: failed)
        }
        return .admitted
    }

    fileprivate final class WriteAdmission: Sendable {
        private struct State: Sendable {
            var snapshot = WriteSnapshot()
            var drainWaiters: [CheckedContinuation<Void, Never>] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let countLimit: Int
        private let byteLimit: Int
        init(countLimit: Int, byteLimit: Int) {
            self.countLimit = countLimit
            self.byteLimit = byteLimit
        }
        var snapshot: WriteSnapshot { state.withLock { $0.snapshot } }
        func reserve(byteCount: Int?) -> AppendDisposition {
            state.withLock {
                if $0.snapshot.isSealed {
                    $0.snapshot.sealedRejectedCount += 1
                    return .sealed
                }
                guard let byteCount, byteCount <= byteLimit,
                      $0.snapshot.pendingWriteCount < countLimit,
                      byteCount <= byteLimit - $0.snapshot.pendingByteCount else {
                    $0.snapshot.overflowRejectedCount += 1
                    return .overflow
                }
                $0.snapshot.pendingWriteCount += 1
                $0.snapshot.pendingByteCount += byteCount
                $0.snapshot.peakPendingWriteCount = max($0.snapshot.peakPendingWriteCount, $0.snapshot.pendingWriteCount)
                $0.snapshot.peakPendingByteCount = max($0.snapshot.peakPendingByteCount, $0.snapshot.pendingByteCount)
                return .admitted
            }
        }
        func finish(byteCount: Int, failed: Bool) {
            let waiters = state.withLock {
                $0.snapshot.pendingWriteCount -= 1
                $0.snapshot.pendingByteCount -= byteCount
                $0.snapshot.completedWriteCount += 1
                if failed { $0.snapshot.failedWriteCount += 1 }
                guard $0.snapshot.pendingWriteCount == 0 else { return [CheckedContinuation<Void, Never>]() }
                let captured = $0.drainWaiters
                $0.drainWaiters.removeAll()
                return captured
            }
            waiters.forEach { $0.resume() }
        }
        func seal() { state.withLock { $0.snapshot.isSealed = true } }
        func drain(onWaiting: (@Sendable () -> Void)? = nil) async {
            await withCheckedContinuation { continuation in
                let waiting = state.withLock {
                    guard $0.snapshot.pendingWriteCount > 0 else { return false }
                    $0.drainWaiters.append(continuation)
                    return true
                }
                // No ordinary lock spans await or arbitrary callbacks.
                if waiting { onWaiting?() }
                else { continuation.resume() }
            }
        }
    }

    func prepareForMode(_ mode: DiagnosticTraceMode, at url: URL) {
        queue.sync {
            let previousMode = preparedModes.withLock { $0[url.path] }
            if mode != .fullText, previousMode == nil || previousMode != mode {
                do {
                    try clearTraceFilesImmediately(at: url)
                } catch {
                    print("[RuntimeTranscriptTraceStore] Cleanup failed: code=\((error as NSError).code)")
                }
            }
            preparedModes.withLock { $0[url.path] = mode }
        }
    }

    func clearTraceFiles(at url: URL) throws {
        try queue.sync {
            try clearTraceFilesImmediately(at: url)
            preparedModes.withLock { $0[url.path] = .off }
        }
    }

    func waitForPendingOperations() {
        queue.sync {}
    }

    private func append(data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileExists = fileManager.fileExists(atPath: url.path)
        // URL resource values can retain a stale size across background appends.
        let currentSize = fileExists
            ? ((try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
            : 0
        if currentSize > 0,
           currentSize + data.count > Self.maxTraceFileSize {
            try rotate(url: url, fileManager: fileManager)
        }

        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func rotate(url: URL, fileManager: FileManager) throws {
        let archiveCount = max(Self.maxTraceFiles - 1, 0)
        guard archiveCount > 0 else {
            try? fileManager.removeItem(at: url)
            return
        }

        // Remove stale files beyond the configured total-file cap.
        for index in archiveCount...Self.maxTraceFiles {
            let staleURL = rotatedURL(for: url, index: index)
            if fileManager.fileExists(atPath: staleURL.path) {
                try fileManager.removeItem(at: staleURL)
            }
        }

        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let sourceURL = rotatedURL(for: url, index: index)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL = rotatedURL(for: url, index: index + 1)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        let firstArchiveURL = rotatedURL(for: url, index: 1)
        if fileManager.fileExists(atPath: firstArchiveURL.path) {
            try fileManager.removeItem(at: firstArchiveURL)
        }
        try fileManager.moveItem(at: url, to: firstArchiveURL)
    }

    private func rotatedURL(for url: URL, index: Int) -> URL {
        url.deletingPathExtension().appendingPathExtension("\(index).jsonl")
    }

    private func clearTraceFilesImmediately(at url: URL) throws {
        let fileManager = FileManager.default
        let candidates = [url] + (1...Self.maxTraceFiles).map {
            rotatedURL(for: url, index: $0)
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }
}
