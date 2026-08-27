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
    private let queue = DispatchQueue(label: "com.langcheng.hireva.audiomanager")
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
        do {
            try registerForCapture(delegate)
        } catch {
            // Existing diagnostic listeners use the non-throwing API. Capture
            // owners that must fail their startup transaction call the
            // throwing variant below.
        }
    }

    /// Registers a delegate and proves that the shared microphone engine is
    /// running before returning. If startup fails, the delegate is removed so
    /// callers never retain a half-started capture registration.
    public func registerForCapture(_ delegate: any AudioEngineBufferDelegate) throws {
        try queue.sync {
            pruneAndClean()
            let alreadyExists = delegates.contains { $0.value === delegate }
            if !alreadyExists {
                delegates.append(WeakAudioBufferDelegateBox(value: delegate))
            }
            
            do {
                try ensureTapInstalled()
            } catch {
                self.audioRecoveryState = "Failed"
                let errorCode = (error as NSError).code
                PrivacySafeLogger.audioFailure(
                    operation: .audioTapInstall,
                    code: errorCode
                )
                let captureError = Self.userFacingCaptureError(code: errorCode)
                if !alreadyExists {
                    delegates.removeAll { $0.value === delegate || $0.value == nil }
                }
                notifyRouteFailed(error: captureError)
                throw captureError
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
            Self.enqueueSharedRebuild(reason: reason)
        }
    }

    private static func enqueueSharedRebuild(reason: String) {
        // This type has a private initializer, so the queue-owned engine is always the shared instance.
        shared.queue.async {
            shared.rebuildInputTap(reason: reason)
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
                
                try Self.performTapStartTransaction(
                    install: {
                        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                            self?.broadcast(buffer: buffer, time: time)
                        }
                        self.audioEngine.prepare()
                    },
                    start: {
                        try self.audioEngine.start()
                    },
                    rollback: {
                        self.tearDownInputTap()
                    }
                )
                isTapInstalled = true
                self.audioRecoveryState = "Active"
                
                // 6. Notify delegates that the audio route changed successfully
                notifyRouteRestarted()
            } catch {
                let errorCode = (error as NSError).code
                PrivacySafeLogger.audioFailure(
                    operation: .audioTapRecovery,
                    code: errorCode
                )
                self.audioRecoveryState = "Failed"
                notifyRouteFailed(error: Self.userFacingCaptureError(code: errorCode))
            }
        } else {
            self.audioRecoveryState = "Idle"
        }
    }

    /// Installs a single tap on AVAudioEngine inputNode bus 0 and starts the engine.
    private func ensureTapInstalled() throws {
        guard !isTapInstalled else {
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    tearDownInputTap()
                    throw error
                }
            }
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        try Self.performTapStartTransaction(
            install: {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, time in
                    self?.broadcast(buffer: buffer, time: time)
                }
                self.audioEngine.prepare()
            },
            start: {
                try self.audioEngine.start()
            },
            rollback: {
                self.tearDownInputTap()
            }
        )
        isTapInstalled = true
        self.audioRecoveryState = "Active"
    }

    /// Keeps tap installation and engine startup atomic. Internal visibility
    /// permits hermetic tests to prove rollback without touching audio hardware.
    static func performTapStartTransaction(
        install: () throws -> Void,
        start: () throws -> Void,
        rollback: () -> Void
    ) throws {
        do {
            try install()
            try start()
        } catch {
            rollback()
            throw error
        }
    }

    private func tearDownInputTap() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        isTapInstalled = false
    }

    /// Stops the shared audio engine and uninstalls the tap.
    private func removeTap() {
        guard isTapInstalled else { return }
        tearDownInputTap()
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

    private static func userFacingCaptureError(code: Int) -> NSError {
        NSError(
            domain: "AudioEngineManager",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: "Microphone audio input could not start. Stop and restart listening."
            ]
        )
    }
}
