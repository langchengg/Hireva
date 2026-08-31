import Foundation
import Testing

@Suite(.serialized, .sharedRuntimeResources)
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
        for relativePath in [
            "script/release/exclusive_rename.rb",
            "script/runtime/macho_payload_sha256.sh",
            "script/runtime/macho_payload_sha256.rb",
            "script/runtime/sanitize_release_build_paths.sh",
            "script/runtime/sanitize_runtime_paths.sh"
        ] {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path), "Missing \(relativePath)")
            #expect(FileManager.default.isExecutableFile(atPath: url.path), "Not executable: \(relativePath)")
        }

        let common = try contents(of: releaseDirectory.appendingPathComponent("release_common.sh"))
        let signing = try contents(of: releaseDirectory.appendingPathComponent("sign_app.sh"))
        let packaging = try contents(of: releaseDirectory.appendingPathComponent("package_release.sh"))
        let notarization = try contents(of: releaseDirectory.appendingPathComponent("notarize_release.sh"))
        let buildAndRun = try contents(of: repositoryRoot.appendingPathComponent("script/build_and_run.sh"))
        let dmgPackaging = try contents(of: repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"))

        #expect(signing.contains("release_collect_nested_bundles"))
        #expect(signing.contains("--options runtime --timestamp"))
        #expect(signing.contains("--timestamp=none"))
        #expect(common.contains("nested Mach-O signing authority differs from outer app"))
        #expect(common.contains("nested Mach-O TeamIdentifier differs from outer app"))
        #expect(common.contains("developer-id TeamIdentifier differs from HIREVA_EXPECTED_TEAM_IDENTIFIER"))
        #expect(common.contains("outer CodeDirectory identifier differs from CFBundleIdentifier"))
        #expect(common.contains("nested Mach-O signature does not match the outer ad-hoc mode"))
        #expect(signing.contains("--entitlements \"$RELEASE_ENTITLEMENTS_PATH\""))
        #expect(!signing.contains("--deep"), "codesign --deep must not be used for signing")
        #expect(common.contains("codesign --verify --deep --strict"))
        #expect(common.contains("signed entitlements differ from reviewed release entitlements"))

        for requiredText in [
            "notarytool submit \"$UPLOAD_DMG\"",
            "--keychain-profile \"$HIREVA_NOTARY_PROFILE\"",
            "--wait",
            "notarytool log",
            "stapler staple \"$STAGED_FINAL_DMG\"",
            "stapler validate \"$STAGED_FINAL_DMG\"",
            "hdiutil verify \"$STAGED_FINAL_DMG\"",
            "spctl -a -t open --context context:primary-signature",
            "submitted DMG changed during notarization",
            "HIREVA_ALLOW_NOTARIZATION_SUBMIT",
            "upload_dmg_sha256",
            "upload_manifest_sha256",
            "distribution_dmg_sha256",
            "distribution_dmg_checksum_artifact",
            "notarization_response_sha256",
            "notarization_log_sha256"
        ] {
            #expect(notarization.contains(requiredText), "Missing notarization contract: \(requiredText)")
        }

        #expect(packaging.contains("version-manifest.json"))
        #expect(packaging.contains("--validate-only"))
        #expect(packaging.contains("disallowed LC_RPATH"))
        #expect(packaging.contains("disallowed LC_LOAD_DYLIB"))
        #expect(packaging.contains("absolute user path leaked into release app"))
        #expect(packaging.contains("probe_pgid"))
        #expect(packaging.contains("ulimit -u 64"))
        #expect(packaging.contains("shasum -a 256") || common.contains("shasum -a 256"))
        #expect(!packaging.contains("HIREVA_NOTARY_PROFILE"))
        #expect(!packaging.contains("HIREVA_SIGNING_IDENTITY"))
        #expect(buildAndRun.contains("HIREVA_EMBED_DEVELOPMENT_PATHS"))
        #expect(buildAndRun.contains("HirevaBuildConfiguration"))
        #expect(buildAndRun.contains("verify_grdb_resource_accessor.sh"))
        #expect(buildAndRun.contains("sanitize_release_build_paths.sh"))
        #expect(packaging.contains("verify_grdb_resource_accessor.sh"))
        #expect(packaging.contains("snapshotting signed app"))
        #expect(packaging.contains("HIREVA_RELEASE_OUTPUT_DIR must not be the source app or one of its descendants"))
        #expect(packaging.contains("Explicit 10-character Apple Team ID"))
        #expect(dmgPackaging.contains("package_release.sh\" --validate-only"))
        #expect(!dmgPackaging.contains("build_and_run.sh"))
        #expect(!dmgPackaging.contains("-ov"))
        #expect(dmgPackaging.contains("app_content_sha256"))
        #expect(dmgPackaging.contains("-readonly"))
        #expect(dmgPackaging.contains("MOUNTED_APP_CONTENT_SHA256"))
        #expect(dmgPackaging.contains("HIREVA_ALLOW_DISTRIBUTION_DMG"))
        #expect(dmgPackaging.contains("HIREVA_SIGNING_IDENTITY"))
        #expect(dmgPackaging.contains("release_validate_identity_for_signing"))
        #expect(dmgPackaging.contains("codesign --force --sign \"$RELEASE_SIGNING_VALUE\" --timestamp \"$FINAL_DMG\""))
        #expect(dmgPackaging.contains("validate_developer_id_dmg_signature"))
        #expect(dmgPackaging.contains("dmg_sha256"))
        #expect(dmgPackaging.contains("source_archive_sha256"))
        #expect(dmgPackaging.contains("signed_artifact_sha256"))
        #expect(dmgPackaging.contains("macho_payload_sha256"))
        #expect(!dmgPackaging.contains("pinned_sha256"))
        #expect(dmgPackaging.contains("EXCLUSIVE_RENAME"))
        #expect(!dmgPackaging.contains(".hireva-packaging-incomplete"))
        #expect(dmgPackaging.contains("parakeet_model.archive_sha256"))
        #expect(dmgPackaging.contains("source-path or signing identity metadata"))
        #expect(dmgPackaging.contains("DMG manifest contains the selected signing identity or Team ID"))
        #expect(!dmgPackaging.contains("notarytool"))
        #expect(!notarization.contains("upload_zip_sha256"))
        #expect(!notarization.contains("distribution_zip_sha256"))

        let entitlementsURL = releaseDirectory.appendingPathComponent("HirevaRelease.entitlements")
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let propertyList = try PropertyListSerialization.propertyList(from: entitlementsData, format: nil)
        let entitlements = try #require(propertyList as? [String: Any])
        #expect(entitlements.count == 1)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.get-task-allow"] == nil)
    }

    @Test
    func grdbResourceAccessorGateDistinguishesLinkedDefinitionFromRuntimeUse() throws {
        let verifier = repositoryRoot.appendingPathComponent(
            "script/runtime/verify_grdb_resource_accessor.sh"
        )
        #expect(FileManager.default.fileExists(atPath: verifier.path))
        #expect(FileManager.default.isExecutableFile(atPath: verifier.path))

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva grdb accessor gate \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let declaration = #"""
        __attribute__((used)) static const char grdb_bundle_marker[] = "GRDB_GRDB.bundle";
        __attribute__((noinline, used))
        void grdb_bundle_accessor(void) __asm__("$sSo8NSBundleC4GRDBE6moduleABvgZ");
        void grdb_bundle_accessor(void) {
            __asm__ volatile("" : : "r"(grdb_bundle_marker));
        }
        """#
        let unusedSource = sandbox.appendingPathComponent("unused-accessor.c")
        let usedSource = sandbox.appendingPathComponent("used-accessor.c")
        try Data(
            "\(declaration)\nint main(void) { return 0; }\n".utf8
        ).write(to: unusedSource)
        try Data(
            "\(declaration)\nint main(void) { grdb_bundle_accessor(); return 0; }\n".utf8
        ).write(to: usedSource)

        let unusedBinary = sandbox.appendingPathComponent("unused-accessor")
        let usedBinary = sandbox.appendingPathComponent("used-accessor")
        try compileC(unusedSource, output: unusedBinary)
        try compileC(usedSource, output: usedBinary)

        let unused = try runScript(verifier, arguments: [unusedBinary.path])
        #expect(unused.status == 0, Comment(rawValue: unused.output))

        let used = try runScript(verifier, arguments: [usedBinary.path])
        #expect(used.status != 0)
        #expect(used.output.contains("live GRDB Bundle.module accessor call"))
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

        let missingDeveloperTeam = try runScript(
            script,
            environment: [
                "HIREVA_SIGNING_MODE": "developer-id",
                "HIREVA_SIGNING_IDENTITY": "synthetic identity"
            ]
        )
        #expect(missingDeveloperTeam.status != 0)
        #expect(missingDeveloperTeam.output.contains("HIREVA_EXPECTED_TEAM_IDENTIFIER"))

        let invalidDeveloperTeam = try runScript(
            script,
            environment: [
                "HIREVA_SIGNING_MODE": "developer-id",
                "HIREVA_SIGNING_IDENTITY": "synthetic identity",
                "HIREVA_EXPECTED_TEAM_IDENTIFIER": "invalid"
            ]
        )
        #expect(invalidDeveloperTeam.status != 0)
        #expect(invalidDeveloperTeam.output.contains("10-character Apple Team ID"))

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
    func developerIDDMGRequiresExplicitAuthorizationAndInstalledIdentityBeforeCreation() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva developer id dmg preflight \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let app = try makeMachOAppFixture(in: sandbox)
        try updateInfoPlist(app) {
            $0["HirevaSigningMode"] = "developer-id"
            $0["HirevaGitTreeState"] = "clean"
            $0["HirevaDistributionBuild"] = true
        }
        try adHocSignFixture(app)
        let output = sandbox.appendingPathComponent("must-not-create-dmg", isDirectory: true)
        let baseEnvironment = [
            "HIREVA_SIGNING_MODE": "developer-id",
            "HIREVA_EXPECTED_TEAM_IDENTIFIER": "ABCDE12345"
        ]

        var unauthorizedEnvironment = baseEnvironment
        unauthorizedEnvironment["HIREVA_SIGNING_IDENTITY"] = "synthetic Developer ID identity"
        let unauthorized = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: [app.path, output.path],
            environment: unauthorizedEnvironment
        )
        #expect(unauthorized.status != 0)
        #expect(unauthorized.output.contains("HIREVA_ALLOW_DISTRIBUTION_DMG=1 authorization"))
        #expect(!FileManager.default.fileExists(atPath: output.path))

        var missingIdentityEnvironment = baseEnvironment
        missingIdentityEnvironment["HIREVA_ALLOW_DISTRIBUTION_DMG"] = "1"
        let missingIdentity = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: [app.path, output.path],
            environment: missingIdentityEnvironment
        )
        #expect(missingIdentity.status != 0)
        #expect(missingIdentity.output.contains("HIREVA_SIGNING_IDENTITY must be set explicitly"))
        #expect(!FileManager.default.fileExists(atPath: output.path))

        var unavailableIdentityEnvironment = missingIdentityEnvironment
        unavailableIdentityEnvironment["HIREVA_SIGNING_IDENTITY"] = "synthetic Developer ID identity"
        let unavailableIdentity = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: [app.path, output.path],
            environment: unavailableIdentityEnvironment
        )
        #expect(unavailableIdentity.status != 0)
        #expect(unavailableIdentity.output.contains("not a valid installed code-signing identity"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!unavailableIdentity.output.contains("Creating Hireva-"))
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
        #expect(sign.output.contains("nested Mach-O: Contents/Helpers/parakeet_asr_helper"))
        #expect(sign.output.contains("SIGNING_MODE=adhoc"))

        let verify = try runScript(
            repositoryRoot.appendingPathComponent("script/release/verify_app.sh"),
            arguments: [app.path],
            environment: baseEnvironment
        )
        #expect(verify.status == 0, Comment(rawValue: verify.output))

        let validateOnlyOutput = sandbox.appendingPathComponent("must-not-be-created", isDirectory: true)
        var validateEnvironment = baseEnvironment
        validateEnvironment["HIREVA_RELEASE_OUTPUT_DIR"] = validateOnlyOutput.path
        let validateOnly = try runScript(
            repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            arguments: ["--validate-only", app.path],
            environment: validateEnvironment
        )
        #expect(validateOnly.status == 0, Comment(rawValue: validateOnly.output))
        #expect(validateOnly.output.contains("VALIDATION=passed"))
        #expect(!FileManager.default.fileExists(atPath: validateOnlyOutput.path))

        let dmgCandidate = sandbox.appendingPathComponent("must-not-create-dmg-output", isDirectory: true)
        let dmgValidateOnly = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: ["--validate-only", app.path, dmgCandidate.path]
        )
        #expect(dmgValidateOnly.status == 0, Comment(rawValue: dmgValidateOnly.output))
        #expect(dmgValidateOnly.output.contains("OUTPUT_DIRECTORY_CANDIDATE=must-not-create-dmg-output"))
        #expect(!FileManager.default.fileExists(atPath: dmgCandidate.path))

        let renamedApp = sandbox.appendingPathComponent("Renamed.app", isDirectory: true)
        try FileManager.default.copyItem(at: app, to: renamedApp)
        let renamedRelease = try runScript(
            repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            arguments: ["--validate-only", renamedApp.path],
            environment: baseEnvironment
        )
        #expect(renamedRelease.status != 0)
        #expect(renamedRelease.output.contains("bundle filename must be Hireva.app"))
        let renamedDmg = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: [renamedApp.path, sandbox.appendingPathComponent("renamed-dmg-output").path]
        )
        #expect(renamedDmg.status != 0)
        #expect(renamedDmg.output.contains("bundle filename must be Hireva.app"))

        let appSymlink = sandbox.appendingPathComponent("Hireva-link.app")
        try FileManager.default.createSymbolicLink(at: appSymlink, withDestinationURL: app)
        let releaseSymlink = try runScript(
            repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            arguments: ["\(appSymlink.path)/"],
            environment: baseEnvironment
        )
        #expect(releaseSymlink.status != 0)
        #expect(releaseSymlink.output.contains("app bundle must not be a symbolic link"))
        let dmgSymlink = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: ["\(appSymlink.path)/", sandbox.appendingPathComponent("symlink-dmg-output").path]
        )
        #expect(dmgSymlink.status != 0)
        #expect(dmgSymlink.output.contains("app bundle must not be a symbolic link"))

        let nestedDotOutput = app.appendingPathComponent(
            "Contents/Resources/must-not-create-nested-dmg",
            isDirectory: true
        )
        let nestedDotSource = try runScript(
            repositoryRoot.appendingPathComponent("scripts/package_dmg.sh"),
            arguments: ["\(app.path)/Contents/..", nestedDotOutput.path]
        )
        #expect(nestedDotSource.status != 0)
        #expect(nestedDotSource.output.contains("output parent must not be the source app"))
        #expect(!FileManager.default.fileExists(atPath: nestedDotOutput.path))

        var nestedOutputEnvironment = baseEnvironment
        nestedOutputEnvironment["HIREVA_RELEASE_OUTPUT_DIR"] = app
            .appendingPathComponent("Contents/Resources", isDirectory: true).path
        let nestedOutput = try runScript(
            repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
            arguments: [app.path],
            environment: nestedOutputEnvironment
        )
        #expect(nestedOutput.status != 0)
        #expect(nestedOutput.output.contains("must not be the source app or one of its descendants"))
        let sourceAfterRejectedOutput = try runScript(
            repositoryRoot.appendingPathComponent("script/release/verify_app.sh"),
            arguments: [app.path],
            environment: baseEnvironment
        )
        #expect(sourceAfterRejectedOutput.status == 0, Comment(rawValue: sourceAfterRejectedOutput.output))

        var packageEnvironment = baseEnvironment
        try FileManager.default.createDirectory(at: releaseRoot, withIntermediateDirectories: true)
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
        #expect(manifest["source_tree_state"] as? String == "dirty")
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

    }

    @Test
    func dmgNotarizationRejectsChecksumMismatchBeforeSubmit() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva notarization checksum \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let releaseDirectory = sandbox.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        let dmgName = "Hireva-9.8.7-42-arm64.dmg"
        let dmg = releaseDirectory.appendingPathComponent(dmgName)
        try Data("synthetic signed DMG fixture".utf8).write(to: dmg)
        let originalHash = try sha256(of: dmg)
        let originalSize = try Data(contentsOf: dmg).count
        let manifest: [String: Any] = [
            "schema_version": 2,
            "dmg_artifact": dmgName,
            "dmg_sha256": originalHash,
            "dmg_size_bytes": originalSize,
            "signing_mode": "developer-id",
            "artifact_scope": "distribution_candidate_not_notarized",
            "source_tree_state": "clean",
            "architecture": "arm64"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(
            to: releaseDirectory.appendingPathComponent("Hireva-9.8.7-42-arm64.manifest.json"),
            options: .atomic
        )
        let handle = try FileHandle(forWritingTo: dmg)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()

        let result = try runScript(
            repositoryRoot.appendingPathComponent("script/release/notarize_release.sh"),
            arguments: [releaseDirectory.path],
            environment: [
                "HIREVA_SIGNING_MODE": "developer-id",
                "HIREVA_BUILD_ARCHS": "arm64",
                "HIREVA_EXPECTED_TEAM_IDENTIFIER": "ABCDE12345",
                "HIREVA_NOTARY_PROFILE": "synthetic-notary-profile",
                "HIREVA_ALLOW_NOTARIZATION_SUBMIT": "1",
                "HIREVA_RELEASE_OUTPUT_DIR": sandbox.path
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("DMG checksum differs from package manifest"))
        #expect(!result.output.contains("notarytool submit"))
        #expect(!FileManager.default.fileExists(
            atPath: releaseDirectory.appendingPathComponent("notarization-submit.plist").path
        ))
    }

    @Test
    func canonicalRuntimeHashSurvivesResigningAndRejectsPayloadAndRangeTampering() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva canonical macho \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let source = sandbox.appendingPathComponent("runtime.c")
        let library = sandbox.appendingPathComponent("runtime.dylib")
        try Data("const char *hireva_payload(void) { return \"canonical-payload-marker\"; }\n".utf8)
            .write(to: source)
        try compileC(
            source,
            output: library,
            extraArguments: ["-dynamiclib", "-Wl,-install_name,@rpath/runtime.dylib"]
        )

        let hashScript = repositoryRoot.appendingPathComponent("script/runtime/macho_payload_sha256.sh")
        let unsigned = try runScript(hashScript, arguments: [library.path])
        #expect(unsigned.status == 0, Comment(rawValue: unsigned.output))
        let expectedHash = unsigned.output.trimmingCharacters(in: .whitespacesAndNewlines)

        for identifier in ["com.langcheng.Hireva.Runtime.Short", "com.langcheng.Hireva.Runtime.Identifier.With.More.Bytes"] {
            let sign = try run(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", "--identifier", identifier, library.path]
            )
            #expect(sign.status == 0, Comment(rawValue: sign.output))
            let resigned = try runScript(hashScript, arguments: [library.path])
            #expect(resigned.status == 0, Comment(rawValue: resigned.output))
            #expect(resigned.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedHash)
        }

        let payloadTampered = sandbox.appendingPathComponent("payload-tampered.dylib")
        try FileManager.default.copyItem(at: library, to: payloadTampered)
        var payloadBytes = try Data(contentsOf: payloadTampered)
        let marker = Data("canonical-payload-marker".utf8)
        let markerRange = try #require(payloadBytes.range(of: marker))
        payloadBytes[markerRange.lowerBound] ^= 0x01
        try payloadBytes.write(to: payloadTampered)
        let tamperedHash = try runScript(hashScript, arguments: [payloadTampered.path])
        #expect(tamperedHash.status == 0, Comment(rawValue: tamperedHash.output))
        #expect(tamperedHash.output.trimmingCharacters(in: .whitespacesAndNewlines) != expectedHash)

        let malformed = sandbox.appendingPathComponent("malformed-section.dylib")
        try FileManager.default.copyItem(at: library, to: malformed)
        try corruptFirstFileBackedSectionOffset(at: malformed)
        let malformedHash = try runScript(hashScript, arguments: [malformed.path])
        #expect(malformedHash.status != 0)
        #expect(malformedHash.output.contains("section exceeds"))

        let malformedSignature = sandbox.appendingPathComponent("malformed-signature.dylib")
        try FileManager.default.copyItem(at: library, to: malformedSignature)
        try corruptCodeSignatureMagic(at: malformedSignature)
        let malformedSignatureHash = try runScript(hashScript, arguments: [malformedSignature.path])
        #expect(malformedSignatureHash.status != 0)
        #expect(malformedSignatureHash.output.contains("SuperBlob"))

        let malformedLinkedit = sandbox.appendingPathComponent("malformed-linkedit.dylib")
        try FileManager.default.copyItem(at: library, to: malformedLinkedit)
        try corruptLinkeditVirtualSize(at: malformedLinkedit)
        let malformedLinkeditHash = try runScript(hashScript, arguments: [malformedLinkedit.path])
        #expect(malformedLinkeditHash.status != 0)
        #expect(malformedLinkeditHash.output.contains("virtual size"))

        let overlappingSegment = sandbox.appendingPathComponent("overlapping-segment.dylib")
        try FileManager.default.copyItem(at: library, to: overlappingSegment)
        try extendFirstNonLinkeditSegmentToEndOfFile(at: overlappingSegment)
        let overlappingSegmentHash = try runScript(hashScript, arguments: [overlappingSegment.path])
        #expect(overlappingSegmentHash.status != 0)
        #expect(overlappingSegmentHash.output.contains("segment overlaps __LINKEDIT"))

        let oversized = sandbox.appendingPathComponent("oversized.dylib")
        try FileManager.default.copyItem(at: library, to: oversized)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try oversizedHandle.close()
        let oversizedHash = try runScript(hashScript, arguments: [oversized.path])
        #expect(oversizedHash.status != 0)
        #expect(oversizedHash.output.contains("64 MiB parser limit"))

        let excessiveCommands = sandbox.appendingPathComponent("excessive-commands.dylib")
        try FileManager.default.copyItem(at: library, to: excessiveCommands)
        try overwriteLoadCommandCount(at: excessiveCommands, count: 1_025)
        let excessiveCommandsHash = try runScript(hashScript, arguments: [excessiveCommands.path])
        #expect(excessiveCommandsHash.status != 0)
        #expect(excessiveCommandsHash.output.contains("1024-load-command limit"))

        let excessiveSections = sandbox.appendingPathComponent("excessive-sections.dylib")
        try FileManager.default.copyItem(at: library, to: excessiveSections)
        try overwriteFirstSegmentSectionCount(at: excessiveSections, count: 16_385)
        let excessiveSectionsHash = try runScript(hashScript, arguments: [excessiveSections.path])
        #expect(excessiveSectionsHash.status != 0)
        #expect(excessiveSectionsHash.output.contains("16384-section limit"))

        let excessiveSignatureEntries = sandbox.appendingPathComponent("excessive-signature-entries.dylib")
        try FileManager.default.copyItem(at: library, to: excessiveSignatureEntries)
        try overwriteCodeSignatureEntryCount(at: excessiveSignatureEntries, count: 65)
        let excessiveSignatureHash = try runScript(hashScript, arguments: [excessiveSignatureEntries.path])
        #expect(excessiveSignatureHash.status != 0)
        #expect(excessiveSignatureHash.output.contains("64-entry limit"))
    }

    @Test
    func runtimePathSanitizerRequiresTheReviewedExactReplacementCount() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva runtime path sanitizer \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let source = sandbox.appendingPathComponent("runtime.c")
        let library = sandbox.appendingPathComponent("runtime.dylib")
        try Data("const char *hireva_path(void) { return \"/Users/runner/work/synthetic/runtime.cc\"; }\n".utf8)
            .write(to: source)
        try compileC(source, output: library, extraArguments: ["-dynamiclib"])

        let sanitizer = repositoryRoot.appendingPathComponent("script/runtime/sanitize_runtime_paths.sh")
        let wrongCount = try runScript(sanitizer, arguments: [library.path, "2"])
        #expect(wrongCount.status != 0)
        #expect(wrongCount.output.contains("expected 2, found 1"))

        let sanitized = try runScript(sanitizer, arguments: [library.path, "1"])
        #expect(sanitized.status == 0, Comment(rawValue: sanitized.output))
        let sanitizedBytes = try Data(contentsOf: library)
        let sanitizedText = String(decoding: sanitizedBytes, as: UTF8.self)
        #expect(!sanitizedText.contains("/Users/"))
        #expect(sanitizedText.contains("/build/source/root/synthetic/runtime.cc"))

        let commit = String(repeating: "a", count: 40)
        let releaseBuildRoot = "/private/tmp/hireva-swiftpm-release-\(commit)"
        let releaseSource = sandbox.appendingPathComponent("release-runtime.c")
        let releaseLibrary = sandbox.appendingPathComponent("release-runtime.dylib")
        try Data(
            "const char *hireva_build_path(void) { return \"\(releaseBuildRoot)/checkouts/GRDB.swift/File.swift\"; }\n".utf8
        ).write(to: releaseSource)
        try compileC(releaseSource, output: releaseLibrary, extraArguments: ["-dynamiclib"])

        let releaseSanitizer = repositoryRoot.appendingPathComponent(
            "script/runtime/sanitize_release_build_paths.sh"
        )
        let wrongReleaseCount = try runScript(
            releaseSanitizer,
            arguments: [releaseLibrary.path, releaseBuildRoot, "2"]
        )
        #expect(wrongReleaseCount.status != 0)
        #expect(wrongReleaseCount.output.contains("expected 2, found 1"))

        let sanitizedRelease = try runScript(
            releaseSanitizer,
            arguments: [releaseLibrary.path, releaseBuildRoot, "1"]
        )
        #expect(sanitizedRelease.status == 0, Comment(rawValue: sanitizedRelease.output))
        let sanitizedReleaseText = String(decoding: try Data(contentsOf: releaseLibrary), as: UTF8.self)
        #expect(!sanitizedReleaseText.contains(releaseBuildRoot))
        #expect(sanitizedReleaseText.contains("/build/root_/hireva-swiftpm-release-\(commit)/checkouts"))
    }

    @Test
    func packagingRejectsInvalidHirevaReleaseContracts() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva release contract \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let baseDirectory = sandbox.appendingPathComponent("base", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let baseApp = try makeMachOAppFixture(in: baseDirectory)

        typealias RejectionFixture = (
            name: String,
            signingMode: String,
            buildArchitectures: String,
            expected: String,
            mutate: (URL) throws -> Void
        )
        let fixtures: [RejectionFixture] = [
            (
                "unexpected-resource-document", "adhoc", "arm64",
                "unexpected resource payload",
                { app in
                    try Data("synthetic release fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/synthetic-candidate.pdf")
                    )
                }
            ),
            (
                "modified-reviewed-document", "adhoc", "arm64",
                "release-installation.md differs from the reviewed release document",
                { app in
                    try Data("synthetic modified release document".utf8).write(
                        to: app.appendingPathComponent(
                            "Contents/Resources/Documentation/release-installation.md"
                        )
                    )
                }
            ),
            (
                "modified-pinned-notice", "adhoc", "arm64",
                "ONNX Runtime license differs from the pinned upstream notice",
                { app in
                    try Data("synthetic modified notice".utf8).write(
                        to: app.appendingPathComponent(
                            "Contents/Resources/ThirdPartyNotices/onnxruntime-LICENSE.txt"
                        )
                    )
                }
            ),
            (
                "unexpected-info-key", "adhoc", "arm64",
                "Info.plist contains a value or key outside the reviewed release contract",
                { app in
                    try updateInfoPlist(app) { $0["SyntheticAPIKey"] = "not-a-secret-fixture" }
                }
            ),
            (
                "wrong-minimum-system-version", "adhoc", "arm64",
                "LSMinimumSystemVersion must be the reviewed value 14.0",
                { app in
                    try updateInfoPlist(app) { $0["LSMinimumSystemVersion"] = "13.0" }
                }
            ),
            (
                "missing-microphone-usage", "adhoc", "arm64",
                "NSMicrophoneUsageDescription differs from the reviewed release text",
                { app in
                    try updateInfoPlist(app) { $0.removeValue(forKey: "NSMicrophoneUsageDescription") }
                }
            ),
            (
                "missing-speech-usage", "adhoc", "arm64",
                "NSSpeechRecognitionUsageDescription differs from the reviewed release text",
                { app in
                    try updateInfoPlist(app) { $0.removeValue(forKey: "NSSpeechRecognitionUsageDescription") }
                }
            ),
            (
                "missing-screen-usage", "adhoc", "arm64",
                "NSScreenCaptureUsageDescription differs from the reviewed release text",
                { app in
                    try updateInfoPlist(app) { $0.removeValue(forKey: "NSScreenCaptureUsageDescription") }
                }
            ),
            (
                "missing-audio-capture-usage", "adhoc", "arm64",
                "NSAudioCaptureUsageDescription differs from the reviewed release text",
                { app in
                    try updateInfoPlist(app) { $0.removeValue(forKey: "NSAudioCaptureUsageDescription") }
                }
            ),
            (
                "debug-configuration", "adhoc", "arm64",
                "HirevaBuildConfiguration must be release",
                { app in
                    try updateInfoPlist(app) { $0["HirevaBuildConfiguration"] = "debug" }
                }
            ),
            (
                "embedded-development-path", "adhoc", "arm64",
                "release app must not embed development source or bundle paths",
                { app in
                    try updateInfoPlist(app) { $0["HirevaSourceRoot"] = "/synthetic/source" }
                }
            ),
            (
                "absolute-user-path", "adhoc", "arm64",
                "absolute user path leaked into release app",
                { app in
                    try Data("/Users/synthetic/release-fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/Documentation/synthetic-path.txt")
                    )
                }
            ),
            (
                "disallowed-rpath", "adhoc", "arm64",
                "disallowed LC_RPATH in Contents/MacOS/Hireva: /opt/synthetic/toolchain",
                { app in
                    let source = app.deletingLastPathComponent().appendingPathComponent("rpath-main.c")
                    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
                    try compileC(
                        source,
                        output: app.appendingPathComponent("Contents/MacOS/Hireva"),
                        extraArguments: ["-Wl,-rpath,/opt/synthetic/toolchain"]
                    )
                }
            ),
            (
                "wrong-bundle-id", "adhoc", "arm64",
                "CFBundleIdentifier must be com.langcheng.Hireva",
                { app in
                    try updateInfoPlist(app) { $0["CFBundleIdentifier"] = "com.example.NotHireva" }
                }
            ),
            (
                "missing-helper", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Helpers/parakeet_asr_helper",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
                    )
                }
            ),
            (
                "missing-documentation", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Resources/Documentation/privacy-and-data-flow.md",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent("Contents/Resources/Documentation/privacy-and-data-flow.md")
                    )
                }
            ),
            (
                "missing-privacy-manifest", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Resources/PrivacyInfo.xcprivacy",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy")
                    )
                }
            ),
            (
                "missing-runtime-provenance", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Resources/RuntimeProvenance.plist",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent("Contents/Resources/RuntimeProvenance.plist")
                    )
                }
            ),
            (
                "tampered-runtime-payload", "adhoc", "arm64",
                "bundled sherpa Mach-O payload differs from verified source provenance",
                { app in
                    try updateRuntimeProvenance(app) {
                        var sherpa = try #require($0["sherpa_onnx"] as? [String: Any])
                        sherpa["macho_payload_sha256"] = String(repeating: "0", count: 64)
                        $0["sherpa_onnx"] = sherpa
                    }
                }
            ),
            (
                "unknown-runtime-provenance-key", "adhoc", "arm64",
                "runtime provenance contains an unexpected declaration",
                { app in
                    try updateRuntimeProvenance(app) { $0["SyntheticUnknownKey"] = "must-fail" }
                }
            ),
            (
                "tracking-enabled", "adhoc", "arm64",
                "app privacy manifest must declare NSPrivacyTracking=false",
                { app in
                    try updatePrivacyManifest(app) { $0["NSPrivacyTracking"] = true }
                }
            ),
            (
                "macos-required-reason-entry", "adhoc", "arm64",
                "app privacy manifest must not declare required-reason APIs for macOS",
                { app in
                    try updatePrivacyManifest(app) {
                        $0["NSPrivacyAccessedAPITypes"] = [[
                            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]
                        ]]
                    }
                }
            ),
            (
                "unknown-app-privacy-key", "adhoc", "arm64",
                "app privacy manifest differs from the reviewed release declaration",
                { app in
                    try updatePrivacyManifest(app) { $0["SyntheticUnknownKey"] = "must-fail" }
                }
            ),
            (
                "missing-grdb-privacy-manifest", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Resources/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent("Contents/Resources/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy")
                    )
                }
            ),
            (
                "grdb-tracking-enabled", "adhoc", "arm64",
                "GRDB privacy manifest must declare NSPrivacyTracking=false",
                { app in
                    try updatePrivacyManifest(app, relativePath: "Contents/Resources/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy") {
                        $0["NSPrivacyTracking"] = true
                    }
                }
            ),
            (
                "unknown-grdb-privacy-key", "adhoc", "arm64",
                "GRDB privacy manifest differs from the pinned dependency declaration",
                { app in
                    try updatePrivacyManifest(
                        app,
                        relativePath: "Contents/Resources/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy"
                    ) { $0["SyntheticUnknownKey"] = "must-fail" }
                }
            ),
            (
                "missing-notice", "adhoc", "arm64",
                "required Hireva payload is missing or empty: Contents/Resources/ThirdPartyNotices/onnxruntime-ThirdPartyNotices.txt",
                { app in
                    try FileManager.default.removeItem(
                        at: app.appendingPathComponent(
                            "Contents/Resources/ThirdPartyNotices/onnxruntime-ThirdPartyNotices.txt"
                        )
                    )
                }
            ),
            (
                "wrong-helper-architecture", "adhoc", "arm64",
                "required Hireva Mach-O must be exactly arm64: Contents/Helpers/parakeet_asr_helper",
                { app in
                    let source = app.deletingLastPathComponent().appendingPathComponent("wrong-arch-helper.c")
                    try Data("int main(void) { return 0; }\n".utf8).write(to: source)
                    try compileC(
                        source,
                        output: app.appendingPathComponent("Contents/Helpers/parakeet_asr_helper"),
                        architecture: "x86_64"
                    )
                }
            ),
            (
                "invalid-health", "adhoc", "arm64",
                "bundled Parakeet helper returned an invalid health contract",
                { app in
                    let source = app.deletingLastPathComponent().appendingPathComponent("invalid-health-helper.c")
                    try Data(
                        #"""
                        #include <stdio.h>
                        int main(void) {
                            puts("{\"status\":\"degraded\"}");
                            return 0;
                        }
                        """#.utf8
                    ).write(to: source)
                    try compileC(
                        source,
                        output: app.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
                    )
                }
            ),
            (
                "hanging-health", "adhoc", "arm64",
                "bundled Parakeet helper health probe exceeded 5 seconds",
                { app in
                    let source = app.deletingLastPathComponent().appendingPathComponent("hanging-health-helper.c")
                    try Data("int main(void) { for (;;) {} }\n".utf8).write(to: source)
                    try compileC(
                        source,
                        output: app.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
                    )
                }
            ),
            (
                "oversized-health", "adhoc", "arm64",
                "bundled Parakeet helper health probe exceeded 65536 bytes",
                { app in
                    let source = app.deletingLastPathComponent().appendingPathComponent("oversized-health-helper.c")
                    try Data(
                        #"""
                        #include <stdio.h>
                        int main(void) { for (int i = 0; i < 131072; ++i) putchar('x'); return 0; }
                        """#.utf8
                    ).write(to: source)
                    try compileC(
                        source,
                        output: app.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
                    )
                }
            ),
            (
                "python-runtime", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/python3",
                { app in
                    try Data("python fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/python3")
                    )
                }
            ),
            (
                "model-payload", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/LocalModels",
                { app in
                    try FileManager.default.createDirectory(
                        at: app.appendingPathComponent("Contents/Resources/LocalModels"),
                        withIntermediateDirectories: true
                    )
                }
            ),
            (
                "sqlite-payload", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/hireva.sqlite",
                { app in
                    try Data("sqlite fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/hireva.sqlite")
                    )
                }
            ),
            (
                "wav-payload", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/interview.wav",
                { app in
                    try Data("wav fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/interview.wav")
                    )
                }
            ),
            (
                "trace-payload", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/runtime_transcript_trace.1.jsonl",
                { app in
                    try Data("trace fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/runtime_transcript_trace.1.jsonl")
                    )
                }
            ),
            (
                "private-key", "adhoc", "arm64",
                "forbidden private/runtime payload in app: Contents/Resources/release.pem",
                { app in
                    try Data("private fixture".utf8).write(
                        to: app.appendingPathComponent("Contents/Resources/release.pem")
                    )
                }
            ),
            (
                "dirty-developer-id", "developer-id", "arm64",
                "developer-id packaging requires a clean source tree",
                { app in
                    try updateInfoPlist(app) {
                        $0["HirevaGitTreeState"] = "dirty"
                        $0["HirevaSigningMode"] = "developer-id"
                        $0["HirevaDistributionBuild"] = true
                    }
                }
            ),
            (
                "non-production-distribution-metadata", "adhoc", "arm64",
                "non-distribution signing mode has distribution metadata",
                { app in
                    try updateInfoPlist(app) { $0["HirevaDistributionBuild"] = true }
                }
            ),
            (
                "unknown-tree-state", "adhoc", "arm64",
                "HirevaGitTreeState must explicitly be clean or dirty",
                { app in
                    try updateInfoPlist(app) { $0["HirevaGitTreeState"] = "unknown" }
                }
            ),
            (
                "short-source-commit", "adhoc", "arm64",
                "HirevaGitCommitHash must be a full lowercase Git object ID",
                { app in
                    try updateInfoPlist(app) { $0["HirevaGitCommitHash"] = "deadbeef" }
                }
            ),
            (
                "embedded-signing-mode", "adhoc", "arm64",
                "embedded signing mode does not match HIREVA_SIGNING_MODE",
                { app in
                    try updateInfoPlist(app) { $0["HirevaSigningMode"] = "development" }
                }
            ),
            (
                "caller-architectures", "adhoc", "x86_64",
                "Hireva release packaging requires exactly HIREVA_BUILD_ARCHS=arm64",
                { _ in }
            ),
            (
                "actual-signature-mode", "developer-id", "arm64",
                "signature does not match HIREVA_SIGNING_MODE=developer-id",
                { app in
                    try updateInfoPlist(app) {
                        $0["HirevaGitTreeState"] = "clean"
                        $0["HirevaSigningMode"] = "developer-id"
                        $0["HirevaDistributionBuild"] = true
                    }
                }
            )
        ]

        for fixture in fixtures {
            let fixtureDirectory = sandbox.appendingPathComponent(fixture.name, isDirectory: true)
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
            let app = fixtureDirectory.appendingPathComponent("Hireva.app", isDirectory: true)
            try FileManager.default.copyItem(at: baseApp, to: app)
            try fixture.mutate(app)
            try adHocSignFixture(app)
            let artifactDirectory = fixtureDirectory.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

            let package = try runScript(
                repositoryRoot.appendingPathComponent("script/release/package_release.sh"),
                arguments: [app.path],
                environment: [
                    "HIREVA_SIGNING_MODE": fixture.signingMode,
                    "HIREVA_BUILD_ARCHS": fixture.buildArchitectures,
                    "HIREVA_RELEASE_OUTPUT_DIR": artifactDirectory.path
                ]
            )
            #expect(package.status != 0, "Fixture unexpectedly packaged: \(fixture.name)")
            #expect(
                package.output.contains(fixture.expected),
                "Fixture \(fixture.name) returned unexpected output: \(package.output)"
            )
        }
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
                "HIREVA_EXPECTED_TEAM_IDENTIFIER": "ABCDE12345",
                "HIREVA_RELEASE_OUTPUT_DIR": FileManager.default.temporaryDirectory.path
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("HIREVA_NOTARY_PROFILE must be set explicitly"))
        #expect(!result.output.contains("notarytool submit"))
    }

    @Test
    func notarizationRequiresExplicitSubmitAuthorizationBeforeArtifactAccess() throws {
        let missing = repositoryRoot.appendingPathComponent("does-not-exist")
        let result = try runScript(
            repositoryRoot.appendingPathComponent("script/release/notarize_release.sh"),
            arguments: [missing.path],
            environment: [
                "HIREVA_SIGNING_MODE": "developer-id",
                "HIREVA_BUILD_ARCHS": "arm64",
                "HIREVA_EXPECTED_TEAM_IDENTIFIER": "ABCDE12345",
                "HIREVA_NOTARY_PROFILE": "synthetic-notary-profile",
                "HIREVA_RELEASE_OUTPUT_DIR": FileManager.default.temporaryDirectory.path
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("HIREVA_ALLOW_NOTARIZATION_SUBMIT=1 authorization"))
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
            "HIREVA_ALLOW_DISTRIBUTION_DMG",
            "HIREVA_ALLOW_NOTARIZATION_SUBMIT",
            "HIREVA_EXPECTED_TEAM_IDENTIFIER",
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

    private func corruptFirstFileBackedSectionOffset(at file: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        func readUInt64(_ offset: Int) -> UInt64 {
            UInt64(readUInt32(offset)) | (UInt64(readUInt32(offset + 4)) << 32)
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command is truncated")
            }
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x19, commandSize >= 72 {
                let sectionCount = Int(readUInt32(cursor + 64))
                for sectionIndex in 0..<sectionCount {
                    let section = cursor + 72 + sectionIndex * 80
                    guard section + 80 <= cursor + commandSize else {
                        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O section table is invalid")
                    }
                    let sectionSize = readUInt64(section + 40)
                    let sectionType = readUInt32(section + 64) & 0xff
                    if sectionSize > 0, ![UInt32(0x1), 0xc, 0x12].contains(sectionType) {
                        bytes.replaceSubrange((section + 48)..<(section + 52), with: [0xff, 0xff, 0xff, 0xff])
                        try Data(bytes).write(to: file)
                        return
                    }
                }
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no file-backed section")
    }

    private func corruptCodeSignatureMagic(at file: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command is truncated")
            }
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x1d, commandSize == 16 {
                let signatureOffset = Int(readUInt32(cursor + 8))
                guard signatureOffset < bytes.count else {
                    throw ReleaseToolingTestError.commandFailed("synthetic code signature is out of range")
                }
                bytes[signatureOffset] ^= 0x01
                try Data(bytes).write(to: file)
                return
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no code signature")
    }

    private func overwriteLoadCommandCount(at file: URL, count: UInt32) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        bytes.replaceSubrange(16..<20, with: [
            UInt8(count & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 24) & 0xff)
        ])
        try Data(bytes).write(to: file)
    }

    private func overwriteCodeSignatureEntryCount(at file: URL, count: UInt32) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command is truncated")
            }
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x1d, commandSize == 16 {
                let signatureOffset = Int(readUInt32(cursor + 8))
                guard signatureOffset + 12 <= bytes.count else {
                    throw ReleaseToolingTestError.commandFailed("synthetic code signature is out of range")
                }
                bytes.replaceSubrange((signatureOffset + 8)..<(signatureOffset + 12), with: [
                    UInt8((count >> 24) & 0xff),
                    UInt8((count >> 16) & 0xff),
                    UInt8((count >> 8) & 0xff),
                    UInt8(count & 0xff)
                ])
                try Data(bytes).write(to: file)
                return
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no code signature")
    }

    private func corruptLinkeditVirtualSize(at file: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            guard cursor + 8 <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command is truncated")
            }
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x19, commandSize >= 72 {
                let nameBytes = bytes[(cursor + 8)..<(cursor + 24)]
                let linkeditName = Array("__LINKEDIT".utf8) + Array(repeating: UInt8(0), count: 6)
                if Array(nameBytes) == linkeditName {
                    bytes[cursor + 32] ^= 0x01
                    try Data(bytes).write(to: file)
                    return
                }
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no __LINKEDIT segment")
    }

    private func extendFirstNonLinkeditSegmentToEndOfFile(at file: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        func writeUInt64(_ value: UInt64, at offset: Int) {
            for index in 0..<8 {
                bytes[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
            }
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x19, commandSize >= 72 {
                let name = String(decoding: bytes[(cursor + 8)..<(cursor + 24)].prefix { $0 != 0 }, as: UTF8.self)
                let fileOffset = UInt64(readUInt32(cursor + 40))
                    | (UInt64(readUInt32(cursor + 44)) << 32)
                if name != "__LINKEDIT", fileOffset == 0 {
                    let fileSize = UInt64(bytes.count)
                    writeUInt64(fileSize, at: cursor + 32)
                    writeUInt64(fileSize, at: cursor + 48)
                    try Data(bytes).write(to: file)
                    return
                }
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no suitable non-__LINKEDIT segment")
    }

    private func overwriteFirstSegmentSectionCount(at file: URL, count: UInt32) throws {
        var bytes = [UInt8](try Data(contentsOf: file))
        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        guard bytes.count >= 32 else {
            throw ReleaseToolingTestError.commandFailed("synthetic Mach-O is too small")
        }
        let commandCount = Int(readUInt32(16))
        var cursor = 32
        for _ in 0..<commandCount {
            let command = readUInt32(cursor)
            let commandSize = Int(readUInt32(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= bytes.count else {
                throw ReleaseToolingTestError.commandFailed("synthetic Mach-O command size is invalid")
            }
            if command == 0x19, commandSize >= 72 {
                bytes.replaceSubrange((cursor + 64)..<(cursor + 68), with: [
                    UInt8(count & 0xff),
                    UInt8((count >> 8) & 0xff),
                    UInt8((count >> 16) & 0xff),
                    UInt8((count >> 24) & 0xff)
                ])
                try Data(bytes).write(to: file)
                return
            }
            cursor += commandSize
        }
        throw ReleaseToolingTestError.commandFailed("synthetic Mach-O has no segment command")
    }

    private func makeMachOAppFixture(in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent("Hireva.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let documentation = contents.appendingPathComponent("Resources/Documentation", isDirectory: true)
        let notices = contents.appendingPathComponent("Resources/ThirdPartyNotices", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)
        let grdbBundle = app.appendingPathComponent(
            "Contents/Resources/GRDB_GRDB.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: grdbBundle, withIntermediateDirectories: true)
        let grdbInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleDevelopmentRegion": "en"],
            format: .xml,
            options: 0
        )
        try grdbInfo.write(to: grdbBundle.appendingPathComponent("Info.plist"), options: .atomic)
        let grdbPrivacy = try PropertyListSerialization.data(
            fromPropertyList: [
                "NSPrivacyTracking": false,
                "NSPrivacyTrackingDomains": [],
                "NSPrivacyCollectedDataTypes": [],
                "NSPrivacyAccessedAPITypes": []
            ],
            format: .xml,
            options: 0
        )
        try grdbPrivacy.write(
            to: grdbBundle.appendingPathComponent("PrivacyInfo.xcprivacy"),
            options: .atomic
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Resources/PrivacyInfo.xcprivacy"),
            to: contents.appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Resources/AppIcon.icns"),
            to: contents.appendingPathComponent("Resources/AppIcon.icns")
        )
        for name in [
            "release-installation.md",
            "local-model-installation.md",
            "privacy-and-data-flow.md",
            "third-party-licenses.md",
            "release-notes-0.1.0.md"
        ] {
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent("docs/\(name)"),
                to: documentation.appendingPathComponent(name)
            )
        }
        for name in [
            "sherpa-onnx-LICENSE.txt",
            "onnxruntime-LICENSE.txt",
            "onnxruntime-ThirdPartyNotices.txt",
            "GRDB-LICENSE.txt"
        ] {
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent("Resources/ThirdPartyNotices/\(name)"),
                to: notices.appendingPathComponent(name)
            )
        }

        let sourceDirectory = directory.appendingPathComponent("fixture-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let mainSource = sourceDirectory.appendingPathComponent("main.c")
        let helperSource = sourceDirectory.appendingPathComponent("helper.c")
        let librarySource = sourceDirectory.appendingPathComponent("runtime.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: mainSource)
        try Data(
            #"""
            #include <stdio.h>
            int main(void) {
                puts("{\"status\":\"ok\",\"source\":\"local_parakeet_asr\",\"runtimeMode\":\"bundled_native\",\"runtimeVersion\":\"1\",\"sherpaVersion\":\"1.13.4\",\"onnxRuntimeVersion\":\"1.27.0\",\"architecture\":\"arm64\",\"modelStatus\":\"not_probed\"}");
                return 0;
            }
            """#.utf8
        ).write(to: helperSource)
        try Data("int hireva_runtime_fixture(void) { return 1; }\n".utf8).write(to: librarySource)

        let mainExecutable = macOS.appendingPathComponent("Hireva")
        let helperExecutable = helpers.appendingPathComponent("parakeet_asr_helper")
        try compileC(mainSource, output: mainExecutable)
        try compileC(helperSource, output: helperExecutable)
        try compileC(
            librarySource,
            output: frameworks.appendingPathComponent("libsherpa-onnx-c-api.dylib"),
            extraArguments: ["-dynamiclib", "-Wl,-install_name,@rpath/libsherpa-onnx-c-api.dylib"]
        )
        try compileC(
            librarySource,
            output: frameworks.appendingPathComponent("libonnxruntime.1.27.0.dylib"),
            extraArguments: ["-dynamiclib", "-Wl,-install_name,@rpath/libonnxruntime.1.27.0.dylib"]
        )

        let sherpaPayloadSHA256 = try machoPayloadSHA256(
            of: frameworks.appendingPathComponent("libsherpa-onnx-c-api.dylib")
        )
        let onnxPayloadSHA256 = try machoPayloadSHA256(
            of: frameworks.appendingPathComponent("libonnxruntime.1.27.0.dylib")
        )
        let runtimeProvenance: [String: Any] = [
            "schema_version": 2,
            "source_verification": "pinned-full-file-sha256-before-reviewed-path-sanitization-and-bundle-signing",
            "payload_hash_algorithm": "hireva-thin-arm64-macho-canonical-sha256-v1",
            "binary_transform_identifier": "equal-length-path-sanitization-and-strip-S-x-v1",
            "path_sanitization_identifier": "github-actions-runner-prefix-to-build-source-root-v1",
            "source_archive_sha256": "c003242369046d3c2adc6b48c3c96e0ff129e76738b7f3aa5342828ec8ba410d",
            "sherpa_onnx": [
                "version": "1.13.4",
                "source_library_sha256": "08caf3346b82648540c8c9b738ee10b06e728a5ea525184230b25321ec57f047",
                "source_path_replacement_count": 214,
                "macho_payload_sha256": sherpaPayloadSHA256
            ],
            "onnx_runtime": [
                "version": "1.27.0",
                "source_library_sha256": "8e822d761fac13e47c6725baf1e65d9858ea00bf0af3e61a43b7c6a65a794439",
                "source_path_replacement_count": 584,
                "macho_payload_sha256": onnxPayloadSHA256
            ]
        ]
        let runtimeProvenanceData = try PropertyListSerialization.data(
            fromPropertyList: runtimeProvenance,
            format: .xml,
            options: 0
        )
        try runtimeProvenanceData.write(
            to: contents.appendingPathComponent("Resources/RuntimeProvenance.plist"),
            options: .atomic
        )

        let info: [String: Any] = [
            "CFBundleExecutable": "Hireva",
            "CFBundleIdentifier": "com.langcheng.Hireva",
            "CFBundleName": "Hireva",
            "CFBundleDisplayName": "Hireva",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "42",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
            "NSHumanReadableCopyright": "Copyright 2026",
            "LSMinimumSystemVersion": "14.0",
            "NSMicrophoneUsageDescription": "Hireva uses the microphone to transcribe interview audio in real time.",
            "NSSpeechRecognitionUsageDescription": "Hireva uses Apple Speech to transcribe selected interview audio. Depending on macOS and locale, processing may occur on Apple servers.",
            "NSScreenCaptureUsageDescription": "Hireva captures system audio to detect interviewer questions automatically.",
            "NSAudioCaptureUsageDescription": "Hireva captures system audio for real-time interviewer question detection.",
            "HirevaBuildTimestampUTC": "2026-08-27T12:00:00Z",
            "HirevaGitCommitHash": String(repeating: "a", count: 40),
            "HirevaGitTreeState": "dirty",
            "HirevaRuntimeMode": "bundled_native",
            "HirevaSigningMode": "adhoc",
            "HirevaBuildConfiguration": "release",
            "HirevaDistributionBuild": false
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        return app
    }

    private func compileC(
        _ source: URL,
        output: URL,
        architecture: String = "arm64",
        extraArguments: [String] = []
    ) throws {
        let result = try run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang", "-arch", architecture] + extraArguments + [source.path, "-o", output.path]
        )
        guard result.status == 0 else {
            throw ReleaseToolingTestError.commandFailed(result.output)
        }
    }

    private func updateInfoPlist(
        _ app: URL,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        var info = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        mutation(&info)
        let updated = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    private func updatePrivacyManifest(
        _ app: URL,
        relativePath: String = "Contents/Resources/PrivacyInfo.xcprivacy",
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let url = app.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        var manifest = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        mutation(&manifest)
        let updated = try PropertyListSerialization.data(
            fromPropertyList: manifest,
            format: .xml,
            options: 0
        )
        try updated.write(to: url, options: .atomic)
    }

    private func updateRuntimeProvenance(
        _ app: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let url = app.appendingPathComponent("Contents/Resources/RuntimeProvenance.plist")
        let data = try Data(contentsOf: url)
        var manifest = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        try mutation(&manifest)
        let updated = try PropertyListSerialization.data(
            fromPropertyList: manifest,
            format: .xml,
            options: 0
        )
        try updated.write(to: url, options: .atomic)
    }

    private func machoPayloadSHA256(of file: URL) throws -> String {
        let result = try run(
            executable: "/bin/bash",
            arguments: [
                repositoryRoot.appendingPathComponent("script/runtime/macho_payload_sha256.sh").path,
                file.path
            ]
        )
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ReleaseToolingTestError.commandFailed(result.output)
        }
        return value
    }

    private func adHocSignFixture(_ app: URL) throws {
        let relativeMachOPaths = [
            "Contents/Frameworks/libsherpa-onnx-c-api.dylib",
            "Contents/Frameworks/libonnxruntime.1.27.0.dylib",
            "Contents/Helpers/parakeet_asr_helper",
            "Contents/MacOS/Hireva"
        ]
        for relativePath in relativeMachOPaths {
            let path = app.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let sign = try run(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", "-", path.path]
            )
            guard sign.status == 0 else {
                throw ReleaseToolingTestError.commandFailed(sign.output)
            }
        }
        let sign = try run(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", app.path]
        )
        guard sign.status == 0 else {
            throw ReleaseToolingTestError.commandFailed(sign.output)
        }
    }

    private enum ReleaseToolingTestError: Error {
        case commandFailed(String)
    }
}
