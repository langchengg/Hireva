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
        guard !isShuttingDown else { return }
        let task = systemAudioPermissions.requestSpeechAuthorization { [weak self] _ in
            self?.refreshPermissions()
        }
#if DEBUG
        if let task { speechPermissionTaskDidRegisterForTesting?(task) }
#endif
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

    /// Native probing is an application policy decision. Passive observations
    /// remain available while audio is starting, running or retiring.
    var canRunSystemAudioPermissionProbe: Bool {
        guard !isShuttingDown, captureStartupTask == nil, captureTeardownTask == nil,
              !isListening, !isActionLoading(ActionID.startInterview),
              !isActionLoading(ActionID.manualRecord) else { return false }
        switch manualCaptureState {
        case .waitingForPermission, .recording, .stopping, .transcribing: return false
        default: return true
        }
    }

    func refreshPermissions(automaticallyProbe: Bool = true) {
        // Older already-queued active callbacks also enter this boundary.
        guard !isShuttingDown else { return }
        systemAudioPermissions.refresh(captureMode: settings.audioCaptureMode,
            automaticallyProbe: automaticallyProbe && canRunSystemAudioPermissionProbe)
        microphoneDiagnostics.refreshSelectedInputDevice()
    }

    /// Explicit Diagnostics buttons can probe when Microphone Only is selected.
    /// The controller creates and retains the task; the view creates none.
    func requestScreenSystemAudioProbe() {
        refreshPermissions(automaticallyProbe: false)
        guard canRunSystemAudioPermissionProbe else {
            showError("Stop audio capture before checking system audio permissions.")
            return
        }
        systemAudioPermissions.requestExplicitProbe()
    }

    func refreshScreenSystemAudioProbe() async {
        guard canRunSystemAudioPermissionProbe else { return }
        do { _ = try await systemAudioPermissions.probeNow() }
        catch is CancellationError { return }
        catch { showError(error.localizedDescription) }
    }

    func determineProbeState(result: ScreenSystemAudioPermissionProbeResult) -> ScreenSystemAudioPermissionState {
        SystemAudioPermissionController.state(for: result)
    }
}
