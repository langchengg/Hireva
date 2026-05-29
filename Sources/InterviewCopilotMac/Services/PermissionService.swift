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

enum ScreenSystemAudioPermissionState: Equatable, Hashable {
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

struct PermissionSnapshot: Hashable {
    var microphone: PermissionState
    var speechRecognition: PermissionState
    var screenRecording: PermissionState
    var systemAudioCapture: PermissionState
}

class PermissionService {
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
        if isRunningUnderTestOrAutomation() {
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
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    print("[Permission] Microphone request returned granted = \(granted)")
                    if granted {
                        continuation.resume(returning: .authorized)
                    } else {
                        continuation.resume(returning: self.checkMicrophonePermission())
                    }
                }
            }
        case .unknown:
            return .unknown
        }
    }

    func requestSpeechRecognition() async -> PermissionState {
        if isRunningUnderTestOrAutomation() {
            return .granted
        }
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

    /// Fetch code signing status asynchronously. Call from a Task or .task modifier.
    /// Do NOT call from the main thread synchronously — it shells out to /usr/bin/codesign.
    func fetchCodeSigningStatus() async -> String {
        let bundlePath = Bundle.main.bundlePath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["-dvvvv", bundlePath]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                let reqProcess = Process()
                reqProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                reqProcess.arguments = ["-d", "-r-", bundlePath]
                let reqPipe = Pipe()
                reqProcess.standardOutput = reqPipe
                reqProcess.standardError = Pipe()
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    
                    try? reqProcess.run()
                    reqProcess.waitUntilExit()
                    let reqData = reqPipe.fileHandleForReading.readDataToEndOfFile()
                    let reqOutput = String(data: reqData, encoding: .utf8) ?? ""
                    
                    let lines = output.components(separatedBy: "\n")
                    var relevant = lines.filter {
                        $0.hasPrefix("Identifier=") ||
                        $0.hasPrefix("Authority=") ||
                        $0.hasPrefix("TeamIdentifier=") ||
                        $0.hasPrefix("Signature=") ||
                        $0.contains("code signature")
                    }
                    
                    if !reqOutput.isEmpty {
                        relevant.append("Designated Requirement: \(reqOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    
                    if relevant.isEmpty {
                        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: trimmed.isEmpty ? "Not signed" : String(trimmed.prefix(200)))
                    } else {
                        continuation.resume(returning: relevant.joined(separator: "\n"))
                    }
                } catch {
                    continuation.resume(returning: "Could not check: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Whether Screen Recording permission requires an app restart.
    /// macOS caches the screen capture access check at launch. If the user
    /// grants it in System Settings while the app is running, CGPreflight
    /// still returns false until the app is relaunched.
    var screenRecordingMayNeedRestart: Bool {
        !CGPreflightScreenCaptureAccess()
    }
}
