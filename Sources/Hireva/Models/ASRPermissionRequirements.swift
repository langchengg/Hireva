import Foundation

struct ASRPermissionRequirements: Equatable {
    let microphone: Bool
    let speechRecognition: Bool
    let screenAndSystemAudio: Bool

    init(provider: ASRProviderID, captureMode: AudioCaptureMode) {
        microphone = captureMode == .microphoneOnly || captureMode == .microphoneAndSystem
        screenAndSystemAudio = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem
        speechRecognition = provider == .appleSpeech
    }
}

struct ASRProviderCapabilities: Equatable {
    let supportsPartialTranscripts: Bool

    static func forProvider(_ provider: ASRProviderID) -> ASRProviderCapabilities {
        switch provider {
        case .appleSpeech:
            return ASRProviderCapabilities(supportsPartialTranscripts: true)
        case .localWhisper, .localParakeet:
            return ASRProviderCapabilities(supportsPartialTranscripts: false)
        }
    }
}
