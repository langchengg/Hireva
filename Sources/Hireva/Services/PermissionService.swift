import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Speech
import os

enum MicrophonePermissionState: String, Codable, Hashable, Sendable {
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

enum PermissionState: String, Codable, Sendable {
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

enum ScreenSystemAudioPermissionState: Equatable, Hashable, Sendable {
    case granted
    case permissionMissing
    case restartLikely
    case identityMismatch
    case shareableContentProbeFailed(String)
    case streamAudioProbeFailed(String)
    
    var displayName: String {
        switch self {
        case .granted: return "Granted"
        case .permissionMissing: return "Permission Missing"
        case .restartLikely: return "Restart Required"
        case .identityMismatch: return "Identity Mismatch"
        case .shareableContentProbeFailed(let error): return "Shareable Content Probe Failed: \(error)"
        case .streamAudioProbeFailed(let error): return "Stream Audio Probe Failed: \(error)"
        }
    }
}

struct PermissionSnapshot: Hashable, Sendable {
    var microphone: PermissionState
    var speechRecognition: PermissionState
    var screenRecording: PermissionState
    var systemAudioCapture: PermissionState
}

@MainActor
class PermissionService {
    private let codeSigningInvocation: CodeSigningDiagnosticsInvocation
    typealias SpeechAuthorizationRequest = @Sendable (@escaping @Sendable (PermissionState) -> Void) -> Void
    private let speechAuthorizationRequest: SpeechAuthorizationRequest?
    typealias MicrophoneAuthorizationRequest = @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    private let microphoneAuthorizationRequest: MicrophoneAuthorizationRequest?
    private let screenCaptureAuthorizationRequest: (@MainActor () -> Void)?
    private let permissionAdmission: VerificationPermissionAdmission

    init(codeSigningInvocation: CodeSigningDiagnosticsInvocation? = nil,
        speechAuthorizationRequest: SpeechAuthorizationRequest? = nil,
        permissionAdmission: VerificationPermissionAdmission = .current,
        microphoneAuthorizationRequest: MicrophoneAuthorizationRequest? = nil,
        screenCaptureAuthorizationRequest: (@MainActor () -> Void)? = nil) {
        self.codeSigningInvocation = codeSigningInvocation ?? CodeSigningDiagnosticsInvocation()
        self.speechAuthorizationRequest = speechAuthorizationRequest
        self.permissionAdmission = permissionAdmission
        self.microphoneAuthorizationRequest = microphoneAuthorizationRequest
        self.screenCaptureAuthorizationRequest = screenCaptureAuthorizationRequest
    }

    func snapshot() -> PermissionSnapshot {
        if isRunningUnderTestOrAutomation() {
            return PermissionSnapshot(
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                systemAudioCapture: .granted
            )
        }
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
        if isRunningUnderTestOrAutomation() {
            return .authorized
        }
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
        if isRunningUnderTestOrAutomation() {
            return .granted
        }
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
        guard permissionAdmission.mayRequestAuthorization else { return checkMicrophonePermission() }
        if microphoneAuthorizationRequest == nil, isRunningUnderTestOrAutomation() {
            return .authorized
        }
        let current = checkMicrophonePermission()
        switch current {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            print("[Permission] Microphone request bypassed (already \(current.rawValue))")
            return current
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                let completion: @Sendable (Bool) -> Void = { granted in
                    print("[Permission] Microphone request returned granted = \(granted)")
                    continuation.resume(returning: granted)
                }
                if let microphoneAuthorizationRequest {
                    microphoneAuthorizationRequest(completion)
                } else {
                    AVCaptureDevice.requestAccess(for: .audio) { completion($0) }
                }
            }
            return granted ? .authorized : checkMicrophonePermission()
        case .unknown:
            return .unknown
        }
    }

    func requestSpeechRecognition() async -> PermissionState {
        guard !Task.isCancelled else { return .unknown }
        guard permissionAdmission.mayRequestAuthorization else { return speechStatus() }
        if speechAuthorizationRequest == nil, isRunningUnderTestOrAutomation() {
            return .granted
        }
        let waiter = SpeechAuthorizationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                requestSpeechAuthorization { waiter.resolve($0) }
            }
        } onCancel: {
            // Swift wait cancellation does not revoke TCC or close the SDK
            // dialog. An already admitted request can still call back later.
            waiter.resolve(.unknown)
        }
    }

    // Tests replace only the SDK invocation. The real continuation bridge,
    // mapping and callers remain in this service; no TCC request is needed.
    private func requestSpeechAuthorization(_ completion: @escaping @Sendable (PermissionState) -> Void) {
        if let speechAuthorizationRequest {
            speechAuthorizationRequest(completion)
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            let state: PermissionState
            switch status {
            case .authorized: state = .granted
            case .denied: state = .denied
            case .restricted: state = .restricted
            case .notDetermined: state = .notDetermined
            @unknown default: state = .unknown
            }
            completion(state)
        }
    }

    func requestScreenRecording() {
        guard permissionAdmission.mayRequestAuthorization else { return }
        if let screenCaptureAuthorizationRequest {
            screenCaptureAuthorizationRequest()
            return
        }
        if isRunningUnderTestOrAutomation() {
            print("[Permission] requestScreenRecording skipped (running under test/automation)")
            return
        }
        _ = CGRequestScreenCaptureAccess()
    }

    func openSystemPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openSpeechRecognitionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        NSWorkspace.shared.open(url)
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - App Identity Diagnostics

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown (no Info.plist)"
    }

    var bundlePath: String {
        Bundle.main.bundlePath
    }

    var processPath: String {
        ProcessInfo.processInfo.arguments.first ?? "Unknown"
    }

    var isRunningFromAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// The diagnostic invocation owns both read-only codesign queries.
    func fetchCodeSigningStatus() async -> String {
        await codeSigningInvocation.run(bundlePath: Bundle.main.bundlePath)
    }

    func shutdownCodeSigningDiagnostics() async -> Bool {
        await codeSigningInvocation.shutdown()
    }

    /// Whether Screen Recording permission requires an app restart.
    /// macOS caches the screen capture access check at launch. If the user
    /// grants it in System Settings while the app is running, CGPreflight
    /// still returns false until the app is relaunched.
    var screenRecordingMayNeedRestart: Bool {
        !CGPreflightScreenCaptureAccess()
    }
}

/// One request owns one continuation. Native callbacks may use any executor;
/// resume happens outside the lock, and late or duplicate callbacks are inert.
private final class SpeechAuthorizationWaiter: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<PermissionState, Never>?
        var result: PermissionState?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// True admits this request's one SDK invocation. Cancellation preceding
    /// admission returns false; cancellation afterward cannot close its dialog.
    func install(_ continuation: CheckedContinuation<PermissionState, Never>) -> Bool {
        let result = state.withLock { state -> PermissionState? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(returning: result)
            return false
        }
        return true
    }

    func resolve(_ result: PermissionState) {
        let continuation = state.withLock { state -> CheckedContinuation<PermissionState, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}
