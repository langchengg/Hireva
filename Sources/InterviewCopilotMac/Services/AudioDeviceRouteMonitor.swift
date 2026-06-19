import AVFoundation
import AppKit
import Combine
import Foundation

/// Service that monitors audio hardware changes, Bluetooth connections, and engine configuration changes on macOS.
@MainActor
public final class AudioDeviceRouteMonitor: ObservableObject {
    public static let shared = AudioDeviceRouteMonitor()

    @Published public private(set) var currentInputDeviceName: String = "Default Input"
    @Published public private(set) var currentInputDeviceID: String = "default"
    @Published public private(set) var lastRouteChangeAt: Date = Date()
    @Published public private(set) var routeChangeReason: String = "Initialized"
    @Published public private(set) var isRecoveringAudioRoute: Bool = false

    private var observers: [NSObjectProtocol] = []

    private init() {
        setupObservers()
        refreshInputDevice()
    }

    deinit {
        let activeObservers = observers
        observers.removeAll()
        Task { @MainActor in
            for observer in activeObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    /// Sets up notifications for configuration change, capture connection, and app focus fallback.
    private func setupObservers() {
        // Swift tests create many AppState instances while sharing the process-wide
        // AudioEngineManager. Real hardware notifications can otherwise rebuild a
        // test-owned tap concurrently and make AVFAudio abort before Swift can catch
        // an error. Tests exercise route handling explicitly; production keeps all
        // external observers enabled.
        guard !isRunningUnderTestOrAutomation() else { return }

        // 1. AVAudioEngine configuration change
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: AudioEngineManager.shared.engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleRouteChange(reason: "AVAudioEngine Configuration Changed")
            }
        }
        observers.append(configObserver)

        // 2. AVCaptureDevice connection
        let connObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Device"
                self?.handleRouteChange(reason: "Audio device connected: \(name)")
            }
        }
        observers.append(connObserver)

        // 3. AVCaptureDevice disconnection
        let disconnObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Device"
                self?.handleRouteChange(reason: "Audio device disconnected: \(name)")
            }
        }
        observers.append(disconnObserver)

        // 4. App focus activation fallback
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInputDevice()
            }
        }
        observers.append(activeObserver)
    }

    /// Triggers dynamic device verification and tells AudioEngineManager to perform robust recovery.
    public func handleRouteChange(reason: String) {
        lastRouteChangeAt = Date()
        routeChangeReason = reason
        isRecoveringAudioRoute = true

        refreshInputDevice()

        // Tell AudioEngineManager to handle route/config change dynamically
        AudioEngineManager.shared.restartForRouteChange(reason: reason)

        // Reset recovery flag after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.isRecoveringAudioRoute = false
        }
    }

    /// Queries CoreAudio capture device attributes to update local published properties.
    public func refreshInputDevice() {
        if let defaultAudioDev = AVCaptureDevice.default(for: .audio) {
            currentInputDeviceName = defaultAudioDev.localizedName
            currentInputDeviceID = defaultAudioDev.uniqueID
        } else {
            currentInputDeviceName = "Default Input"
            currentInputDeviceID = "default"
        }
    }
}
