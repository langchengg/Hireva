import Foundation
import Testing
@testable import Hireva

struct ParakeetHelperPreferenceIsolationTests {
    @Test(arguments: [false, true])
    func releaseAndVerificationDoNotReadStoredDevelopmentPreference(verification: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var reads = 0
        func syntheticLookup() -> String? {
            reads += 1
            return fixture.syntheticOverride.path
        }
        let result = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: fixture.bundle,
            environment: [:],
            storedDevelopmentPath: syntheticLookup(),
            currentDirectory: fixture.root,
            allowDevelopmentOverrides: verification,
            verificationConfiguration: verification ? fixture.configuration : nil
        )
        #expect(reads == 0, "This resolver must never evaluate the supplied product preference lookup")
        #expect(result == nil)
    }

    @Test
    func ordinaryDebugDiscoveryReadsOnlyTheSuppliedSyntheticLookup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var reads = 0
        func syntheticLookup() -> String? {
            reads += 1
            return fixture.syntheticOverride.path
        }
        let result = ParakeetSidecarRuntimeClient.discoverExecutable(
            bundleURL: fixture.bundle,
            environment: [:],
            storedDevelopmentPath: syntheticLookup(),
            currentDirectory: fixture.root,
            allowDevelopmentOverrides: true,
            verificationConfiguration: nil
        )
        #expect(reads == 1)
        #expect(result == fixture.syntheticOverride)
    }

    private struct Fixture {
        let root: URL
        let bundle: URL
        let syntheticOverride: URL
        let configuration: HirevaVerificationConfiguration

        init() throws {
            let nonce = UUID().uuidString
            root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaHelperDiscovery-\(nonce)")
            bundle = root.appendingPathComponent("Synthetic.app")
            syntheticOverride = root.appendingPathComponent("synthetic-helper")
            let support = root.appendingPathComponent("support")
            let output = root.appendingPathComponent("output")
            for directory in [root, support, output] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scenario = root.appendingPathComponent("scenario.json")
            try "{\"synthetic\":true,\"runID\":\"\(nonce)\"}".write(to: scenario, atomically: true, encoding: .utf8)
            configuration = try #require(HirevaVerificationConfiguration.load(environment: [
                "HIREVA_VERIFICATION_MODE": "1",
                "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
                "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
                "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path
            ], bundleSourceRoot: nil))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
