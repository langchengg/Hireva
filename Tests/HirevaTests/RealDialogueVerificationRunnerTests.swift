import CryptoKit
import Foundation
import Testing
@testable import Hireva

@Suite("Real dialogue verification runner")
struct RealDialogueVerificationRunnerTests {
    @Test
    func testScenarioValidationAcceptsExplicitSmallMatrixCounts() throws {
        let result = try validateScenario(
            sessions: [[
                turn("What did you build?", trigger: true, needle: "did you build"),
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
                turn("How do you prevent stale answers?", trigger: true, needle: "prevent stale answers", rapid: true),
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
        let scenario = scenarioPayload(
            sessions: [[turn(question, trigger: true, needle: "did you build")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        let scenarioData = try JSONSerialization.data(withJSONObject: scenario, options: [.sortedKeys])
        try scenarioData.write(to: scenarioURL)
        let scenarioSHA256 = digest(scenarioData)

        try writeJSONLines(
            evidenceEvents(
                scenarioSHA256: scenarioSHA256,
                answerProvider: "local_superseded_question_snapshot"
            ),
            to: eventsURL
        )
        let rejected = try runRunner(["--validate-evidence", scenarioURL.path, eventsURL.path])
        #expect(rejected.status != 0)

        try writeJSONLines(
            evidenceEvents(scenarioSHA256: scenarioSHA256, answerProvider: "ollama_qwen"),
            to: eventsURL
        )
        let accepted = try runRunner(["--validate-evidence", scenarioURL.path, eventsURL.path])
        #expect(accepted.status == 0)
        #expect(accepted.output.contains("transcripts=1 questions=1 generations=1 visible=1"))
        #expect(accepted.output.contains("schema_errors=0 missing_visible_matches=0 invalid_visible=0"))
        #expect(!HirevaVerificationEventPolicy.recordsVisibleSuggestion(
            stageBStatus: "superseded",
            finalVisibleSource: "local_superseded_question_snapshot"
        ))
    }

    @Test
    func testScenarioValidationRejectsUnreviewedProvenanceAndNonReservedEmail() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var payload = scenarioPayload(
            sessions: [[turn("What did you build?", trigger: true, needle: "did you build")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        var provenance = try #require(payload["provenance"] as? [String: Any])
        provenance["reviewedForRelease"] = false
        payload["provenance"] = provenance
        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)
        var result = try runRunner(["--validate-scenario", scenarioURL.path])
        #expect(result.status != 0)
        #expect(result.output.contains("reviewedForRelease=true"))

        provenance["reviewedForRelease"] = true
        payload["provenance"] = provenance
        var candidate = try #require(payload["candidateProfile"] as? [String: Any])
        candidate["evidence"] = [[
            "id": "synthetic-evidence-email",
            "type": "project",
            "statement": "Synthetic contact: fixture-user@unapproved-domain.dev",
        ]]
        payload["candidateProfile"] = candidate
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)
        result = try runRunner(["--validate-scenario", scenarioURL.path])
        #expect(result.status != 0)
        #expect(result.output.contains("non-reserved email address"))
    }

    @Test
    func testScenarioValidationRejectsWeakNeedleAndNonIntegerCountWithoutExecutingIt() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var payload = scenarioPayload(
            sessions: [[turn("What did you build?", trigger: true, needle: "a")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)
        var result = try runRunner(["--validate-scenario", scenarioURL.path])
        #expect(result.status != 0)
        #expect(result.output.contains("specific multi-word needle"))

        let markerURL = temporaryDirectory.appendingPathComponent("must-not-exist")
        payload = scenarioPayload(
            sessions: [[turn("What did you build?", trigger: true, needle: "did you build")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        payload["expectedTurnCount"] = "1$(touch \(markerURL.path))"
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)
        result = try runRunner(["--validate-scenario", scenarioURL.path])
        #expect(result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func testRealRunRejectsSchemaValidButUnapprovedScenarioBeforeCreatingOutput() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelRoot = temporaryDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        let outputURL = temporaryDirectory.appendingPathComponent("output", isDirectory: true)
        let supportURL = temporaryDirectory.appendingPathComponent("support", isDirectory: true)
        let payload = scenarioPayload(
            sessions: [[turn("What did you build?", trigger: true, needle: "did you build")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)

        let result = try runRunner([
            scenarioURL.path,
            outputURL.path,
            supportURL.path,
            modelRoot.path,
        ])

        #expect(result.status != 0)
        #expect(result.output.contains("approved release verification"))
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    @Test
    func testEvidenceValidationRejectsRawTextAndFailureEvents() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        let eventsURL = temporaryDirectory.appendingPathComponent("events.jsonl")
        let scenario = scenarioPayload(
            sessions: [[turn("What did you build?", trigger: true, needle: "did you build")]],
            expectedTurns: 1,
            expectedTriggers: 1,
            expectedRejects: 0
        )
        let scenarioData = try JSONSerialization.data(withJSONObject: scenario, options: [.sortedKeys])
        try scenarioData.write(to: scenarioURL)
        var events = evidenceEvents(scenarioSHA256: digest(scenarioData), answerProvider: "ollama_qwen")
        events[2]["text"] = "raw transcript must never be accepted"
        events.append(event("bootstrap.failed", ["errorCode": "bootstrap_failure"]))
        try writeJSONLines(events, to: eventsURL)

        let result = try runRunner(["--validate-evidence", scenarioURL.path, eventsURL.path])
        #expect(result.status != 0)
        #expect(result.output.contains("failures=1"))
        #expect(result.output.contains("forbidden_fields=1"))
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

        let payload = scenarioPayload(
            sessions: sessions,
            expectedTurns: expectedTurns,
            expectedTriggers: expectedTriggers,
            expectedRejects: expectedRejects
        )
        let scenarioURL = temporaryDirectory.appendingPathComponent("scenario.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: scenarioURL)

        return try runRunner(["--validate-scenario", scenarioURL.path])
    }

    private func scenarioPayload(
        sessions: [[[String: Any]]],
        expectedTurns: Int,
        expectedTriggers: Int,
        expectedRejects: Int
    ) -> [String: Any] {
        [
            "synthetic": true,
            "runID": "synthetic-runner-test",
            "provenance": [
                "schemaVersion": 1,
                "origin": "project_authored_synthetic_fixture",
                "containsRealPersonalData": false,
                "reviewedForRelease": true,
            ],
            "asrProvider": "local_parakeet",
            "answerProvider": "local_qwen",
            "qwenModel": "qwen3.5:4b",
            "diagnosticTraceMode": "metadataOnly",
            "candidateProfile": [
                "id": "synthetic-candidate",
                "displayName": "Synthetic Candidate",
                "domain": "software_engineering",
                "evidence": [[
                    "id": "synthetic-candidate-evidence",
                    "type": "project",
                    "statement": "Built a synthetic event-intake service with documented latency checks.",
                ]],
            ],
            "opportunityContext": [
                "id": "synthetic-opportunity",
                "title": "Synthetic Release Engineering Role",
                "evidence": [[
                    "id": "synthetic-opportunity-evidence",
                    "type": "requirement",
                    "statement": "The synthetic role requires deterministic release validation.",
                ]],
            ],
            "expectedSessionCount": sessions.count,
            "expectedTurnCount": expectedTurns,
            "expectedTriggerCount": expectedTriggers,
            "expectedRejectCount": expectedRejects,
            "sessions": sessions.enumerated().map { index, turns in
                ["id": "session-\(index)", "turns": turns]
            },
        ]
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

    private func evidenceEvents(
        scenarioSHA256: String,
        answerProvider: String
    ) -> [[String: Any]] {
        [
            event("bootstrap.started", [
                "runID": "synthetic-runner-test",
                "databaseLocation": "isolated_verification_support",
                "scenarioSHA256": scenarioSHA256,
            ]),
            event("bootstrap.ready", [
                "sessionID": "session-0",
                "contextSnapshotID": "snapshot-1",
                "activeASRProvider": "local_parakeet",
                "systemCaptureRunning": true,
            ]),
            event("sck.first_buffer", [
                "sessionID": "session-0",
                "totalBuffers": 1,
                "sampleRate": 48_000,
                "channelCount": 2,
                "lastBufferAt": "2026-08-27T12:00:00Z",
            ]),
            event("asr.transcript", [
                "sessionID": "session-0",
                "segmentID": "segment-1",
                "textCharacters": 19,
                "textWords": 4,
                "source": "systemAudio",
                "speaker": "interviewer",
                "asrProvider": "local_parakeet",
                "isFinal": true,
                "finalizationReason": "final_accepted",
            ]),
            event("question.accepted", [
                "sessionID": "session-0",
                "questionID": "question-1",
                "questionCharacters": 19,
                "contextSnapshotID": "snapshot-1",
            ]),
            event("generation.started", [
                "sessionID": "session-0",
                "questionID": "question-1",
                "generationID": "generation-1",
                "contextSnapshotID": "snapshot-1",
            ]),
            event("suggestion.visible", [
                "sessionID": "session-0",
                "suggestionID": "suggestion-1",
                "questionID": "question-1",
                "generationID": "generation-1",
                "contextSnapshotID": "snapshot-1",
                "matchedTurnID": "session-0.0",
                "answerCharacters": 64,
                "answerProvider": answerProvider,
                "alignmentVerdict": "aligned",
            ]),
            event("verification.finished", [
                "suggestionRows": 1,
                "databaseLocation": "isolated_verification_support",
                "systemCaptureRunning": false,
            ]),
        ]
    }

    private func event(_ name: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var payload = fields
        payload["event"] = name
        payload["timestamp"] = "2026-08-27T12:00:00Z"
        return payload
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
