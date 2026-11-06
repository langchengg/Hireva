import Foundation
import Speech

/// The actual request-owning recognizer supplies capability. The request flag
/// alone is not honored when that recognizer lacks on-device support.
enum AppleSpeechRequestFactory {
    static func make(
        requiresOnDeviceRecognition: Bool = false,
        supportsOnDeviceRecognition: Bool,
        verificationMode: Bool = HirevaVerificationConfiguration.current != nil ||
            ProcessInfo.processInfo.environment["HIREVA_VERIFICATION_MODE"] == "1",
        allocate: () -> SFSpeechAudioBufferRecognitionRequest = { SFSpeechAudioBufferRecognitionRequest() }
    ) throws -> SFSpeechAudioBufferRecognitionRequest {
        // Verification remains local even through a legacy/default entry point.
        let required = requiresOnDeviceRecognition || verificationMode
        guard !required || supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable("Apple Speech on-device recognition is unavailable for the selected locale.")
        }
        let request = allocate()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = required
        return request
    }
}
