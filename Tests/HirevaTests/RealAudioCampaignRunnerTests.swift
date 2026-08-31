import Foundation
import Testing

@Suite("Real audio campaign runner", .serialized, .sharedRuntimeResources)
struct RealAudioCampaignRunnerTests {
    @Test
    func validationPlanIsManifestBoundAndComplete() throws {
        guard FileManager.default.isExecutableFile(atPath: runnerURL.path) else {
            Issue.record("The sequential real-audio campaign runner is missing or not executable.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runnerURL.path, "--validate-plan"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(process.terminationStatus == 0, Comment(rawValue: output))
        #expect(output.contains("REAL_AUDIO_CAMPAIGN_PLAN=valid"))
        #expect(output.contains("REAL_AUDIO_SCENARIOS=16"))
        #expect(output.contains("REAL_AUDIO_TURNS=128"))
        #expect(output.contains("REAL_AUDIO_TRIGGERS=80"))
        #expect(output.contains("REAL_AUDIO_REJECTS=48"))
    }

    private var runnerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/run_real_audio_campaign.sh")
    }
}
