import Foundation
import Testing

struct CampaignVerificationScriptTests {
    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    @Test
    func campaignShellEntrypointsAreSyntacticallyValidAndDocumentForegroundExecution() throws {
        let scripts = [
            "run_24h_campaign.sh",
            "resume_24h_campaign.sh",
            "campaign_status.sh",
            "prepare_local_integration.sh"
        ]
        for scriptName in scripts {
            let script = repositoryRoot
                .appendingPathComponent("scripts/verification")
                .appendingPathComponent(scriptName)
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            let result = try run(
                executable: "/bin/bash",
                arguments: ["-n", script.path],
                currentDirectory: repositoryRoot
            )
            #expect(result.status == 0, Comment(rawValue: result.output))
        }

        let runner = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verification/run_24h_campaign.sh"),
            encoding: .utf8
        )
        #expect(runner.contains("Active time advances\nonly while this supervisor is running"))
        #expect(runner.contains("HIREVA_FIXED_USER_HOME"))
        #expect(runner.contains("trap cleanup EXIT"))
        #expect(runner.contains(".retry-"))
        #expect(runner.contains("wc -l < \"$FAILURE_QUEUE\"") == false)
        #expect(runner.contains("max // 0"))
        #expect(runner.contains("HIREVA_DB_DIAGNOSTICS_DB_PATH"))
        #expect(runner.contains("HIREVA_DB_DIAGNOSTICS_TRACE_PATH"))
        #expect(runner.contains("env HOME=") == false)
        #expect(runner.contains("/bin/ps -axo pid=,comm="))
        #expect(runner.contains("while read -r pid executable"))
        #expect(runner.contains("done < <(/bin/ps -axo pid=,comm=)"))
        #expect(runner.contains("$2 == app") == false)
        #expect(runner.contains("owned runtime processes remain after SIGKILL"))
        #expect(runner.contains("git reset --hard") == false)
        #expect(runner.contains("git clean") == false)

        let integrationPreflight = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/verification/prepare_local_integration.sh"
            ),
            encoding: .utf8
        )
        #expect(integrationPreflight.contains(".legacy-migration.json"))
        #expect(integrationPreflight.contains("build_parakeet_helper.sh"))
        #expect(integrationPreflight.contains("generate_synthetic_parakeet_fixture.sh"))
        #expect(integrationPreflight.contains("validate_synthetic_audio_provenance.rb"))
        #expect(integrationPreflight.contains("--probe-model"))
        #expect(integrationPreflight.contains("qwen3.5:4b"))
        for requiredEnvironment in [
            "HIREVA_REAL_OLLAMA_SMOKE=1",
            "RUN_LOCAL_QWEN_EXTRACTION_TEST=1",
            "HIREVA_REAL_PARAKEET_STREAM_TEST=1",
            "HIREVA_PARAKEET_HELPER_PATH",
            "HIREVA_PARAKEET_MODEL_PATH",
            "HIREVA_PARAKEET_TEST_AUDIO",
            "HIREVA_PARAKEET_TEST_AUDIO_PROVENANCE"
        ] {
            #expect(runner.contains(requiredEnvironment))
        }
    }

    @Test
    func campaignPersistsTerminalStatusBeforeGeneratingReports() throws {
        let runner = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verification/run_24h_campaign.sh"),
            encoding: .utf8
        )
        let expectedFinalizationOrder = """
        if (( FINAL_FAILURES == 0 )); then
            CAMPAIGN_EXIT_REASON="completed"
        else
            CAMPAIGN_EXIT_REASON="completed_with_failures"
        fi
        persist_state
        python3 "$ROOT_DIR/scripts/verification/analyze_campaign_results.py"
        """
        #expect(runner.contains(expectedFinalizationOrder))
    }

    @Test
    func campaignAnalyzerDoesNotTreatMissingEvidenceAsPassing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaCampaignAnalyzer-\(UUID().uuidString)")
        let stateDirectory = sandbox.appendingPathComponent("state")
        let artifactDirectory = sandbox.appendingPathComponent("artifacts")
        let resultsDirectory = artifactDirectory.appendingPathComponent("results")
        let reportsDirectory = artifactDirectory.appendingPathComponent("reports")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)

        let state: [String: Any] = [
            "campaign_id": "synthetic-campaign",
            "status": "interrupted",
            "start_time_utc": "2026-08-31T00:00:00Z",
            "target_end_time_utc": "2026-09-01T00:00:00Z",
            "active_elapsed_seconds": 60,
            "target_active_seconds": 86_400,
            "completed_cycles": 0,
            "base_commit": String(repeating: "a", count: 40),
            "last_good_commit": String(repeating: "a", count: 40),
            "branch": "synthetic",
            "state_dir": stateDirectory.path,
            "artifact_dir": artifactDirectory.path
        ]
        let stateData = try JSONSerialization.data(
            withJSONObject: state,
            options: [.prettyPrinted, .sortedKeys]
        )
        try stateData.write(to: stateDirectory.appendingPathComponent("campaign_state.json"))
        for path in [
            stateDirectory.appendingPathComponent("failure_queue.jsonl"),
            stateDirectory.appendingPathComponent("research_sources.jsonl"),
            stateDirectory.appendingPathComponent("checkpoints.jsonl"),
            resultsDirectory.appendingPathComponent("scenario_results.jsonl"),
            resultsDirectory.appendingPathComponent("real_audio_results.jsonl"),
            resultsDirectory.appendingPathComponent("answer_quality_results.jsonl")
        ] {
            try Data().write(to: path)
        }

        let analyzer = repositoryRoot
            .appendingPathComponent("scripts/verification/analyze_campaign_results.py")
        let result = try run(
            executable: "/usr/bin/env",
            arguments: [
                "python3", analyzer.path,
                "--state-dir", stateDirectory.path,
                "--artifact-dir", artifactDirectory.path
            ],
            currentDirectory: repositoryRoot
        )
        #expect(result.status == 0, Comment(rawValue: result.output))
        let metricsData = try Data(
            contentsOf: reportsDirectory.appendingPathComponent("metrics.json")
        )
        let metrics = try #require(
            JSONSerialization.jsonObject(with: metricsData) as? [String: Any]
        )
        #expect(metrics["scenario_results"] as? Int == 0)
        #expect(metrics["scenario_passes"] as? Int == 0)
        let report = try String(
            contentsOf: reportsDirectory.appendingPathComponent("full_campaign_report.md"),
            encoding: .utf8
        )
        #expect(report.contains("Full duration reached: `no`"))
        #expect(report.contains(
            "Empty or missing categories are\nnot treated as passed or verified."
        ))
    }
}
