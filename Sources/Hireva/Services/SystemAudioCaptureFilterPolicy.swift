import Foundation

enum SystemAudioCaptureFilterSelection: Equatable {
    case allDisplay
    case application(index: Int)
}

/// The same selection feeds live capture and its permission probe. SDK objects
/// remain at the capture boundary; tests can supply only process identities.
enum SystemAudioCaptureFilterPolicy {
    static func validateNativeCapture(verification: HirevaVerificationConfiguration?) throws {
        guard let verification else { return }
        guard let processID = verification.controlledAudioProcessID, processID > 1,
              let bundle = verification.controlledAudioBundleIdentifier,
              !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SystemAudioCaptureFilterError.missingControlledApplication
        }
    }

    static func select(
        verification: HirevaVerificationConfiguration?,
        applications: [(processID: Int32, bundleIdentifier: String)]
    ) throws -> SystemAudioCaptureFilterSelection {
        try validateNativeCapture(verification: verification)
        guard let verification else { return .allDisplay }
        guard let index = applications.firstIndex(where: {
            $0.processID == verification.controlledAudioProcessID &&
            $0.bundleIdentifier == verification.controlledAudioBundleIdentifier
        }) else {
            throw SystemAudioCaptureFilterError.controlledApplicationUnavailable
        }
        return .application(index: index)
    }
}

enum SystemAudioCaptureFilterError: LocalizedError {
    case missingControlledApplication
    case controlledApplicationUnavailable

    var errorDescription: String? {
        switch self {
        case .missingControlledApplication:
            "Verification system audio requires an explicitly owned player process and bundle identifier."
        case .controlledApplicationUnavailable:
            "The owned verification player was not found with the configured process and bundle identifier."
        }
    }
}
