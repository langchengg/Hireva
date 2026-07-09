import Foundation

final class RuntimeTranscriptTraceStore: @unchecked Sendable {
    static let shared = RuntimeTranscriptTraceStore()
    static let maxTraceFileSize = 25 * 1_024 * 1_024
    static let maxTraceFiles = 5

    private let queue = DispatchQueue(
        label: "com.langcheng.InterviewCopilotMac.runtime-transcript-trace",
        qos: .utility
    )

    func append(line: String, to url: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async {
            do {
                try self.append(data: data, to: url)
            } catch {
                print("[RuntimeTranscriptTraceStore] Write failed: \(error.localizedDescription)")
            }
        }
    }

    private func append(data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileExists = fileManager.fileExists(atPath: url.path)
        let currentSize = fileExists
            ? (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            : 0
        if currentSize > 0,
           currentSize + data.count > Self.maxTraceFileSize {
            try rotate(url: url, fileManager: fileManager)
        }

        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
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
}
