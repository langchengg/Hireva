import Foundation
import Testing

@Suite("Real audio campaign fixtures", .serialized, .sharedRuntimeResources)
struct RealAudioCampaignFixtureTests {
    @Test
    func deterministicGeneratorProducesReviewedSixteenRoleMatrix() throws {
        guard FileManager.default.isExecutableFile(atPath: generatorURL.path) else {
            Issue.record("The deterministic real-audio campaign fixture generator is missing or not executable.")
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [generatorURL.path, temporaryDirectory.path]
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

        let generatedNames = try scenarioNames(in: temporaryDirectory)
        let reviewedNames = try scenarioNames(in: reviewedFixtureDirectory)
        #expect(generatedNames.count == 16)
        #expect(generatedNames == reviewedNames)

        var roleFamilies = Set<String>()
        var candidateProfiles = Set<String>()
        var opportunityContexts = Set<String>()
        var audioProfiles = Set<String>()
        var voiceSlots = Set<Int>()
        var rates = Set<Int>()
        var turnCount = 0
        var triggerCount = 0
        var rejectCount = 0
        var rapidCount = 0

        for name in generatedNames {
            let generatedURL = temporaryDirectory.appendingPathComponent(name)
            let reviewedURL = reviewedFixtureDirectory.appendingPathComponent(name)
            #expect(try Data(contentsOf: generatedURL) == Data(contentsOf: reviewedURL))

            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: generatedURL)) as? [String: Any]
            )
            let campaign = try #require(object["campaignMetadata"] as? [String: Any])
            roleFamilies.insert(try #require(campaign["roleFamilyID"] as? String))
            let candidate = try #require(object["candidateProfile"] as? [String: Any])
            candidateProfiles.insert(try #require(candidate["sourceProfileID"] as? String))
            let opportunity = try #require(object["opportunityContext"] as? [String: Any])
            opportunityContexts.insert(try #require(opportunity["sourceOpportunityContextID"] as? String))
            let sessions = try #require(object["sessions"] as? [[String: Any]])
            #expect(sessions.count == 1)
            let turns = try #require(sessions.first?["turns"] as? [[String: Any]])
            #expect(turns.count == 8)
            for turn in turns {
                turnCount += 1
                if (turn["expectedShouldTrigger"] as? Bool) == true {
                    triggerCount += 1
                } else {
                    rejectCount += 1
                }
                if (turn["rapid"] as? Bool) == true { rapidCount += 1 }
                audioProfiles.insert(try #require(turn["audioProfile"] as? String))
                voiceSlots.insert(try #require(turn["voiceSlot"] as? Int))
                rates.insert(try #require(turn["rate"] as? Int))
            }

            let validation = try validateScenario(generatedURL)
            #expect(validation.status == 0, Comment(rawValue: validation.output))
        }

        #expect(roleFamilies.count == 16)
        #expect(candidateProfiles.count == 10)
        #expect(opportunityContexts.count == 16)
        #expect(turnCount == 128)
        #expect(triggerCount == 80)
        #expect(rejectCount == 48)
        #expect(rapidCount == 16)
        #expect(audioProfiles == Set([
            "clean", "low_volume", "high_volume_limited",
            "white_noise", "synthetic_cafe_noise", "mild_echo",
        ]))
        #expect(voiceSlots == Set([0, 1, 2, 3]))
        #expect(rates == Set([145, 175, 210]))

        let generatedManifest = temporaryDirectory.appendingPathComponent("manifest.json")
        let reviewedManifest = reviewedFixtureDirectory.appendingPathComponent("manifest.json")
        #expect(try Data(contentsOf: generatedManifest) == Data(contentsOf: reviewedManifest))
    }

    private func scenarioNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("role-") && $0.hasSuffix(".json") }
            .sorted()
    }

    private func validateScenario(_ scenarioURL: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runnerURL.path, "--validate-scenario", scenarioURL.path]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationStatus, output)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var generatorURL: URL {
        repositoryRoot.appendingPathComponent("scripts/generate_real_audio_campaign_fixtures.rb")
    }

    private var runnerURL: URL {
        repositoryRoot.appendingPathComponent("scripts/run_real_dialogue_verification.sh")
    }

    private var reviewedFixtureDirectory: URL {
        repositoryRoot.appendingPathComponent("scripts/fixtures/real_audio_campaign", isDirectory: true)
    }
}
