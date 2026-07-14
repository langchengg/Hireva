import Foundation

enum SoakResourceMetricsError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidArguments(String)
    case commandFailed(String)
    case invalidLifecycleMetrics(String)
    case targetNotObserved(processName: String)
    case unexpectedTargetProcessCount(processName: String, actual: Int)
    case targetDisappeared(processName: String, consecutiveSamples: Int)
    case insufficientSampleCoverage(expected: Int, observed: Int, minimum: Double)
    case collectionErrorLimitExceeded(actual: Int, maximum: Int)
    case rowExceedsFileLimit

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidArguments(let message):
            return message
        case .commandFailed(let executable):
            return "Resource metrics command failed: \(executable)"
        case .invalidLifecycleMetrics(let message):
            return message
        case .targetNotObserved(let processName):
            return "Resource soak failed: no running \(processName) process was observed."
        case .unexpectedTargetProcessCount(let processName, let actual):
            return "Resource soak failed: expected exactly one \(processName) process, observed \(actual)."
        case .targetDisappeared(let processName, let consecutiveSamples):
            return "Resource soak failed: \(processName) was missing for \(consecutiveSamples) consecutive samples."
        case .insufficientSampleCoverage(let expected, let observed, let minimum):
            let percentage = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), minimum * 100)
            return "Resource soak failed: exact-target sample coverage was \(observed)/\(expected); required at least \(percentage)%."
        case .collectionErrorLimitExceeded(let actual, let maximum):
            return "Resource soak failed: collection errors \(actual) exceeded the allowed maximum of \(maximum)."
        case .rowExceedsFileLimit:
            return "A resource metrics CSV header and row exceed the configured file-size limit."
        }
    }
}

struct SoakResourceMetricsConfiguration: Equatable {
    static let minimumIntervalSeconds = 5.0
    static let maximumIntervalSeconds = 10.0
    static let maximumDurationSeconds = 86_400.0
    static let minimumFileSizeBytes = 1_024
    static let maximumFileSizeBytes = 64 * 1_024 * 1_024
    static let maximumFileCount = 10
    static let defaultMinimumSampleCoverage = 0.9
    static let defaultMaximumCollectionErrorCount = 3
    static let defaultMaximumConsecutiveMissingAppSamples = 3

    let outputURL: URL
    let processName: String
    let helperProcessNames: Set<String>
    let databaseURL: URL?
    let traceURL: URL?
    let lifecycleMetricsURL: URL?
    let sqliteExecutableURL: URL?
    let intervalSeconds: Double
    let durationSeconds: Double
    let maximumFileSizeBytes: Int
    let maximumFileCount: Int
    let minimumSampleCoverage: Double
    let maximumCollectionErrorCount: Int
    let maximumConsecutiveMissingAppSamples: Int

    init(
        outputURL: URL,
        processName: String,
        helperProcessNames: Set<String> = [],
        databaseURL: URL? = nil,
        traceURL: URL? = nil,
        lifecycleMetricsURL: URL? = nil,
        sqliteExecutableURL: URL? = nil,
        intervalSeconds: Double = 5,
        durationSeconds: Double = 300,
        maximumFileSizeBytes: Int = 5 * 1_024 * 1_024,
        maximumFileCount: Int = 4,
        minimumSampleCoverage: Double = Self.defaultMinimumSampleCoverage,
        maximumCollectionErrorCount: Int = Self.defaultMaximumCollectionErrorCount,
        maximumConsecutiveMissingAppSamples: Int = Self.defaultMaximumConsecutiveMissingAppSamples
    ) throws {
        guard outputURL.pathExtension.lowercased() == "csv" else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics output must use a .csv extension.")
        }
        guard !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics process name must not be empty.")
        }
        guard Self.minimumIntervalSeconds...Self.maximumIntervalSeconds ~= intervalSeconds else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics interval must be between 5 and 10 seconds.")
        }
        guard durationSeconds >= intervalSeconds,
              durationSeconds <= Self.maximumDurationSeconds else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics duration must be at least one interval and at most 24 hours.")
        }
        guard Self.minimumFileSizeBytes...Self.maximumFileSizeBytes ~= maximumFileSizeBytes else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics file-size limit must be between 1 KiB and 64 MiB.")
        }
        guard 1...Self.maximumFileCount ~= maximumFileCount else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics file-count limit must be between 1 and 10.")
        }
        guard minimumSampleCoverage > 0, minimumSampleCoverage <= 1 else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics sample coverage must be greater than 0 and at most 1.")
        }
        guard maximumCollectionErrorCount >= 0 else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics collection-error limit must not be negative.")
        }
        guard maximumConsecutiveMissingAppSamples >= 2 else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics missing-app limit must be at least two consecutive samples.")
        }

        self.outputURL = outputURL
        self.processName = processName
        self.helperProcessNames = helperProcessNames
        self.databaseURL = databaseURL
        self.traceURL = traceURL
        self.lifecycleMetricsURL = lifecycleMetricsURL
        self.sqliteExecutableURL = sqliteExecutableURL
        self.intervalSeconds = intervalSeconds
        self.durationSeconds = durationSeconds
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.maximumFileCount = maximumFileCount
        self.minimumSampleCoverage = minimumSampleCoverage
        self.maximumCollectionErrorCount = maximumCollectionErrorCount
        self.maximumConsecutiveMissingAppSamples = maximumConsecutiveMissingAppSamples
    }
}

struct SoakProcessRecord: Equatable {
    let processID: Int32
    let parentProcessID: Int32
    let cpuPercent: Double
    let residentBytes: UInt64
    let executableName: String
}

enum SoakProcessListParser {
    static func parse(_ output: String) -> [SoakProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 5,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1]),
                  let cpuPercent = Double(fields[2]),
                  let residentKiB = UInt64(fields[3]) else {
                return nil
            }

            let residentBytes: UInt64
            let multiplied = residentKiB.multipliedReportingOverflow(by: 1_024)
            residentBytes = multiplied.overflow ? UInt64.max : multiplied.partialValue

            return SoakProcessRecord(
                processID: processID,
                parentProcessID: parentProcessID,
                cpuPercent: cpuPercent,
                residentBytes: residentBytes,
                executableName: URL(fileURLWithPath: String(fields[4])).lastPathComponent
            )
        }
    }
}

struct SoakProcessSnapshot: Equatable {
    let appProcessIDs: Set<Int32>
    let appCPUPercent: Double
    let appResidentBytes: UInt64
    let helperProcessIDs: Set<Int32>
    let helperCPUPercent: Double
    let helperResidentBytes: UInt64
    let ollamaProcessIDs: Set<Int32>
    let ollamaCPUPercent: Double
    let ollamaResidentBytes: UInt64

    var primaryAppProcessID: Int32? { appProcessIDs.min() }

    static func make(
        records: [SoakProcessRecord],
        processName: String,
        helperProcessNames: Set<String>
    ) -> SoakProcessSnapshot {
        let appRecords = records.filter { $0.executableName == processName }
        let appProcessIDs = Set(appRecords.map(\.processID))
        let ollamaRecords = records.filter { $0.executableName == "ollama" }
        let ollamaProcessIDs = Set(ollamaRecords.map(\.processID))

        var descendantProcessIDs = Set<Int32>()
        var parents = appProcessIDs
        while !parents.isEmpty {
            let children = Set(records.lazy
                .filter { parents.contains($0.parentProcessID) }
                .map(\.processID))
                .subtracting(descendantProcessIDs)
                .subtracting(appProcessIDs)
            guard !children.isEmpty else { break }
            descendantProcessIDs.formUnion(children)
            parents = children
        }

        let helperRecords = records.filter { record in
            !appProcessIDs.contains(record.processID) &&
                !ollamaProcessIDs.contains(record.processID) &&
                (descendantProcessIDs.contains(record.processID) || helperProcessNames.contains(record.executableName))
        }

        return SoakProcessSnapshot(
            appProcessIDs: appProcessIDs,
            appCPUPercent: appRecords.reduce(0) { $0 + $1.cpuPercent },
            appResidentBytes: saturatingResidentBytes(appRecords),
            helperProcessIDs: Set(helperRecords.map(\.processID)),
            helperCPUPercent: helperRecords.reduce(0) { $0 + $1.cpuPercent },
            helperResidentBytes: saturatingResidentBytes(helperRecords),
            ollamaProcessIDs: ollamaProcessIDs,
            ollamaCPUPercent: ollamaRecords.reduce(0) { $0 + $1.cpuPercent },
            ollamaResidentBytes: saturatingResidentBytes(ollamaRecords)
        )
    }

    private static func saturatingResidentBytes(_ records: [SoakProcessRecord]) -> UInt64 {
        records.reduce(0) { total, record in
            let sum = total.addingReportingOverflow(record.residentBytes)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }
}

struct SoakLifecycleCounts: Equatable {
    let appRestarts: Int
    let helperRestarts: Int
    let helperCleanups: Int
    let ollamaRestarts: Int
}

struct SoakProcessLifecycleTracker {
    private var previousAppProcessIDs = Set<Int32>()
    private var previousHelperProcessIDs = Set<Int32>()
    private var previousOllamaProcessIDs = Set<Int32>()
    private var hasSeenApp = false
    private var hasSeenHelper = false
    private var hasSeenOllama = false
    private var appRestartCount = 0
    private var helperRestartCount = 0
    private var helperCleanupCount = 0
    private var ollamaRestartCount = 0

    mutating func update(with snapshot: SoakProcessSnapshot) -> SoakLifecycleCounts {
        let appTransition = Self.additions(
            current: snapshot.appProcessIDs,
            previous: previousAppProcessIDs,
            hasSeen: hasSeenApp
        )
        hasSeenApp = appTransition.hasSeen
        appRestartCount += appTransition.count

        let helperTransition = Self.additions(
            current: snapshot.helperProcessIDs,
            previous: previousHelperProcessIDs,
            hasSeen: hasSeenHelper
        )
        hasSeenHelper = helperTransition.hasSeen
        helperRestartCount += helperTransition.count

        let ollamaTransition = Self.additions(
            current: snapshot.ollamaProcessIDs,
            previous: previousOllamaProcessIDs,
            hasSeen: hasSeenOllama
        )
        hasSeenOllama = ollamaTransition.hasSeen
        ollamaRestartCount += ollamaTransition.count
        helperCleanupCount += previousHelperProcessIDs.subtracting(snapshot.helperProcessIDs).count

        previousAppProcessIDs = snapshot.appProcessIDs
        previousHelperProcessIDs = snapshot.helperProcessIDs
        previousOllamaProcessIDs = snapshot.ollamaProcessIDs

        return SoakLifecycleCounts(
            appRestarts: appRestartCount,
            helperRestarts: helperRestartCount,
            helperCleanups: helperCleanupCount,
            ollamaRestarts: ollamaRestartCount
        )
    }

    private static func additions(
        current: Set<Int32>,
        previous: Set<Int32>,
        hasSeen: Bool
    ) -> (count: Int, hasSeen: Bool) {
        guard !current.isEmpty else { return (0, hasSeen) }
        if !hasSeen {
            return (0, true)
        }
        return (current.subtracting(previous).count, true)
    }
}

struct SoakFileMetrics: Equatable {
    let traceFileCount: Int
    let traceBytes: UInt64
    let databaseBytes: UInt64
    let walBytes: UInt64
    let captureStopCount: Int
    let captureRestartCount: Int
    let captureCleanupCount: Int
    let stopStartCount: Int
    let lastCleanupDurationMS: Int?

    static func collect(
        databaseURL: URL?,
        traceURL: URL?,
        lifecycleMetrics: SoakCaptureLifecycleMetrics = .unavailable,
        fileManager: FileManager = .default
    ) -> SoakFileMetrics {
        let collectedTraceMetrics = traceURL.map { Self.traceMetrics(for: $0, fileManager: fileManager) } ?? .empty
        let databaseBytes = databaseURL.map { fileSize(at: $0, fileManager: fileManager) } ?? 0
        let walBytes = databaseURL.map {
            fileSize(at: URL(fileURLWithPath: $0.path + "-wal"), fileManager: fileManager)
        } ?? 0

        return SoakFileMetrics(
            traceFileCount: collectedTraceMetrics.fileCount,
            traceBytes: collectedTraceMetrics.bytes,
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            captureStopCount: lifecycleMetrics.stopCompletedCount,
            captureRestartCount: lifecycleMetrics.restartCompletedCount,
            captureCleanupCount: lifecycleMetrics.cleanupCompletedCount,
            stopStartCount: lifecycleMetrics.pairedStopRestartCount,
            lastCleanupDurationMS: lifecycleMetrics.lastCleanupDurationMS
        )
    }

    private struct TraceMetrics {
        static let empty = TraceMetrics(fileCount: 0, bytes: 0)

        let fileCount: Int
        let bytes: UInt64
    }

    private static func traceMetrics(for traceURL: URL, fileManager: FileManager) -> TraceMetrics {
        let directoryURL = traceURL.deletingLastPathComponent()
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        let baseName = traceURL.lastPathComponent
        let stem = traceURL.deletingPathExtension().lastPathComponent
        let pathExtension = traceURL.pathExtension
        let matching = candidates.filter { candidate in
            let name = candidate.lastPathComponent
            if name == baseName { return true }
            guard !pathExtension.isEmpty,
                  name.hasPrefix(stem + "."),
                  name.hasSuffix("." + pathExtension) else {
                return false
            }
            let suffixStart = name.index(name.startIndex, offsetBy: stem.count + 1)
            let suffixEnd = name.index(name.endIndex, offsetBy: -(pathExtension.count + 1))
            return Int(name[suffixStart..<suffixEnd]) != nil
        }

        var fileCount = 0
        var bytes = UInt64(0)
        for url in matching {
            fileCount += 1
            let size = fileSize(at: url, fileManager: fileManager)
            let sum = bytes.addingReportingOverflow(size)
            bytes = sum.overflow ? UInt64.max : sum.partialValue
        }
        return TraceMetrics(fileCount: fileCount, bytes: bytes)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> UInt64 {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return 0
        }
        return size
    }
}

struct SoakCaptureLifecycleMetrics: Equatable {
    static let maximumFileSizeBytes = 4 * 1_024
    static let csvHeader = "stop_completed_count,restart_completed_count,cleanup_completed_count,last_cleanup_duration_ms"
    static let unavailable = SoakCaptureLifecycleMetrics(
        stopCompletedCount: 0,
        restartCompletedCount: 0,
        cleanupCompletedCount: 0,
        lastCleanupDurationMS: nil
    )

    let stopCompletedCount: Int
    let restartCompletedCount: Int
    let cleanupCompletedCount: Int
    let lastCleanupDurationMS: Int?

    var pairedStopRestartCount: Int {
        min(stopCompletedCount, restartCompletedCount)
    }

    static func read(from url: URL?, fileManager: FileManager = .default) throws -> SoakCaptureLifecycleMetrics {
        guard let url else { return .unavailable }
        guard fileManager.fileExists(atPath: url.path) else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics file was not found: \(url.path)"
            )
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics input must be a regular, non-symbolic-link file."
            )
        }
        guard let fileSize = values.fileSize, fileSize <= maximumFileSizeBytes else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics input exceeds the 4096-byte privacy limit."
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileSizeBytes + 1) ?? Data()
        guard data.count <= maximumFileSizeBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics input is not bounded UTF-8 data."
            )
        }

        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == 2, lines[0] == Substring(csvHeader) else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics input does not match the privacy-safe numeric schema."
            )
        }
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4,
              let stopCompletedCount = nonnegativeInteger(fields[0]),
              let restartCompletedCount = nonnegativeInteger(fields[1]),
              let cleanupCompletedCount = nonnegativeInteger(fields[2]),
              let lastCleanupDurationMS = optionalNonnegativeInteger(fields[3]) else {
            throw SoakResourceMetricsError.invalidLifecycleMetrics(
                "Lifecycle metrics input must contain only nonnegative numeric values."
            )
        }

        return SoakCaptureLifecycleMetrics(
            stopCompletedCount: stopCompletedCount,
            restartCompletedCount: restartCompletedCount,
            cleanupCompletedCount: cleanupCompletedCount,
            lastCleanupDurationMS: lastCleanupDurationMS
        )
    }

    private static func nonnegativeInteger(_ value: Substring) -> Int? {
        guard let parsed = Int(value), parsed >= 0 else { return nil }
        return parsed
    }

    private static func optionalNonnegativeInteger(_ value: Substring) -> Int?? {
        guard !value.isEmpty else { return .some(nil) }
        guard let parsed = nonnegativeInteger(value) else { return nil }
        return .some(parsed)
    }
}

struct SoakDatabaseCounts: Equatable {
    var sessions: Int?
    var transcriptSegments: Int?
    var detectedQuestions: Int?
    var suggestions: Int?
    var generations: Int?

    static let unavailable = SoakDatabaseCounts()

    init(
        sessions: Int? = nil,
        transcriptSegments: Int? = nil,
        detectedQuestions: Int? = nil,
        suggestions: Int? = nil,
        generations: Int? = nil
    ) {
        self.sessions = sessions
        self.transcriptSegments = transcriptSegments
        self.detectedQuestions = detectedQuestions
        self.suggestions = suggestions
        self.generations = generations
    }

    static func parse(_ output: String) -> SoakDatabaseCounts {
        var counts = SoakDatabaseCounts()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 1)
            guard fields.count == 2, let count = Int(fields[1]) else { continue }
            switch fields[0] {
            case "interview_sessions": counts.sessions = count
            case "transcript_segments": counts.transcriptSegments = count
            case "detected_questions": counts.detectedQuestions = count
            case "suggestion_cards": counts.suggestions = count
            case "generation_count": counts.generations = count
            default: continue
            }
        }
        return counts
    }
}

struct SoakCommandResult: Equatable {
    let status: Int32
    let standardOutput: String
}

protocol SoakCommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> SoakCommandResult
}

struct FoundationSoakCommandRunner: SoakCommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> SoakCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SoakCommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: data, as: UTF8.self)
        )
    }
}

struct SoakDatabaseCounter {
    private static let tableNames = [
        "interview_sessions",
        "transcript_segments",
        "detected_questions",
        "suggestion_cards"
    ]

    let runner: any SoakCommandRunning

    func read(databaseURL: URL?, sqliteExecutableURL: URL?) throws -> SoakDatabaseCounts {
        guard let databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path),
              let sqliteExecutableURL else {
            return .unavailable
        }

        let tableListSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name IN (\(Self.tableNames.map { "'\($0)'" }.joined(separator: ",")));"
        let tableResult = try runner.run(
            executableURL: sqliteExecutableURL,
            arguments: ["-readonly", "-noheader", databaseURL.path, tableListSQL]
        )
        guard tableResult.status == 0 else {
            throw SoakResourceMetricsError.commandFailed(sqliteExecutableURL.lastPathComponent)
        }

        let existingTables = Set(tableResult.standardOutput.split(whereSeparator: \.isNewline).map(String.init))
        let countQueries = Self.tableNames.compactMap { tableName -> String? in
            guard existingTables.contains(tableName) else { return nil }
            return "SELECT '\(tableName)', COUNT(*) FROM \(tableName)"
        }
        var queries = countQueries
        if existingTables.contains("suggestion_cards") {
            queries.append("SELECT 'generation_count', COUNT(DISTINCT generation_id) FROM suggestion_cards WHERE generation_id IS NOT NULL")
        }
        guard !queries.isEmpty else { return .unavailable }

        let countsResult = try runner.run(
            executableURL: sqliteExecutableURL,
            arguments: [
                "-readonly",
                "-noheader",
                "-separator", "|",
                databaseURL.path,
                queries.joined(separator: " UNION ALL ") + ";"
            ]
        )
        guard countsResult.status == 0 else {
            throw SoakResourceMetricsError.commandFailed(sqliteExecutableURL.lastPathComponent)
        }
        return SoakDatabaseCounts.parse(countsResult.standardOutput)
    }
}

struct SoakResourceMetricsSample: Equatable {
    static let csvColumns = [
        "timestamp_utc",
        "elapsed_seconds",
        "app_pid",
        "app_process_count",
        "app_cpu_percent",
        "app_rss_bytes",
        "helper_process_count",
        "helper_cpu_percent",
        "helper_rss_bytes",
        "ollama_process_count",
        "ollama_cpu_percent",
        "ollama_rss_bytes",
        "trace_file_count",
        "trace_bytes",
        "db_bytes",
        "wal_bytes",
        "session_count",
        "transcript_segment_count",
        "detected_question_count",
        "suggestion_count",
        "generation_count",
        "capture_stop_count",
        "capture_restart_count",
        "capture_cleanup_count",
        "stop_start_count",
        "last_cleanup_duration_ms",
        "app_restart_count",
        "helper_restart_count",
        "helper_cleanup_count",
        "ollama_restart_count",
        "collection_error_count",
        "metrics_rotation_count",
        "metrics_cleanup_count"
    ]

    let timestamp: Date
    let elapsedSeconds: Double
    let processSnapshot: SoakProcessSnapshot
    let fileMetrics: SoakFileMetrics
    let databaseCounts: SoakDatabaseCounts
    let lifecycleCounts: SoakLifecycleCounts
    let collectionErrorCount: Int

    static var csvHeader: String { csvColumns.joined(separator: ",") }

    func csvLine(metricsRotationCount: Int, metricsCleanupCount: Int) -> String {
        var values: [String] = []
        values.reserveCapacity(Self.csvColumns.count)
        values.append(ISO8601DateFormatter().string(from: timestamp))
        values.append(Self.decimal(elapsedSeconds))
        values.append(processSnapshot.primaryAppProcessID.map(String.init) ?? "")
        values.append(String(processSnapshot.appProcessIDs.count))
        values.append(Self.decimal(processSnapshot.appCPUPercent))
        values.append(String(processSnapshot.appResidentBytes))
        values.append(String(processSnapshot.helperProcessIDs.count))
        values.append(Self.decimal(processSnapshot.helperCPUPercent))
        values.append(String(processSnapshot.helperResidentBytes))
        values.append(String(processSnapshot.ollamaProcessIDs.count))
        values.append(Self.decimal(processSnapshot.ollamaCPUPercent))
        values.append(String(processSnapshot.ollamaResidentBytes))
        values.append(String(fileMetrics.traceFileCount))
        values.append(String(fileMetrics.traceBytes))
        values.append(String(fileMetrics.databaseBytes))
        values.append(String(fileMetrics.walBytes))
        values.append(databaseCounts.sessions.map(String.init) ?? "")
        values.append(databaseCounts.transcriptSegments.map(String.init) ?? "")
        values.append(databaseCounts.detectedQuestions.map(String.init) ?? "")
        values.append(databaseCounts.suggestions.map(String.init) ?? "")
        values.append(databaseCounts.generations.map(String.init) ?? "")
        values.append(String(fileMetrics.captureStopCount))
        values.append(String(fileMetrics.captureRestartCount))
        values.append(String(fileMetrics.captureCleanupCount))
        values.append(String(fileMetrics.stopStartCount))
        values.append(fileMetrics.lastCleanupDurationMS.map(String.init) ?? "")
        values.append(String(lifecycleCounts.appRestarts))
        values.append(String(lifecycleCounts.helperRestarts))
        values.append(String(lifecycleCounts.helperCleanups))
        values.append(String(lifecycleCounts.ollamaRestarts))
        values.append(String(collectionErrorCount))
        values.append(String(metricsRotationCount))
        values.append(String(metricsCleanupCount))
        return values.joined(separator: ",")
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

final class SoakResourceMetricsCSVWriter {
    let outputURL: URL
    let maximumFileSizeBytes: Int
    let maximumFileCount: Int
    private(set) var rotationCount = 0
    private(set) var cleanupCount = 0
    private var prepared = false

    init(outputURL: URL, maximumFileSizeBytes: Int, maximumFileCount: Int) {
        self.outputURL = outputURL
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.maximumFileCount = maximumFileCount
    }

    func append(_ sample: SoakResourceMetricsSample) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !prepared {
            try removeOutOfRangeArchives(fileManager: fileManager)
            try validateActiveFile(fileManager: fileManager)
            prepared = true
        }

        let existingSize = fileSize(fileManager: fileManager)
        let candidateLine = sample.csvLine(
            metricsRotationCount: rotationCount,
            metricsCleanupCount: cleanupCount
        ) + "\n"
        if existingSize > 0,
           existingSize + candidateLine.utf8.count > maximumFileSizeBytes {
            try rotate(fileManager: fileManager)
        }

        let finalLine = sample.csvLine(
            metricsRotationCount: rotationCount,
            metricsCleanupCount: cleanupCount
        ) + "\n"
        let needsHeader = fileSize(fileManager: fileManager) == 0
        let payload = (needsHeader ? SoakResourceMetricsSample.csvHeader + "\n" : "") + finalLine
        guard payload.utf8.count <= maximumFileSizeBytes else {
            throw SoakResourceMetricsError.rowExceedsFileLimit
        }

        let data = Data(payload.utf8)
        if fileManager.fileExists(atPath: outputURL.path) {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: outputURL, options: .atomic)
        }
    }

    private func rotate(fileManager: FileManager) throws {
        rotationCount += 1
        let archiveCount = maximumFileCount - 1
        guard archiveCount > 0 else {
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
                cleanupCount += 1
            }
            return
        }

        let oldestURL = archiveURL(index: archiveCount)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
            cleanupCount += 1
        }

        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let sourceURL = archiveURL(index: index)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL = archiveURL(index: index + 1)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                    cleanupCount += 1
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        let firstArchiveURL = archiveURL(index: 1)
        if fileManager.fileExists(atPath: firstArchiveURL.path) {
            try fileManager.removeItem(at: firstArchiveURL)
            cleanupCount += 1
        }
        try fileManager.moveItem(at: outputURL, to: firstArchiveURL)
    }

    private func removeOutOfRangeArchives(fileManager: FileManager) throws {
        let directoryURL = outputURL.deletingLastPathComponent()
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for file in files {
            guard let index = archiveIndex(for: file), index >= maximumFileCount else { continue }
            try fileManager.removeItem(at: file)
            cleanupCount += 1
        }
    }

    private func validateActiveFile(fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: outputURL.path) else { return }
        let values = try outputURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw SoakResourceMetricsError.invalidConfiguration("Resource metrics output must not be a symbolic link.")
        }
        guard fileSize(fileManager: fileManager) > 0 else { return }

        let expectedHeader = Data((SoakResourceMetricsSample.csvHeader + "\n").utf8)
        let handle = try FileHandle(forReadingFrom: outputURL)
        defer { try? handle.close() }
        let actualHeader = try handle.read(upToCount: expectedHeader.count) ?? Data()
        guard actualHeader == expectedHeader else {
            throw SoakResourceMetricsError.invalidConfiguration("Existing resource metrics output does not match the privacy-safe CSV schema.")
        }
    }

    private func archiveIndex(for url: URL) -> Int? {
        let name = url.lastPathComponent
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let pathExtension = outputURL.pathExtension
        let prefix = stem + "."
        let suffix = "." + pathExtension
        guard name != outputURL.lastPathComponent,
              name.hasPrefix(prefix),
              name.hasSuffix(suffix),
              name.count > prefix.count + suffix.count else {
            return nil
        }
        let indexText = name.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(indexText)
    }

    private func archiveURL(index: Int) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("\(index).\(outputURL.pathExtension)")
    }

    private func fileSize(fileManager: FileManager) -> Int {
        guard fileManager.fileExists(atPath: outputURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return 0
        }
        return max(0, size)
    }
}

struct SoakResourceMetricsRunSummary: Equatable {
    let sampleCount: Int
    let expectedSampleCount: Int
    let exactTargetSampleCount: Int
    let collectionErrorCount: Int
    let rotationCount: Int
    let cleanupCount: Int
}

protocol SoakMonotonicClock {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval)
}

struct SystemSoakMonotonicClock: SoakMonotonicClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

enum SoakFixedIntervalSchedule {
    static func expectedSampleCount(durationSeconds: Double, intervalSeconds: Double) -> Int {
        Int(floor(durationSeconds / intervalSeconds)) + 1
    }

    static func sampleIndex(
        nextSampleIndex: Int,
        startTime: TimeInterval,
        now: TimeInterval,
        intervalSeconds: Double,
        expectedSampleCount: Int
    ) -> Int {
        let elapsed = max(0, now - startTime)
        let dueSampleIndex = Int(floor(elapsed / intervalSeconds))
        return min(max(nextSampleIndex, dueSampleIndex), expectedSampleCount - 1)
    }

    static func delay(
        startTime: TimeInterval,
        sampleIndex: Int,
        intervalSeconds: Double,
        now: TimeInterval
    ) -> TimeInterval {
        max(0, startTime + (Double(sampleIndex) * intervalSeconds) - now)
    }
}

final class SoakResourceMetricsCollector {
    private let configuration: SoakResourceMetricsConfiguration
    private let runner: any SoakCommandRunning
    private let clock: any SoakMonotonicClock

    init(
        configuration: SoakResourceMetricsConfiguration,
        runner: any SoakCommandRunning = FoundationSoakCommandRunner(),
        clock: any SoakMonotonicClock = SystemSoakMonotonicClock()
    ) {
        self.configuration = configuration
        self.runner = runner
        self.clock = clock
    }

    func run() throws -> SoakResourceMetricsRunSummary {
        let writer = SoakResourceMetricsCSVWriter(
            outputURL: configuration.outputURL,
            maximumFileSizeBytes: configuration.maximumFileSizeBytes,
            maximumFileCount: configuration.maximumFileCount
        )
        let databaseCounter = SoakDatabaseCounter(runner: runner)
        var lifecycleTracker = SoakProcessLifecycleTracker()
        var collectionErrorCount = 0
        var sampleCount = 0
        var exactTargetSampleCount = 0
        var hasObservedTarget = false
        var consecutiveMissingTargetSamples = 0
        let startTime = clock.now()
        let expectedSampleCount = SoakFixedIntervalSchedule.expectedSampleCount(
            durationSeconds: configuration.durationSeconds,
            intervalSeconds: configuration.intervalSeconds
        )
        var nextSampleIndex = 0

        while nextSampleIndex < expectedSampleCount {
            let now = clock.now()
            let elapsedBeforeSleep = max(0, now - startTime)
            guard elapsedBeforeSleep <= configuration.durationSeconds else { break }

            nextSampleIndex = SoakFixedIntervalSchedule.sampleIndex(
                nextSampleIndex: nextSampleIndex,
                startTime: startTime,
                now: now,
                intervalSeconds: configuration.intervalSeconds,
                expectedSampleCount: expectedSampleCount
            )
            let sleepDuration = SoakFixedIntervalSchedule.delay(
                startTime: startTime,
                sampleIndex: nextSampleIndex,
                intervalSeconds: configuration.intervalSeconds,
                now: now
            )
            if sleepDuration > 0 {
                clock.sleep(for: sleepDuration)
            }

            let elapsed = max(0, clock.now() - startTime)
            guard elapsed <= configuration.durationSeconds else { break }
            let processRecords: [SoakProcessRecord]
            let processCollectionSucceeded: Bool
            do {
                let result = try runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-axo", "pid=,ppid=,%cpu=,rss=,comm="]
                )
                guard result.status == 0 else {
                    throw SoakResourceMetricsError.commandFailed("ps")
                }
                processRecords = SoakProcessListParser.parse(result.standardOutput)
                processCollectionSucceeded = true
            } catch {
                collectionErrorCount += 1
                processRecords = []
                processCollectionSucceeded = false
            }

            let processSnapshot = SoakProcessSnapshot.make(
                records: processRecords,
                processName: configuration.processName,
                helperProcessNames: configuration.helperProcessNames
            )
            let databaseCounts: SoakDatabaseCounts
            do {
                databaseCounts = try databaseCounter.read(
                    databaseURL: configuration.databaseURL,
                    sqliteExecutableURL: configuration.sqliteExecutableURL
                )
            } catch {
                collectionErrorCount += 1
                databaseCounts = .unavailable
            }

            let captureLifecycleMetrics: SoakCaptureLifecycleMetrics
            do {
                captureLifecycleMetrics = try SoakCaptureLifecycleMetrics.read(
                    from: configuration.lifecycleMetricsURL
                )
            } catch {
                collectionErrorCount += 1
                captureLifecycleMetrics = .unavailable
            }

            var targetFailure: SoakResourceMetricsError?
            if processCollectionSucceeded {
                switch processSnapshot.appProcessIDs.count {
                case 1:
                    hasObservedTarget = true
                    consecutiveMissingTargetSamples = 0
                    exactTargetSampleCount += 1
                case 0:
                    consecutiveMissingTargetSamples += 1
                    if consecutiveMissingTargetSamples >= configuration.maximumConsecutiveMissingAppSamples {
                        targetFailure = hasObservedTarget
                            ? .targetDisappeared(
                                processName: configuration.processName,
                                consecutiveSamples: consecutiveMissingTargetSamples
                            )
                            : .targetNotObserved(processName: configuration.processName)
                    }
                default:
                    targetFailure = .unexpectedTargetProcessCount(
                        processName: configuration.processName,
                        actual: processSnapshot.appProcessIDs.count
                    )
                }
            }

            let sample = SoakResourceMetricsSample(
                timestamp: Date(),
                elapsedSeconds: elapsed,
                processSnapshot: processSnapshot,
                fileMetrics: SoakFileMetrics.collect(
                    databaseURL: configuration.databaseURL,
                    traceURL: configuration.traceURL,
                    lifecycleMetrics: captureLifecycleMetrics
                ),
                databaseCounts: databaseCounts,
                lifecycleCounts: lifecycleTracker.update(with: processSnapshot),
                collectionErrorCount: collectionErrorCount
            )
            try writer.append(sample)
            sampleCount += 1
            nextSampleIndex += 1

            if collectionErrorCount > configuration.maximumCollectionErrorCount {
                throw SoakResourceMetricsError.collectionErrorLimitExceeded(
                    actual: collectionErrorCount,
                    maximum: configuration.maximumCollectionErrorCount
                )
            }
            if let targetFailure {
                throw targetFailure
            }
        }

        guard hasObservedTarget else {
            throw SoakResourceMetricsError.targetNotObserved(processName: configuration.processName)
        }
        let requiredSampleCount = Int(ceil(Double(expectedSampleCount) * configuration.minimumSampleCoverage))
        guard exactTargetSampleCount >= requiredSampleCount else {
            throw SoakResourceMetricsError.insufficientSampleCoverage(
                expected: expectedSampleCount,
                observed: exactTargetSampleCount,
                minimum: configuration.minimumSampleCoverage
            )
        }

        return SoakResourceMetricsRunSummary(
            sampleCount: sampleCount,
            expectedSampleCount: expectedSampleCount,
            exactTargetSampleCount: exactTargetSampleCount,
            collectionErrorCount: collectionErrorCount,
            rotationCount: writer.rotationCount,
            cleanupCount: writer.cleanupCount
        )
    }
}

enum SoakResourceMetricsCLI {
    static let helpText = """
    Usage: resource_metrics --output PATH --process-name NAME [options]

      --duration SECONDS      Total sampling duration (one interval to 86400; default: 300)
      --interval SECONDS      Sampling interval from 5 through 10 (default: 5)
      --database PATH         SQLite database to count in read-only mode
      --trace PATH            Runtime trace base file to measure by size only
      --lifecycle-metrics PATH
                              Bounded numeric capture lifecycle summary
      --helper-name NAME      Helper executable basename; may be repeated
      --sqlite3 PATH          sqlite3 executable used for predefined count-only queries
      --max-bytes BYTES       Per-file CSV limit from 1024 through 67108864
      --max-files COUNT       Total active plus rotated CSV files from 1 through 10
      --help                  Show this message

    A valid run requires exactly one target process in at least 90% of expected
    samples, fails after three consecutive missing samples, and allows at most
    three collection errors. Lifecycle input is limited to 4096 bytes and the
    numeric schema printed by --help; interview trace content is never read.

    Lifecycle schema:
    \(SoakCaptureLifecycleMetrics.csvHeader)
    """

    static func parse(arguments: [String]) throws -> SoakResourceMetricsConfiguration {
        var outputURL: URL?
        var processName: String?
        var helperProcessNames = Set<String>()
        var databaseURL: URL?
        var traceURL: URL?
        var lifecycleMetricsURL: URL?
        var sqliteExecutableURL: URL?
        var intervalSeconds = 5.0
        var durationSeconds = 300.0
        var maximumFileSizeBytes = 5 * 1_024 * 1_024
        var maximumFileCount = 4
        var index = 0

        func value(after option: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw SoakResourceMetricsError.invalidArguments("Missing value after \(option).")
            }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--output":
                outputURL = URL(fileURLWithPath: try value(after: option))
            case "--process-name":
                processName = try value(after: option)
            case "--helper-name":
                helperProcessNames.insert(try value(after: option))
            case "--database":
                databaseURL = URL(fileURLWithPath: try value(after: option))
            case "--trace":
                traceURL = URL(fileURLWithPath: try value(after: option))
            case "--lifecycle-metrics":
                lifecycleMetricsURL = URL(fileURLWithPath: try value(after: option))
            case "--sqlite3":
                sqliteExecutableURL = URL(fileURLWithPath: try value(after: option))
            case "--interval":
                guard let parsed = Double(try value(after: option)) else {
                    throw SoakResourceMetricsError.invalidArguments("Invalid numeric value after \(option).")
                }
                intervalSeconds = parsed
            case "--duration":
                guard let parsed = Double(try value(after: option)) else {
                    throw SoakResourceMetricsError.invalidArguments("Invalid numeric value after \(option).")
                }
                durationSeconds = parsed
            case "--max-bytes":
                guard let parsed = Int(try value(after: option)) else {
                    throw SoakResourceMetricsError.invalidArguments("Invalid integer value after \(option).")
                }
                maximumFileSizeBytes = parsed
            case "--max-files":
                guard let parsed = Int(try value(after: option)) else {
                    throw SoakResourceMetricsError.invalidArguments("Invalid integer value after \(option).")
                }
                maximumFileCount = parsed
            case "--help":
                throw SoakResourceMetricsError.invalidArguments(helpText)
            default:
                throw SoakResourceMetricsError.invalidArguments("Unknown resource metrics option: \(option)")
            }
            index += option == "--help" ? 1 : 2
        }

        guard let outputURL else {
            throw SoakResourceMetricsError.invalidArguments("Missing required --output path.")
        }
        guard let processName else {
            throw SoakResourceMetricsError.invalidArguments("Missing required --process-name value.")
        }
        return try SoakResourceMetricsConfiguration(
            outputURL: outputURL,
            processName: processName,
            helperProcessNames: helperProcessNames,
            databaseURL: databaseURL,
            traceURL: traceURL,
            lifecycleMetricsURL: lifecycleMetricsURL,
            sqliteExecutableURL: sqliteExecutableURL,
            intervalSeconds: intervalSeconds,
            durationSeconds: durationSeconds,
            maximumFileSizeBytes: maximumFileSizeBytes,
            maximumFileCount: maximumFileCount
        )
    }
}
