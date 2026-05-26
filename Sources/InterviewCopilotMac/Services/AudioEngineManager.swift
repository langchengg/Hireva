import AVFoundation
import Foundation

/// A class-only protocol that listeners must conform to to receive audio buffers and route change notifications.
public protocol AudioEngineBufferDelegate: AnyObject {
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    )

    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    )

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    )
}

/// Provide default empty implementations so existing delegates are not forced to implement them all.
public extension AudioEngineBufferDelegate {
    func audioEngineManager(
        _ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {}

    func audioEngineManagerDidRestartAfterRouteChange(
        _ manager: AudioEngineManager
    ) {}

    func audioEngineManager(
        _ manager: AudioEngineManager,
        didFailWith error: Error
    ) {}
}

/// A wrapper to hold weak references to delegate listeners.
struct WeakAudioBufferDelegateBox {
    weak var value: AnyObject?
}

/// Thread-safe manager that hosts a single shared AVAudioEngine and multiplexes its microphone tap buffer to all delegates.
/// Robustly handles audio route/Bluetooth changes and recovers gracefully.
public final class AudioEngineManager {
    public static let shared = AudioEngineManager()

    private let audioEngine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.interviewcopilot.audiomanager")
    private var delegates: [WeakAudioBufferDelegateBox] = []
    private var isTapInstalled = false
    private var routeChangeDebounceTask: Task<Void, Never>?

    public private(set) var lastAudioBufferAt: Date?
    public private(set) var audioRecoveryState: String = "Idle"

    public var isEngineRunning: Bool { audioEngine.isRunning }
    public var engine: AVAudioEngine { audioEngine }

    private init() {}

    /// Registers a delegate to receive audio buffer callbacks.
    public func register(_ delegate: any AudioEngineBufferDelegate) {
        queue.sync {
            pruneAndClean()
            let alreadyExists = delegates.contains { $0.value === delegate }
            if !alreadyExists {
                delegates.append(WeakAudioBufferDelegateBox(value: delegate))
            }
            
            do {
                try ensureTapInstalled()
            } catch {
                print("[AudioEngineManager] Failed to install audio tap: \(error.localizedDescription)")
            }
        }
    }

    /// Unregisters a delegate from receiving audio buffer callbacks.
    public func unregister(_ delegate: any AudioEngineBufferDelegate) {
        queue.sync {
            delegates.removeAll { $0.value === delegate || $0.value == nil }
            if delegates.isEmpty {
                removeTap()
            }
        }
    }

    /// Queries the current dynamic inputNode format from CoreAudio.
    public func currentInputFormatDescription() -> String {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        return "\(Int(format.sampleRate))Hz \(format.channelCount)Ch"
    }

    /// Handles the AVAudioEngineConfigurationChange notification or configuration update.
    public func handleAudioConfigurationChanged() {
        restartForRouteChange(reason: "AVAudioEngine Configuration Changed")
    }

    /// Triggers a debounced recovery operation for route changes or manual restarts.
    public func restartForRouteChange(reason: String) {
        routeChangeDebounceTask?.cancel()
        routeChangeDebounceTask = Task {
            do {
                // Debounce notifications for 0.8 seconds to avoid rapid consecutive triggers
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.queue.async {
                self.rebuildInputTap(reason: reason)
            }
        }
    }

    /// Performs an immediate rebuild of the input tap.
    public func rebuildInputTap() {
        queue.sync {
            self.rebuildInputTap(reason: "Immediate rebuild requested")
        }
    }

    /// Performs the safe, safe teardown and dynamic tap rebuild.
    private func rebuildInputTap(reason: String) {
        print("[AudioEngineManager] Rebuilding input tap due to: \(reason)")
        
        // 1. Stop engine safely
        audioEngine.stop()
        
        // 2. Remove tap
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
        
        // 3. Reset the engine to clear stale formats
        audioEngine.reset()
        
        // 4. Update recovery state attributes
        self.lastAudioBufferAt = nil
        self.audioRecoveryState = "Reconnecting..."
        
        // 5. Re-query inputNode and install tap if we have delegates
        if !delegates.isEmpty {
            do {
                let inputNode = audioEngine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                
                inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                    self?.broadcast(buffer: buffer, time: time)
                }
                
                audioEngine.prepare()
                try audioEngine.start()
                isTapInstalled = true
                self.audioRecoveryState = "Active"
                
                // 6. Notify delegates that the audio route changed successfully
                notifyRouteRestarted()
            } catch {
                print("[AudioEngineManager] Recovery failed: \(error.localizedDescription)")
                self.audioRecoveryState = "Failed"
                notifyRouteFailed(error: error)
            }
        } else {
            self.audioRecoveryState = "Idle"
        }
    }

    /// Installs a single tap on AVAudioEngine inputNode bus 0 and starts the engine.
    private func ensureTapInstalled() throws {
        guard !isTapInstalled else {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
            self?.broadcast(buffer: buffer, time: time)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isTapInstalled = true
        self.audioRecoveryState = "Active"
    }

    /// Stops the shared audio engine and uninstalls the tap.
    private func removeTap() {
        guard isTapInstalled else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
        self.audioRecoveryState = "Idle"
    }

    /// Broadcasts the buffer to copies of all active delegates in a thread-safe manner.
    private func broadcast(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        self.lastAudioBufferAt = Date()
        
        let activeDelegates: [any AudioEngineBufferDelegate] = queue.sync {
            delegates.compactMap { $0.value as? (any AudioEngineBufferDelegate) }
        }

        for delegate in activeDelegates {
            delegate.audioEngineManager(self, didReceive: buffer, at: time)
        }
    }

    /// Safely prunes deallocated weak delegate references.
    private func pruneAndClean() {
        delegates.removeAll { $0.value == nil }
    }

    private func notifyRouteRestarted() {
        let activeDelegates: [any AudioEngineBufferDelegate] = delegates.compactMap { $0.value as? (any AudioEngineBufferDelegate) }
        for delegate in activeDelegates {
            delegate.audioEngineManagerDidRestartAfterRouteChange(self)
        }
    }

    private func notifyRouteFailed(error: Error) {
        let activeDelegates: [any AudioEngineBufferDelegate] = delegates.compactMap { $0.value as? (any AudioEngineBufferDelegate) }
        for delegate in activeDelegates {
            delegate.audioEngineManager(self, didFailWith: error)
        }
    }
}
