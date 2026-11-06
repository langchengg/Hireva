import Foundation
import Testing
@testable import Hireva

/// Real factory drivers with synthetic process metadata, without SDK capture.
@Suite(.serialized)
@MainActor
struct OwnedSystemAudioFilterTests {
    private static let ownedPID: Int32 = 4242
    private static let playerBundle = "com.langcheng.Hireva.VerificationPlayer"
    private static let applications: [(processID: Int32, bundleIdentifier: String)] = [
        (2222, "synthetic.unrelated"), (ownedPID, playerBundle)
    ]

    @Test
    func configurationFreezesOwnedPlayerMetadataAndKeepsLegacyFixturesValid() throws {
        let fixture = try Fixture(pid: Self.ownedPID, bundle: Self.playerBundle)
        defer { fixture.remove() }
        #expect(fixture.configuration.controlledAudioProcessID == Self.ownedPID)
        #expect(fixture.configuration.controlledAudioBundleIdentifier == Self.playerBundle)
        let legacy = try Fixture()
        defer { legacy.remove() }
        #expect(legacy.configuration.controlledAudioProcessID == nil)
        #expect(legacy.configuration.controlledAudioBundleIdentifier == nil)
    }

    @Test(arguments: MalformedOwner.allCases)
    func configurationRejectsMalformedOwnerMetadataBeforeCanonicalStartup(owner: MalformedOwner) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.replaceOwnerMetadata(owner.fields)
        #expect(HirevaVerificationConfiguration.load(environment: fixture.environment, bundleSourceRoot: nil) == nil)
        var productionCalls = 0
        do {
            try HirevaStartup.preparePersistentIdentity(environment: fixture.environment,
                bundleSourceRoot: nil, migrateProduction: { productionCalls += 1 })
            Issue.record("Malformed capture owner must reject canonical verification startup.")
        } catch {
            #expect(error is HirevaStartupError)
        }
        #expect(productionCalls == 0)
    }

    @Test
    func actualLiveTinyFactoryReceivesOnlyOwnedApplication() async throws {
        let fixture = try Fixture(pid: Self.ownedPID, bundle: Self.playerBundle)
        defer { fixture.remove() }
        var created: [StreamToken] = []
        let stream = try await makeLive(configuration: fixture.configuration, applications: Self.applications) {
            created.append($0)
        }
        #expect(stream.filter.selection == .application(index: 1))
        #expect(created.count == 1)
        #expect(!stream.nativeResolution)
    }

    @Test
    func actualLiveNativeFallbackReusesTheSameOwnedFilter() async throws {
        let fixture = try Fixture(pid: Self.ownedPID, bundle: Self.playerBundle)
        defer { fixture.remove() }
        var created: [StreamToken] = []
        var filterCount = 0
        var fallbackCount = 0
        let stream = try await ScreenCaptureKitSystemAudioCaptureService.startFilteredCapture(
            verification: fixture.configuration,
            applications: Self.applications,
            filterFactory: { selection in
                filterCount += 1
                return FilterToken(selection)
            },
            streamFactory: { filter, nativeResolution in
                let stream = StreamToken(filter: filter, nativeResolution: nativeResolution)
                created.append(stream)
                return stream
            },
            startStream: { stream in
                if !stream.nativeResolution { throw SyntheticStartError() }
            },
            allowFallback: { _ in fallbackCount += 1 }
        )
        #expect(filterCount == 1)
        #expect(fallbackCount == 1)
        #expect(created.count == 2)
        #expect(created.first?.filter === stream.filter)
        #expect(created.last?.filter === stream.filter)
        #expect(stream.filter.selection == .application(index: 1))
        #expect(stream.nativeResolution)
    }

    @Test
    func actualPermissionProbeFactoryReceivesOnlyOwnedApplication() throws {
        let fixture = try Fixture(pid: Self.ownedPID, bundle: Self.playerBundle)
        defer { fixture.remove() }
        var factoryCount = 0
        let stream = try ScreenSystemAudioPermissionProbe.createFilteredProbeStream(
            verification: fixture.configuration,
            applications: Self.applications,
            filterFactory: FilterToken.init,
            streamFactory: { filter in
                factoryCount += 1
                return StreamToken(filter: filter, nativeResolution: false)
            }
        )
        #expect(factoryCount == 1)
        #expect(stream.filter.selection == .application(index: 1))
    }

    @Test(arguments: [Rejection.missingOwner, .unknownPID, .wrongBundle, .sameBundleWrongPID])
    func unsafeVerificationCannotReachAnyOfTheThreeActualStreamFactories(rejection: Rejection) async throws {
        let fixture: Fixture
        let applications: [(processID: Int32, bundleIdentifier: String)]
        switch rejection {
        case .missingOwner:
            fixture = try Fixture()
            applications = Self.applications
        case .unknownPID:
            fixture = try Fixture(pid: 9999, bundle: Self.playerBundle)
            applications = Self.applications
        case .wrongBundle:
            fixture = try Fixture(pid: Self.ownedPID, bundle: "synthetic.wrong-bundle")
            applications = Self.applications
        case .sameBundleWrongPID:
            fixture = try Fixture(pid: Self.ownedPID, bundle: Self.playerBundle)
            applications = [(9999, Self.playerBundle)]
        }
        defer { fixture.remove() }
        var liveFactoryCount = 0
        do {
            _ = try await makeLive(configuration: fixture.configuration, applications: applications) { _ in
                liveFactoryCount += 1
            }
            Issue.record("Unsafe verification must reject before the live stream factory.")
        } catch {}
        #expect(liveFactoryCount == 0)
        var probeFactoryCount = 0
        do {
            _ = try ScreenSystemAudioPermissionProbe.createFilteredProbeStream(
                verification: fixture.configuration,
                applications: applications,
                filterFactory: FilterToken.init,
                streamFactory: { filter in
                    probeFactoryCount += 1
                    return StreamToken(filter: filter, nativeResolution: false)
                }
            )
            Issue.record("Unsafe verification must reject before the permission-probe stream factory.")
        } catch {}
        #expect(probeFactoryCount == 0)
    }

    @Test
    func manualUINativePermissionRefreshRequiresAnOwnerBeforeContentQuery() throws {
        let fixture = try Fixture(manualUI: true)
        defer { fixture.remove() }
        do {
            // Actual native entry is after hermetic/mock early returns and
            // before any CG/SCShareableContent/SCStream operations.
            try SystemAudioCaptureFilterPolicy.validateNativeCapture(verification: fixture.configuration)
            Issue.record("Manual UI verification needs an owned player before native permission probing.")
        } catch {}
    }

    @Test
    func ordinaryLiveAndPermissionProbeRetainTheirExistingDisplayScope() async throws {
        let stream = try await makeLive(configuration: nil, applications: Self.applications) { _ in }
        #expect(stream.filter.selection == .allDisplay)
        let probe = try ScreenSystemAudioPermissionProbe.createFilteredProbeStream(
            verification: nil,
            applications: Self.applications,
            filterFactory: FilterToken.init,
            streamFactory: { StreamToken(filter: $0, nativeResolution: false) }
        )
        #expect(probe.filter.selection == .allDisplay)
        try SystemAudioCaptureFilterPolicy.validateNativeCapture(verification: nil)
    }

    enum Rejection: String, CaseIterable {
        case missingOwner, unknownPID, wrongBundle, sameBundleWrongPID
    }

    enum MalformedOwner: String, CaseIterable {
        case pidOnly, bundleOnly, nullPID, nullBundle, stringPID, booleanPID
        case fractionalPID, zeroPID, systemPID, negativePID, overflowingPID
        case numericBundle, emptyBundle, whitespaceBundle

        @MainActor var fields: [String: Any] {
            let pid: Any
            let bundle: Any
            switch self {
            case .pidOnly: return ["controlledAudioProcessID": OwnedSystemAudioFilterTests.ownedPID]
            case .bundleOnly: return ["controlledAudioBundleIdentifier": OwnedSystemAudioFilterTests.playerBundle]
            case .nullPID: pid = NSNull(); bundle = OwnedSystemAudioFilterTests.playerBundle
            case .nullBundle: pid = OwnedSystemAudioFilterTests.ownedPID; bundle = NSNull()
            case .stringPID: pid = "4242"; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .booleanPID: pid = true; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .fractionalPID: pid = 4242.5; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .zeroPID: pid = 0; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .systemPID: pid = 1; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .negativePID: pid = -4242; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .overflowingPID: pid = Int64(Int32.max) + 1; bundle = OwnedSystemAudioFilterTests.playerBundle
            case .numericBundle: pid = OwnedSystemAudioFilterTests.ownedPID; bundle = 123
            case .emptyBundle: pid = OwnedSystemAudioFilterTests.ownedPID; bundle = ""
            case .whitespaceBundle: pid = OwnedSystemAudioFilterTests.ownedPID; bundle = " \n "
            }
            return ["controlledAudioProcessID": pid, "controlledAudioBundleIdentifier": bundle]
        }
    }

    private func makeLive(
        configuration: HirevaVerificationConfiguration?,
        applications: [(processID: Int32, bundleIdentifier: String)],
        didCreate: (StreamToken) -> Void
    ) async throws -> StreamToken {
        try await ScreenCaptureKitSystemAudioCaptureService.startFilteredCapture(
            verification: configuration,
            applications: applications,
            filterFactory: FilterToken.init,
            streamFactory: { filter, nativeResolution in
                let stream = StreamToken(filter: filter, nativeResolution: nativeResolution)
                didCreate(stream)
                return stream
            },
            startStream: { _ in },
            allowFallback: { _ in }
        )
    }

    private final class FilterToken {
        let selection: SystemAudioCaptureFilterSelection
        init(_ selection: SystemAudioCaptureFilterSelection) { self.selection = selection }
    }
    private struct StreamToken {
        let filter: FilterToken
        let nativeResolution: Bool
    }
    private struct SyntheticStartError: Error {}

    private struct Fixture {
        let root: URL
        let configuration: HirevaVerificationConfiguration

        var environment: [String: String] {
            ["HIREVA_VERIFICATION_MODE": "1",
             "HIREVA_VERIFICATION_SCENARIO_PATH": configuration.scenarioURL.path,
             "HIREVA_VERIFICATION_OUTPUT_ROOT": configuration.outputDirectory.path,
             "HIREVA_VERIFICATION_APP_SUPPORT_DIR": configuration.applicationSupportDirectory.path]
        }

        init(pid: Int32? = nil, bundle: String? = nil, manualUI: Bool = false) throws {
            let runID = UUID().uuidString
            root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnedSystemAudioFilter-\(runID)")
            let output = root.appendingPathComponent("output", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            for directory in [output, support] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scenario = root.appendingPathComponent("scenario.json")
            var object: [String: Any] = ["synthetic": true, "runID": runID, "manualUI": manualUI]
            if let pid { object["controlledAudioProcessID"] = pid }
            if let bundle { object["controlledAudioBundleIdentifier"] = bundle }
            try JSONSerialization.data(withJSONObject: object).write(to: scenario, options: .atomic)
            configuration = try #require(HirevaVerificationConfiguration.load(environment: [
                "HIREVA_VERIFICATION_MODE": "1",
                "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
                "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path,
                "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path
            ], bundleSourceRoot: nil))
        }

        func replaceOwnerMetadata(_ fields: [String: Any]) throws {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configuration.scenarioURL)) as? [String: Any])
            object.removeValue(forKey: "controlledAudioProcessID")
            object.removeValue(forKey: "controlledAudioBundleIdentifier")
            object.merge(fields) { _, new in new }
            try JSONSerialization.data(withJSONObject: object).write(to: configuration.scenarioURL, options: .atomic)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
