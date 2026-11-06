import CoreFoundation
import Foundation
import Darwin

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
    let controlledAudioProcessID: Int32?
    let controlledAudioBundleIdentifier: String?
    var retainNativePCM = false
    var nativePCMOutputDirectory: URL? = nil
    var nativePCMOutputDevice: Int32? = nil
    var nativePCMOutputInode: UInt64? = nil

    // Verification has a fixed native-ASR privacy boundary. Scenario input
    // cannot relax it, and older synthetic scenarios inherit this requirement.
    var requiresLocalASR: Bool { true }

    static func isRequested(environment: [String: String]) -> Bool {
        ["HIREVA_VERIFICATION_MODE", "HIREVA_VERIFICATION_SCENARIO_PATH",
         "HIREVA_VERIFICATION_OUTPUT_ROOT", "HIREVA_VERIFICATION_APP_SUPPORT_DIR",
         "HIREVA_VERIFICATION_MODEL_ROOT"].contains { environment[$0] != nil }
    }

    static func load(
        environment: [String: String],
        bundleSourceRoot: String?,
        fileManager: FileManager = .default,
        productionHomeDirectory: URL? = nil
    ) -> HirevaVerificationConfiguration? {
        guard environment["HIREVA_VERIFICATION_MODE"] == "1",
              let scenarioPath = nonempty(environment["HIREVA_VERIFICATION_SCENARIO_PATH"]),
              let outputPath = nonempty(environment["HIREVA_VERIFICATION_OUTPUT_ROOT"]),
              let appSupportPath = nonempty(environment["HIREVA_VERIFICATION_APP_SUPPORT_DIR"]),
              [scenarioPath, outputPath, appSupportPath].allSatisfy({ $0.hasPrefix("/") }) else {
            return nil
        }

        let scenarioURL = URL(fileURLWithPath: scenarioPath).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let applicationSupportDirectory = URL(fileURLWithPath: appSupportPath, isDirectory: true).standardizedFileURL
        guard scenarioURL.path.hasPrefix("/"),
              outputDirectory.path.hasPrefix("/"),
              applicationSupportDirectory.path.hasPrefix("/"),
              (try? fileManager.attributesOfItem(atPath: scenarioURL.path)[.type]) as? FileAttributeType == .typeRegular,
              directoryExists(outputDirectory, fileManager: fileManager),
              directoryExists(applicationSupportDirectory, fileManager: fileManager) else { return nil }

        // Resolve aliases before containment checks, but retain the caller's
        // spelling for existing diagnostics. Never inspect production contents.
        let home = productionHomeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let protected = [
            library.appendingPathComponent("Application Support/\(HirevaProductIdentity.applicationSupportDirectoryName)"),
            library.appendingPathComponent("Application Support/\(LegacyHirevaIdentifiers.applicationSupportDirectoryName)"),
            library.appendingPathComponent("Preferences"), library.appendingPathComponent("Caches")
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL }
        let verifiedOutputDirectory = outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        let writable = [outputDirectory, applicationSupportDirectory]
        guard writable.allSatisfy({ directory in
            let actual = directory.resolvingSymlinksInPath().standardizedFileURL
            return protected.allSatisfy { !isContained(actual, in: $0) && !isContained($0, in: actual) }
        }), protected.allSatisfy({ !isContained(scenarioURL.resolvingSymlinksInPath(), in: $0) }) else {
            return nil
        }

        if let sourceRoot = bundleSourceRoot, !sourceRoot.isEmpty {
            let sourceURL = URL(fileURLWithPath: sourceRoot, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard writable.allSatisfy({
                let actual = $0.resolvingSymlinksInPath()
                return !isContained(actual, in: sourceURL) && !isContained(sourceURL, in: actual)
            }) else { return nil }
        }
        guard writable.allSatisfy({ isolatedWritableTree($0, fileManager: fileManager) }),
              let data = try? Data(contentsOf: scenarioURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["synthetic"] as? Bool == true,
              let runID = object["runID"] as? String,
              runID.range(of: #"^[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) != nil else {
            return nil
        }

        let modelPath = nonempty(environment["HIREVA_VERIFICATION_MODEL_ROOT"])
        if let modelPath, !modelPath.hasPrefix("/") { return nil }
        let modelRoot = modelPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        if let modelRoot {
            // Model health checks can migrate legacy layouts. An explicit model
            // root is therefore writable, even when this run only requests ASR.
            let actual = modelRoot.resolvingSymlinksInPath().standardizedFileURL
            guard directoryExists(modelRoot, fileManager: fileManager),
                  protected.allSatisfy({ !isContained(actual, in: $0) && !isContained($0, in: actual) }),
                  isolatedWritableTree(modelRoot, fileManager: fileManager) else { return nil }
            if let sourceRoot = bundleSourceRoot, !sourceRoot.isEmpty {
                let sourceURL = URL(fileURLWithPath: sourceRoot).resolvingSymlinksInPath()
                guard !isContained(actual, in: sourceURL), !isContained(sourceURL, in: actual) else { return nil }
            }
        }

        let controlledAudioProcessID: Int32?
        let controlledAudioBundleIdentifier: String?
        if object.keys.contains("controlledAudioProcessID") || object.keys.contains("controlledAudioBundleIdentifier") {
            // Absence preserves legacy synthetic fixtures. A present malformed
            // owner must not silently become an unrestricted legacy request.
            guard let number = object["controlledAudioProcessID"] as? NSNumber,
                  let processID = Int32(exactly: number.doubleValue), processID > 1,
                  let bundle = nonempty(object["controlledAudioBundleIdentifier"] as? String) else {
                return nil
            }
            controlledAudioProcessID = processID
            controlledAudioBundleIdentifier = bundle
        } else {
            controlledAudioProcessID = nil
            controlledAudioBundleIdentifier = nil
        }

        var retainNativePCM = false
        if let value = object["retainNativePCM"] {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            retainNativePCM = number.boolValue
            guard !retainNativePCM || (controlledAudioProcessID != nil && controlledAudioBundleIdentifier != nil) else { return nil }
        }
        var outputIdentity = stat()
        if retainNativePCM {
            guard outputDirectory.resolvingSymlinksInPath().standardizedFileURL == verifiedOutputDirectory,
                  lstat(verifiedOutputDirectory.path, &outputIdentity) == 0,
                  outputIdentity.st_mode & S_IFMT == S_IFDIR else { return nil }
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
            userDefaultsSuiteName: "com.langcheng.Hireva.verification.\(safeRunID)",
            controlledAudioProcessID: controlledAudioProcessID,
            controlledAudioBundleIdentifier: controlledAudioBundleIdentifier,
            retainNativePCM: retainNativePCM,
            nativePCMOutputDirectory: retainNativePCM ? verifiedOutputDirectory : nil,
            nativePCMOutputDevice: retainNativePCM ? outputIdentity.st_dev : nil,
            nativePCMOutputInode: retainNativePCM ? outputIdentity.st_ino : nil
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

    private static func isolatedWritableTree(_ directory: URL, fileManager: FileManager) -> Bool {
        // SQLite/WAL, material and cache children must not redirect writes into
        // another run or production. Metadata only; no child file is opened.
        var enumerationFailed = false
        guard (try? fileManager.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              let entries = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in enumerationFailed = true; return false }) else { return false }
        for case let child as URL in entries {
            guard let attributes = try? fileManager.attributesOfItem(atPath: child.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory || type == .typeRegular else { return false }
            if type == .typeRegular {
                guard let links = attributes[.referenceCount] as? NSNumber, links.intValue == 1 else { return false }
            }
        }
        return !enumerationFailed
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }
}

// Existing-authorizations-only verification never admits a new TCC request.
// A missing configuration is not production when verification was requested
// or this is a verification-only bundle; it remains fail closed.
enum VerificationPermissionAdmission: Equatable, Sendable {
    case production
    case existingAuthorizationOnly
    case invalidVerification

    static var current: Self {
        resolve(verification: HirevaVerificationConfiguration.current,
            environment: ProcessInfo.processInfo.environment,
            verificationOnlyBundle: Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool == true)
    }

    static func resolve(verification: HirevaVerificationConfiguration?,
        environment: [String: String], verificationOnlyBundle: Bool) -> Self {
        if verification != nil { return .existingAuthorizationOnly }
        if HirevaVerificationConfiguration.isRequested(environment: environment) || verificationOnlyBundle {
            return .invalidVerification
        }
        return .production
    }

    var mayRequestAuthorization: Bool { self == .production }

    @MainActor
    func validateNativeScreenCapture(preflightAccess: @MainActor () -> Bool) throws {
        switch self {
        case .production: return
        case .invalidVerification:
            throw VerificationPermissionAdmissionError.invalidConfiguration
        case .existingAuthorizationOnly:
            guard preflightAccess() else {
                throw VerificationPermissionAdmissionError.screenAuthorizationMissing
            }
        }
    }
}

enum VerificationPermissionAdmissionError: LocalizedError {
    case invalidConfiguration
    case screenAuthorizationMissing

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Invalid verification configuration; native permission admission was denied."
        case .screenAuthorizationMissing:
            "Verification requires existing Screen & System Audio Recording authorization; no permission request was issued."
        }
    }
}
