import Foundation
import Testing
@testable import Hireva

@Suite("Release privacy integration regressions", .serialized, .sharedRuntimeResources)
@MainActor
struct ReleasePrivacyIntegrationRegressionTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test
    func appPrivacyManifestAndReleaseScriptsDeclareAndEnforceTheReviewedContract() throws {
        let manifestURL = repositoryRoot.appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try #require(
            PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any]
        )

        #expect(Set(manifest.keys) == [
            "NSPrivacyTracking",
            "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes"
        ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)

        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.count == 1)
        let content = try #require(collected.first)
        #expect(content["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeOtherUserContent")
        #expect(content["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
        #expect(content["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
        #expect(
            content["NSPrivacyCollectedDataTypePurposes"] as? [String]
                == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        )

        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        #expect(accessed.isEmpty, "Hireva is macOS-only; reviewed required-reason declarations are empty")

        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let packageScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            encoding: .utf8
        )
        #expect(buildScript.contains("Resources/PrivacyInfo.xcprivacy"))
        #expect(buildScript.contains("PRIVACY_MANIFEST_BUNDLE"))
        #expect(buildScript.contains("GRDB_GRDB.bundle"))
        #expect(packageScript.contains("validate_hireva_privacy_manifest"))
        #expect(packageScript.contains("validate_grdb_privacy_manifest"))
        #expect(packageScript.contains("app privacy manifest must not declare required-reason APIs for macOS"))
    }

    @Test
    func transcriptionServicesCanOnlyUseTheTypedMetadataLoggingBoundary() throws {
        let sourcePaths = [
            "Sources/Hireva/Services/AppleSpeechTranscriptionService.swift",
            "Sources/Hireva/Services/ManualQuestionTranscriptionService.swift",
            "Sources/Hireva/Services/LocalASRProviders.swift",
            "Sources/Hireva/Services/RuntimeTranscriptTraceStore.swift"
        ]
        for relativePath in sourcePaths {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(
                source.contains("PrivacySafeLogger."),
                "\(relativePath) must use the typed metadata-only logging boundary"
            )
            #expect(
                source.contains("AppLogger.") == false,
                "\(relativePath) must not access the arbitrary-message logger"
            )
            #expect(source.contains("print(") == false, "\(relativePath) must not use console prints")
        }

        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/Hireva", isDirectory: true)
        let productionSources = allRegularFiles(under: sourceRoot)
            .filter { $0.pathExtension == "swift" }
        #expect(!productionSources.isEmpty)
        for sourceURL in productionSources {
            let relativePath = sourceURL.path.replacingOccurrences(
                of: sourceRoot.path + "/",
                with: ""
            )
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for forbiddenSink in [
                "print(",
                "Swift.print(",
                "fputs(",
                "debugPrint(",
                "NSLog(",
                "os_log("
            ] {
                #expect(
                    source.contains(forbiddenSink) == false,
                    "\(relativePath) must not write to unstructured production sink \(forbiddenSink)"
                )
            }
            if relativePath != "Utilities/Logger.swift" {
                #expect(
                    source.contains("Logger(") == false,
                    "\(relativePath) must use PrivacySafeLogger instead of constructing Logger"
                )
                #expect(
                    source.contains("AppLogger.") == false,
                    "\(relativePath) must not bypass the typed privacy boundary"
                )
            }
        }

        let loggerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Hireva/Utilities/Logger.swift"),
            encoding: .utf8
        )
        #expect(loggerSource.contains("private enum AppLogger"))
        #expect(loggerSource.contains("enum PrivacySafeLogger"))
        let functionSignatureRegex = try NSRegularExpression(
            pattern: #"static func\s+\w+\s*\((?s:.*?)\)"#
        )
        let loggerRange = NSRange(loggerSource.startIndex..., in: loggerSource)
        let functionSignatures = functionSignatureRegex.matches(
            in: loggerSource,
            range: loggerRange
        ).compactMap { match -> String? in
            guard let range = Range(match.range, in: loggerSource) else { return nil }
            return String(loggerSource[range])
        }
        #expect(!functionSignatures.isEmpty)
        for signature in functionSignatures {
            for forbiddenTypePattern in [
                #":\s*String\b"#,
                #":\s*Error\b"#,
                #":\s*URL\b"#,
                #":\s*Data\b"#
            ] {
                #expect(
                    signature.range(
                        of: forbiddenTypePattern,
                        options: .regularExpression
                    ) == nil,
                    "PrivacySafeLogger API must not accept sensitive open-ended parameter type"
                )
            }
        }
        for forbiddenStringParameter in [
            "message: String",
            "text: String",
            "transcript: String",
            "content: String",
            "path: String",
            "response: String",
            "line: String"
        ] {
            #expect(
                loggerSource.contains(forbiddenStringParameter) == false,
                "PrivacySafeLogger must not accept sensitive string parameter \(forbiddenStringParameter)"
            )
        }
    }

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
