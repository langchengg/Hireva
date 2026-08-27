import Foundation
import Combine
import SwiftUI
import AVFoundation

enum SystemAudioPermissionVerificationOutcome: Sendable {
    case result(ScreenSystemAudioPermissionProbeResult)
    case timedOut
    case cancelled
}

private actor SystemAudioPermissionVerificationRace {
    private var outcome: SystemAudioPermissionVerificationOutcome?
    private var waiter: CheckedContinuation<SystemAudioPermissionVerificationOutcome, Never>?

    func wait() async -> SystemAudioPermissionVerificationOutcome {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func resolve(_ outcome: SystemAudioPermissionVerificationOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(returning: outcome)
        waiter = nil
    }
}

private func runSystemAudioPermissionVerification(
    probe: any ScreenSystemAudioPermissionProbing,
    timeout: Duration
) async -> SystemAudioPermissionVerificationOutcome {
    let race = SystemAudioPermissionVerificationRace()
    let probeTask = Task {
        let result = await probe.probe()
        await race.resolve(.result(result))
    }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: timeout)
            await race.resolve(.timedOut)
        } catch {
            // Losing the race cancels this task. The winning outcome has
            // already been recorded by the actor.
        }
    }

    return await withTaskCancellationHandler {
        let outcome = await race.wait()
        probeTask.cancel()
        timeoutTask.cancel()
        return outcome
    } onCancel: {
        probeTask.cancel()
        timeoutTask.cancel()
        Task {
            await race.resolve(.cancelled)
        }
    }
}

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

        if permissionSnapshot.screenRecording == .granted {
            if systemAudioProbeResult == nil {
                systemAudioPermissionState = .granted
            } else if systemAudioPermissionState != .granted {
                // Preserve the most recent explicit verification failure. A
                // passive preflight cannot prove that SCShareableContent and
                // SCStream are operational.
                permissionSnapshot.systemAudioCapture = .denied
            }
        } else {
            cancelSystemAudioPermissionVerification()
            systemAudioProbeResult = nil
            systemAudioPermissionState = .permissionMissing
        }
    }

    @discardableResult
    func verifySystemAudioPermission() -> Task<Void, Never> {
        if let systemAudioPermissionVerificationTask {
            return systemAudioPermissionVerificationTask
        }

        systemAudioPermissionVerificationGeneration &+= 1
        let generation = systemAudioPermissionVerificationGeneration
        let probe = screenSystemAudioPermissionProbe
        let timeout = systemAudioPermissionVerificationTimeout
        isVerifyingSystemAudioPermission = true

        let task = Task { [weak self] in
            let outcome = await runSystemAudioPermissionVerification(
                probe: probe,
                timeout: timeout
            )
            self?.finishSystemAudioPermissionVerification(
                outcome,
                generation: generation
            )
        }
        systemAudioPermissionVerificationTask = task
        return task
    }

    func cancelSystemAudioPermissionVerification() {
        guard systemAudioPermissionVerificationTask != nil else { return }
        systemAudioPermissionVerificationGeneration &+= 1
        systemAudioPermissionVerificationTask?.cancel()
        systemAudioPermissionVerificationTask = nil
        isVerifyingSystemAudioPermission = false
    }

    func finishSystemAudioPermissionVerification(
        _ outcome: SystemAudioPermissionVerificationOutcome,
        generation: UInt64
    ) {
        guard generation == systemAudioPermissionVerificationGeneration else {
            return
        }

        systemAudioPermissionVerificationTask = nil
        isVerifyingSystemAudioPermission = false

        switch outcome {
        case .result(let result):
            let state = determineProbeState(result: result)
            systemAudioProbeResult = result
            systemAudioPermissionState = state
            permissionSnapshot.screenRecording =
                result.preflightGranted || result.shareableContentProbeSucceeded ? .granted : .denied
            permissionSnapshot.systemAudioCapture = state == .granted ? .granted : .denied
        case .timedOut:
            let message = "System audio verification timed out."
            systemAudioProbeResult = ScreenSystemAudioPermissionProbeResult(
                preflightGranted: permissionSnapshot.screenRecording == .granted,
                shareableContentProbeSucceeded: false,
                streamAudioProbeSucceeded: false,
                errorDescription: message,
                likelyIdentityMismatch: false
            )
            systemAudioPermissionState = .shareableContentProbeFailed(message)
            permissionSnapshot.systemAudioCapture = .denied
        case .cancelled:
            break
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
