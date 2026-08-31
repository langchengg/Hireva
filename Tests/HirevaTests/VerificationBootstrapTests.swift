import CryptoKit
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct VerificationBootstrapTests {
    @Test
    func transcriptEvidenceExcludesSystemStatusAndRecordsInterviewSpeaker() {
        #expect(!HirevaVerificationEventPolicy.recordsTranscript(isSystemSpeaker: true))
        #expect(HirevaVerificationEventPolicy.recordsTranscript(isSystemSpeaker: false))
        #expect(!HirevaVerificationEventPolicy.recordsTranscript(
            isSystemSpeaker: false,
            isFinal: false
        ))
    }

    @Test
    func visibleSuggestionEvidenceRetainsHistoryAndDeduplicatesCurrentCard() {
        let history = ["answer-a", "answer-b"]
        #expect(HirevaVerificationEventPolicy.orderedUniqueCandidates(
            history: history,
            current: "answer-b",
            id: { $0 }
        ) == history)
        #expect(HirevaVerificationEventPolicy.orderedUniqueCandidates(
            history: history,
            current: "answer-c",
            id: { $0 }
        ) == ["answer-a", "answer-b", "answer-c"])
        let payload: [String: Any] = [
            "alignmentVerdict": HirevaVerificationEventPolicy.alignmentVerdictValue(.aligned),
        ]
        #expect(JSONSerialization.isValidJSONObject(payload))
        #expect(payload["alignmentVerdict"] as? String == "aligned")
    }

    @Test
    func everyTriggeringTurnIncludingRapidCanMapVisibleEvidence() throws {
        let ordinary = try #require(HirevaVerificationEventPolicy.expectedTurnMatch(
            sessionID: "session-1",
            turnIndex: 1,
            expectedShouldTrigger: true,
            isRapid: false,
            expectedQuestionNeedle: "ordinary question"
        ))
        let rapid = try #require(HirevaVerificationEventPolicy.expectedTurnMatch(
            sessionID: "session-1",
            turnIndex: 2,
            expectedShouldTrigger: true,
            isRapid: true,
            expectedQuestionNeedle: "rapid question"
        ))

        #expect(ordinary.turnID == "session-1.1")
        #expect(rapid.turnID == "session-1.2")
        #expect(HirevaVerificationEventPolicy.expectedTurnMatch(
            sessionID: "session-1",
            turnIndex: 3,
            expectedShouldTrigger: false,
            isRapid: false,
            expectedQuestionNeedle: nil
        ) == nil)
    }

    @Test
    func visibleEvidenceMatchingNormalizesSpokenAndNumericNumberForms() {
        #expect(HirevaVerificationEventPolicy.questionContainsExpectedNeedle(
            question: "You deployed the pipeline to 1 million production users, correct?",
            needle: "one million production users"
        ))
        #expect(HirevaVerificationEventPolicy.questionContainsExpectedNeedle(
            question: "Was the measured improvement 20 percent?",
            needle: "twenty percent"
        ))
        #expect(!HirevaVerificationEventPolicy.questionContainsExpectedNeedle(
            question: "You deployed the pipeline to 2 million production users, correct?",
            needle: "one million production users"
        ))
        #expect(!HirevaVerificationEventPolicy.questionContainsExpectedNeedle(
            question: "The pipeline served one hundred test cases.",
            needle: "one million production users"
        ))
    }

    @Test
    func verificationEvidenceAllowlistRejectsPathsRawAnswersAndErrors() {
        #expect(HirevaVerificationEventPolicy.allows(
            event: "bootstrap.started",
            fields: ["runID": "synthetic-run", "databaseLocation": "isolated_verification_support", "scenarioSHA256": String(repeating: "a", count: 64)]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(
            event: "bootstrap.started",
            fields: ["databasePath": "private-path-token"]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(
            event: "suggestion.visible",
            fields: ["answer": "private-answer-token"]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(
            event: "suggestion.visible",
            fields: ["questionText": "private-question-token"]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(
            event: "dialogue.decision",
            fields: ["ignoredReason": "private-reason-token"]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(
            event: "app.error",
            fields: ["error": "private-error-token"]
        ))
        #expect(!HirevaVerificationEventPolicy.allows(event: "unknown.event", fields: [:]))
        #expect(HirevaVerificationEventPolicy.finalizationReasonCode("final is longer or similar") == "final_accepted")
        #expect(HirevaVerificationEventPolicy.finalizationReasonCode("provider supplied detail") == "other")
        #expect(HirevaVerificationEventPolicy.verificationTurnID(sessionID: "session-1", turnIndex: 2) == "session-1.2")
    }

    @Test
    func verificationErrorCodeClassifiesPermissionStateWithoutRawErrorText() {
        let canary = "HIREVA_PRIVATE_ERROR_CANARY"
        let cases: [(ScreenSystemAudioPermissionState, String)] = [
            (.granted, "app_reported_error"),
            (.permissionMissing, "screen_audio_permission_missing"),
            (.restartLikely, "screen_audio_restart_required"),
            (.identityMismatch, "screen_audio_identity_mismatch"),
            (.shareableContentProbeFailed(canary), "screen_audio_shareable_probe_failed"),
            (.streamAudioProbeFailed(canary), "screen_audio_stream_probe_failed"),
        ]

        for (state, expectedCode) in cases {
            let code = HirevaVerificationEventPolicy.appErrorCode(systemAudioPermissionState: state)
            #expect(code == expectedCode)
            #expect(!code.contains(canary))
        }
    }

    @Test
    func syntheticDocumentSeederSatisfiesProductionOnboardingGate() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerificationSeeder-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let database = try AppDatabase(path: databaseURL)
        let repository = DocumentRepository(database: database)
        let seeded = try HirevaVerificationDocumentSeeder.seed(
            in: repository,
            candidateStatements: [String(repeating: "Swift system audio reliability evidence. ", count: 12)],
            opportunityStatements: [String(repeating: "Role requires macOS release engineering. ", count: 12)]
        )

        #expect(seeded.candidate.type == DocumentType.cv)
        #expect(seeded.opportunity.type == DocumentType.jobDescription)
        #expect(!ProductionContextPolicy.isSynthetic(id: seeded.candidate.id, name: seeded.candidate.title))
        #expect(!ProductionContextPolicy.isSynthetic(id: seeded.opportunity.id, name: seeded.opportunity.title))
        #expect(try repository.isOnboardingComplete())
    }

    @Test
    func verificationReadinessAcceptsOnlyUsableContextStates() {
        #expect(HirevaVerificationReadinessPolicy.accepts(.ready, hasUsableCandidateContext: true))
        #expect(HirevaVerificationReadinessPolicy.accepts(.needsReview, hasUsableCandidateContext: true))
        #expect(!HirevaVerificationReadinessPolicy.accepts(.ready, hasUsableCandidateContext: false))
        #expect(!HirevaVerificationReadinessPolicy.accepts(.noDocuments, hasUsableCandidateContext: true))
    }

    @Test
    func configurationRequiresEveryFailClosedInputAndSyntheticScenario() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VerificationConfig-\(UUID().uuidString)")
        let output = root.appendingPathComponent("output", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let scenario = root.appendingPathComponent("scenario.json")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [root, output, support, models] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let scenarioSHA256 = try writeConfigurationScenario(
            to: scenario,
            synthetic: true,
            runID: "verification-test"
        )

        var environment = [
            "HIREVA_VERIFICATION_MODE": "1",
            "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
            "HIREVA_VERIFICATION_SCENARIO_SHA256": scenarioSHA256,
            "HIREVA_VERIFICATION_RUN_NONCE": String(repeating: "a", count: 32),
            "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
            "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
            "HIREVA_VERIFICATION_MODEL_ROOT": models.path,
        ]
        let configuration = try #require(HirevaVerificationConfiguration.load(
            environment: environment,
            bundleSourceRoot: "/definitely/a/different/source/root"
        ))
        #expect(configuration.runID == "verification-test")
        #expect(configuration.runNonce == String(repeating: "a", count: 32))
        #expect(configuration.scenarioSHA256 == scenarioSHA256)
        #expect(configuration.outputDirectory == output.standardizedFileURL)
        #expect(configuration.applicationSupportDirectory == support.standardizedFileURL)
        #expect(configuration.localModelsDirectory == models.standardizedFileURL)
        #expect(configuration.userDefaultsSuiteName.hasSuffix(".\(String(repeating: "a", count: 32))"))

        var secondRunEnvironment = environment
        secondRunEnvironment["HIREVA_VERIFICATION_RUN_NONCE"] = String(repeating: "b", count: 32)
        let secondRun = try #require(HirevaVerificationConfiguration.load(
            environment: secondRunEnvironment,
            bundleSourceRoot: nil
        ))
        #expect(secondRun.userDefaultsSuiteName != configuration.userDefaultsSuiteName)

        let scenarioLink = root.appendingPathComponent("scenario-link.json")
        try FileManager.default.createSymbolicLink(at: scenarioLink, withDestinationURL: scenario)
        var linkedScenario = environment
        linkedScenario["HIREVA_VERIFICATION_SCENARIO_PATH"] = scenarioLink.path
        #expect(HirevaVerificationConfiguration.load(environment: linkedScenario, bundleSourceRoot: nil) == nil)

        let outputLink = root.appendingPathComponent("output-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: output)
        var linkedOutput = environment
        linkedOutput["HIREVA_VERIFICATION_OUTPUT_ROOT"] = outputLink.path
        #expect(HirevaVerificationConfiguration.load(environment: linkedOutput, bundleSourceRoot: nil) == nil)

        var missingMode = environment
        missingMode.removeValue(forKey: "HIREVA_VERIFICATION_MODE")
        #expect(HirevaVerificationConfiguration.load(environment: missingMode, bundleSourceRoot: nil) == nil)

        var missingDigest = environment
        missingDigest.removeValue(forKey: "HIREVA_VERIFICATION_SCENARIO_SHA256")
        #expect(HirevaVerificationConfiguration.load(environment: missingDigest, bundleSourceRoot: nil) == nil)

        var missingNonce = environment
        missingNonce.removeValue(forKey: "HIREVA_VERIFICATION_RUN_NONCE")
        #expect(HirevaVerificationConfiguration.load(environment: missingNonce, bundleSourceRoot: nil) == nil)

        try FileHandle(forWritingTo: scenario).closeAfterWriting(Data([0x0A]))
        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil) == nil)

        environment["HIREVA_VERIFICATION_SCENARIO_SHA256"] = try writeConfigurationScenario(
            to: scenario,
            synthetic: false,
            runID: "verification-test"
        )
        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil) == nil)
    }

    @Test
    func configurationRejectsRepositoryContainedOutputAndMissingModelRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VerificationContainment-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let output = sourceRoot.appendingPathComponent("output", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let scenario = root.appendingPathComponent("scenario.json")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [sourceRoot, output, support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let scenarioSHA256 = try writeConfigurationScenario(
            to: scenario,
            synthetic: true,
            runID: "containment-test"
        )
        let environment = [
            "HIREVA_VERIFICATION_MODE": "1",
            "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
            "HIREVA_VERIFICATION_SCENARIO_SHA256": scenarioSHA256,
            "HIREVA_VERIFICATION_RUN_NONCE": String(repeating: "c", count: 32),
            "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
            "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
            "HIREVA_VERIFICATION_MODEL_ROOT": root.appendingPathComponent("missing-model-root").path,
        ]

        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: sourceRoot.path) == nil)
        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil) == nil)
    }

    private func writeConfigurationScenario(
        to url: URL,
        synthetic: Bool,
        runID: String
    ) throws -> String {
        let payload: [String: Any] = [
            "synthetic": synthetic,
            "runID": runID,
            "provenance": [
                "schemaVersion": 1,
                "origin": "project_authored_synthetic_fixture",
                "containsRealPersonalData": false,
                "reviewedForRelease": true,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension FileHandle {
    func closeAfterWriting(_ data: Data) throws {
        try seekToEnd()
        try write(contentsOf: data)
        try close()
    }
}
