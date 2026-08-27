import CryptoKit
import Foundation

struct HirevaVerificationConfiguration: Equatable {
    static let isRequested = ProcessInfo.processInfo.environment["HIREVA_VERIFICATION_MODE"] == "1"
    static let current = load(
        environment: ProcessInfo.processInfo.environment,
        bundleSourceRoot: Bundle.main.object(forInfoDictionaryKey: "HirevaSourceRoot") as? String
    )

    let runID: String
    let runNonce: String
    let scenarioSHA256: String
    let scenarioURL: URL
    let outputDirectory: URL
    let applicationSupportDirectory: URL
    let localModelsDirectory: URL?
    let userDefaultsSuiteName: String

    static func load(
        environment: [String: String],
        bundleSourceRoot: String?,
        fileManager: FileManager = .default
    ) -> HirevaVerificationConfiguration? {
        guard environment["HIREVA_VERIFICATION_MODE"] == "1",
              let scenarioPath = nonempty(environment["HIREVA_VERIFICATION_SCENARIO_PATH"]),
              let expectedScenarioSHA256 = nonempty(environment["HIREVA_VERIFICATION_SCENARIO_SHA256"]),
              expectedScenarioSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let runNonce = nonempty(environment["HIREVA_VERIFICATION_RUN_NONCE"]),
              runNonce.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
              let outputPath = nonempty(environment["HIREVA_VERIFICATION_OUTPUT_ROOT"]),
              let appSupportPath = nonempty(environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"]) else {
            return nil
        }

        let scenarioURL = URL(fileURLWithPath: scenarioPath).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let applicationSupportDirectory = URL(fileURLWithPath: appSupportPath, isDirectory: true).standardizedFileURL
        guard scenarioURL.path.hasPrefix("/"),
              outputDirectory.path.hasPrefix("/"),
              applicationSupportDirectory.path.hasPrefix("/"),
              regularFileExists(scenarioURL, fileManager: fileManager),
              directoryExists(outputDirectory, fileManager: fileManager),
              directoryExists(applicationSupportDirectory, fileManager: fileManager),
              let data = try? Data(contentsOf: scenarioURL),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedScenarioSHA256,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["synthetic"] as? Bool == true,
              let provenance = object["provenance"] as? [String: Any],
              provenance["schemaVersion"] as? Int == 1,
              provenance["origin"] as? String == "project_authored_synthetic_fixture",
              provenance["containsRealPersonalData"] as? Bool == false,
              provenance["reviewedForRelease"] as? Bool == true,
              let runID = object["runID"] as? String,
              runID.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) != nil else {
            return nil
        }

        if let sourceRoot = bundleSourceRoot, !sourceRoot.isEmpty {
            let sourceURL = URL(fileURLWithPath: sourceRoot, isDirectory: true).standardizedFileURL
            guard !isContained(outputDirectory, in: sourceURL),
                  !isContained(applicationSupportDirectory, in: sourceURL) else {
                return nil
            }
        }

        let modelRoot = nonempty(environment["HIREVA_VERIFICATION_MODEL_ROOT"]).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        if let modelRoot, !directoryExists(modelRoot, fileManager: fileManager) {
            return nil
        }

        let safeRunID = runID.replacingOccurrences(
            of: #"[^A-Za-z0-9.-]"#,
            with: "-",
            options: .regularExpression
        )
        return HirevaVerificationConfiguration(
            runID: runID,
            runNonce: runNonce,
            scenarioSHA256: expectedScenarioSHA256,
            scenarioURL: scenarioURL,
            outputDirectory: outputDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            localModelsDirectory: modelRoot,
            userDefaultsSuiteName: "com.langcheng.Hireva.verification.\(safeRunID).\(expectedScenarioSHA256.prefix(16)).\(runNonce)"
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func regularFileExists(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}
