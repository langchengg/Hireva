import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct VerificationBootstrapTests {
    @Test
    func verificationEventsRespectPrivacyAndExplicitFullTextOptIn() throws {
        let fields: [String: Any] = ["sessionID": "synthetic-session", "count": 1,
            "text": "RAW_CANARY", "questionText": "RAW_CANARY", "answer": "RAW_CANARY",
            "latestQuestion": "RAW_CANARY", "error": "RAW_CANARY", "triggerReason": "RAW_CANARY",
            "futureUnreviewedField": "RAW_CANARY"]
        var settings = AppSettings.default
        settings.diagnosticTraceMode = .metadataOnly
        let metadata = try #require(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings))
        #expect(Set(metadata.keys) == ["sessionID", "count"])
        settings.diagnosticTraceMode = .fullText
        settings.saveTranscriptsLocally = true
        #expect(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings)?["answer"] as? String == "RAW_CANARY")
        settings.saveTranscriptsLocally = false
        #expect(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings)?["answer"] == nil)
        settings.diagnosticTraceMode = .off
        #expect(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings) == nil)
    }

    @Test
    func workMetricsAreExplicitlyAllowedWithoutTextAndRespectOffMode() throws {
        let names = [
            "workMetricsMonotonicNS",
            "verificationPendingTasks",
            "generationActiveTasks",
            "generationRetiringTasks",
            "generationPendingTasks",
            "liveDetectionActiveTasks",
            "liveDetectionRetiringTasks",
            "liveDetectionPendingTasks",
            "capturePendingTasks",
            "captureRetiringRecords",
            "captureFailedTeardownRecords",
            "documentImportActiveTasks",
            "documentImportRetiringTasks",
            "documentImportPendingTasks",
            "documentEmbeddingActiveTasks",
            "documentEmbeddingRetiringTasks",
            "documentEmbeddingPendingTasks",
            "ragPrefetchActiveTasks",
            "ragPrefetchRetiringTasks",
            "ragPrefetchPendingTasks",
            "localParakeetOwnerVisible",
            "parakeetOwnedWorkPresent",
            "parakeetCleanupFailurePresent",
            "diagnosticSamplingIdentityCount",
            "diagnosticSamplingIdentityCapacity",
            "diagnosticSamplingIdentityEvictions"
        ]
        var fields: [String: Any] = Dictionary(uniqueKeysWithValues: names.map { ($0, 0 as Any) })
        fields["futureUnreviewedField"] = "RAW_CANARY"
        fields["answer"] = "RAW_CANARY"
        var settings = AppSettings.default
        settings.diagnosticTraceMode = .metadataOnly
        let permitted = try #require(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings))
        #expect(Set(permitted.keys) == Set(names))
        #expect(permitted.values.allSatisfy { $0 is Int })
        #expect(JSONSerialization.isValidJSONObject(permitted))

        // Exercise the actual policy with malformed values under every new
        // metric key. Text and containers must not pass just because the key does.
        let invalidValues: [Any] = [
            "RAW_CANARY", NSString(string: "RAW_CANARY"),
            ["RAW_CANARY"], ["answer": "RAW_CANARY"], NSNull(),
            Data("RAW_CANARY".utf8)
        ]
        for invalidValue in invalidValues {
            var malformed = Dictionary(uniqueKeysWithValues: names.map { ($0, invalidValue) })
            malformed["sessionID"] = "synthetic-session"
            malformed["count"] = 1
            let filtered = try #require(HirevaVerificationEventPolicy.fieldsForLogging(malformed, settings: settings))
            #expect(Set(filtered.keys) == ["sessionID", "count"])
            #expect(JSONSerialization.isValidJSONObject(filtered))
        }
        // NSNumber is a type boundary, not an integer/range validator. The
        // actual emitter uses UInt64 monotonic time and Int counts/0-or-1 indicators.
        let numericValues: [Any] = [0, 1, UInt64(1), 1.5, NSNumber(value: 1), true]
        for numericValue in numericValues {
            let numeric = Dictionary(uniqueKeysWithValues: names.map { ($0, numericValue) })
            let filtered = try #require(HirevaVerificationEventPolicy.fieldsForLogging(numeric, settings: settings))
            #expect(Set(filtered.keys) == Set(names))
            #expect(filtered.values.allSatisfy { $0 is NSNumber })
            #expect(JSONSerialization.isValidJSONObject(filtered))
        }
        settings.diagnosticTraceMode = .off
        #expect(HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings) == nil)
    }

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
    func typedSyntheticProjectFactsRetainExactSourcesAndMustAllBeAdmitted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypedVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentRepository(database: try AppDatabase(path: root.appendingPathComponent("fixture.sqlite")))
        let lines = [
            "I built a small database learning prototype.",
            "I tested transaction rollback with deliberately injected failures.",
            "I compared concurrent updates and index trade offs in the prototype."
        ]
        let statements = [lines.joined(separator: "\n")]
        let seeded = try HirevaVerificationDocumentSeeder.seed(
            in: repository, candidateStatements: statements,
            opportunityStatements: ["The role requires explaining database transactions."],
            candidateEvidenceTypes: ["project"]
        )
        let extraction = StructuredEvidenceExtractor().extract(
            documentID: seeded.candidate.id, classification: .resume,
            content: seeded.candidate.content, persistedChunks: try repository.chunks(type: .cv)
        )
        let evidence = extraction.candidateEvidence
        #expect(evidence.map(\.statement) == lines)
        #expect(evidence.map(\.sourceSpan) == lines.map(Optional.some))
        #expect(evidence.allSatisfy { $0.isUsable && $0.explicitness == .explicit && $0.evidenceType == .project && $0.sourceChunkID != nil })
        func admitted(_ rows: [ProfileEvidence], declared: [String] = statements) -> Bool {
            HirevaVerificationDocumentSeeder.admitsDeclaredCandidateEvidence(
                statements: declared, types: ["project"], documentID: seeded.candidate.id, evidence: rows
            )
        }
        #expect(admitted(evidence))
        #expect(!admitted(Array(evidence.prefix(1))))
        var modified = evidence
        modified[1].explicitness = .inferred
        #expect(!admitted(modified))
        modified = evidence
        modified[1].sourceDocumentID = "different-document"
        #expect(!admitted(modified))
        modified = evidence
        modified[1].sourceSpan = "different-source"
        #expect(!admitted(modified))
        modified = evidence
        modified[1].evidenceType = .skill
        #expect(!admitted(modified))
        #expect(!admitted(evidence, declared: [statements[0] + "\n" + lines[1]]))

        // Untyped product-style extraction retains its conservative behavior.
        let legacy = StructuredEvidenceExtractor().extract(
            documentID: "legacy", classification: .resume, content: statements[0]
        ).candidateEvidence
        #expect(legacy.filter(\.isUsable).count == 1)
        #expect(legacy.suffix(2).allSatisfy { $0.explicitness == .inferred })
    }

    @Test
    func typedSyntheticSectionsResetBetweenEvidenceBlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MixedVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentRepository(database: try AppDatabase(path: root.appendingPathComponent("fixture.sqlite")))
        let statements = ["Designed a synthetic ledger exercise.", "Swift concurrency and SQLite.", "Mentored a small synthetic team."]
        let types = ["project", "skill", "experience"]
        let seeded = try HirevaVerificationDocumentSeeder.seed(
            in: repository, candidateStatements: statements, opportunityStatements: ["Synthetic role requirements."],
            candidateEvidenceTypes: types
        )
        let evidence = StructuredEvidenceExtractor().extract(
            documentID: seeded.candidate.id, classification: .resume, content: seeded.candidate.content
        ).candidateEvidence
        #expect(evidence.map(\.statement) == statements)
        #expect(evidence.map { $0.evidenceType.rawValue } == types)
        #expect(HirevaVerificationDocumentSeeder.admitsDeclaredCandidateEvidence(
            statements: statements, types: types, documentID: seeded.candidate.id, evidence: evidence
        ))
    }

    @Test
    func invalidSyntheticTypesFailBeforeAnyDocumentWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InvalidTypedVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentRepository(database: try AppDatabase(path: root.appendingPathComponent("fixture.sqlite")))
        let invalidDeclarations: [([String], [String])] = [
            (["A declared synthetic statement."], []),
            (["A declared synthetic statement."], ["other"]),
            (["A declared synthetic statement."], ["required_skill"]),
            (["A declared synthetic statement."], ["unknown"]),
            (["A declared synthetic statement."], ["project", "skill"]),
            ([], []), ([""], ["project"]), ([" \n\t"], ["project"])
        ]
        for (statements, types) in invalidDeclarations {
            #expect(throws: (any Error).self) {
                try HirevaVerificationDocumentSeeder.seed(
                    in: repository, candidateStatements: statements,
                    opportunityStatements: ["A synthetic role."], candidateEvidenceTypes: types
                )
            }
            #expect(try repository.documents().isEmpty)
        }
        #expect(!HirevaVerificationDocumentSeeder.admitsDeclaredCandidateEvidence(
            statements: [], types: [], documentID: "fixture", evidence: []
        ))
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
