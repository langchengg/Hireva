import Foundation
import Testing

@Suite(.serialized)
struct RuntimeVerificationScriptTests {
    @Test
    func runtimeSmokeRejectsUnknownSuiteBeforeRunningTests() throws {
        let result = try runScript("scripts/runtime_smoke.sh", arguments: ["--suite", "not-a-suite"])

        #expect(result.status == 2)
        #expect(result.output.contains("unknown runtime smoke suite"))
        #expect(!result.output.contains("Runtime smoke suite:"))
    }

    @Test
    func runtimeStabilityGateExistsIsExecutableAndRunsRequiredCommandsInOrder() throws {
        let url = repositoryRoot.appendingPathComponent("scripts/verify_runtime_stability.sh")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))

        let contents = try String(contentsOf: url, encoding: .utf8)
        let requiredInvocations = [
            "run_step \"Swift build\" swift build",
            "run_step \"Swift test\" swift test",
            "run_step \"runtime_smoke\" ./scripts/runtime_smoke.sh --suite all",
            "run_step \"build_and_run verify\" run_build_and_run_verification"
        ]
        var previousOffset = contents.startIndex
        for invocation in requiredInvocations {
            let range = try #require(contents.range(of: invocation, range: previousOffset..<contents.endIndex))
            previousOffset = range.upperBound
        }

        #expect(contents.contains("ICBuildTimestampUTC"))
        #expect(contents.contains("interview_copilot.sqlite"))
    }

    @Test
    func runtimeStabilityGateFailsAndReportsAllStatusesWhenBuildVerifyFails() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-stability-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scriptsDirectory = sandbox.appendingPathComponent("scripts")
        let scriptDirectory = sandbox.appendingPathComponent("script")
        let binDirectory = sandbox.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("scripts/verify_runtime_stability.sh"),
            to: scriptsDirectory.appendingPathComponent("verify_runtime_stability.sh")
        )
        try writeExecutable("#!/usr/bin/env bash\nexit 0\n", to: binDirectory.appendingPathComponent("swift"))
        try writeExecutable("#!/usr/bin/env bash\nexit 0\n", to: scriptsDirectory.appendingPathComponent("runtime_smoke.sh"))
        try writeExecutable("#!/usr/bin/env bash\nexit 23\n", to: scriptDirectory.appendingPathComponent("build_and_run.sh"))

        let result = try runScript(
            at: scriptsDirectory.appendingPathComponent("verify_runtime_stability.sh"),
            currentDirectory: sandbox,
            environment: ["PATH": "\(binDirectory.path):/usr/bin:/bin"]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Swift build: PASS"))
        #expect(result.output.contains("Swift test: PASS"))
        #expect(result.output.contains("runtime_smoke: PASS"))
        #expect(result.output.contains("build_and_run verify: FAIL"))
        #expect(result.output.contains("overall: FAIL"))
        #expect(!result.output.contains("overall: PASS"))
    }

    @Test
    func runtimeStabilityGatePrintsFailingTestNameLogPathAndRelevantTail() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-stability-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scriptsDirectory = sandbox.appendingPathComponent("scripts")
        let scriptDirectory = sandbox.appendingPathComponent("script")
        let binDirectory = sandbox.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("scripts/verify_runtime_stability.sh"),
            to: scriptsDirectory.appendingPathComponent("verify_runtime_stability.sh")
        )
        try writeExecutable(
            """
            #!/usr/bin/env bash
            if [[ "${1:-}" == "test" ]]; then
                echo '✘ Test syntheticPersistenceFailure() failed after 0.1 seconds with 1 issue.'
                exit 41
            fi
            exit 0
            """,
            to: binDirectory.appendingPathComponent("swift")
        )
        try writeExecutable("#!/usr/bin/env bash\nexit 0\n", to: scriptsDirectory.appendingPathComponent("runtime_smoke.sh"))
        try writeExecutable("#!/usr/bin/env bash\nexit 23\n", to: scriptDirectory.appendingPathComponent("build_and_run.sh"))

        let result = try runScript(
            at: scriptsDirectory.appendingPathComponent("verify_runtime_stability.sh"),
            currentDirectory: sandbox,
            environment: ["PATH": "\(binDirectory.path):/usr/bin:/bin"]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Step failed: Swift test"))
        #expect(result.output.contains("Full log:"))
        #expect(result.output.contains("Failing tests:"))
        #expect(result.output.contains("syntheticPersistenceFailure"))
        #expect(result.output.contains("Last 80 relevant lines:"))
    }

    @Test
    func buildAndRunContainsRequiredSigningCleanupAndFailureDiagnostics() throws {
        let url = repositoryRoot.appendingPathComponent("script/build_and_run.sh")
        let contents = try String(contentsOf: url, encoding: .utf8)

        let requiredSnippets = [
            "find \"$DIST_DIR\" -name '._*' -delete",
            "find \"$DIST_DIR\" -name '.DS_Store' -delete",
            "xattr -cr \"$APP_BUNDLE\"",
            "security find-identity -v -p codesigning",
            "INTERVIEW_COPILOT_SIGNING_IDENTITY",
            "Using ad-hoc signing. AMFI may reject this on some systems.",
            "codesign --verify --deep --strict --verbose=4",
            "spctl --assess --type execute --verbose=4",
            "xattr -lr",
            "process == \"amfid\" OR eventMessage CONTAINS \"InterviewCopilotMac\""
        ]

        for snippet in requiredSnippets {
            #expect(contents.contains(snippet), "Missing required signing snippet: \(snippet)")
        }
    }

    @Test
    func databaseDiagnosticsScriptExistsIsExecutableAndUsesReadOnlySQLite() throws {
        let url = repositoryRoot.appendingPathComponent("scripts/db_diagnostics.sh")

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("sqlite3 -readonly"))
    }

    @Test
    func phase2IReleaseDocsExistAndLinkTheOperatorWorkflow() throws {
        let requiredDocuments = [
            "docs/release-runbook.md",
            "docs/release-checklist.md",
            "docs/macos-local-signing.md"
        ]
        for relativePath in requiredDocuments {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path), "Missing \(relativePath)")
        }

        let runbook = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/release-runbook.md"),
            encoding: .utf8
        )
        for snippet in [
            "dist/InterviewCopilotMac.app",
            "dist/InterviewCopilotMac.app/Contents/MacOS/InterviewCopilotMacRunner",
            "$HOME/Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite",
            "$HOME/Library/Application Support/InterviewCopilotMac/runtime_transcript_trace.jsonl",
            "./scripts/verify_runtime_stability.sh",
            "./scripts/runtime_smoke.sh --suite all",
            "./script/build_and_run.sh --verify",
            "./scripts/db_diagnostics.sh"
        ] {
            #expect(runbook.contains(snippet), "Release runbook is missing \(snippet)")
        }

        let checklist = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/release-checklist.md"),
            encoding: .utf8
        )
        #expect(checklist.contains("Do not release if"))
        #expect(checklist.contains("verify_runtime_stability.sh"))
        #expect(checklist.contains("runtime_smoke.sh"))
        #expect(checklist.contains("build_and_run.sh --verify"))

        let signing = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/macos-local-signing.md"),
            encoding: .utf8
        )
        #expect(signing.contains("security find-identity -v -p codesigning"))
        #expect(signing.contains("INTERVIEW_COPILOT_SIGNING_IDENTITY=\"Apple Development: NAME (TEAMID)\""))
        #expect(signing.contains("codesign --verify --deep --strict --verbose=4"))
        #expect(signing.contains("Google Drive"))

        for relativePath in [
            "docs/runtime-regression-checklist.md",
            "docs/ai-coding-agent-rules.md"
        ] {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for requiredLink in requiredDocuments + ["scripts/release_status.sh"] {
                #expect(contents.contains(requiredLink), "\(relativePath) is missing \(requiredLink)")
            }
        }
    }

    @Test
    func releaseStatusScriptIsExecutableReadOnlyAndToleratesMissingRuntimeFiles() throws {
        let url = repositoryRoot.appendingPathComponent("scripts/release_status.sh")
        let sandboxHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-status-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandboxHome) }
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.isExecutableFile(atPath: url.path))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("sqlite3 -readonly"))
        #expect(contents.contains("INTERVIEW_COPILOT_SIGNING_IDENTITY"))
        #expect(contents.contains("security find-identity -v -p codesigning"))

        let result = try runScript(
            at: url,
            currentDirectory: repositoryRoot,
            environment: ["HOME": sandboxHome.path]
        )
        #expect(result.status == 0)
        for label in [
            "Current branch:",
            "Latest commit:",
            "Git status (short):",
            "Latest tags:",
            "App bundle:",
            "Bundle ID:",
            "App binary timestamp:",
            "Expected DB:",
            "Expected trace:",
            "INTERVIEW_COPILOT_SIGNING_IDENTITY:",
            "Available codesigning identities:",
            "Database exists: no",
            "Trace exists: no"
        ] {
            #expect(result.output.contains(label), "release_status.sh is missing \(label)")
        }
    }

    @Test
    func releaseStatusFailsForMissingBundleAndRedactsTraceText() throws {
        let scriptURL = repositoryRoot.appendingPathComponent("scripts/release_status.sh")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("release status fixtures \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let traceURL = sandbox.appendingPathComponent("runtime trace.jsonl")
        let secret = "SECRET INTERVIEW QUESTION"
        try """
        {"event_type":"syntheticEvent","timestamp":"2026-06-19T12:00:00Z","acceptance_status":"accepted","candidate_text":"\(secret)"}
        """.write(to: traceURL, atomically: true, encoding: .utf8)

        let result = try runScript(
            at: scriptURL,
            currentDirectory: repositoryRoot,
            environment: [
                "HOME": sandbox.path,
                "RELEASE_STATUS_APP_BUNDLE": sandbox.appendingPathComponent("Missing.app").path,
                "RELEASE_STATUS_TRACE_PATH": traceURL.path
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("App bundle exists: no"))
        #expect(result.output.contains("Overall release status: FAIL"))
        #expect(result.output.contains("syntheticEvent"))
        #expect(!result.output.contains(secret))
    }

    @Test
    func phase2JDistributionScriptsExposeSafeContracts() throws {
        let packageURL = repositoryRoot.appendingPathComponent("scripts/package_local_release.sh")
        let signingURL = repositoryRoot.appendingPathComponent("scripts/signing_status.sh")

        for url in [packageURL, signingURL] {
            #expect(FileManager.default.fileExists(atPath: url.path), "Missing \(url.lastPathComponent)")
            #expect(FileManager.default.isExecutableFile(atPath: url.path), "Not executable: \(url.lastPathComponent)")
        }

        let help = try runScript(
            at: packageURL,
            currentDirectory: repositoryRoot,
            arguments: ["--help"]
        )
        #expect(help.status == 0)
        #expect(help.output.contains("Usage:"))
        #expect(help.output.contains("--skip-verify"))

        let packageContents = try String(contentsOf: packageURL, encoding: .utf8)
        for snippet in [
            "./scripts/verify_runtime_stability.sh",
            "./script/build_and_run.sh --verify",
            "codesign --verify --deep --strict",
            "RELEASE_INFO.txt",
            "docs/local-workspace-migration.md",
            "docs/notarization-prep.md",
            "docs/rollback-known-good.md",
            "interview_copilot.sqlite",
            "runtime_transcript_trace.jsonl",
            ".git",
            ".build",
            ".DS_Store",
            "._*"
        ] {
            #expect(packageContents.contains(snippet), "Package contract is missing \(snippet)")
        }

        let signing = try runScript(at: signingURL, currentDirectory: repositoryRoot)
        #expect(signing.status == 0)
        for label in [
            "Apple Development identities:",
            "Developer ID Application identities:",
            "INTERVIEW_COPILOT_SIGNING_IDENTITY:",
            "Signing status:"
        ] {
            #expect(signing.output.contains(label), "Signing status is missing \(label)")
        }
        let allowedStatuses = [
            "AD_HOC_ONLY",
            "APPLE_DEVELOPMENT_AVAILABLE",
            "DEVELOPER_ID_AVAILABLE",
            "UNKNOWN"
        ]
        #expect(allowedStatuses.contains { signing.output.contains("Signing status: \($0)") })
    }

    @Test
    func phase2JDocsExistAndReleaseDocsLinkDistributionWorkflow() throws {
        let newDocuments = [
            "docs/local-workspace-migration.md",
            "docs/notarization-prep.md",
            "docs/rollback-known-good.md"
        ]
        for relativePath in newDocuments {
            #expect(
                FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(relativePath).path),
                "Missing \(relativePath)"
            )
        }

        let migration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/local-workspace-migration.md"),
            encoding: .utf8
        )
        #expect(migration.contains("$HOME/Developer/InterviewCopilotMac"))
        #expect(migration.contains("rsync -a --delete"))
        #expect(migration.contains("--exclude '.git'"))

        let notarization = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/notarization-prep.md"),
            encoding: .utf8
        )
        #expect(notarization.contains("Developer ID Application"))
        #expect(notarization.contains("xcrun notarytool"))
        #expect(notarization.contains("xcrun stapler"))
        #expect(notarization.contains("app-specific password"))

        let rollback = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/rollback-known-good.md"),
            encoding: .utf8
        )
        #expect(rollback.contains("git tag --list"))
        #expect(rollback.contains("phase2h-runtime-stability-gate-complete"))
        #expect(rollback.contains("phase2i-release-packaging-complete"))
        #expect(rollback.contains("phase2j-local-distribution-prep-complete"))

        let requiredReferences = [
            "scripts/package_local_release.sh",
            "scripts/signing_status.sh",
            "docs/local-workspace-migration.md",
            "docs/notarization-prep.md",
            "docs/rollback-known-good.md"
        ]
        for relativePath in [
            "docs/release-runbook.md",
            "docs/release-checklist.md",
            "docs/macos-local-signing.md",
            "docs/runtime-regression-checklist.md",
            "docs/ai-coding-agent-rules.md"
        ] {
            let contents = try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for reference in requiredReferences {
                #expect(contents.contains(reference), "\(relativePath) is missing \(reference)")
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runScript(_ relativePath: String, arguments: [String]) throws -> (status: Int32, output: String) {
        try runScript(
            at: repositoryRoot.appendingPathComponent(relativePath),
            currentDirectory: repositoryRoot,
            arguments: arguments
        )
    }

    private func runScript(
        at scriptURL: URL,
        currentDirectory: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
