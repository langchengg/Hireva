import Foundation
import Testing
@testable import Hireva

@Suite("Real dialogue verification runner")
struct RealDialogueVerificationRunnerTests {
    @Test
    func testScenarioValidationAcceptsExplicitSmallMatrixCounts() throws {
        let result = try validateScenario(
            sessions: [[
                turn("What did you build?", trigger: true, needle: "build"),
                turn("The room is quiet.", trigger: false),
            ]],
            expectedTurns: 2,
            expectedTriggers: 1,
            expectedRejects: 1
        )

        #expect(result.status == 0)
        #expect(result.output.contains("sessions=1 turns=2 triggers=1 rejects=1 visible=1 rapid_cancellations=0"))
    }

    @Test
    func testScenarioValidationTreatsRapidGenerationAsCancelledByFollowUp() throws {
        let result = try validateScenario(
            sessions: [[
                turn("How do you prevent stale answers?", trigger: true, needle: "stale", rapid: true),
                turn("What if another question arrives?", trigger: true, needle: "another question"),
            ]],
            expectedTurns: 2,
            expectedTriggers: 2,
            expectedRejects: 0
        )

        #expect(result.status == 0)
        #expect(result.output.contains("visible=1 rapid_cancellations=1"))
    }

    @Test
    func testEvidenceValidationRejectsSupersededSnapshotAsVisibleAnswer() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        let eventsURL = temporaryDirectory.appendingPathComponent("events.jsonl")
        let question = "What did you build?"
        let scenario: [String: Any] = [
            "synthetic": true,
            "expectedSessionCount": 1,
            "expectedTurnCount": 1,
            "expectedTriggerCount": 1,
            "expectedRejectCount": 0,
            "sessions": [[
                "id": "session-1",
                "turns": [turn(question, trigger: true, needle: "build")],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: scenario).write(to: scenarioURL)

        let commonEvents: [[String: Any]] = [
            ["event": "bootstrap.ready"],
            ["event": "sck.first_buffer"],
            ["event": "asr.transcript"],
            ["event": "question.accepted"],
            ["event": "generation.started"],
        ]
        let snapshotEvent: [String: Any] = [
            "event": "suggestion.visible",
            "questionText": question,
            "answerProvider": "local_superseded_question_snapshot",
            "alignmentVerdict": "aligned",
        ]
        try writeJSONLines(commonEvents + [snapshotEvent], to: eventsURL)
        let rejected = try runRunner(["--validate-evidence", scenarioURL.path, eventsURL.path])
        #expect(rejected.status != 0)

        let qwenEvent: [String: Any] = [
            "event": "suggestion.visible",
            "questionText": question,
            "answerProvider": "ollama_qwen",
            "alignmentVerdict": "aligned",
        ]
        try writeJSONLines(commonEvents + [qwenEvent], to: eventsURL)
        let accepted = try runRunner(["--validate-evidence", scenarioURL.path, eventsURL.path])
        #expect(accepted.status == 0)
        #expect(accepted.output.contains("transcripts=1 questions=1 generations=1 visible=1"))
        #expect(accepted.output.contains("missing_visible_needles=0 invalid_visible=0"))
        #expect(!HirevaVerificationEventPolicy.recordsVisibleSuggestion(
            stageBStatus: "superseded",
            finalVisibleSource: "local_superseded_question_snapshot"
        ))
    }

    private func validateScenario(
        sessions: [[[String: Any]]],
        expectedTurns: Int,
        expectedTriggers: Int,
        expectedRejects: Int
    ) throws -> (status: Int32, output: String) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let payload: [String: Any] = [
            "synthetic": true,
            "expectedSessionCount": sessions.count,
            "expectedTurnCount": expectedTurns,
            "expectedTriggerCount": expectedTriggers,
            "expectedRejectCount": expectedRejects,
            "sessions": sessions.enumerated().map { index, turns in
                ["id": "session-\(index)", "turns": turns]
            },
        ]
        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)

        return try runRunner(["--validate-scenario", scenarioURL.path])
    }

    private func runRunner(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runnerURL.path] + arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    private func writeJSONLines(_ values: [[String: Any]], to url: URL) throws {
        var data = Data()
        for value in values {
            data.append(try JSONSerialization.data(withJSONObject: value))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func turn(
        _ text: String,
        trigger: Bool,
        needle: String? = nil,
        rapid: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = [
            "text": text,
            "expectedShouldTrigger": trigger,
            "rate": 175,
            "voiceSlot": 0,
        ]
        if let needle { value["expectedQuestionNeedle"] = needle }
        if rapid { value["rapid"] = true }
        return value
    }

    private var runnerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/run_real_dialogue_verification.sh")
    }
}
