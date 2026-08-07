import Foundation
import Testing
@testable import Hireva

@Suite("Release privacy trace regressions")
struct ReleasePrivacyTraceRegressionTests {
    private let canary = "HIREVA-PRIVACY-CANARY-7F3A9D"

    @Test
    func diagnosticTraceModeDefaultsAndUnknownValuesFailClosedWithoutResettingOtherSettings() throws {
        #expect(AppSettings.default.diagnosticTraceMode == .off)

        let missingMode = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"floatingWindowOpacity":0.71,"automaticQuestionDetectionEnabled":false}"#.utf8)
        )
        #expect(missingMode.diagnosticTraceMode == .off)
        #expect(missingMode.floatingWindowOpacity == 0.71)
        #expect(missingMode.automaticQuestionDetectionEnabled == false)

        let unknownMode = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"diagnosticTraceMode":"future-mode","floatingWindowOpacity":0.63,"automaticQuestionDetectionEnabled":false}"#.utf8)
        )
        #expect(unknownMode.diagnosticTraceMode == .off)
        #expect(unknownMode.floatingWindowOpacity == 0.63)
        #expect(unknownMode.automaticQuestionDetectionEnabled == false)
    }

    @Test
    func disabledTranscriptPersistenceCapsEffectiveTraceModeAtMetadataOnly() {
        var settings = AppSettings.default
        settings.diagnosticTraceMode = .fullText
        settings.saveTranscriptsLocally = false

        #expect(settings.effectiveDiagnosticTraceMode == .metadataOnly)

        settings.diagnosticTraceMode = .off
        #expect(settings.effectiveDiagnosticTraceMode == .off)
    }

    @Test
    func metadataAndOffSerializationNeverContainTextOrReversibleDuplicateKeys() throws {
        let record = makeCanaryRecord()

        #expect(record.jsonLine(for: .off) == nil)

        let metadata = try #require(record.jsonLine(for: .metadataOnly))
        #expect(!metadata.contains(canary))
        #expect(!metadata.contains("duplicate_key"))
        #expect(!metadata.contains("raw_text"))
        #expect(!metadata.contains("candidate_text"))
        #expect(!metadata.contains("ui_transcript_text"))
        #expect(!metadata.contains("visible_question_text"))

        let fullText = try #require(record.jsonLine(for: .fullText))
        #expect(fullText.contains(canary))
    }

    @Test
    func traceStoreDoesNotCreateFilesWhenOffAndDeletesOnlyActiveAndRotatedTraceFamily() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let active = fixture.traceURL
        let rotatedOne = active.deletingPathExtension().appendingPathExtension("1.jsonl")
        let rotatedFive = active.deletingPathExtension().appendingPathExtension("5.jsonl")
        let unrelated = active.deletingLastPathComponent().appendingPathComponent("runtime_transcript_trace.notes.jsonl")
        try Data(canary.utf8).write(to: active)
        try Data(canary.utf8).write(to: rotatedOne)
        try Data(canary.utf8).write(to: rotatedFive)
        try Data("keep".utf8).write(to: unrelated)

        let store = RuntimeTranscriptTraceStore()
        store.prepareForMode(.off, at: active)
        store.append(line: makeCanaryRecord().jsonLine(for: .off), to: active, mode: .off)
        store.waitForPendingOperations()

        #expect(!FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: rotatedOne.path))
        #expect(!FileManager.default.fileExists(atPath: rotatedFive.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func metadataStoreOutputExcludesCanaryWhileExplicitFullTextIncludesIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let store = RuntimeTranscriptTraceStore()
        let record = makeCanaryRecord()
        store.append(line: record.jsonLine(for: .metadataOnly), to: fixture.traceURL, mode: .metadataOnly)
        store.waitForPendingOperations()

        let metadata = try String(contentsOf: fixture.traceURL, encoding: .utf8)
        #expect(!metadata.contains(canary))
        #expect(!metadata.contains("duplicate_key"))

        try store.clearTraceFiles(at: fixture.traceURL)
        store.append(line: record.jsonLine(for: .fullText), to: fixture.traceURL, mode: .fullText)
        store.waitForPendingOperations()

        let fullText = try String(contentsOf: fixture.traceURL, encoding: .utf8)
        #expect(fullText.contains(canary))
    }

    private func makeCanaryRecord() -> TranscriptRuntimeEventRecord {
        TranscriptRuntimeEventRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            name: "questionAccepted",
            sessionID: "session-privacy-fixture",
            questionID: "question-privacy-fixture",
            generationID: "generation-privacy-fixture",
            text: "Question \(canary)",
            reason: "Reason \(canary)",
            rawText: "Raw \(canary)",
            canonicalText: "Canonical \(canary)",
            candidateText: "Candidate \(canary)",
            duplicateKey: "reversible-\(canary)",
            uiTranscriptText: "Transcript \(canary)",
            visibleQuestionText: "Visible \(canary)",
            splitCandidates: ["Split \(canary)"],
            oldQuestionText: "Old \(canary)",
            currentQuestionText: "Current \(canary)"
        )
    }

    private func makeFixture() throws -> (root: URL, traceURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaReleasePrivacyTraceTests-\(UUID().uuidString)", isDirectory: true)
        let traceDirectory = root.appendingPathComponent("Application Support/Hireva", isDirectory: true)
        try FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
        return (root, traceDirectory.appendingPathComponent("runtime_transcript_trace.jsonl"))
    }
}
