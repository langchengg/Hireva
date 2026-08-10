import Foundation

struct HirevaVerificationConfiguration: Equatable {
    static let current = load(
        environment: ProcessInfo.processInfo.environment,
        bundleSourceRoot: Bundle.main.object(forInfoDictionaryKey: "HirevaSourceRoot") as? String
    )

    let runID: String
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
              fileManager.fileExists(atPath: scenarioURL.path),
              directoryExists(outputDirectory, fileManager: fileManager),
              directoryExists(applicationSupportDirectory, fileManager: fileManager),
              let data = try? Data(contentsOf: scenarioURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["synthetic"] as? Bool == true,
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
            scenarioURL: scenarioURL,
            outputDirectory: outputDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            localModelsDirectory: modelRoot,
            userDefaultsSuiteName: "com.langcheng.Hireva.verification.\(safeRunID)"
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}
