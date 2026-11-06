import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct VerificationPreferenceIsolationTests {
    @Test
    func unavailableVerificationSuiteFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var requestedDomain: String?
        do {
            _ = try resolveVerificationPreferences(configuration: fixture.configuration) {
                requestedDomain = $0
                return nil
            }
            Issue.record("Verification suite failure must not fall back to product preferences.")
        } catch {
            #expect(error.localizedDescription.contains("verification preferences"))
        }
        #expect(requestedDomain == fixture.configuration.userDefaultsSuiteName)
    }

    @Test
    func verificationResolverUsesItsExactSuiteObject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let defaults = try resolveVerificationPreferences(configuration: fixture.configuration) {
            #expect($0 == fixture.configuration.userDefaultsSuiteName)
            return fixture.defaults
        }
        #expect(defaults === fixture.defaults)
    }

    @Test
    func verificationDoesNotConfigureProductFrameAutosave() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var names: [String] = []
        FloatingAssistantPanelController.configureFrameAutosave(verification: fixture.configuration) {
            names.append($0)
        }
        #expect(names.isEmpty)
    }

    @Test
    func ordinaryFrameAutosaveKeepsItsExistingName() {
        var names: [String] = []
        FloatingAssistantPanelController.configureFrameAutosave(verification: nil) {
            names.append($0)
        }
        #expect(names == ["HirevaFloatingAssistant"])
    }

    @Test
    func verificationDoesNotConsumeLegacyDiagnosticFlagOrQuestion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: "ICRunLiveSystemAudioFinalDiagnostic")
        fixture.defaults.set("Synthetic legacy diagnostic canary", forKey: "ICLiveSystemAudioDiagnosticQuestion")
        let question = AppState.consumeLegacyDiagnosticLaunchRequest(
            defaults: fixture.defaults, verification: fixture.configuration
        )
        #expect(question == nil)
        #expect(fixture.defaults.bool(forKey: "ICRunLiveSystemAudioFinalDiagnostic"))
        #expect(fixture.defaults.string(forKey: "ICLiveSystemAudioDiagnosticQuestion") == "Synthetic legacy diagnostic canary")
    }

    @Test
    func ordinaryLegacyDiagnosticConsumesItsFlagOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: "ICRunLiveSystemAudioFinalDiagnostic")
        fixture.defaults.set("Synthetic diagnostic question", forKey: "ICLiveSystemAudioDiagnosticQuestion")
        #expect(AppState.consumeLegacyDiagnosticLaunchRequest(defaults: fixture.defaults, verification: nil) == "Synthetic diagnostic question")
        #expect(AppState.consumeLegacyDiagnosticLaunchRequest(defaults: fixture.defaults, verification: nil) == nil)
        #expect(!fixture.defaults.bool(forKey: "ICRunLiveSystemAudioFinalDiagnostic"))
    }

    @Test
    func verificationDoesNotInstallLegacyDiagnosticObserver() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let database = try AppDatabase(inMemory: true)
        let state = AppState(database: database, verificationMocksEnabled: false, dialogueDefaults: fixture.defaults)
        state.installLiveSystemAudioDiagnosticNotificationObserver(verification: fixture.configuration)
        #expect(state.liveSystemAudioDiagnosticObserverToken == nil)
        await state.shutdownForTesting()
        try database.close()
    }

    @Test
    func dialogueMigrationWritesOnlyItsResolvedSyntheticDomain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.otherDefaults.set("synthetic-existing-model", forKey: HirevaPreferenceKeys.selectedQwenModel)
        fixture.otherDefaults.set("synthetic-existing-mode", forKey: HirevaPreferenceKeys.interviewSessionMode)
        let defaults = try resolveVerificationPreferences(configuration: fixture.configuration) { _ in fixture.defaults }
        _ = DialogueSettingsStore.loadAndMigrate(defaults: defaults)
        #expect(defaults.string(forKey: HirevaPreferenceKeys.interviewSessionMode) == InterviewSessionMode.auto.rawValue)
        #expect(fixture.otherDefaults.string(forKey: HirevaPreferenceKeys.selectedQwenModel) == "synthetic-existing-model")
        #expect(fixture.otherDefaults.string(forKey: HirevaPreferenceKeys.interviewSessionMode) == "synthetic-existing-mode")
    }

    private struct Fixture {
        let root: URL
        let configuration: HirevaVerificationConfiguration
        let defaults: UserDefaults
        let otherDefaults: UserDefaults
        let otherDomain: String

        init() throws {
            let runID = UUID().uuidString
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaPreferenceIsolation-\(runID)")
            let support = root.appendingPathComponent("support", isDirectory: true)
            let output = root.appendingPathComponent("output", isDirectory: true)
            for directory in [support, output] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scenario = root.appendingPathComponent("scenario.json")
            try "{\"synthetic\":true,\"runID\":\"\(runID)\"}".write(to: scenario, atomically: true, encoding: .utf8)
            configuration = try #require(HirevaVerificationConfiguration.load(environment: [
                "HIREVA_VERIFICATION_MODE": "1",
                "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
                "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
                "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path
            ], bundleSourceRoot: nil))
            defaults = try #require(UserDefaults(suiteName: configuration.userDefaultsSuiteName))
            otherDomain = "com.langcheng.Hireva.tests.other-preferences.\(runID)"
            otherDefaults = try #require(UserDefaults(suiteName: otherDomain))
        }

        func remove() {
            defaults.removePersistentDomain(forName: configuration.userDefaultsSuiteName)
            otherDefaults.removePersistentDomain(forName: otherDomain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
