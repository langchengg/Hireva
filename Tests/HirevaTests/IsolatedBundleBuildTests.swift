import Foundation
import Testing

@Suite(.serialized)
struct IsolatedBundleBuildTests {
    @Test
    func verificationLaunchModesRejectBeforeStoppingAnyApplication() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (mode, configuration) in [
            ("run", ["HIREVA_VERIFICATION_MODE": "1"]),
            ("--verify", ["HIREVA_VERIFICATION_MODE": "1"]),
            ("--relaunch", ["HIREVA_VERIFICATION_MODE": "1"]),
            ("--debug", ["HIREVA_VERIFICATION_MODE": "1"]),
            ("--reset-tcc", ["HIREVA_VERIFICATION_MODE": "1"]),
            ("run", ["HIREVA_VERIFICATION_MODE": ""]),
            ("--relaunch", ["HIREVA_VERIFICATION_APP_SUPPORT_DIR": "/synthetic/missing"])
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("script/build_and_run.sh").path, mode]
            process.currentDirectoryURL = root
            process.environment = ["PATH": "/usr/bin:/bin", "HIREVA_SIGNING_MODE": "adhoc"]
                .merging(configuration, uniquingKeysWith: { _, new in new })
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 2)
            #expect(text.contains("verification requires --build-only"))
            #expect(!text.contains("[quit]"))
            #expect(!text.contains("[relaunch]"))
            #expect(!text.contains("[bundle]"))
            #expect(!text.contains("Resetting TCC"))
        }
    }

    @Test
    func buildOnlyCannotCleanAnExistingUnrelatedOutputTree() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canary = directory.appendingPathComponent(".DS_Store")
        try Data("owned synthetic canary".utf8).write(to: canary)
        let alias = directory.appendingPathComponent("output-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        for destination in [directory.path, alias.path] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("script/build_and_run.sh").path, "--build-only"]
            process.currentDirectoryURL = root
            process.environment = ["PATH": "/usr/bin:/bin", "HIREVA_SIGNING_MODE": "adhoc",
                "HIREVA_BUNDLE_OUTPUT_DIR": destination]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 2)
            #expect(text.contains("independent fresh or empty"))
            #expect(!text.contains("[bundle]"))
            #expect(try Data(contentsOf: canary) == Data("owned synthetic canary".utf8))
        }
    }

    @Test
    func buildOnlyRejectsLegacyDestinationsBeforeAnyMutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("Hireva.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let canary = bundle.appendingPathComponent("must-survive.txt")
        try Data("Owned synthetic canary".utf8).write(to: canary)
        for destination in ["relative-directory", directory.path] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("script/build_and_run.sh").path, "--build-only"]
            process.currentDirectoryURL = root
            // Isolated environment: no signing credential, fixed user home or
            // prebuilt binary inherited from a developer's shell.
            var environment = ["PATH": "/usr/bin:/bin", "HIREVA_SIGNING_MODE": "adhoc"]
            environment["HIREVA_BUNDLE_OUTPUT_DIR"] = destination
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            #expect(process.terminationStatus == 2)
            #expect(text.contains("--build-only requires an absolute"))
            #expect(!text.contains("[quit]"))
            #expect(!text.contains("[bundle]"))
            #expect(try String(contentsOf: canary) == "Owned synthetic canary")
        }
    }
}
