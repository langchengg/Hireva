import AVFoundation
import Foundation
import os

/// One source/request binding. Native PCM borrows only its exact checked input;
/// control callbacks enqueue values for a retained MainActor service worker.
final class AppleSpeechNativeReceiver: AudioEngineBufferDelegate, SystemAudioBufferDelegate, Sendable {
    let id = UUID()
    let source: AudioSourceType
    let input: AppleSpeechPCMInput?
    let controls: AppleSpeechNativeControlIngress

    init(source: AudioSourceType, input: AppleSpeechPCMInput?, controls: AppleSpeechNativeControlIngress) {
        self.source = source; self.input = input; self.controls = controls
    }
    // These checked, source-bound channels can close synchronously even when
    // their actor owner is released without an explicit stop. No SDK state is
    // accessed here. Any input drain uses the input's one retained close worker.
    deinit { close() }
    func close() { controls.close(); input?.close() }
    func audioEngineManager(_ manager: AudioEngineManager, didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard source == .microphone else { return }
        _ = input?.append(buffer)
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard source == .systemAudio else { return }
        _ = input?.append(buffer)
    }
    func audioEngineManagerDidRestartAfterRouteChange(_ manager: AudioEngineManager) {
        guard source == .microphone else { return }
        controls.enqueueRouteRestart()
    }
    func audioEngineManager(_ manager: AudioEngineManager, didFailWith error: Error) {
        guard source == .microphone, controls.enqueueFailure(error) else { return }
        input?.close()
    }
    @MainActor
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService, didFailWithError error: Error) {
        guard source == .systemAudio, controls.enqueueFailure(error) else { return }
        input?.close()
    }
}

/// The native callback channel is specific to one Apple source receiver.
/// One source failure is terminal for this receiver and is never dropped;
/// identical route restart requests coalesce until their current device is read.
final class AppleSpeechNativeControlIngress: Sendable {
    enum Event: Sendable { case failure(Error), routeRestart }
    private struct State: Sendable {
        var accepting: Bool
        var sourceFailed = false
        var routeQueued = false
        var events: [Event] = [] // at most one failure + one route restart
    }
    private let state: OSAllocatedUnfairLock<State>
    private let pulses = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var signals: AsyncStream<Void> { pulses.stream }
    var pendingControlCount: Int { state.withLock { $0.events.count } }
    var isAccepting: Bool { state.withLock { $0.accepting } }
    init(accepting: Bool = true) { state = OSAllocatedUnfairLock(initialState: State(accepting: accepting)) }
    @discardableResult
    func enqueueFailure(_ error: Error) -> Bool {
        let admitted = state.withLock { value in
            guard value.accepting, !value.sourceFailed else { return false }
            value.sourceFailed = true
            value.events.append(.failure(error))
            return true
        }
        if admitted { pulses.continuation.yield(()) }
        return admitted
    }
    func enqueueRouteRestart() {
        let admitted = state.withLock { value in
            guard value.accepting, !value.sourceFailed, !value.routeQueued else { return false }
            value.routeQueued = true
            value.events.append(.routeRestart)
            return true
        }
        if admitted { pulses.continuation.yield(()) }
    }
    func takePending() -> [Event] {
        state.withLock { value in
            let captured = value.events
            value.events.removeAll(keepingCapacity: true)
            value.routeQueued = false
            return captured
        }
    }
    func close() {
        state.withLock { $0.accepting = false }
        pulses.continuation.finish()
    }
}

struct AppleSpeechPCMDisplayBatch: Sendable {
    let bufferCount: Int
    let frameCount: Int
    let timestamp: Date
}

/// Exact numeric deltas aggregate while MainActor is busy. Only the wake token
/// coalesces; no PCM count is lost and no native buffer crosses this boundary.
final class AppleSpeechPCMDisplayInbox: Sendable {
    private struct State: Sendable {
        var bufferCount = 0
        var frameCount = 0
        var timestamp: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pulses = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var signals: AsyncStream<Void> { pulses.stream }
    var pendingSnapshotCount: Int { state.withLock { $0.bufferCount == 0 ? 0 : 1 } }
    func record(frameCount: Int, timestamp: Date) {
        state.withLock {
            $0.bufferCount += 1
            $0.frameCount += frameCount
            $0.timestamp = timestamp
        }
        pulses.continuation.yield(())
    }
    func takePending() -> AppleSpeechPCMDisplayBatch? {
        state.withLock { value in
            guard value.bufferCount > 0, let timestamp = value.timestamp else { return nil }
            let captured = AppleSpeechPCMDisplayBatch(bufferCount: value.bufferCount,
                frameCount: value.frameCount, timestamp: timestamp)
            value = State()
            return captured
        }
    }
    func finish() { pulses.continuation.finish() }
}
