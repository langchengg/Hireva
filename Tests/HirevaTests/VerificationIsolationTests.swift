import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct VerificationIsolationTests {
    @Test(arguments: ["valid", "production", "microphone", "combined", "backend", "revoked", "replaced", "before_factory"])
    @MainActor
    func actualPCMCommitPreservesExclusiveFileAndFrozenConsent(boundary: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scenario = URL(fileURLWithPath: try #require(fixture.environment["HIREVA_VERIFICATION_SCENARIO_PATH"]))
        try #"{"synthetic":true,"runID":"pcm-file-test","retainNativePCM":true,"controlledAudioProcessID":12345,"controlledAudioBundleIdentifier":"synthetic.owned.player"}"#.write(to: scenario, atomically: true, encoding: .utf8)
        let configuration = try #require(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil))
        let consent = PersistenceConsent()
        let ticket = consent.ticket()
        let capture: AudioCaptureMode = boundary == "microphone" ? .microphoneOnly : boundary == "combined" ? .microphoneAndSystem : .systemAudioOnly
        if ["production", "microphone", "combined", "backend"].contains(boundary) {
            #expect(throws: CancellationError.self) {
                _ = try AppState.verificationPCMCommit(verification: configuration, verificationOnlyBundle: boundary != "production",
                    captureMode: capture, provider: boundary == "backend" ? .appleSpeech : .localParakeet, consent: consent, ticket: ticket)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path).isEmpty)
            return
        }
        if boundary == "before_factory" {
            let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: configuration.outputDirectory, to: fixture.root.appendingPathComponent("old-output"))
            try FileManager.default.createSymbolicLink(at: configuration.outputDirectory, withDestinationURL: replacement)
            #expect(throws: POSIXError.self) {
                _ = try AppState.verificationPCMCommit(verification: configuration, verificationOnlyBundle: true,
                    captureMode: capture, provider: .localParakeet, consent: consent, ticket: ticket)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: replacement.path).isEmpty)
            return
        }
        let commit = try #require(try AppState.verificationPCMCommit(verification: configuration, verificationOnlyBundle: true,
            captureMode: capture, provider: .localParakeet, consent: consent, ticket: ticket))
        let diagnostics = ParakeetAudioWriterDiagnostics(maximumPendingChunks: 2048, maximumPendingBytes: 8 * 1024 * 1024,
            pendingChunks: 0, pendingBytes: 0, droppedChunks: 0)
        let payload = Data("synthetic exact PCM wire bytes\n".utf8)
        if boundary == "revoked" {
            consent.update(enabled: false); consent.update(enabled: true)
            #expect(throws: CancellationError.self) { try commit(payload, 1, false, diagnostics) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path).isEmpty)
        } else if boundary == "replaced" {
            let old = fixture.root.appendingPathComponent("old-output")
            try FileManager.default.moveItem(at: configuration.outputDirectory, to: old)
            try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: false)
            #expect(throws: POSIXError.self) { try commit(payload, 1, false, diagnostics) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: configuration.outputDirectory.path).isEmpty)
        } else {
            try commit(payload, 1, false, diagnostics)
            let file = try #require(FileManager.default.contentsOfDirectory(at: configuration.outputDirectory,
                includingPropertiesForKeys: nil).first)
            #expect(try Data(contentsOf: file) == payload)
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(throws: POSIXError.self) { try commit(Data("overwrite".utf8), 1, false, diagnostics) }
            #expect(try Data(contentsOf: file) == payload)
        }
    }

    @Test(arguments: ["absent", "false", "true", "1", "\"true\"", "null"])
    func nativePCMEvidenceRequiresBooleanOptInAndControlledOwner(value: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scenario = URL(fileURLWithPath: try #require(fixture.environment["HIREVA_VERIFICATION_SCENARIO_PATH"]))
        let field = value == "absent" ? "" : ",\"retainNativePCM\":\(value)"
        for owner in [false, true] {
            let identity = owner ? ",\"controlledAudioProcessID\":12345,\"controlledAudioBundleIdentifier\":\"synthetic.owned.player\"" : ""
            try "{\"synthetic\":true,\"runID\":\"pcm-isolation-test\"\(identity)\(field)}".write(to: scenario, atomically: true, encoding: .utf8)
            let configuration = HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil)
            let valid = value == "absent" || value == "false" || (value == "true" && owner)
            #expect((configuration != nil) == valid)
            if valid { #expect(configuration?.retainNativePCM == (value == "true")) }
        }
    }

    @Test
    func validVerificationUsesOnlyInMemoryCredentialsOutsideTests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try #require(HirevaVerificationConfiguration.load(
            environment: fixture.environment, bundleSourceRoot: nil
        ))
        let store = KeychainService.defaultStore(isTestProcess: false, verification: configuration)
        #expect(store is InMemoryMockKeychainStore)
        // Do not call SecItem on a failed red assertion. Only the in-memory
        // implementation receives synthetic credentials.
        if let mock = store as? InMemoryMockKeychainStore {
            let keys = KeychainService(store: mock)
            try keys.saveAPIKey("synthetic-verification-credential")
            #expect(try keys.loadAPIKey() == "synthetic-verification-credential")
        }
    }

    @Test
    func validSyntheticStartupDoesNotImportProductionIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var productionCalls = 0
        try HirevaStartup.preparePersistentIdentity(environment: fixture.environment,
            bundleSourceRoot: nil, migrateProduction: { productionCalls += 1 })
        #expect(productionCalls == 0)
    }

    @Test
    func startupUsesTheSameFrozenConfigurationAsStorageAfterScenarioRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try #require(HirevaVerificationConfiguration.load(
            environment: fixture.environment, bundleSourceRoot: nil))
        try FileManager.default.removeItem(at: configuration.scenarioURL)
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil) == nil)
        var productionCalls = 0
        try HirevaStartup.preparePersistentIdentity(environment: fixture.environment,
            verificationOnlyBundle: true, verificationConfiguration: configuration,
            migrateProduction: { productionCalls += 1 })
        #expect(productionCalls == 0)
        #expect(configuration.applicationSupportDirectory.path == fixture.environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"])
        #expect(throws: HirevaStartupError.self) {
            try HirevaStartup.preparePersistentIdentity(environment: fixture.environment,
                verificationOnlyBundle: true, verificationConfiguration: nil,
                migrateProduction: { productionCalls += 1 })
        }
        #expect(productionCalls == 0)
    }

    @Test
    func invalidExplicitVerificationFailsBeforeProductionMigration() throws {
        var productionCalls = 0
        do {
            try HirevaStartup.preparePersistentIdentity(environment: ["HIREVA_VERIFICATION_MODE": "1"],
                bundleSourceRoot: nil, migrateProduction: { productionCalls += 1 })
            Issue.record("Invalid explicit verification must fail closed before production migration.")
        } catch {
            #expect(error.localizedDescription.contains("verification configuration"))
        }
        #expect(productionCalls == 0)
    }

    @Test
    func verificationOnlyBundleWithoutIsolationCannotMigrateProduction() throws {
        for environment: [String: String] in [[:], ["HIREVA_VERIFICATION_MODE": "0"],
            ["HIREVA_VERIFICATION_MODE": ""], ["HIREVA_VERIFICATION_MODE": "true"]] {
            var productionCalls = 0
            do {
                try HirevaStartup.preparePersistentIdentity(environment: environment,
                    bundleSourceRoot: nil, verificationOnlyBundle: true,
                    migrateProduction: { productionCalls += 1 })
                Issue.record("An acceptance bundle must reject a relaunch that loses its isolation environment.")
            } catch {
                #expect(error.localizedDescription.contains("verification configuration"))
            }
            #expect(productionCalls == 0)
        }
    }

    @Test
    func verificationOnlyBundleWithValidIsolationStillStartsSafely() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var productionCalls = 0
        try HirevaStartup.preparePersistentIdentity(environment: fixture.environment,
            bundleSourceRoot: nil, verificationOnlyBundle: true,
            migrateProduction: { productionCalls += 1 })
        #expect(productionCalls == 0)
    }

    @Test
    func ordinaryStartupPreservesItsExistingIdentityAndCredentialBackend() throws {
        var productionCalls = 0
        try HirevaStartup.preparePersistentIdentity(environment: [:], bundleSourceRoot: nil,
            migrateProduction: { productionCalls += 1 })
        #expect(productionCalls == 1)
        #expect(KeychainService.defaultStore(isTestProcess: false, verification: nil) is RealKeychainStore)
        #expect(KeychainService.defaultStore(isTestProcess: true, verification: nil) is InMemoryMockKeychainStore)
        #expect(KeychainConstants.service == HirevaProductIdentity.keychainService)
        #expect(KeychainConstants.deepSeekAccount == "deepseek.default")
    }

    @Test
    func partialOrMisspelledVerificationCannotFallThroughToProduction() throws {
        for environment in [["HIREVA_VERIFICATION_MODE": "true"],
            ["HIREVA_VERIFICATION_MODE": "0"],
            ["HIREVA_VERIFICATION_APP_SUPPORT_DIR": "/synthetic/missing"]] {
            var productionCalls = 0
            #expect(throws: HirevaStartupError.self) {
                try HirevaStartup.preparePersistentIdentity(environment: environment,
                    bundleSourceRoot: nil, migrateProduction: { productionCalls += 1 })
            }
            #expect(productionCalls == 0)
            #expect(VerificationPermissionAdmission.resolve(verification: nil,
                environment: environment, verificationOnlyBundle: false) == .invalidVerification)
        }
    }

    @Test
    func relativeWritablePathsAndRepositorySymlinkAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for key in ["HIREVA_VERIFICATION_APP_SUPPORT_DIR", "HIREVA_VERIFICATION_OUTPUT_ROOT"] {
            var environment = fixture.environment
            environment[key] = "."
            #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil) == nil)
        }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var ancestor = fixture.environment
        ancestor["HIREVA_VERIFICATION_OUTPUT_ROOT"] = fixture.root.path
        #expect(HirevaVerificationConfiguration.load(environment: ancestor, bundleSourceRoot: source.path) == nil)
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        var environment = fixture.environment
        environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"] = alias.path
        #expect(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: source.path) == nil)
    }

    @Test
    func writableChildSymlinkCannotRedirectTheIsolatedDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canary = fixture.root.appendingPathComponent("unrelated.sqlite")
        try Data("synthetic protected bytes".utf8).write(to: canary)
        let support = URL(fileURLWithPath: try #require(fixture.environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"]))
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("hireva.sqlite"),
            withDestinationURL: canary)
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil) == nil)
        #expect(try Data(contentsOf: canary) == Data("synthetic protected bytes".utf8))
    }

    @Test
    func protectedPathsAreRejectedUsingOnlyASyntheticHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = fixture.root.appendingPathComponent("synthetic-home")
        for suffix in ["Library/Application Support/Hireva", "Library/Application Support/InterviewCopilotMac",
            "Library/Preferences", "Library/Caches"] {
            let directory = home.appendingPathComponent(suffix)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let alias = fixture.root.appendingPathComponent("alias-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            for key in ["HIREVA_VERIFICATION_APP_SUPPORT_DIR", "HIREVA_VERIFICATION_OUTPUT_ROOT", "HIREVA_VERIFICATION_MODEL_ROOT"] {
                for path in [directory.path, alias.path, home.path] {
                    var environment = fixture.environment
                    environment[key] = path
                    #expect(HirevaVerificationConfiguration.load(environment: environment,
                        bundleSourceRoot: nil, productionHomeDirectory: home) == nil)
                }
            }
        }
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment,
            bundleSourceRoot: nil, productionHomeDirectory: home) != nil)
    }

    @Test
    func unreadableSubtreeCannotBeAcceptedAsInspected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let support = URL(fileURLWithPath: try #require(fixture.environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"]))
        let blocked = support.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil) == nil)
    }

    @Test
    func hardlinkedDatabaseCannotRedirectWritesToAnotherRun() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let canary = fixture.root.appendingPathComponent("other-run.sqlite")
        try Data("synthetic preserved data".utf8).write(to: canary)
        let support = URL(fileURLWithPath: try #require(fixture.environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"]))
        try FileManager.default.linkItem(at: canary, to: support.appendingPathComponent("hireva.sqlite"))
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil) == nil)
        #expect(try Data(contentsOf: canary) == Data("synthetic preserved data".utf8))
    }

    private struct Fixture {
        let root: URL
        let environment: [String: String]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaIsolation-\(UUID().uuidString)")
            let support = root.appendingPathComponent("support/Hireva", isDirectory: true)
            let output = root.appendingPathComponent("output", isDirectory: true)
            for directory in [support, output] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scenario = root.appendingPathComponent("scenario.json")
            try #"{"synthetic":true,"runID":"credential-isolation-test"}"#.write(to: scenario,
                atomically: true, encoding: .utf8)
            environment = ["HIREVA_VERIFICATION_MODE": "1",
                "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
                "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
                "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path]
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
