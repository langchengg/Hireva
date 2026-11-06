import AVFoundation
import Foundation
import ScreenCaptureKit
import os

/// MainActor owns recording controls and display. Each backend registers a
/// separate epoch receiver; realtime callbacks touch only bounded PCM storage.
@MainActor
public final class ManualQuestionCaptureService: NSObject, ObservableObject, SystemAudioBufferDelegate, AudioEngineBufferDelegate {
    public static let shared = ManualQuestionCaptureService()
    @Published public private(set) var isRecording = false
    @Published public var recordingDuration: Double = 0
    @Published public private(set) var rmsLevel: Double = 0
    @Published public private(set) var decibels: Double = -90
    @Published public var capturedBufferCount = 0
    @Published public var lastBufferTimestamp: Date?
    @Published public private(set) var captureFailure: String?

    private let systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService
    private let usesSharedTestHooks: Bool
    private let maximumStoredBytes: Int
    private nonisolated let storage = ManualPCMStorage()
    private var timer: Timer?
    private let startFence = CaptureStartFence()
    private var maxSeconds = 60
    private var onTimeoutTriggered: (() -> Void)?
    private var onFailure: ((Error) -> Void)?
    private var activeSource: ManualCaptureSource = .systemAudio
    private(set) var activeBufferReceiver: ManualPCMReceiver?
    private var displayTasks: [UInt64: Task<Void, Never>] = [:]
    private var retiringDisplayTasks: [Task<Void, Never>] {
        let activeEpoch = activeBufferReceiver?.epoch
        return displayTasks.compactMap { entry in
            entry.key == activeEpoch ? nil : entry.value
        }
    }
#if DEBUG
    // The owning test can cancel and join a held regression without needing
    // MainActor to close the new receiver first. This never changes ownership.
    var ownedDisplayTasksForTesting: [Task<Void, Never>] { Array(displayTasks.values) }
#endif
    private var closed = false
    // Stable alias of the SCK-owned epoch. Its current attempt is a derived
    // compatibility projection; another caller's retry cannot strand us.
    private var nativeStopReceipt: SystemAudioCaptureStopReceipt?
    private var nativeStopTask: Task<Void, Error>? { nativeStopReceipt?.issuedStopTask }
    private var ownedStop: ManualCaptureCapabilities.Stop? {
        nativeStopReceipt.map { .systemAudio($0) }
    }

    private override init() {
        systemAudioCaptureService = .shared
        usesSharedTestHooks = true
        maximumStoredBytes = 32 * 1024 * 1024
        super.init()
    }

    init(systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService,
        maximumStoredBytes: Int = 32 * 1024 * 1024) {
        self.systemAudioCaptureService = systemAudioCaptureService
        usesSharedTestHooks = false
        self.maximumStoredBytes = max(maximumStoredBytes, 0)
        super.init()
    }

    public static var mockStartCapture: (@MainActor (ManualCaptureSource, Int, @escaping () -> Void) async throws -> Void)?
    public static var mockStopCapture: (() -> [AVAudioPCMBuffer])?
    public static var mockCancelCapture: (() -> Void)?
    public var normalizedLevel: Double { min(max((decibels + 60) / 60, 0), 1) }

    public func startCapture(source: ManualCaptureSource, maxDuration: Int = 60,
        onFailure: ((Error) -> Void)? = nil, onTimeout: @escaping () -> Void) async throws {
        guard !closed else { throw CancellationError() }
        _ = cancelCaptureAndReturnOwnedStop(retryFailedResource: false)
        let previousStop = ownedStop
        let startRevision = startFence.begin()
        if usesSharedTestHooks, let mock = Self.mockStartCapture {
            try await mock(source, maxDuration, onTimeout)
            guard startFence.isCurrent(startRevision), !Task.isCancelled, !closed else { throw CancellationError() }
            return
        }
        if let previousStop {
            try await finishStopping(capturedReceipt: previousStop)
        } else if source == .systemAudio {
            try await systemAudioCaptureService.finishStoppingSystemAudioCapture()
        }
        guard startFence.isCurrent(startRevision), !Task.isCancelled, !closed else { throw CancellationError() }
        let updates = AsyncStream<ManualPCMDisplay>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let epoch = storage.open(systemAudio: source == .systemAudio,
            capacity: maximumStoredBytes, updates: updates.continuation)
        let receiver = ManualPCMReceiver(storage: storage, epoch: epoch)
        activeBufferReceiver = receiver
        activeSource = source
        self.maxSeconds = maxDuration
        onTimeoutTriggered = onTimeout
        self.onFailure = onFailure
        isRecording = true
        recordingDuration = 0
        rmsLevel = 0
        decibels = -90
        capturedBufferCount = 0
        lastBufferTimestamp = nil
        captureFailure = nil
        displayTasks[epoch] = Task { @MainActor [weak self] in
            defer { self?.displayTasks[epoch] = nil }
            var lastPublication: ContinuousClock.Instant?
            for await display in updates.stream {
                guard let self, !Task.isCancelled, self.activeBufferReceiver === receiver else { return }
                let now = ContinuousClock.now
                if display.failure == nil, let lastPublication,
                   lastPublication.duration(to: now) < .milliseconds(100) { continue }
                lastPublication = now
                self.publish(display)
                if let failure = display.failure {
                    _ = self.stopCaptureAndReturnBuffers()
                    self.onFailure?(NSError(domain: "ManualQuestionCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: failure]))
                    return
                }
            }
        }
        do {
            if source == .systemAudio {
                let owned = systemAudioCaptureService.beginSystemAudioCapture(onOwned: { [self] receipt in
                    nativeStopReceipt = receipt
                    systemAudioCaptureService.register(receiver, capturedReceipt: receipt)
                })
                try await systemAudioCaptureService.finishStartingSystemAudioCapture(
                    capturedStart: owned.startup, capturedReceipt: owned.receipt)
            } else {
                try AudioEngineManager.shared.register(receiver).get()
            }
            guard startFence.isCurrent(startRevision), !Task.isCancelled, !closed else { throw CancellationError() }
            installRecordingTimer()
        } catch {
            // A late old start cannot tear down the replacement recording.
            if activeBufferReceiver === receiver {
                _ = cancelCaptureAndReturnOwnedStop(retryFailedResource: false)
            }
            throw error
        }
    }

    private func installRecordingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 0.1, target: self,
            selector: #selector(recordingTimerDidFire(_:)), userInfo: nil, repeats: true)
    }

    @objc private func recordingTimerDidFire(_ timer: Timer) {
        guard self.timer === timer, isRecording else { return }
        recordingDuration += timer.timeInterval
        if recordingDuration >= Double(maxSeconds) {
            timer.invalidate()
            self.timer = nil
            onTimeoutTriggered?()
        }
    }

    public func stopCaptureAndReturnBuffers() -> [AVAudioPCMBuffer] {
        stopCaptureAndReturnOwnedAudio().buffers
    }

    func stopCaptureAndReturnOwnedAudio() -> (buffers: [AVAudioPCMBuffer],
        bufferCount: Int, lastBufferTimestamp: Date?, drain: Task<Void, Error>?) {
        let count = capturedBufferCount, timestamp = lastBufferTimestamp
        startFence.invalidate()
        if usesSharedTestHooks, let mock = Self.mockStopCapture {
            return (mock(), count, timestamp, nativeStopTask)
        }
        timer?.invalidate()
        timer = nil
        isRecording = false
        let result = storage.close(takeBuffers: true)
        publish(result.display)
        let drain = unregisterReceiver()
        // Failed/overflowed PCM is never passed to ASR as a complete recording.
        return (result.display.failure == nil ? result.buffers : [],
            result.display.count, result.display.timestamp, drain)
    }

    public func cancelCapture() { _ = cancelCaptureAndReturnOwnedStop() }

    func cancelCaptureAndReturnOwnedStop(retryFailedResource: Bool = true) -> Task<Void, Error>? {
        startFence.invalidate()
        if usesSharedTestHooks, let mock = Self.mockCancelCapture {
            mock()
            return nativeStopTask
        }
        timer?.invalidate()
        timer = nil
        isRecording = false
        _ = storage.close(takeBuffers: false)
        return unregisterReceiver(retryFailedResource: retryFailedResource)
    }

    @discardableResult
    private func unregisterReceiver(retryFailedResource: Bool = true) -> Task<Void, Error>? {
        guard let receiver = activeBufferReceiver else { return nativeStopTask }
        activeBufferReceiver = nil
        if activeSource == .systemAudio {
            systemAudioCaptureService.unregister(receiver)
            if let nativeStopReceipt {
                _ = systemAudioCaptureService.stopSystemAudioCapture(
                    capturedReceipt: nativeStopReceipt, retryFailed: retryFailedResource)
            }
        } else {
            AudioEngineManager.shared.unregister(receiver)
        }
        return nativeStopTask
    }

    func finishStopping(capturedStop: Task<Void, Error>?) async throws {
        // Stop closed these display streams synchronously. Capture handles
        // before awaiting the exact native stop, then join even if it failed.
        let ownedDisplay = retiringDisplayTasks
        var failure: Error?
        if let capturedStop {
            do {
                try await systemAudioCaptureService.finishStoppingSystemAudioCapture(capturedStop: capturedStop)
                if nativeStopReceipt?.issuedStopTask == capturedStop { nativeStopReceipt = nil }
            } catch { failure = error }
        }
        for task in ownedDisplay { await task.value }
        if let failure { throw failure }
    }

    func stopCaptureAndReturnOwnedReceiptAudio() -> (buffers: [AVAudioPCMBuffer],
        bufferCount: Int, lastBufferTimestamp: Date?, drain: ManualCaptureCapabilities.Stop?) {
        let stopped = stopCaptureAndReturnOwnedAudio()
        return (stopped.buffers, stopped.bufferCount, stopped.lastBufferTimestamp, ownedStop)
    }

    func cancelCaptureAndReturnOwnedReceipt() -> ManualCaptureCapabilities.Stop? {
        _ = cancelCaptureAndReturnOwnedStop()
        return ownedStop
    }

    func finishStopping(capturedReceipt: ManualCaptureCapabilities.Stop?) async throws {
        let ownedDisplay = retiringDisplayTasks
        var failure: Error?
        if let capturedReceipt {
            do {
                switch capturedReceipt {
                case .systemAudio(let receipt):
                    try await systemAudioCaptureService.finishStoppingSystemAudioCapture(capturedReceipt: receipt)
                    if nativeStopReceipt === receipt { nativeStopReceipt = nil }
                case .controlled(let task):
                    try await task.value
                }
            } catch { failure = error }
        }
        for task in ownedDisplay { await task.value }
        if let failure { throw failure }
    }

    func retryStopping(capturedReceipt: ManualCaptureCapabilities.Stop) async throws {
        // The captured resource, never the service's current capture, authorizes
        // this retry. Released old receipts cannot stop a replacement epoch.
        if case .systemAudio(let receipt) = capturedReceipt {
            _ = systemAudioCaptureService.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
        }
        try await finishStopping(capturedReceipt: capturedReceipt)
    }

    func shutdown() async throws {
        let retry = closed
        closed = true
        let captured = cancelCaptureAndReturnOwnedReceipt()
        while !displayTasks.isEmpty {
            for task in Array(displayTasks.values) { await task.value }
        }
        if retry, let captured { try await retryStopping(capturedReceipt: captured) }
        else { try await finishStopping(capturedReceipt: captured) }
    }

    private func publish(_ display: ManualPCMDisplay) {
        rmsLevel = display.rms
        decibels = display.decibels
        capturedBufferCount = display.count
        lastBufferTimestamp = display.timestamp
        captureFailure = display.failure
    }

    // Compatibility callbacks use the same storage rules. Production registers
    // ManualPCMReceiver instead, so a copied old delegate retains its old epoch.
    nonisolated func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        storage.receive(buffer, systemAudio: true, epoch: nil)
    }
    nonisolated func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {
        storage.fail(error.localizedDescription, epoch: nil)
    }
    nonisolated public func audioEngineManager(_ manager: AudioEngineManager,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        storage.receive(buffer, systemAudio: false, epoch: nil)
    }
}

private struct ManualPCMDisplay: Sendable {
    var count = 0
    var rms: Double = 0
    var decibels: Double = -90
    var timestamp: Date?
    var failure: String?
}

/// Owned buffer copies never alias framework input. The lock protects every
/// access until close atomically removes the array; only that caller receives
/// exclusive ownership. No lock is held across an await or calls into UI/I/O.
private final class ManualPCMStorage: Sendable {
    private struct State {
        var revision: UInt64 = 0
        var open = false
        var systemAudio = false
        var capacity = 0
        var bytes = 0
        var buffers: [AVAudioPCMBuffer] = []
        var display = ManualPCMDisplay()
        var updates: AsyncStream<ManualPCMDisplay>.Continuation?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func open(systemAudio: Bool, capacity: Int,
        updates: AsyncStream<ManualPCMDisplay>.Continuation) -> UInt64 {
        state.withLockUnchecked {
            $0.revision &+= 1
            $0.open = true
            $0.systemAudio = systemAudio
            $0.capacity = capacity
            $0.bytes = 0
            $0.buffers.removeAll(keepingCapacity: false)
            $0.display = .init()
            $0.updates = updates
            return $0.revision
        }
    }

    func close(takeBuffers: Bool) -> (buffers: [AVAudioPCMBuffer], display: ManualPCMDisplay) {
        state.withLockUnchecked {
            $0.open = false
            $0.updates?.finish()
            $0.updates = nil
            let buffers = takeBuffers ? $0.buffers : []
            $0.buffers = []
            $0.bytes = 0
            return (buffers, $0.display)
        }
    }

    func fail(_ message: String, epoch: UInt64?) {
        state.withLockUnchecked {
            guard $0.open, epoch == nil || $0.revision == epoch else { return }
            $0.open = false
            $0.display.failure = message
            $0.updates?.yield($0.display)
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, systemAudio: Bool, epoch: UInt64?) {
        state.withLockUnchecked {
            guard $0.open, $0.systemAudio == systemAudio,
                  epoch == nil || $0.revision == epoch, buffer.frameLength > 0 else { return }
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
            guard bytes > 0, bytes <= $0.capacity - $0.bytes, $0.buffers.count < 8192,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                $0.open = false
                $0.display.failure = "Manual recording exceeded its bounded PCM capacity or could not copy audio. Record a shorter question."
                $0.updates?.yield($0.display)
                return
            }
            copy.frameLength = buffer.frameLength
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == destination.count else {
                $0.open = false
                $0.display.failure = "Manual recording has an unsupported PCM layout."
                $0.updates?.yield($0.display)
                return
            }
            for index in source.indices {
                let size = Int(source[index].mDataByteSize)
                guard size <= Int(destination[index].mDataByteSize),
                      let input = source[index].mData, let output = destination[index].mData else {
                    $0.open = false
                    $0.display.failure = "Manual recording has an invalid PCM buffer."
                    $0.updates?.yield($0.display)
                    return
                }
                memcpy(output, input, size)
            }
            $0.buffers.append(copy)
            $0.bytes += bytes
            $0.display.count = $0.buffers.count
            $0.display.timestamp = Date()
            let frames = Int(copy.frameLength), channels = Int(copy.format.channelCount)
            if frames > 0, channels > 0 {
                var sum: Double = 0
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        let offset = frame * copy.stride
                        let value: Double
                        if let data = copy.floatChannelData { value = Double(data[channel][offset]) }
                        else if let data = copy.int16ChannelData { value = Double(data[channel][offset]) / 32768 }
                        else if let data = copy.int32ChannelData { value = Double(data[channel][offset]) / 2147483648 }
                        else { value = 0 }
                        sum += value * value
                    }
                }
                $0.display.rms = sqrt(sum / Double(frames * channels))
                $0.display.decibels = 20 * log10(max($0.display.rms, 0.000_001))
            }
            $0.updates?.yield($0.display)
        }
    }
}

/// The callback object carries only immutable epoch identity and synchronized
/// storage. It does not read a mutable UI source or current recording state.
final class ManualPCMReceiver: SystemAudioBufferDelegate, AudioEngineBufferDelegate, Sendable {
    private let storage: ManualPCMStorage
    fileprivate let epoch: UInt64
    fileprivate init(storage: ManualPCMStorage, epoch: UInt64) { self.storage = storage; self.epoch = epoch }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        storage.receive(buffer, systemAudio: true, epoch: epoch)
    }
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService, didFailWithError error: Error) {
        storage.fail(error.localizedDescription, epoch: epoch)
    }
    func audioEngineManager(_ manager: AudioEngineManager, didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        storage.receive(buffer, systemAudio: false, epoch: epoch)
    }
}
