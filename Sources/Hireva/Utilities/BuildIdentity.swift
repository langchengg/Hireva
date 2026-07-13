import Foundation

struct BuildIdentity: Hashable {
    static let expectedBundleIdentifier = HirevaProductIdentity.bundleIdentifier
    static let expectedDistBundleSuffix = "/dist/Hireva.app"

    let bundlePath: String
    let executablePath: String
    let executableName: String
    let infoPlistPath: String
    let bundleIdentifier: String
    let bundleName: String
    let buildTimestampUTC: String
    let gitCommitHash: String
    let gitBranch: String
    let sourceRoot: String
    let expectedBundlePath: String
    let executableModifiedAt: Date?
    let infoPlistModifiedAt: Date?
    let latestSourceModifiedAt: Date?
    let runningFromDistApp: Bool
    let expectedBundlePathMatches: Bool
    let bundleIdentifierMatches: Bool

    var appearsStale: Bool {
        staleWarning != nil
    }

    var staleWarning: String? {
        if !bundleIdentifierMatches {
            return "This app bundle has bundle id \(bundleIdentifier), expected \(Self.expectedBundleIdentifier)."
        }
        if !runningFromDistApp {
            return "You may be running a development or stale app build."
        }
        if !expectedBundlePathMatches {
            return "You may be running a development or stale app build."
        }
        guard let latestSourceModifiedAt, let executableModifiedAt else {
            return nil
        }
        if latestSourceModifiedAt.timeIntervalSince(executableModifiedAt) > 5 {
            return "This app bundle may be stale. Rebuild and relaunch from dist/Hireva.app."
        }
        return nil
    }

    var executableModifiedDisplay: String {
        Self.displayDate(executableModifiedAt)
    }

    var infoPlistModifiedDisplay: String {
        Self.displayDate(infoPlistModifiedAt)
    }

    var latestSourceModifiedDisplay: String {
        Self.displayDate(latestSourceModifiedAt)
    }

    static func current(bundle: Bundle = .main, fileManager: FileManager = .default) -> BuildIdentity {
        let info = bundle.infoDictionary ?? [:]
        let bundlePath = bundle.bundlePath
        let executablePath = bundle.executableURL?.path ?? "Unknown"
        let executableName = bundle.executableURL?.lastPathComponent ?? "Unknown"
        let infoPlistPath = bundle.url(forResource: "Info", withExtension: "plist")?.path
            ?? URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist").path
        let bundleIdentifier = bundle.bundleIdentifier ?? "Unknown"
        let bundleName = info["CFBundleName"] as? String ?? "Unknown"
        let buildTimestampUTC = info["HirevaBuildTimestampUTC"] as? String ?? "Unknown"
        let gitCommitHash = info["HirevaGitCommitHash"] as? String ?? "Unknown"
        let gitBranch = info["HirevaGitBranch"] as? String ?? "Unknown"
        let sourceRoot = info["HirevaSourceRoot"] as? String ?? Self.inferSourceRoot(bundlePath: bundlePath, fileManager: fileManager)
        let expectedBundlePath = info["HirevaExpectedBundlePath"] as? String
            ?? Self.expectedBundlePath(sourceRoot: sourceRoot, bundlePath: bundlePath)
        let standardizedBundlePath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let standardizedExpectedPath = URL(fileURLWithPath: expectedBundlePath).standardizedFileURL.path

        return BuildIdentity(
            bundlePath: bundlePath,
            executablePath: executablePath,
            executableName: executableName,
            infoPlistPath: infoPlistPath,
            bundleIdentifier: bundleIdentifier,
            bundleName: bundleName,
            buildTimestampUTC: buildTimestampUTC,
            gitCommitHash: gitCommitHash,
            gitBranch: gitBranch,
            sourceRoot: sourceRoot,
            expectedBundlePath: expectedBundlePath,
            executableModifiedAt: modificationDate(at: executablePath, fileManager: fileManager),
            infoPlistModifiedAt: modificationDate(at: infoPlistPath, fileManager: fileManager),
            latestSourceModifiedAt: latestSourceModificationDate(sourceRoot: sourceRoot, fileManager: fileManager),
            runningFromDistApp: standardizedBundlePath.hasSuffix(Self.expectedDistBundleSuffix),
            expectedBundlePathMatches: standardizedBundlePath == standardizedExpectedPath,
            bundleIdentifierMatches: bundleIdentifier == Self.expectedBundleIdentifier
        )
    }

    private static func expectedBundlePath(sourceRoot: String, bundlePath: String) -> String {
        if sourceRoot != "Unknown" {
            return URL(fileURLWithPath: sourceRoot)
                .appendingPathComponent("dist/Hireva.app")
                .path
        }
        return bundlePath
    }

    private static func inferSourceRoot(bundlePath: String, fileManager: FileManager) -> String {
        let standardized = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        if let range = standardized.range(of: Self.expectedDistBundleSuffix) {
            return String(standardized[..<range.lowerBound])
        }

        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL
        for _ in 0..<8 {
            let package = current.appendingPathComponent("Package.swift").path
            let sources = current.appendingPathComponent("Sources/Hireva").path
            if fileManager.fileExists(atPath: package), fileManager.fileExists(atPath: sources) {
                return current.path
            }
            current.deleteLastPathComponent()
        }
        return "Unknown"
    }

    private static func modificationDate(at path: String, fileManager: FileManager) -> Date? {
        guard path != "Unknown" else { return nil }
        return try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func latestSourceModificationDate(sourceRoot: String, fileManager: FileManager) -> Date? {
        guard sourceRoot != "Unknown" else { return nil }
        let root = URL(fileURLWithPath: sourceRoot)
        let candidates = [
            root.appendingPathComponent("Package.swift"),
            root.appendingPathComponent("script/build_and_run.sh"),
            root.appendingPathComponent("Sources")
        ]

        var latest: Date?
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let isDirectory = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard let enumerator = fileManager.enumerator(
                    at: candidate,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension == "swift" else { continue }
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
                    if latest == nil || date > latest! {
                        latest = date
                    }
                }
            } else if let date = modificationDate(at: candidate.path, fileManager: fileManager) {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }

    private static func displayDate(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
