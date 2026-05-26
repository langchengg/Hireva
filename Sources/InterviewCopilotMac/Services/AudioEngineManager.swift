import AVFoundation
import Foundation

/// A class-only protocol that listeners must conform to to receive audio buffers.
public protocol AudioEngineBufferDelegate: AnyObject {
    func audioEngineDidReceiveBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime)
}

/// A wrapper to hold weak references to delegate listeners.
struct WeakAudioBufferDelegateBox {
    weak var value: AnyObject?
}

/// Thread-safe manager that hosts a single shared AVAudioEngine and multiplexes its microphone tap buffer to all delegates.
public final class AudioEngineManager {
    public static let shared = AudioEngineManager()

    private let audioEngine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.interviewcopilot.audiomanager")
    private var delegates: [WeakAudioBufferDelegateBox] = []
    private var isTapInstalled = false

    private init() {}

    /// Registers a delegate to receive audio buffer callbacks.
    public func register(_ delegate: any AudioEngineBufferDelegate) {
        queue.sync {
            // Prune dead delegates and check if already registered
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
    }

    /// Stops the shared audio engine and uninstalls the tap.
    private func removeTap() {
        guard isTapInstalled else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    /// Broadcasts the buffer to copies of all active delegates in a thread-safe manner.
    private func broadcast(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Copy delegates before broadcasting to prevent mutation issues
        let activeDelegates: [any AudioEngineBufferDelegate] = queue.sync {
            delegates.compactMap { $0.value as? (any AudioEngineBufferDelegate) }
        }

        for delegate in activeDelegates {
            delegate.audioEngineDidReceiveBuffer(buffer, time: time)
        }
    }

    /// Safely prunes deallocated weak delegate references.
    private func pruneAndClean() {
        delegates.removeAll { $0.value == nil }
    }
}
