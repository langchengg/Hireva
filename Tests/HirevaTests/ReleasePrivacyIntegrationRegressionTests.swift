import Foundation
import Testing
@testable import Hireva

@Suite("Release privacy integration regressions")
@MainActor
struct ReleasePrivacyIntegrationRegressionTests {
    @Test
    func disabledTranscriptPersistenceKeepsCanaryOutOfSQLiteAndTraceFiles() async throws {
        let canary = "HIREVA-APPSTATE-PRIVACY-CANARY-4A6E1C"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaReleasePrivacyIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase(path: root.appendingPathComponent("privacy.sqlite"))
        let defaultsName = "com.langcheng.Hireva.tests.privacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let appState = AppState(
            database: database,
            verificationMocksEnabled: true,
            dialogueDefaults: defaults
        )
        appState.runtimeTranscriptTraceLogURL = root.appendingPathComponent("runtime_transcript_trace.jsonl")

        var settings = appState.settings
        settings.automaticQuestionDetectionEnabled = false
        settings.saveTranscriptsLocally = false
        settings.diagnosticTraceMode = .fullText
        appState.saveSettings(settings)
        #expect(appState.settings.effectiveDiagnosticTraceMode == .metadataOnly)

        let session = try appState.sessionRepository.createSession(mode: .mock, title: "Privacy integration")
        appState.currentSession = session
        let segment = TranscriptSegment(
            id: "privacy-canary-segment",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Can you explain \(canary)?",
            createdAt: Date(),
            confidence: 1.0,
            asrSource: .localParakeetASR,
            asrFinalizationReason: "final_accepted"
        )

        await appState.handleTranscriptSegment(segment)
        try await waitForTraceFile(at: appState.runtimeTranscriptTraceLogURL)

        #expect(try appState.transcriptRepository.segments(sessionID: session.id).isEmpty)
        #expect(appState.transcriptSegments.contains(where: { $0.text.contains(canary) }))

        let files = allRegularFiles(under: root)
        #expect(!files.isEmpty)
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(
                !String(decoding: bytes, as: UTF8.self).contains(canary),
                "Privacy canary leaked to \(file.lastPathComponent)"
            )
        }
    }

    private func waitForTraceFile(at url: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for metadata trace output at \(url.path)")
    }

    private func allRegularFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }
}
