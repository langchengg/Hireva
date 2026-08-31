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
            "campaign_status.sh"
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
        #expect(runner.contains("git reset --hard") == false)
        #expect(runner.contains("git clean") == false)
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
