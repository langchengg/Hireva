import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Speech

enum MicrophonePermissionState: String, Codable, Hashable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unknown

    var displayName: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .unknown:
            return "Unknown"
        }
    }

    var legacyState: PermissionState {
        switch self {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .unknown:
            return .unknown
        }
    }
}

enum PermissionState: String, Codable {
    case unknown
    case granted
    case denied
    case restricted
    case notDetermined

    var displayName: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        }
    }
}

struct PermissionSnapshot: Hashable {
    var microphone: PermissionState
    var speechRecognition: PermissionState
    var screenRecording: PermissionState
    var systemAudioCapture: PermissionState
}

final class PermissionService {
    func snapshot() -> PermissionSnapshot {
        let screenState: PermissionState = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        return PermissionSnapshot(
            microphone: checkMicrophonePermission().legacyState,
            speechRecognition: speechStatus(),
            screenRecording: screenState,
            systemAudioCapture: screenState
        )
    }

    func refreshPermissions() -> PermissionSnapshot {
        snapshot()
    }

    func checkMicrophonePermission() -> MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    func microphoneStatus() -> PermissionState {
        checkMicrophonePermission().legacyState
    }

    func speechStatus() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    func requestMicrophone() async -> PermissionState {
        await requestMicrophonePermission().legacyState
    }

    func requestMicrophonePermission() async -> MicrophonePermissionState {
        let current = checkMicrophonePermission()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    continuation.resume(returning: .authorized)
                } else {
                    continuation.resume(returning: self.checkMicrophonePermission())
                }
            }
        }
    }

    func requestSpeechRecognition() async -> PermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                let state: PermissionState
                switch status {
                case .authorized:
                    state = .granted
                case .denied:
                    state = .denied
                case .restricted:
                    state = .restricted
                case .notDetermined:
                    state = .notDetermined
                @unknown default:
                    state = .unknown
                }
                continuation.resume(returning: state)
            }
        }
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    func openSystemPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
