import Foundation
import Testing

@Suite(.serialized)
struct ReleaseToolingTests {
    @Test
    func scriptsExposeReviewedSigningAndNotarizationContracts() throws {
        let releaseDirectory = repositoryRoot.appendingPathComponent("script/release", isDirectory: true)
        let scriptNames = [
            "check_identity.sh",
            "notarize_release.sh",
            "package_release.sh",
            "sign_app.sh",
            "verify_app.sh"
        ]

        for name in scriptNames {
            let url = releaseDirectory.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "Missing \(name)")
            #expect(FileManager.default.isExecutableFile(atPath: url.path), "Not executable: \(name)")
        }

        let common = try contents(of: releaseDirectory.appendingPathComponent("release_common.sh"))
        let signing = try contents(of: releaseDirectory.appendingPathComponent("sign_app.sh"))
        let packaging = try contents(of: releaseDirectory.appendingPathComponent("package_release.sh"))
        let notarization = try contents(of: releaseDirectory.appendingPathComponent("notarize_release.sh"))

        #expect(signing.contains("release_collect_nested_bundles"))
        #expect(signing.contains("--options runtime --timestamp"))
        #expect(signing.contains("--timestamp=none"))
        #expect(signing.contains("--entitlements \"$RELEASE_ENTITLEMENTS_PATH\""))
        #expect(!signing.contains("--deep"), "codesign --deep must not be used for signing")
        #expect(common.contains("codesign --verify --deep --strict"))
        #expect(common.contains("signed entitlements differ from reviewed release entitlements"))

        for requiredText in [
            "notarytool submit",
            "--keychain-profile \"$HIREVA_NOTARY_PROFILE\"",
            "--wait",
            "notarytool log",
            "stapler staple",
            "stapler validate",
            "spctl --assess",
            "submitted ZIP changed during notarization"
        ] {
            #expect(notarization.contains(requiredText), "Missing notarization contract: \(requiredText)")
        }

        #expect(packaging.contains("version-manifest.json"))
        #expect(packaging.contains("shasum -a 256") || common.contains("shasum -a 256"))
        #expect(!packaging.contains("HIREVA_NOTARY_PROFILE"))
        #expect(!packaging.contains("HIREVA_SIGNING_IDENTITY"))

        let entitlementsURL = releaseDirectory.appendingPathComponent("HirevaRelease.entitlements")
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let propertyList = try PropertyListSerialization.propertyList(from: entitlementsData, format: nil)
        let entitlements = try #require(propertyList as? [String: Any])
        #expect(entitlements.count == 1)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.get-task-allow"] == nil)
    }

    @Test
    func identitySelectionFailsClosedWithoutFallback() throws {
        let script = repositoryRoot.appendingPathComponent("script/release/check_identity.sh")

        let missingMode = try runScript(script)
        #expect(missingMode.status != 0)
        #expect(missingMode.output.contains("HIREVA_SIGNING_MODE"))

        let missingDevelopmentIdentity = try runScript(
            script,
            environment: ["HIREVA_SIGNING_MODE": "development"]
        )
        #expect(missingDevelopmentIdentity.status != 0)
        #expect(missingDevelopmentIdentity.output.contains("HIREVA_SIGNING_IDENTITY"))

        let forbiddenAdhocIdentity = try runScript(
            script,
            environment: [
                "HIREVA_SIGNING_MODE": "adhoc",
                "HIREVA_SIGNING_IDENTITY": "must-not-fallback"
            ]
        )
        #expect(forbiddenAdhocIdentity.status != 0)
        #expect(forbiddenAdhocIdentity.output.contains("must be unset"))

        let explicitAdhoc = try runScript(
            script,
            environment: ["HIREVA_SIGNING_MODE": "adhoc"]
        )
        #expect(explicitAdhoc.status == 0)
        #expect(explicitAdhoc.output.contains("ad-hoc mode explicitly selected"))
    }

    @Test
    func adhocSigningAndPackagingProduceChecksumBoundSecretFreeArtifacts() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva release tooling \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let app = try makeMachOAppFixture(in: sandbox)
        let architectures = try architectures(of: app.appendingPathComponent("Contents/MacOS/Hireva"))
        let releaseRoot = sandbox.appendingPathComponent("release output", isDirectory: true)
        let baseEnvironment = [
            "HIREVA_SIGNING_MODE": "adhoc",
            "HIREVA_BUILD_ARCHS": architectures
        ]

        let sign = try runScript(
            repositoryRoot.appendingPathComponent("script/release/sign_app.sh"),
            arguments: [app.path],
            environment: baseEnvironment
        )
        #expect(sign.status == 0, Comment(rawValue: sign.output))
        #expect(sign.output.contains("nested Mach-O: Contents/Helpers/HirevaHelper"))
        #expect(sign.output.contains("SIGNING_MODE=adhoc"))

        let verify = try runScript(
            repositoryRoot.appendingPathComponent("script/release/verify_app.sh"),
            arguments: [app.path],
            environment: baseEnvironment
        )
        #expect(verify.status == 0, Comment(rawValue: verify.output))

        var packageEnvironment = baseEnvironment
        packageEnvironment["HIREVA_RELEASE_OUTPUT_DIR"] = releaseRoot.path
        packageEnvironment["HIREVA_NOTARY_PROFILE"] = "SECRET-PROFILE-MUST-NOT-BE-SERIALIZED"
        let package = try runScript(
            repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            arguments: [app.path],
            environment: packageEnvironment
        )
        #expect(package.status == 0, Comment(rawValue: package.output))

        let releaseDirectory = releaseRoot.appendingPathComponent("Hireva-9.8.7-42-adhoc", isDirectory: true)
        let manifestURL = releaseDirectory.appendingPathComponent("version-manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])

        #expect(manifest["short_version"] as? String == "9.8.7")
        #expect(manifest["bundle_version"] as? String == "42")
        #expect(manifest["signing_mode"] as? String == "adhoc")
        #expect(manifest["notarized"] as? Bool == false)
        #expect(manifest["documentation_artifact"] as? String == "Documentation")
        #expect(manifest["requested_architectures"] as? [String] == architectures.split(separator: " ").map(String.init))
        #expect(manifest["signing_identity"] == nil)
        #expect(manifest["notary_profile"] == nil)
        #expect(!manifestText.contains("SECRET-PROFILE-MUST-NOT-BE-SERIALIZED"))

        let zipName = try #require(manifest["zip_artifact"] as? String)
        let expectedHash = try #require(manifest["zip_sha256"] as? String)
        let zipURL = releaseDirectory.appendingPathComponent(zipName)
        #expect(try sha256(of: zipURL) == expectedHash)

        let wrongMode = try runScript(
            repositoryRoot.appendingPathComponent("script/release/notarize_release.sh"),
            arguments: [releaseDirectory.path],
            environment: packageEnvironment
        )
        #expect(wrongMode.status != 0)
        #expect(wrongMode.output.contains("requires HIREVA_SIGNING_MODE=developer-id"))
        #expect(!FileManager.default.fileExists(atPath: releaseDirectory.appendingPathComponent("notarization-submit.plist").path))

        var tamperedManifest = manifest
        tamperedManifest["signing_mode"] = "developer-id"
        let tamperedManifestData = try JSONSerialization.data(withJSONObject: tamperedManifest, options: [.sortedKeys])
        try tamperedManifestData.write(to: manifestURL, options: .atomic)
        let zipHandle = try FileHandle(forWritingTo: zipURL)
        try zipHandle.seekToEnd()
        try zipHandle.write(contentsOf: Data("tampered".utf8))
        try zipHandle.close()

        var notaryEnvironment = packageEnvironment
        notaryEnvironment["HIREVA_SIGNING_MODE"] = "developer-id"
        let tampered = try runScript(
            repositoryRoot.appendingPathComponent("script/release/notarize_release.sh"),
            arguments: [releaseDirectory.path],
            environment: notaryEnvironment
        )
        #expect(tampered.status != 0)
        #expect(tampered.output.contains("ZIP checksum differs from version manifest"))
        #expect(!FileManager.default.fileExists(atPath: releaseDirectory.appendingPathComponent("notarization-submit.plist").path))
    }

    @Test
    func notarizationRequiresKeychainProfileBeforeArtifactAccess() throws {
        let missing = repositoryRoot.appendingPathComponent("does-not-exist")
        let result = try runScript(
            repositoryRoot.appendingPathComponent("script/release/notarize_release.sh"),
            arguments: [missing.path],
            environment: [
                "HIREVA_SIGNING_MODE": "developer-id",
                "HIREVA_BUILD_ARCHS": "arm64",
                "HIREVA_RELEASE_OUTPUT_DIR": FileManager.default.temporaryDirectory.path
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("HIREVA_NOTARY_PROFILE must be set explicitly"))
        #expect(!result.output.contains("notarytool submit"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func runScript(
        _ script: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        var processEnvironment = ProcessInfo.processInfo.environment
        for key in [
            "HIREVA_BUILD_ARCHS",
            "HIREVA_NOTARY_PROFILE",
            "HIREVA_RELEASE_OUTPUT_DIR",
            "HIREVA_SIGNING_IDENTITY",
            "HIREVA_SIGNING_MODE"
        ] {
            processEnvironment.removeValue(forKey: key)
        }
        processEnvironment.merge(environment) { _, override in override }

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = processEnvironment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func run(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func architectures(of executable: URL) throws -> String {
        let result = try run(executable: "/usr/bin/lipo", arguments: ["-archs", executable.path])
        guard result.status == 0 else {
            throw ReleaseToolingTestError.commandFailed(result.output)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sha256(of file: URL) throws -> String {
        let result = try run(executable: "/usr/bin/shasum", arguments: ["-a", "256", file.path])
        guard result.status == 0, let hash = result.output.split(separator: " ").first else {
            throw ReleaseToolingTestError.commandFailed(result.output)
        }
        return String(hash)
    }

    private func makeMachOAppFixture(in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("Hireva.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let documentation = contents.appendingPathComponent("Resources/Documentation", isDirectory: true)
        let notices = contents.appendingPathComponent("Resources/ThirdPartyNotices", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        try Data("fixture documentation".utf8).write(to: documentation.appendingPathComponent("release-installation.md"))
        try Data("fixture notice".utf8).write(to: notices.appendingPathComponent("LICENSE.txt"))

        let systemExecutable = URL(fileURLWithPath: "/usr/bin/true")
        let mainExecutable = macOS.appendingPathComponent("Hireva")
        let helperExecutable = helpers.appendingPathComponent("HirevaHelper")
        try FileManager.default.copyItem(at: systemExecutable, to: mainExecutable)
        try FileManager.default.copyItem(at: systemExecutable, to: helperExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainExecutable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperExecutable.path)

        let info: [String: Any] = [
            "CFBundleExecutable": "Hireva",
            "CFBundleIdentifier": "com.langcheng.Hireva.ReleaseToolingFixture",
            "CFBundleName": "Hireva",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "42",
            "HirevaGitCommitHash": "release-tooling-fixture"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        return app
    }

    private enum ReleaseToolingTestError: Error {
        case commandFailed(String)
    }
}
