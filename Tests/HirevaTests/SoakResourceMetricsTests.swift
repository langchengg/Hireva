import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
struct SoakResourceMetricsTests {
    @Test
    func configurationEnforcesSamplingAndRotationBounds() throws {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("metrics.csv")

        let minimum = try SoakResourceMetricsConfiguration(
            outputURL: outputURL,
            processName: "Hireva",
            intervalSeconds: 5,
            durationSeconds: 5,
            maximumFileSizeBytes: 1_024,
            maximumFileCount: 1
        )
        let maximum = try SoakResourceMetricsConfiguration(
            outputURL: outputURL,
            processName: "Hireva",
            intervalSeconds: 10,
            durationSeconds: 86_400,
            maximumFileSizeBytes: 64 * 1_024 * 1_024,
            maximumFileCount: 10
        )

        #expect(minimum.intervalSeconds == 5)
        #expect(maximum.intervalSeconds == 10)
        #expect(throws: SoakResourceMetricsError.self) {
            try SoakResourceMetricsConfiguration(
                outputURL: outputURL,
                processName: "Hireva",
                intervalSeconds: 4.99,
                durationSeconds: 5
            )
        }
        #expect(throws: SoakResourceMetricsError.self) {
            try SoakResourceMetricsConfiguration(
                outputURL: outputURL,
                processName: "Hireva",
                intervalSeconds: 10.01,
                durationSeconds: 11
            )
        }
    }

    @Test
    func processSnapshotAggregatesAppDescendantsAndOllamaWithoutCommandLines() {
        let records = SoakProcessListParser.parse("""
          100     1  12.5  2048 /Applications/Hireva.app/Contents/MacOS/Hireva
          101   100   2.5  1024 /usr/bin/python3
          102   101   1.0   512 /tmp/parakeet_asr_helper
          200     1   3.0  4096 /opt/homebrew/bin/ollama
        """)
        let snapshot = SoakProcessSnapshot.make(
            records: records,
            processName: "Hireva",
            helperProcessNames: ["parakeet_asr_helper"]
        )

        #expect(snapshot.appProcessIDs == [100])
        #expect(snapshot.appCPUPercent == 12.5)
        #expect(snapshot.appResidentBytes == 2_048 * 1_024)
        #expect(snapshot.helperProcessIDs == [101, 102])
        #expect(snapshot.helperCPUPercent == 3.5)
        #expect(snapshot.helperResidentBytes == 1_536 * 1_024)
        #expect(snapshot.ollamaProcessIDs == [200])
        #expect(snapshot.ollamaResidentBytes == 4_096 * 1_024)
    }

    @Test
    func lifecycleTrackerCountsRestartsAndHelperCleanup() {
        var tracker = SoakProcessLifecycleTracker()
        let first = tracker.update(with: snapshot(app: [100], helpers: [101], ollama: [200]))
        let restarted = tracker.update(with: snapshot(app: [110], helpers: [102], ollama: [201]))
        let cleaned = tracker.update(with: snapshot(app: [110], helpers: [], ollama: [201]))

        #expect(first == SoakLifecycleCounts(appRestarts: 0, helperRestarts: 0, helperCleanups: 0, ollamaRestarts: 0))
        #expect(restarted == SoakLifecycleCounts(appRestarts: 1, helperRestarts: 1, helperCleanups: 1, ollamaRestarts: 1))
        #expect(cleaned == SoakLifecycleCounts(appRestarts: 1, helperRestarts: 1, helperCleanups: 2, ollamaRestarts: 1))
    }

    @Test
    func csvContainsOnlyFixedTimestampAndNumericMetrics() {
        let sample = makeSample(elapsedSeconds: 5)
        let line = sample.csvLine(metricsRotationCount: 2, metricsCleanupCount: 1)
        let fields = line.components(separatedBy: ",")

        #expect(fields.count == SoakResourceMetricsSample.csvColumns.count)
        #expect(fields.dropFirst().allSatisfy { $0.isEmpty || Double($0) != nil })
        #expect(SoakResourceMetricsSample.csvHeader.contains("app_cpu_percent"))
        #expect(SoakResourceMetricsSample.csvHeader.contains("wal_bytes"))
        #expect(SoakResourceMetricsSample.csvHeader.contains("helper_cleanup_count"))
        #expect(!SoakResourceMetricsSample.csvHeader.contains("transcript_text"))
        #expect(!SoakResourceMetricsSample.csvHeader.contains("question_text"))
        #expect(!SoakResourceMetricsSample.csvHeader.contains("answer_text"))
        #expect(!SoakResourceMetricsSample.csvHeader.contains("command_line"))
        #expect(!line.contains("private interview sentence"))
    }

    @Test
    func fileMetricsMeasureTraceDatabaseAndWALWithoutPersistingContent() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let traceURL = directory.appendingPathComponent("runtime_transcript_trace.jsonl")
        let rotatedTraceURL = directory.appendingPathComponent("runtime_transcript_trace.1.jsonl")
        let unrelatedURL = directory.appendingPathComponent("runtime_transcript_trace.backup.jsonl")
        let databaseURL = directory.appendingPathComponent("hireva.sqlite")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")

        try Data(repeating: 1, count: 11).write(to: traceURL)
        try Data(repeating: 2, count: 13).write(to: rotatedTraceURL)
        try Data(repeating: 3, count: 17).write(to: unrelatedURL)
        try Data(repeating: 4, count: 19).write(to: databaseURL)
        try Data(repeating: 5, count: 23).write(to: walURL)

        let metrics = SoakFileMetrics.collect(databaseURL: databaseURL, traceURL: traceURL)
        #expect(metrics.traceFileCount == 2)
        #expect(metrics.traceBytes == 24)
        #expect(metrics.databaseBytes == 19)
        #expect(metrics.walBytes == 23)
        #expect(metrics.stopStartCount == 0)
        #expect(metrics.lastCleanupDurationMS == nil)
    }

    @Test
    func fileMetricsReadTraceSizeOnlyAndUseBoundedLifecycleSummary() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let traceURL = directory.appendingPathComponent("runtime_transcript_trace.jsonl")
        let lifecycleURL = directory.appendingPathComponent("runtime_lifecycle_metrics.csv")
        let lines = [
            #"{"timestamp":"2026-07-14T11:00:00Z","event_type":"capture.stop.completed","rejection_reason":"cleanup_ms=42|reason=userRequested","raw_text":"private"}"#,
            #"{"timestamp":"2026-07-14T11:01:00Z","event_type":"capture.stop.completed","rejection_reason":"cleanup_ms=17|reason=userRequested","raw_text":"private"}"#,
            #"{"timestamp":"2026-07-14T11:02:00Z","event_type":"transcript.final","raw_text":"must not be exported"}"#
        ]
        let privateTrace = lines.joined(separator: "\n") + "\n"
        try Data(privateTrace.utf8).write(to: traceURL)
        try Data((SoakCaptureLifecycleMetrics.csvHeader + "\n5,2,4,17\n").utf8).write(to: lifecycleURL)

        let lifecycleMetrics = try SoakCaptureLifecycleMetrics.read(from: lifecycleURL)
        let metrics = SoakFileMetrics.collect(
            databaseURL: nil,
            traceURL: traceURL,
            lifecycleMetrics: lifecycleMetrics
        )
        #expect(metrics.traceBytes == UInt64(privateTrace.utf8.count))
        #expect(metrics.captureStopCount == 5)
        #expect(metrics.captureRestartCount == 2)
        #expect(metrics.captureCleanupCount == 4)
        #expect(metrics.stopStartCount == 2)
        #expect(metrics.lastCleanupDurationMS == 17)

        try Data(repeating: 0, count: SoakCaptureLifecycleMetrics.maximumFileSizeBytes + 1).write(to: lifecycleURL)
        #expect(throws: SoakResourceMetricsError.self) {
            try SoakCaptureLifecycleMetrics.read(from: lifecycleURL)
        }
    }

    @Test
    func databaseCountParserAcceptsCountsButNoRows() {
        let counts = SoakDatabaseCounts.parse("""
        interview_sessions|4
        transcript_segments|20
        detected_questions|7
        suggestion_cards|6
        generation_count|5
        ignored_table|999
        """)

        #expect(counts.sessions == 4)
        #expect(counts.transcriptSegments == 20)
        #expect(counts.detectedQuestions == 7)
        #expect(counts.suggestions == 6)
        #expect(counts.generations == 5)
    }

    @Test
    func writerRotatesAndPrunesWithinConfiguredCaps() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("metrics.csv")
        let staleURL = directory.appendingPathComponent("metrics.2.csv")
        try Data("stale".utf8).write(to: staleURL)

        let writer = SoakResourceMetricsCSVWriter(
            outputURL: outputURL,
            maximumFileSizeBytes: 1_024,
            maximumFileCount: 2
        )
        for index in 0..<30 {
            try writer.append(makeSample(elapsedSeconds: Double(index * 5)))
        }

        let archiveURL = directory.appendingPathComponent("metrics.1.csv")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(writer.rotationCount > 0)
        #expect(writer.cleanupCount > 0)
        #expect(try fileSize(outputURL) <= 1_024)
        #expect(try fileSize(archiveURL) <= 1_024)
        #expect(try String(contentsOf: outputURL, encoding: .utf8).hasPrefix(SoakResourceMetricsSample.csvHeader + "\n"))
    }

    @Test
    func writerRejectsAnExistingTextBearingOutput() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("metrics.csv")
        try Data("transcript_text,answer_text\nprivate interview sentence\n".utf8).write(to: outputURL)
        let writer = SoakResourceMetricsCSVWriter(
            outputURL: outputURL,
            maximumFileSizeBytes: 1_024,
            maximumFileCount: 2
        )

        #expect(throws: SoakResourceMetricsError.self) {
            try writer.append(makeSample(elapsedSeconds: 0))
        }
        #expect(try String(contentsOf: outputURL, encoding: .utf8).contains("private interview sentence"))
    }

    @Test
    func writerReopensAndAppendsToAnExistingMetricsFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("metrics.csv")
        let firstWriter = SoakResourceMetricsCSVWriter(
            outputURL: outputURL,
            maximumFileSizeBytes: 2_048,
            maximumFileCount: 2
        )
        try firstWriter.append(makeSample(elapsedSeconds: 0))

        let secondWriter = SoakResourceMetricsCSVWriter(
            outputURL: outputURL,
            maximumFileSizeBytes: 2_048,
            maximumFileCount: 2
        )
        try secondWriter.append(makeSample(elapsedSeconds: 5))

        let rows = try String(contentsOf: outputURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(rows.count == 3)
    }

    @Test
    func fixedIntervalScheduleUsesAbsoluteDeadlinesAndSkipsMissedSlots() {
        #expect(SoakFixedIntervalSchedule.expectedSampleCount(durationSeconds: 10, intervalSeconds: 5) == 3)
        #expect(SoakFixedIntervalSchedule.delay(
            startTime: 100,
            sampleIndex: 2,
            intervalSeconds: 5,
            now: 107
        ) == 3)
        #expect(SoakFixedIntervalSchedule.delay(
            startTime: 100,
            sampleIndex: 2,
            intervalSeconds: 5,
            now: 111
        ) == 0)
        #expect(SoakFixedIntervalSchedule.sampleIndex(
            nextSampleIndex: 1,
            startTime: 100,
            now: 112,
            intervalSeconds: 5,
            expectedSampleCount: 5
        ) == 2)
    }

    @Test
    func collectorFailsWhenTargetIsNeverObserved() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let runner = ScriptedSoakCommandRunner(outputs: ["", ""])
        let configuration = try collectorConfiguration(directory: directory, durationSeconds: 5)

        #expect(throws: SoakResourceMetricsError.targetNotObserved(processName: "Hireva")) {
            try SoakResourceMetricsCollector(
                configuration: configuration,
                runner: runner,
                clock: clock
            ).run()
        }
    }

    @Test
    func collectorRequiresExactlyOneTargetProcess() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let runner = ScriptedSoakCommandRunner(outputs: [psOutput(appProcessIDs: [100, 101])])
        let configuration = try collectorConfiguration(directory: directory, durationSeconds: 5)

        #expect(throws: SoakResourceMetricsError.unexpectedTargetProcessCount(
            processName: "Hireva",
            actual: 2
        )) {
            try SoakResourceMetricsCollector(
                configuration: configuration,
                runner: runner,
                clock: clock
            ).run()
        }
    }

    @Test
    func collectorFailsAfterSustainedTargetDisappearance() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let runner = ScriptedSoakCommandRunner(outputs: [
            psOutput(appProcessIDs: [100]),
            "",
            "",
            ""
        ])
        let configuration = try collectorConfiguration(directory: directory, durationSeconds: 15)

        #expect(throws: SoakResourceMetricsError.targetDisappeared(
            processName: "Hireva",
            consecutiveSamples: 3
        )) {
            try SoakResourceMetricsCollector(
                configuration: configuration,
                runner: runner,
                clock: clock
            ).run()
        }
    }

    @Test
    func collectorFailsWhenSlowCollectionDropsExpectedCoverage() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let runner = ScriptedSoakCommandRunner(
            outputs: [psOutput(appProcessIDs: [100])],
            clock: clock,
            collectionDurationSeconds: 11
        )
        let configuration = try collectorConfiguration(directory: directory, durationSeconds: 10)

        #expect(throws: SoakResourceMetricsError.insufficientSampleCoverage(
            expected: 3,
            observed: 1,
            minimum: 0.9
        )) {
            try SoakResourceMetricsCollector(
                configuration: configuration,
                runner: runner,
                clock: clock
            ).run()
        }
    }

    @Test
    func collectorFailsWhenCollectionErrorsExceedBudget() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let runner = ScriptedSoakCommandRunner(outputs: [nil])
        let configuration = try collectorConfiguration(
            directory: directory,
            durationSeconds: 5,
            maximumCollectionErrorCount: 0
        )

        #expect(throws: SoakResourceMetricsError.collectionErrorLimitExceeded(actual: 1, maximum: 0)) {
            try SoakResourceMetricsCollector(
                configuration: configuration,
                runner: runner,
                clock: clock
            ).run()
        }
    }

    @Test
    func collectorSucceedsWithExactTargetCoverageOnFixedIntervals() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestSoakMonotonicClock()
        let appOutput = psOutput(appProcessIDs: [100])
        let runner = ScriptedSoakCommandRunner(
            outputs: [appOutput, appOutput, appOutput],
            clock: clock,
            collectionDurationSeconds: 2
        )
        let configuration = try collectorConfiguration(directory: directory, durationSeconds: 10)

        let summary = try SoakResourceMetricsCollector(
            configuration: configuration,
            runner: runner,
            clock: clock
        ).run()

        #expect(summary.sampleCount == 3)
        #expect(summary.expectedSampleCount == 3)
        #expect(summary.exactTargetSampleCount == 3)
        #expect(summary.collectionErrorCount == 0)
        #expect(clock.sleepDurations == [3, 3])

        let rows = try String(contentsOf: configuration.outputURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        let elapsedValues = rows.dropFirst().compactMap { row in
            Double(row.split(separator: ",", omittingEmptySubsequences: false)[1])
        }
        #expect(elapsedValues == [0, 5, 10])
    }

    @Test
    func soakRunnerBuildsAssignedSourceAndAvoidsNameBasedKilling() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot.appendingPathComponent("script/soak/run_resource_soak.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("Sources/Hireva/Services/SoakResourceMetrics.swift"))
        #expect(script.contains("xcrun swiftc -parse-as-library"))
        #expect(script.contains("--interval"))
        #expect(script.contains("--lifecycle-metrics"))
        #expect(script.contains("--max-bytes"))
        #expect(!script.contains("pkill"))
        #expect(!script.contains("killall"))
    }

    private func collectorConfiguration(
        directory: URL,
        durationSeconds: Double,
        maximumCollectionErrorCount: Int = SoakResourceMetricsConfiguration.defaultMaximumCollectionErrorCount
    ) throws -> SoakResourceMetricsConfiguration {
        try SoakResourceMetricsConfiguration(
            outputURL: directory.appendingPathComponent("metrics.csv"),
            processName: "Hireva",
            intervalSeconds: 5,
            durationSeconds: durationSeconds,
            maximumFileSizeBytes: 4 * 1_024,
            maximumFileCount: 2,
            minimumSampleCoverage: 0.9,
            maximumCollectionErrorCount: maximumCollectionErrorCount,
            maximumConsecutiveMissingAppSamples: 3
        )
    }

    private func psOutput(appProcessIDs: [Int32]) -> String {
        appProcessIDs.map { processID in
            "\(processID) 1 1.0 1024 /Applications/Hireva.app/Contents/MacOS/Hireva"
        }.joined(separator: "\n")
    }

    private final class TestSoakMonotonicClock: SoakMonotonicClock {
        private(set) var currentTime: TimeInterval = 100
        private(set) var sleepDurations: [TimeInterval] = []

        func now() -> TimeInterval {
            currentTime
        }

        func sleep(for seconds: TimeInterval) {
            sleepDurations.append(seconds)
            currentTime += seconds
        }

        func advance(by seconds: TimeInterval) {
            currentTime += seconds
        }
    }

    private enum ScriptedRunnerError: Error {
        case requestedFailure
        case exhausted
    }

    private final class ScriptedSoakCommandRunner: SoakCommandRunning {
        private var outputs: [String?]
        private weak var clock: TestSoakMonotonicClock?
        private let collectionDurationSeconds: TimeInterval

        init(
            outputs: [String?],
            clock: TestSoakMonotonicClock? = nil,
            collectionDurationSeconds: TimeInterval = 0
        ) {
            self.outputs = outputs
            self.clock = clock
            self.collectionDurationSeconds = collectionDurationSeconds
        }

        func run(executableURL: URL, arguments: [String]) throws -> SoakCommandResult {
            defer { clock?.advance(by: collectionDurationSeconds) }
            guard !outputs.isEmpty else { throw ScriptedRunnerError.exhausted }
            guard let output = outputs.removeFirst() else { throw ScriptedRunnerError.requestedFailure }
            return SoakCommandResult(status: 0, standardOutput: output)
        }
    }

    private func snapshot(
        app: Set<Int32>,
        helpers: Set<Int32>,
        ollama: Set<Int32>
    ) -> SoakProcessSnapshot {
        SoakProcessSnapshot(
            appProcessIDs: app,
            appCPUPercent: 0,
            appResidentBytes: 0,
            helperProcessIDs: helpers,
            helperCPUPercent: 0,
            helperResidentBytes: 0,
            ollamaProcessIDs: ollama,
            ollamaCPUPercent: 0,
            ollamaResidentBytes: 0
        )
    }

    private func makeSample(elapsedSeconds: Double) -> SoakResourceMetricsSample {
        SoakResourceMetricsSample(
            timestamp: Date(timeIntervalSince1970: 0),
            elapsedSeconds: elapsedSeconds,
            processSnapshot: snapshot(app: [100], helpers: [101], ollama: [200]),
            fileMetrics: SoakFileMetrics(
                traceFileCount: 2,
                traceBytes: 100,
                databaseBytes: 200,
                walBytes: 50,
                captureStopCount: 8,
                captureRestartCount: 6,
                captureCleanupCount: 8,
                stopStartCount: 6,
                lastCleanupDurationMS: 75
            ),
            databaseCounts: SoakDatabaseCounts(
                sessions: 1,
                transcriptSegments: 2,
                detectedQuestions: 3,
                suggestions: 4,
                generations: 4
            ),
            lifecycleCounts: SoakLifecycleCounts(appRestarts: 0, helperRestarts: 0, helperCleanups: 0, ollamaRestarts: 0),
            collectionErrorCount: 0
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoakResourceMetricsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }
}
