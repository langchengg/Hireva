import Foundation
import Combine
import SwiftUI
import AVFoundation

extension AppState {
    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            refreshPermissions()
            return
        }
        if status == .denied || status == .restricted {
            openMicrophonePrivacySettings()
            refreshPermissions()
            return
        }
        Task {
            _ = await permissionService.requestMicrophonePermission()
            refreshPermissions()
        }
    }

    func requestSpeechPermission() {
        Task {
            _ = await permissionService.requestSpeechRecognition()
            refreshPermissions()
        }
    }

    func requestScreenRecordingPermission() {
        permissionService.requestScreenRecording()
        refreshPermissions()
    }

    func openSystemPrivacySettings() {
        permissionService.openSystemPrivacySettings()
    }

    func openMicrophonePrivacySettings() {
        permissionService.openPrivacySettings()
    }

    func openSpeechRecognitionPrivacySettings() {
        permissionService.openSpeechRecognitionSettings()
        refreshPermissions()
    }

    func openScreenRecordingPrivacySettings() {
        permissionService.openScreenRecordingSettings()
        refreshPermissions()
    }

    func handleReadinessPermissionAction(itemID: String?) {
        switch itemID {
        case "speech":
            switch permissionSnapshot.speechRecognition {
            case .notDetermined, .unknown:
                requestSpeechPermission()
            case .denied, .restricted:
                openSpeechRecognitionPrivacySettings()
            case .granted:
                refreshPermissions()
            }
        case "microphone":
            requestMicrophonePermission()
        case "system-audio":
            openScreenRecordingPrivacySettings()
        default:
            openSystemPrivacySettings()
        }
    }

    func refreshPermissions() {
        microphonePermissionState = permissionService.checkMicrophonePermission()
        permissionSnapshot = permissionService.refreshPermissions()
        microphoneDiagnostics.refreshSelectedInputDevice()
        
        Task {
            await refreshScreenSystemAudioProbe()
        }
    }
    
    func refreshScreenSystemAudioProbe() async {
        let result = await ScreenSystemAudioPermissionProbe.shared.probe()
        let state = determineProbeState(result: result)
        
        await MainActor.run {
            self.systemAudioProbeResult = result
            self.systemAudioPermissionState = state
            
            if state == .granted {
                self.permissionSnapshot.screenRecording = .granted
                self.permissionSnapshot.systemAudioCapture = .granted
            } else {
                self.permissionSnapshot.screenRecording = .denied
                self.permissionSnapshot.systemAudioCapture = .denied
            }
        }
    }
    
    func determineProbeState(result: ScreenSystemAudioPermissionProbeResult) -> ScreenSystemAudioPermissionState {
        if result.shareableContentProbeSucceeded {
            if result.likelyIdentityMismatch {
                return .identityMismatch
            }
            if !result.streamAudioProbeSucceeded {
                return .streamAudioProbeFailed(result.errorDescription ?? "Stream audio timeout")
            }
            return .granted
        } else {
            if result.preflightGranted {
                if result.likelyIdentityMismatch {
                    return .identityMismatch
                }
                return .restartLikely
            } else {
                if result.likelyIdentityMismatch {
                    return .identityMismatch
                }
                return .permissionMissing
            }
        }
    }
}
