import AVFoundation
import Foundation
import Speech
import os

/// Native I/O replacement per session, never a process-global hook.
struct AppleSpeechPCMTestingOperations: Sendable {
    let append: @Sendable (AVAudioPCMBuffer) -> Void
    let endAudio: @Sendable () -> Void
}

/// Exact request input and its authoritative PCM counters. Configuration is
/// frozen before construction. Admission, counters and retained close work
/// have one authority; no synchronous stop waits on native append or MainActor.
final class AppleSpeechPCMInput: Sendable {
    struct Snapshot: Sendable {
        let bufferCount: Int
        let lastBufferAt: Date?
        let simulated: Bool
    }
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        let operations: AppleSpeechPCMTestingOperations?
        let simulated: Bool
        var accepting = true
        var ended = false
        var inFlight = 0
        var bufferCount = 0
        var lastBufferAt: Date?
        var closeTask: Task<Void, Never>?
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }
    // The SDK lock exclusively owns the request pointer and counters. Native
    // calls borrow a local request only synchronously, never across an await.
    private let state: OSAllocatedUnfairLock<State>
    private let appendSerial = OSAllocatedUnfairLock(initialState: ())
    private let displays = AppleSpeechPCMDisplayInbox()
    var displaySignals: AsyncStream<Void> { displays.signals }
    var pendingDisplaySnapshotCount: Int { displays.pendingSnapshotCount }
    func takePendingDisplayBatch() -> AppleSpeechPCMDisplayBatch? { displays.takePending() }
    init(request: SFSpeechAudioBufferRecognitionRequest,
        simulated: Bool, operations: AppleSpeechPCMTestingOperations?) {
        state = OSAllocatedUnfairLock(uncheckedState: State(request: request,
            operations: operations, simulated: simulated))
    }
    var snapshot: Snapshot {
        state.withLockUnchecked { Snapshot(bufferCount: $0.bufferCount,
            lastBufferAt: $0.lastBufferAt, simulated: $0.simulated) }
    }
    var inFlightAppendCount: Int { state.withLockUnchecked { $0.inFlight } }
    var ownedCloseTask: Task<Void, Never>? { state.withLockUnchecked { $0.closeTask } }
    var isAcceptingForTesting: Bool { state.withLockUnchecked { $0.accepting } }

    var hasUnreleasedInput: Bool { state.withLockUnchecked { !$0.ended || $0.inFlight > 0 || $0.closeTask != nil } }

    func append(_ buffer: AVAudioPCMBuffer) -> Snapshot? {
        // Late callbacks must reject closed input before waiting behind an
        // already admitted native append. Admission is checked again below.
        guard state.withLockUnchecked({ $0.accepting }) else { return nil }
        // Only synchronous request append calls serialize here. Stop uses the
        // separate admission lock and async drain, never this native-I/O lock.
        return appendSerial.withLockUnchecked {
            let borrow = state.withLockUnchecked { value -> (SFSpeechAudioBufferRecognitionRequest?, AppleSpeechPCMTestingOperations?, Bool)? in
                guard value.accepting else { return nil }
                value.inFlight += 1
                return (value.request, value.operations, value.simulated)
            }
            guard let (request, operations, simulated) = borrow else { return nil }
            if let operations { operations.append(buffer) }
            else if !simulated { request?.append(buffer) }
            let appendedAt = Date()
            let result = state.withLockUnchecked { value -> Snapshot in
                value.bufferCount += 1
                value.lastBufferAt = appendedAt
                return Snapshot(bufferCount: value.bufferCount, lastBufferAt: value.lastBufferAt,
                    simulated: value.simulated)
            }
            // Register the exact numeric display delta before releasing the
            // admitted borrow. End/finish cannot overtake this final record.
            displays.record(frameCount: Int(buffer.frameLength), timestamp: appendedAt)
            let waiters = state.withLockUnchecked { value in
                value.inFlight -= 1
                let captured = value.inFlight == 0 ? value.drainWaiters : []
                if value.inFlight == 0 { value.drainWaiters.removeAll() }
                return captured
            }
            waiters.forEach { $0.resume() }
            return result
        }
    }

    /// Admission closes synchronously. The one retained worker remains owned
    /// until every admitted native append returns and endAudio has executed.
    @discardableResult
    func close() -> Task<Void, Never>? {
        state.withLockUnchecked { value in
            guard !value.ended else { return nil }
            value.accepting = false
            if let task = value.closeTask { return task }
            // Register while holding the short state lock. A scheduled worker
            // cannot complete and clear its slot before its handle is installed.
            let task = Task { [self] in
                await waitForAdmittedAppendExit()
                endNativeInput()
            }
            value.closeTask = task
            return task
        }
    }

    private func waitForAdmittedAppendExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLockUnchecked { value in
                guard value.inFlight > 0 else { return true }
                value.drainWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func endNativeInput() {
        // Closed admission + zero borrows guarantee exclusive endAudio. The
        // native object remains private and is never captured across an await.
        let borrow = state.withLockUnchecked { value in (value.request, value.operations) }
        if let operations = borrow.1 { operations.endAudio() }
        else { borrow.0?.endAudio() }
        displays.finish()
        state.withLockUnchecked { value in
            value.request = nil
            value.ended = true
            value.closeTask = nil
        }
    }

}

/// Session.start/stop and its legacy PCM API share this sole current input.
/// The slot synchronizes pointer replacement; each append retains its exact
/// input borrow independently of a later start replacing the slot.
final class AppleSpeechPCMInputSlot: Sendable {
    private struct State: Sendable {
        var current: AppleSpeechPCMInput?
        var retiring: [AppleSpeechPCMInput] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    // Destruction cannot await. Close the exact checked inputs so input-owned
    // drain/display work can finish; explicit owner stop/join remains the
    // resource-exit contract and also cancels the actor-isolated SDK task.
    deinit {
        let inputs = state.withLock { [$0.current].compactMap { $0 } + $0.retiring }
        for input in inputs { input.close() }
    }
    var current: AppleSpeechPCMInput? { state.withLock { $0.current } }
    var hasUnreleasedInput: Bool {
        let inputs = state.withLock { [$0.current].compactMap { $0 } + $0.retiring }
        return inputs.contains { $0.hasUnreleasedInput }
    }
    func replace(_ input: AppleSpeechPCMInput) {
        state.withLock {
            if let old = $0.current, old !== input, old.hasUnreleasedInput { $0.retiring.append(old) }
            $0.current = input
        }
    }
    func finishStopping() async {
        let inputs = state.withLock { [$0.current].compactMap { $0 } + $0.retiring }
        let captured = inputs.compactMap { $0.close() }
        for task in captured { await task.value }
        state.withLock { $0.retiring.removeAll { !$0.hasUnreleasedInput } }
    }
}
