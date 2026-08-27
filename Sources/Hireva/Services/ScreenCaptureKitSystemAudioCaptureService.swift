import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol SystemAudioBufferDelegate: AnyObject {
    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    )

    func systemAudioCaptureService(
        _ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error
    )
}

final class SystemAudioAsyncOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue<Value>(
        _ operation: @escaping @MainActor () async throws -> Value
    ) -> Task<Value, Error> {
        lock.withLock {
            let previous = tail
            let task = Task { @MainActor in
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = await task.result }
            return task
        }
    }
}

final class SystemAudioStreamSessionGate: @unchecked Sendable {
    struct Token: Equatable {
        let generation: UInt64
        let identity: ObjectIdentifier
    }

    enum StopDisposition: Equatable {
        case expected
        case unexpected(Token)
        case stale
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active: Token?
    private var expectedStops: Set<ObjectIdentifier> = []
    private var confirmedStops: Set<ObjectIdentifier> = []
    private var unexpectedStops: Set<ObjectIdentifier> = []

    func beginCandidate(identity: ObjectIdentifier) -> Token {
        lock.withLock {
            generation &+= 1
            expectedStops.remove(identity)
            confirmedStops.remove(identity)
            unexpectedStops.remove(identity)
            let token = Token(generation: generation, identity: identity)
            active = token
            return token
        }
    }

    func accepts(_ token: Token) -> Bool {
        lock.withLock { active == token }
    }

    func accepts(identity: ObjectIdentifier) -> Bool {
        lock.withLock { active?.identity == identity }
    }

    func beginRequestedStop() -> Token? {
        lock.withLock {
            guard let active else { return nil }
            generation &+= 1
            self.active = nil
            expectedStops.insert(active.identity)
            return active
        }
    }

    func discardCandidate(_ token: Token) {
        lock.withLock {
            guard active == token else { return }
            generation &+= 1
            active = nil
            expectedStops.insert(token.identity)
        }
    }

    func restoreAfterStopFailure(_ token: Token) -> Token? {
        lock.withLock {
            expectedStops.remove(token.identity)
            if confirmedStops.remove(token.identity) != nil { return nil }
            guard active == nil else { return nil }
            generation &+= 1
            let restored = Token(generation: generation, identity: token.identity)
            active = restored
            return restored
        }
    }

    func didStop(identity: ObjectIdentifier) -> StopDisposition {
        lock.withLock {
            if expectedStops.remove(identity) != nil {
                confirmedStops.insert(identity)
                return .expected
            }
            guard let active, active.identity == identity else { return .stale }
            guard unexpectedStops.insert(identity).inserted else { return .stale }
            generation &+= 1
            self.active = nil
            return .unexpected(active)
        }
    }
}

enum SystemAudioStopFailurePolicy {
    static let isCapturingWhenRetryable = true
    static let publicErrorDomain = "ScreenCaptureKitSystemAudioCaptureService"
    static let publicErrorCode = -7
    static let publicErrorMessage = "System audio capture could not stop cleanly. Restart the app before starting another capture."

    static func publicError() -> NSError {
        NSError(
            domain: publicErrorDomain,
            code: publicErrorCode,
            userInfo: [NSLocalizedDescriptionKey: publicErrorMessage]
        )
    }
}

enum SystemAudioUnexpectedStopCleanupPolicy {
    @discardableResult
    static func applyIfCurrent(
        stoppedIdentity: ObjectIdentifier,
        currentIdentity: ObjectIdentifier?,
        cleanup: () -> Void
    ) -> Bool {
        guard currentIdentity == stoppedIdentity else { return false }
        cleanup()
        return true
    }
}

enum SystemAudioCandidateTransaction {
    struct RollbackFailure: Error {
        let underlying: Error
    }

    static func start(
        start: () async throws -> Void,
        rollback: () async throws -> Void
    ) async throws {
        do {
            try await start()
        } catch {
            do {
                try await rollback()
            } catch let rollbackError {
                throw RollbackFailure(underlying: rollbackError)
            }
            throw error
        }
    }
}

final class ScreenCaptureKitSystemAudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, ObservableObject {
    static let shared = ScreenCaptureKitSystemAudioCaptureService()

    @Published var isCapturing = false
    @Published var rmsLevel: Double = 0
    @Published var decibels: Double = -90
    @Published var lastError: String?
    @Published var lastStopError: String?
    @Published var lastBufferReceivedAt: Date? = nil
    @Published var totalBuffersReceived: Int = 0
    @Published var sampleRate: Double = 0
    @Published var channelCount: Int = 0
    @Published var lastBufferFrameCapacity: Int = 0

    private var stream: SCStream?
    private var streamToken: SystemAudioStreamSessionGate.Token?
    private let operationQueue = SystemAudioAsyncOperationQueue()
    private let sessionGate = SystemAudioStreamSessionGate()
    private let queue = DispatchQueue(label: "com.langcheng.hireva.systemaudiocapture")
    private let delegateQueue = DispatchQueue(label: "com.langcheng.hireva.systemaudiodelegates")
    private var delegates: [WeakAudioBufferDelegateBox] = []
    
    private let converter = SampleBufferAudioConverter()
    private var lastUpdateTimestamp = Date.distantPast
    
    private var sampleWatchdogTask: Task<Void, Never>?
    private var hasReceivedSamplesSinceStart = false

    var normalizedLevel: Double {
        min(max((decibels + 60) / 60, 0), 1)
    }

    override init() {
        super.init()
    }

    func register(_ delegate: any SystemAudioBufferDelegate) {
        delegateQueue.sync {
            delegates.removeAll { $0.value == nil }
            let alreadyExists = delegates.contains { $0.value === delegate }
            if !alreadyExists {
                delegates.append(WeakAudioBufferDelegateBox(value: delegate))
            }
        }
    }

    func unregister(_ delegate: any SystemAudioBufferDelegate) {
        delegateQueue.sync {
            delegates.removeAll { $0.value === delegate || $0.value == nil }
        }
    }

    @MainActor
    func startSystemAudioCapture() async throws {
        let task = operationQueue.enqueue { [weak self] in
            guard let self else { return }
            try await self.startSystemAudioCaptureSerialized()
        }
        try await task.value
    }

    @MainActor
    private func startSystemAudioCaptureSerialized() async throws {
        try await stopSystemAudioCaptureSerialized()
        lastError = nil
        lastStopError = nil

        if isRunningUnderTestOrAutomation() {
            self.isCapturing = true
            return
        }

        // 1. Verify screen capture permissions
        let preflight = CGPreflightScreenCaptureAccess()
        var hasAccess = preflight
        let shareableContent: SCShareableContent
        
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            hasAccess = true
        } catch {
            if !hasAccess {
                let errorMsg = "Enable Screen & System Audio Recording in System Settings."
                lastError = errorMsg
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            } else {
                let errorMsg = "System audio capture could not access shareable screen content."
                lastError = errorMsg
                throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
        }

        guard let display = shareableContent.displays.first else {
            let errorMsg = "No shareable display detected."
            lastError = errorMsg
            throw NSError(domain: "ScreenCaptureKitSystemAudioCaptureService", code: -2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        // 3. Create content filter
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 4. Configure stream configuration with dynamic video fallback
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        
        // ScreenCaptureKit still produces screen frames for a display stream.
        // Register .screen output and discard it so the framework does not keep
        // logging "stream output NOT found" while we use the audio buffers.
        config.queueDepth = 3
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)

        var activeSession: (stream: SCStream, token: SystemAudioStreamSessionGate.Token)?
        do {
            activeSession = try await startCandidate(filter: filter, configuration: config)
        } catch {
            if let rollbackFailure = error as? SystemAudioCandidateTransaction.RollbackFailure {
                publishStopFailure(rollbackFailure.underlying)
                throw rollbackFailure.underlying
            }
            PrivacySafeLogger.audioFailure(
                operation: .screenCaptureCompactStream,
                code: (error as NSError).code
            )
            
            // Fallback to display's native width/height to avoid resolution rejection, but ignore video frames
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // Ultra slow video frames

            do {
                activeSession = try await startCandidate(filter: filter, configuration: config)
            } catch {
                if let rollbackFailure = error as? SystemAudioCandidateTransaction.RollbackFailure {
                    publishStopFailure(rollbackFailure.underlying)
                    throw rollbackFailure.underlying
                }
                PrivacySafeLogger.audioFailure(
                    operation: .screenCaptureFallbackStream,
                    code: (error as NSError).code
                )
                let errorMessage = "System audio capture could not start. Check Screen & System Audio Recording permission."
                lastError = errorMessage
                throw NSError(
                    domain: "ScreenCaptureKitSystemAudioCaptureService",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }
        }

        guard let activeSession else { return }
        self.stream = activeSession.stream
        self.streamToken = activeSession.token
        self.isCapturing = true
        
        // 5. Start sample delivery watchdog
        sampleWatchdogTask?.cancel()
        hasReceivedSamplesSinceStart = false
        let watchdogToken = activeSession.token
        sampleWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            } catch {
                return
            }
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            if self.sessionGate.accepts(watchdogToken) && self.isCapturing && !self.hasReceivedSamplesSinceStart {
                PrivacySafeLogger.audioFailure(operation: .screenCaptureNoSamples, code: -3)
                Task { @MainActor in
                    guard self.sessionGate.accepts(watchdogToken) else { return }
                    self.lastError = "System audio stream started but no samples received. Open a browser tab and play some audio (YouTube/music)."
                    self.notifyFailure(error: NSError(
                        domain: "ScreenCaptureKitSystemAudioCaptureService",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "System audio stream started but no samples received."]
                    ))
                }
            }
        }
    }

    @MainActor
    private func startCandidate(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> (stream: SCStream, token: SystemAudioStreamSessionGate.Token) {
        let candidate = SCStream(filter: filter, configuration: configuration, delegate: self)
        let token = sessionGate.beginCandidate(identity: ObjectIdentifier(candidate))
        do {
            try await SystemAudioCandidateTransaction.start(
                start: {
                    try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                    try await candidate.startCapture()
                },
                rollback: {
                    self.sessionGate.discardCandidate(token)
                    try await candidate.stopCapture()
                }
            )
            guard sessionGate.accepts(token) else {
                try await candidate.stopCapture()
                throw CancellationError()
            }
            return (candidate, token)
        } catch {
            sessionGate.discardCandidate(token)
            throw error
        }
    }

    nonisolated func stopSystemAudioCapture() {
        _ = operationQueue.enqueue { [weak self] in
            try await self?.stopSystemAudioCaptureSerialized()
        }
    }

    @MainActor
    func stopSystemAudioCaptureAndWait() async throws {
        let task = operationQueue.enqueue { [weak self] in
            try await self?.stopSystemAudioCaptureSerialized()
        }
        try await task.value
    }

    @MainActor
    private func stopSystemAudioCaptureSerialized() async throws {
        sampleWatchdogTask?.cancel()
        sampleWatchdogTask = nil
        self.isCapturing = false
        self.rmsLevel = 0
        self.decibels = -90
        self.hasReceivedSamplesSinceStart = false

        guard let stream, streamToken != nil else { return }
        guard let stopToken = sessionGate.beginRequestedStop() else { return }

        do {
            try await stream.stopCapture()
            self.stream = nil
            self.streamToken = nil
        } catch {
            let restoredToken = sessionGate.restoreAfterStopFailure(stopToken)
            if let restoredToken {
                self.stream = stream
                self.streamToken = restoredToken
                self.isCapturing = SystemAudioStopFailurePolicy.isCapturingWhenRetryable
            } else {
                self.stream = nil
                self.streamToken = nil
                self.isCapturing = false
            }
            publishStopFailure(error)
            throw error
        }
    }

    @MainActor
    private func publishStopFailure(_ error: Error) {
        let publicError = SystemAudioStopFailurePolicy.publicError()
        lastStopError = publicError.localizedDescription
        lastError = publicError.localizedDescription
        PrivacySafeLogger.audioFailure(
            operation: .screenCaptureCompactStream,
            code: (error as NSError).code
        )
        notifyFailure(error: publicError)
    }

    // MARK: - SCStreamOutput conformance

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let streamIdentity = ObjectIdentifier(stream)
        guard sessionGate.accepts(identity: streamIdentity) else { return }
        guard type == .audio else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        
        if !hasReceivedSamplesSinceStart {
            hasReceivedSamplesSinceStart = true
        }
        
        Task { @MainActor in
            guard self.sessionGate.accepts(identity: streamIdentity) else { return }
            self.lastBufferReceivedAt = Date()
            self.totalBuffersReceived += 1
        }

        do {
            // Convert CMSampleBuffer audio into AVAudioPCMBuffer using our dedicated converter
            let pcmBuffer = try converter.convert(sampleBuffer: sampleBuffer)
            
            Task { @MainActor in
                guard self.sessionGate.accepts(identity: streamIdentity) else { return }
                self.sampleRate = pcmBuffer.format.sampleRate
                self.channelCount = Int(pcmBuffer.format.channelCount)
                self.lastBufferFrameCapacity = Int(pcmBuffer.frameLength)
            }
            
            calculateMetrics(from: pcmBuffer, streamIdentity: streamIdentity)
            
            let time = AVAudioTime(hostTime: mach_absolute_time())
            
            // Broadcast buffer to active delegates
            guard sessionGate.accepts(identity: streamIdentity) else { return }
            let activeDelegates: [any SystemAudioBufferDelegate] = delegateQueue.sync {
                delegates.compactMap { $0.value as? (any SystemAudioBufferDelegate) }
            }

            for delegate in activeDelegates {
                delegate.systemAudioCaptureService(self, didReceive: pcmBuffer, at: time)
            }
        } catch {
            PrivacySafeLogger.audioFailure(
                operation: .screenCaptureConversion,
                code: (error as NSError).code
            )
            Task { @MainActor in
                guard self.sessionGate.accepts(identity: streamIdentity) else { return }
                let errorMessage = "System audio conversion failed. Stop and restart listening."
                self.lastError = errorMessage
                self.notifyFailure(error: NSError(
                    domain: "ScreenCaptureKitSystemAudioCaptureService",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                ))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream)
        guard case .unexpected = sessionGate.didStop(identity: identity) else { return }
        PrivacySafeLogger.audioFailure(
            operation: .screenCaptureCompactStream,
            code: (error as NSError).code
        )
        _ = operationQueue.enqueue { [weak self] in
            guard let self else { return }
            SystemAudioUnexpectedStopCleanupPolicy.applyIfCurrent(
                stoppedIdentity: identity,
                currentIdentity: self.stream.map(ObjectIdentifier.init)
            ) {
                self.stream = nil
                self.streamToken = nil
                self.sampleWatchdogTask?.cancel()
                self.sampleWatchdogTask = nil
                self.isCapturing = false
                self.rmsLevel = 0
                self.decibels = -90
                self.hasReceivedSamplesSinceStart = false
                let publicError = NSError(
                    domain: "ScreenCaptureKitSystemAudioCaptureService",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "System audio capture stopped unexpectedly. Stop and restart listening."]
                )
                self.lastError = publicError.localizedDescription
                self.notifyFailure(error: publicError)
            }
        }
    }

    private func calculateMetrics(
        from buffer: AVAudioPCMBuffer,
        streamIdentity: ObjectIdentifier
    ) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(channelCount * frameLength))
        let db = 20 * log10(max(Double(rms), 0.000_001))

        let now = Date()

        Task { @MainActor in
            guard self.sessionGate.accepts(identity: streamIdentity) else { return }
            // Throttle level meter updates to 25 FPS (0.04s)
            guard now.timeIntervalSince(self.lastUpdateTimestamp) >= 0.04 else { return }
            self.lastUpdateTimestamp = now

            let alpha = 0.3
            self.rmsLevel = alpha * Double(rms) + (1.0 - alpha) * self.rmsLevel
            self.decibels = alpha * max(db, -90) + (1.0 - alpha) * self.decibels
        }
    }

    private func notifyFailure(error: Error) {
        let activeDelegates: [any SystemAudioBufferDelegate] = delegateQueue.sync {
            delegates.compactMap { $0.value as? (any SystemAudioBufferDelegate) }
        }
        for delegate in activeDelegates {
            delegate.systemAudioCaptureService(self, didFailWithError: error)
        }
    }
}
