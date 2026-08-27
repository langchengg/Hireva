import Foundation
import Testing
@testable import Hireva

@Suite("Build identity")
struct BuildIdentityTests {
    @Test("Installed ad-hoc Release remains an internal Release build")
    func installedAdHocReleaseIsPortableAndNotDistribution() {
        let installedApp = syntheticRoot().appendingPathComponent("Applications/Hireva.app")
        let identity = makeIdentity(
            bundlePath: installedApp.path,
            info: validInfo(
                buildConfiguration: "release",
                signingMode: "adhoc",
                distributionBuild: false
            )
        )

        #expect(identity.isReleaseBuild)
        #expect(identity.hasValidReleaseMetadata)
        #expect(!identity.distributionBuild)
        #expect(!identity.hasExplicitDevelopmentPaths)
        #expect(identity.sourceRoot == "Unknown")
        #expect(identity.expectedBundlePath == "Unknown")
        #expect(identity.expectedBundlePathMatches)
        #expect(identity.latestSourceModifiedAt == nil)
        #expect(identity.identityWarning == nil)
    }

    @Test("A dist directory does not create distribution identity")
    func distDirectoryDoesNotCreateDistributionIdentity() {
        let workspaceApp = syntheticRoot().appendingPathComponent("workspace/dist/Hireva.app")
        let identity = makeIdentity(
            bundlePath: workspaceApp.path,
            info: validInfo(
                buildConfiguration: "release",
                signingMode: "adhoc",
                distributionBuild: false
            )
        )

        #expect(identity.isReleaseBuild)
        #expect(identity.hasValidReleaseMetadata)
        #expect(!identity.distributionBuild)
        #expect(identity.identityWarning == nil)
    }

    @Test("Developer ID distribution intent is independent of install path")
    func developerIDDistributionIsPortable() {
        let alternateInstall = syntheticRoot().appendingPathComponent("Alternate/Hireva.app")
        let identity = makeIdentity(
            bundlePath: alternateInstall.path,
            info: validInfo(
                buildConfiguration: "release",
                signingMode: "developer-id",
                distributionBuild: true
            )
        )

        #expect(identity.isReleaseBuild)
        #expect(identity.hasValidReleaseMetadata)
        #expect(identity.distributionBuild)
        #expect(identity.identityWarning == nil)
    }

    @Test("Development-signed Release remains a non-distribution Release build")
    func developmentSignedReleaseIsValidAndNotDistribution() {
        let identity = makeIdentity(
            bundlePath: syntheticRoot().appendingPathComponent("Alternate/Hireva.app").path,
            info: validInfo(
                buildConfiguration: "release",
                signingMode: "development",
                distributionBuild: false
            )
        )

        #expect(identity.isReleaseBuild)
        #expect(identity.hasValidReleaseMetadata)
        #expect(!identity.distributionBuild)
        #expect(identity.identityWarning == nil)
    }

    @Test("Explicit development path mismatch fails closed")
    func explicitDevelopmentPathMismatchIsReported() {
        let root = syntheticRoot()
        let expectedApp = root.appendingPathComponent("workspace/dist/Hireva.app")
        let movedApp = root.appendingPathComponent("moved/Hireva.app")
        var info = validInfo(
            buildConfiguration: "debug",
            signingMode: "development",
            distributionBuild: false
        )
        info["HirevaSourceRoot"] = root.appendingPathComponent("workspace").path
        info["HirevaExpectedBundlePath"] = expectedApp.path

        let identity = makeIdentity(bundlePath: movedApp.path, info: info)

        #expect(!identity.isReleaseBuild)
        #expect(identity.hasExplicitDevelopmentPaths)
        #expect(!identity.expectedBundlePathMatches)
        #expect(identity.identityWarning == "This development build is running from an unexpected app bundle path.")
    }

    @Test("Inconsistent signing and distribution metadata fails closed")
    func inconsistentDistributionMetadataIsReported() {
        let identity = makeIdentity(
            bundlePath: syntheticRoot().appendingPathComponent("Hireva.app").path,
            info: validInfo(
                buildConfiguration: "release",
                signingMode: "adhoc",
                distributionBuild: true
            )
        )

        #expect(!identity.hasValidReleaseMetadata)
        #expect(identity.identityWarning == "This app bundle has inconsistent signing and distribution metadata.")
    }

    @Test("Missing or mistyped distribution metadata fails closed")
    func invalidDistributionMetadataIsReported() {
        let app = syntheticRoot().appendingPathComponent("Hireva.app")
        var missing = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        missing.removeValue(forKey: "HirevaDistributionBuild")
        var mistyped = missing
        mistyped["HirevaDistributionBuild"] = "false"
        var integerZero = missing
        integerZero["HirevaDistributionBuild"] = NSNumber(value: 0)
        var integerOne = missing
        integerOne["HirevaDistributionBuild"] = NSNumber(value: 1)

        let missingIdentity = makeIdentity(bundlePath: app.path, info: missing)
        let mistypedIdentity = makeIdentity(bundlePath: app.path, info: mistyped)
        let integerZeroIdentity = makeIdentity(bundlePath: app.path, info: integerZero)
        let integerOneIdentity = makeIdentity(bundlePath: app.path, info: integerOne)

        #expect(missingIdentity.identityWarning == "This app bundle has missing or invalid distribution metadata.")
        #expect(mistypedIdentity.identityWarning == "This app bundle has missing or invalid distribution metadata.")
        #expect(integerZeroIdentity.identityWarning == "This app bundle has missing or invalid distribution metadata.")
        #expect(integerOneIdentity.identityWarning == "This app bundle has missing or invalid distribution metadata.")
        #expect(!missingIdentity.hasValidReleaseMetadata)
        #expect(!mistypedIdentity.hasValidReleaseMetadata)
        #expect(!integerZeroIdentity.hasValidReleaseMetadata)
        #expect(!integerOneIdentity.hasValidReleaseMetadata)
    }

    @Test("Development path metadata must be complete, absolute, and scoped")
    func invalidDevelopmentPathMetadataIsRejectedWithoutScanning() {
        let root = syntheticRoot()
        let app = root.appendingPathComponent("workspace/dist/Hireva.app")

        var sourceOnly = validInfo(
            buildConfiguration: "debug",
            signingMode: "development",
            distributionBuild: false
        )
        sourceOnly["HirevaSourceRoot"] = root.appendingPathComponent("workspace").path

        var relative = validInfo(
            buildConfiguration: "debug",
            signingMode: "development",
            distributionBuild: false
        )
        relative["HirevaSourceRoot"] = "workspace"
        relative["HirevaExpectedBundlePath"] = "workspace/dist/Hireva.app"

        var wrongScope = validInfo(
            buildConfiguration: "debug",
            signingMode: "adhoc",
            distributionBuild: false
        )
        wrongScope["HirevaSourceRoot"] = root.appendingPathComponent("workspace").path
        wrongScope["HirevaExpectedBundlePath"] = app.path

        let sourceOnlyIdentity = makeIdentity(bundlePath: app.path, info: sourceOnly)
        let relativeIdentity = makeIdentity(bundlePath: app.path, info: relative)
        let wrongScopeIdentity = makeIdentity(bundlePath: app.path, info: wrongScope)

        #expect(sourceOnlyIdentity.identityWarning == "Development path metadata must contain non-empty absolute source and bundle paths.")
        #expect(relativeIdentity.identityWarning == "Development path metadata must contain non-empty absolute source and bundle paths.")
        #expect(wrongScopeIdentity.identityWarning == "Development path metadata is valid only for debug development-signed builds.")
        #expect(sourceOnlyIdentity.latestSourceModifiedAt == nil)
        #expect(relativeIdentity.latestSourceModifiedAt == nil)
        #expect(wrongScopeIdentity.latestSourceModifiedAt == nil)
    }

    @Test("Invalid timestamp and commit metadata fail closed")
    func invalidProvenanceMetadataIsReported() {
        let app = syntheticRoot().appendingPathComponent("Hireva.app")
        var invalidTimestamp = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        invalidTimestamp["HirevaBuildTimestampUTC"] = "2026-99-99T99:99:99Z"
        var invalidCommit = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        invalidCommit["HirevaGitCommitHash"] = "deadbeef"

        let timestampIdentity = makeIdentity(bundlePath: app.path, info: invalidTimestamp)
        let commitIdentity = makeIdentity(bundlePath: app.path, info: invalidCommit)

        #expect(timestampIdentity.identityWarning == "This app bundle has missing or invalid build timestamp metadata.")
        #expect(commitIdentity.identityWarning == "This app bundle has missing or invalid Git commit metadata.")
    }

    @Test("Runtime mode and Git tree metadata match packaging contracts")
    func invalidRuntimeAndTreeMetadataAreReported() {
        let app = syntheticRoot().appendingPathComponent("Hireva.app")
        var missingRuntime = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        missingRuntime.removeValue(forKey: "HirevaRuntimeMode")
        var invalidTree = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        invalidTree["HirevaGitTreeState"] = "unknown"
        var dirtyDeveloperID = validInfo(
            buildConfiguration: "release",
            signingMode: "developer-id",
            distributionBuild: true
        )
        dirtyDeveloperID["HirevaGitTreeState"] = "dirty"

        let runtimeIdentity = makeIdentity(bundlePath: app.path, info: missingRuntime)
        let treeIdentity = makeIdentity(bundlePath: app.path, info: invalidTree)
        let developerIDIdentity = makeIdentity(bundlePath: app.path, info: dirtyDeveloperID)

        #expect(runtimeIdentity.identityWarning == "This app bundle has missing or invalid runtime mode metadata.")
        #expect(treeIdentity.identityWarning == "This app bundle has missing or invalid Git tree state metadata.")
        #expect(developerIDIdentity.identityWarning == "Developer ID release metadata requires a clean Git tree.")
        #expect(!runtimeIdentity.hasValidReleaseMetadata)
        #expect(!treeIdentity.hasValidReleaseMetadata)
        #expect(!developerIDIdentity.hasValidReleaseMetadata)
    }

    @Test("Bundle identifier failure takes precedence")
    func wrongBundleIdentifierIsReportedFirst() {
        var invalidInfo = validInfo(
            buildConfiguration: "release",
            signingMode: "adhoc",
            distributionBuild: false
        )
        invalidInfo.removeValue(forKey: "HirevaDistributionBuild")

        let identity = makeIdentity(
            bundlePath: syntheticRoot().appendingPathComponent("Hireva.app").path,
            bundleIdentifier: "example.invalid",
            info: invalidInfo
        )

        #expect(
            identity.identityWarning
                == "This app bundle has bundle id example.invalid, expected \(HirevaProductIdentity.bundleIdentifier)."
        )
    }

    @Test("A matching debug development build remains an RC policy warning")
    func matchingDevelopmentBuildIsNotPresentedAsRelease() {
        let root = syntheticRoot()
        let app = root.appendingPathComponent("workspace/dist/Hireva.app")
        var info = validInfo(
            buildConfiguration: "debug",
            signingMode: "development",
            distributionBuild: false
        )
        info["HirevaSourceRoot"] = root.appendingPathComponent("workspace").path
        info["HirevaExpectedBundlePath"] = app.path

        let identity = makeIdentity(bundlePath: app.path, info: info)

        #expect(identity.expectedBundlePathMatches)
        #expect(!identity.hasValidReleaseMetadata)
        #expect(identity.identityWarning == "This is a debug build. Use a release build for RC validation.")
    }

    @Test("Development freshness uses the existing five-second boundary")
    func developmentFreshnessBoundaryIsDeterministic() throws {
        let fileManager = FileManager.default
        let root = syntheticRoot()
        let sourceRoot = root.appendingPathComponent("workspace")
        let app = sourceRoot.appendingPathComponent("dist/Hireva.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Hireva")
        let source = sourceRoot.appendingPathComponent("Sources/Fixture.swift")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try Data().write(to: source)
        defer { try? fileManager.removeItem(at: root) }

        let executableDate = Date(timeIntervalSince1970: 1_800_000_000)
        try fileManager.setAttributes(
            [.modificationDate: executableDate],
            ofItemAtPath: executable.path
        )
        var info = validInfo(
            buildConfiguration: "debug",
            signingMode: "development",
            distributionBuild: false
        )
        info["HirevaSourceRoot"] = sourceRoot.path
        info["HirevaExpectedBundlePath"] = app.path

        try fileManager.setAttributes(
            [.modificationDate: executableDate.addingTimeInterval(5)],
            ofItemAtPath: source.path
        )
        let boundaryIdentity = BuildIdentity.evaluate(
            bundlePath: app.path,
            executablePath: executable.path,
            info: info,
            fileManager: fileManager
        )

        try fileManager.setAttributes(
            [.modificationDate: executableDate.addingTimeInterval(6)],
            ofItemAtPath: source.path
        )
        let staleIdentity = BuildIdentity.evaluate(
            bundlePath: app.path,
            executablePath: executable.path,
            info: info,
            fileManager: fileManager
        )

        #expect(boundaryIdentity.identityWarning == "This is a debug build. Use a release build for RC validation.")
        #expect(
            staleIdentity.identityWarning
                == "This app bundle may be stale. Rebuild and relaunch from dist/\(HirevaProductIdentity.productName).app."
        )
    }

    private func makeIdentity(
        bundlePath: String,
        bundleIdentifier: String = HirevaProductIdentity.bundleIdentifier,
        info: [String: Any]
    ) -> BuildIdentity {
        BuildIdentity.evaluate(
            bundlePath: bundlePath,
            executablePath: URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("Contents/MacOS/Hireva")
                .path,
            bundleIdentifier: bundleIdentifier,
            info: info
        )
    }

    private func validInfo(
        buildConfiguration: String,
        signingMode: String,
        distributionBuild: Bool
    ) -> [String: Any] {
        [
            "CFBundleName": HirevaProductIdentity.productName,
            "HirevaBuildTimestampUTC": "2026-08-27T20:57:02Z",
            "HirevaGitCommitHash": String(repeating: "a", count: 40),
            "HirevaGitTreeState": signingMode == "developer-id" ? "clean" : "dirty",
            "HirevaBuildConfiguration": buildConfiguration,
            "HirevaRuntimeMode": "bundled_native",
            "HirevaSigningMode": signingMode,
            "HirevaDistributionBuild": distributionBuild
        ]
    }

    private func syntheticRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaBuildIdentityTests")
            .appendingPathComponent(UUID().uuidString)
    }
}
