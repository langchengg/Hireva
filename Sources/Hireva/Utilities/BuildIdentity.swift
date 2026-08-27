import Foundation
import CoreFoundation

struct BuildIdentity: Hashable {
    static let expectedBundleIdentifier = HirevaProductIdentity.bundleIdentifier

    let bundlePath: String
    let executablePath: String
    let executableName: String
    let infoPlistPath: String
    let bundleIdentifier: String
    let bundleName: String
    let buildTimestampUTC: String
    let gitCommitHash: String
    let gitBranch: String
    let gitTreeState: String
    let buildConfiguration: String
    let runtimeMode: String
    let signingMode: String
    let distributionBuild: Bool
    let sourceRoot: String
    let expectedBundlePath: String
    let hasExplicitDevelopmentPaths: Bool
    let executableModifiedAt: Date?
    let infoPlistModifiedAt: Date?
    let latestSourceModifiedAt: Date?
    let expectedBundlePathMatches: Bool
    let bundleIdentifierMatches: Bool
    let metadataWarning: String?

    var isReleaseBuild: Bool {
        buildConfiguration == "release"
    }

    var hasValidReleaseMetadata: Bool {
        isReleaseBuild && identityWarning == nil
    }

    var hasIdentityWarning: Bool {
        identityWarning != nil
    }

    var identityWarning: String? {
        if !bundleIdentifierMatches {
            return "This app bundle has bundle id \(bundleIdentifier), expected \(Self.expectedBundleIdentifier)."
        }
        if let metadataWarning {
            return metadataWarning
        }
        if hasExplicitDevelopmentPaths, !expectedBundlePathMatches {
            return "This development build is running from an unexpected app bundle path."
        }
        if let latestSourceModifiedAt,
           let executableModifiedAt,
           latestSourceModifiedAt.timeIntervalSince(executableModifiedAt) > 5 {
            return "This app bundle may be stale. Rebuild and relaunch from dist/\(HirevaProductIdentity.productName).app."
        }
        if !isReleaseBuild {
            return "This is a debug build. Use a release build for RC validation."
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
        let bundlePath = bundle.bundlePath
        let executablePath = bundle.executableURL?.path ?? "Unknown"
        let executableName = bundle.executableURL?.lastPathComponent ?? "Unknown"
        let infoPlistPath = bundle.url(forResource: "Info", withExtension: "plist")?.path
            ?? URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist").path

        return evaluate(
            bundlePath: bundlePath,
            executablePath: executablePath,
            executableName: executableName,
            infoPlistPath: infoPlistPath,
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            info: bundle.infoDictionary ?? [:],
            fileManager: fileManager
        )
    }

    static func evaluate(
        bundlePath: String,
        executablePath: String,
        executableName: String = HirevaProductIdentity.productName,
        infoPlistPath: String = "Unknown",
        bundleIdentifier: String = HirevaProductIdentity.bundleIdentifier,
        info: [String: Any],
        fileManager: FileManager = .default
    ) -> BuildIdentity {
        let bundleName = info["CFBundleName"] as? String ?? "Unknown"
        let buildTimestampUTC = info["HirevaBuildTimestampUTC"] as? String ?? "Unknown"
        let gitCommitHash = info["HirevaGitCommitHash"] as? String ?? "Unknown"
        let gitBranch = info["HirevaGitBranch"] as? String ?? "Unknown"
        let gitTreeState = info["HirevaGitTreeState"] as? String ?? "Unknown"
        let buildConfiguration = info["HirevaBuildConfiguration"] as? String ?? "Unknown"
        let runtimeMode = info["HirevaRuntimeMode"] as? String ?? "Unknown"
        let signingMode = info["HirevaSigningMode"] as? String ?? "Unknown"
        let distributionMetadata = strictBoolean(info["HirevaDistributionBuild"])
        let distributionBuild = distributionMetadata ?? false

        let hasSourceRootKey = info.keys.contains("HirevaSourceRoot")
        let hasExpectedBundlePathKey = info.keys.contains("HirevaExpectedBundlePath")
        let hasExplicitDevelopmentPaths = hasSourceRootKey || hasExpectedBundlePathKey
        let explicitSourceRoot = info["HirevaSourceRoot"] as? String
        let explicitExpectedBundlePath = info["HirevaExpectedBundlePath"] as? String
        let sourceRoot = explicitSourceRoot ?? "Unknown"
        let expectedBundlePath = explicitExpectedBundlePath ?? "Unknown"

        let developmentPathContractValid = hasExplicitDevelopmentPaths
            && buildConfiguration == "debug"
            && signingMode == "development"
            && isAbsoluteNonemptyPath(explicitSourceRoot)
            && isAbsoluteNonemptyPath(explicitExpectedBundlePath)

        let metadataWarning: String?
        if buildConfiguration != "debug" && buildConfiguration != "release" {
            metadataWarning = "This app bundle has missing or invalid build configuration metadata."
        } else if signingMode != "adhoc" && signingMode != "development" && signingMode != "developer-id" {
            metadataWarning = "This app bundle has missing or invalid signing mode metadata."
        } else if distributionMetadata == nil {
            metadataWarning = "This app bundle has missing or invalid distribution metadata."
        } else if distributionBuild != (signingMode == "developer-id") {
            metadataWarning = "This app bundle has inconsistent signing and distribution metadata."
        } else if hasExplicitDevelopmentPaths,
                  buildConfiguration != "debug" || signingMode != "development" {
            metadataWarning = "Development path metadata is valid only for debug development-signed builds."
        } else if hasExplicitDevelopmentPaths, !developmentPathContractValid {
            metadataWarning = "Development path metadata must contain non-empty absolute source and bundle paths."
        } else if !isValidBuildTimestamp(buildTimestampUTC) {
            metadataWarning = "This app bundle has missing or invalid build timestamp metadata."
        } else if !isValidGitCommit(gitCommitHash) {
            metadataWarning = "This app bundle has missing or invalid Git commit metadata."
        } else if runtimeMode != "bundled_native" {
            metadataWarning = "This app bundle has missing or invalid runtime mode metadata."
        } else if gitTreeState != "clean" && gitTreeState != "dirty" {
            metadataWarning = "This app bundle has missing or invalid Git tree state metadata."
        } else if signingMode == "developer-id", gitTreeState != "clean" {
            metadataWarning = "Developer ID release metadata requires a clean Git tree."
        } else {
            metadataWarning = nil
        }

        let mayInspectDevelopmentSource = developmentPathContractValid && metadataWarning == nil
        let expectedBundlePathMatches: Bool
        if !hasExplicitDevelopmentPaths {
            expectedBundlePathMatches = true
        } else if mayInspectDevelopmentSource, let explicitExpectedBundlePath {
            let standardizedBundlePath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
            let standardizedExpectedPath = URL(fileURLWithPath: explicitExpectedBundlePath).standardizedFileURL.path
            expectedBundlePathMatches = standardizedBundlePath == standardizedExpectedPath
        } else {
            expectedBundlePathMatches = false
        }

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
            gitTreeState: gitTreeState,
            buildConfiguration: buildConfiguration,
            runtimeMode: runtimeMode,
            signingMode: signingMode,
            distributionBuild: distributionBuild,
            sourceRoot: sourceRoot,
            expectedBundlePath: expectedBundlePath,
            hasExplicitDevelopmentPaths: hasExplicitDevelopmentPaths,
            executableModifiedAt: modificationDate(at: executablePath, fileManager: fileManager),
            infoPlistModifiedAt: modificationDate(at: infoPlistPath, fileManager: fileManager),
            latestSourceModifiedAt: mayInspectDevelopmentSource
                ? latestSourceModificationDate(sourceRoot: sourceRoot, fileManager: fileManager)
                : nil,
            expectedBundlePathMatches: expectedBundlePathMatches,
            bundleIdentifierMatches: bundleIdentifier == Self.expectedBundleIdentifier,
            metadataWarning: metadataWarning
        )
    }

    private static func isAbsoluteNonemptyPath(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return (value as NSString).isAbsolutePath
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        let coreFoundationValue = value as CFTypeRef
        guard CFGetTypeID(coreFoundationValue) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    private static func isValidBuildTimestamp(_ value: String) -> Bool {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#,
            options: .regularExpression
        ) != nil else { return false }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }

    private static func isValidGitCommit(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
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
