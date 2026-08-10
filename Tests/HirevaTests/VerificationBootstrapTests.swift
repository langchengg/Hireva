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
        try #"{"synthetic":true,"runID":"verification-test"}"#.write(to: scenario, atomically: true, encoding: .utf8)

        let environment = [
            "HIREVA_VERIFICATION_MODE": "1",
            "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
            "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
            "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
            "HIREVA_VERIFICATION_MODEL_ROOT": models.path,
        ]
        let configuration = try #require(HirevaVerificationConfiguration.load(
            environment: environment,
            bundleSourceRoot: "/definitely/a/different/source/root"
        ))
        #expect(configuration.runID == "verification-test")
        #expect(configuration.outputDirectory == output.standardizedFileURL)
        #expect(configuration.applicationSupportDirectory == support.standardizedFileURL)
        #expect(configuration.localModelsDirectory == models.standardizedFileURL)

        var missingMode = environment
        missingMode.removeValue(forKey: "HIREVA_VERIFICATION_MODE")
        #expect(HirevaVerificationConfiguration.load(environment: missingMode, bundleSourceRoot: nil) == nil)

        try #"{"synthetic":false,"runID":"verification-test"}"#.write(to: scenario, atomically: true, encoding: .utf8)
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
        try #"{"synthetic":true,"runID":"containment-test"}"#.write(to: scenario, atomically: true, encoding: .utf8)
        let environment = [
            "HIREVA_VERIFICATION_MODE": "1",
            "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
            "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
            "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
            "HIREVA_VERIFICATION_MODEL_ROOT": root.appendingPathComponent("missing-model-root").path,
        ]

        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: sourceRoot.path) == nil)
        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil) == nil)
    }
}
