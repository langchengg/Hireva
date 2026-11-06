import AVFoundation
import Combine
import Foundation
import Testing
import os
@testable import Hireva

/// Actual registered delegate callbacks, provider bridge and App lastError sink.
/// The capture override suppresses microphones; the optional native stream is synthetic.
@MainActor
struct ParakeetCombinedChannelBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: CombinedFailedChannel.allCases)
    fileprivate func failedChannelRejectsPCMAndLateFinalWhileHealthyChannelContinues(first: CombinedFailedChannel) async throws {
        let fixture = CombinedChannelFixture()
        do {
            let stream = try await fixture.provider.startTranscription(config: fixture.config("source-survivor"))
            let consumer = fixture.consume(stream)
            let callbacks = try #require(fixture.delegates.last)
            callbacks.fail(first, capture: fixture.capture)
            callbacks.append(first, buffer: fixture.buffer)
            callbacks.append(first.other, buffer: fixture.buffer)
            #expect(fixture.runtime.appendCount(first) == 0,
                "Failed-channel admission closes on the callback executor before MainActor cleanup.")
            #expect(fixture.runtime.appendCount(first.other) == 1)
            fixture.runtime.emit(first, id: "late-failed-source")
            fixture.runtime.emit(first.other, id: "healthy-source")
            fixture.runtime.finish()
            switch await consumer.result {
            case .success(let values):
                #expect(values.count == 1)
                #expect(values.first?.id == "healthy-source")
                #expect(values.first?.source == first.other.source)
                #expect(values.first?.speaker == .unknown)
            case .failure: Issue.record("One failed channel ended its healthy Combined peer.")
            }
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: CombinedFailedChannel.allCases)
    fileprivate func bothSourceFailureOrdersCloseAllAdmissionAndKeepTheFirstCause(first: CombinedFailedChannel) async throws {
        let fixture = CombinedChannelFixture()
        do {
            let stream = try await fixture.provider.startTranscription(config: fixture.config("both-failed"))
            let consumer = fixture.consume(stream)
            let callbacks = try #require(fixture.delegates.last)
            callbacks.fail(first, capture: fixture.capture)
            callbacks.fail(first.other, capture: fixture.capture)
            callbacks.append(.microphone, buffer: fixture.buffer)
            callbacks.append(.system, buffer: fixture.buffer)
            #expect(fixture.runtime.appendCount(.microphone) == 0)
            #expect(fixture.runtime.appendCount(.system) == 0)
            fixture.runtime.emit(.microphone, id: "late-microphone")
            fixture.runtime.emit(.system, id: "late-system")
            fixture.runtime.finish()
            switch await consumer.result {
            case .success: Issue.record("Both failed channels returned normal EOF instead of their source cause.")
            case .failure(let error):
                #expect(error as? CombinedChannelFailure == first.failure)
            }
            await fixture.provider.stopTranscription()
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            #expect(!fixture.runtime.running)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func capturedOldDelegatesCannotAppendOrFailAReplacementRound() async throws {
        let fixture = CombinedChannelFixture()
        do {
            let first = try await fixture.provider.startTranscription(config: fixture.config("retired-source"))
            let oldConsumer = fixture.consume(first)
            let old = try #require(fixture.delegates.last)
            await fixture.provider.stopTranscription()
            _ = await oldConsumer.result
            let next = try await fixture.provider.startTranscription(config: fixture.config("replacement-source"))
            let consumer = fixture.consume(next)
            let current = try #require(fixture.delegates.last)
            old.append(.microphone, buffer: fixture.buffer)
            old.append(.system, buffer: fixture.buffer)
            old.fail(.microphone, capture: fixture.capture)
            old.fail(.system, capture: fixture.capture)
            current.append(.microphone, buffer: fixture.buffer)
            current.append(.system, buffer: fixture.buffer)
            #expect(fixture.runtime.appendCount(.microphone) == 1)
            #expect(fixture.runtime.appendCount(.system) == 1)
            fixture.runtime.emit(.microphone, id: "replacement-final")
            fixture.runtime.finish()
            switch await consumer.result {
            case .success(let values):
                #expect(values.map(\.sessionID) == ["replacement-source"])
                #expect(values.first?.speaker == .unknown)
            case .failure: Issue.record("A captured old delegate failed the replacement epoch.")
            }
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitStopJoinsTheAlreadyFailingSystemsCapturedNativeStop() async throws {
        let fixture = CombinedChannelFixture(nativeSystem: true,
            providerOwnsNativeStop: true, releaseOnExplicitNativeJoin: true)
        var stop: Task<Void, Never>?
        do {
            let stream = try await fixture.provider.startTranscription(config: fixture.config("degraded-stop"))
            _ = fixture.consume(stream)
            fixture.armDegradedNativeJoin()
            fixture.capture.receiveStreamFailure(CombinedChannelFailure.system, from: fixture.native)
            try await fixture.waitFor(.nativeStopEntered)
            #expect(fixture.provider.hasHealthyCaptureSource)
            #expect(fixture.runtime.running)
            #expect(!fixture.native.stopExited)
            let callbacks = try #require(fixture.delegates.last)
            callbacks.append(.system, buffer: fixture.buffer)
            callbacks.append(.microphone, buffer: fixture.buffer)
            #expect(fixture.runtime.appendCount(.system) == 0)
            #expect(fixture.runtime.appendCount(.microphone) == 1)

            let task = Task { @MainActor in
                await fixture.provider.stopTranscription()
                fixture.events.continuation.yield(.providerStopReturned)
            }
            stop = task
            let next = try await fixture.nextControlEvent()
            #expect(next == .explicitCapturedStopJoined,
                "Explicit stop must join the captured native stop already owned by the failed source.")
            // Release our own gate even if the assertion fails, then join every
            // saved worker. The red contract cannot hang behind its own latch.
            fixture.native.release()
            await task.value
            #expect(fixture.native.stopExited)
            #expect(fixture.native.stopCalls == 1)
            #expect(!fixture.runtime.running)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
            #expect(fixture.provider.captureCleanupFailure == nil)
            callbacks.append(.microphone, buffer: fixture.buffer)
            #expect(fixture.runtime.appendCount(.microphone) == 1)
            try await fixture.cleanup()
        } catch {
            fixture.native.release()
            stop?.cancel()
            await stop?.value
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualAppSystemErrorSinkKeepsHealthyCombinedRuntimeNonBlocking() async throws {
        let fixture = CombinedChannelFixture(nativeSystem: true)
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.combined-partial.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var app: AppState?
        var startup: Task<Void, Never>?
        var transcription: Task<Void, Never>?
        do {
            var settings = AppSettings.default
            settings.audioCaptureMode = .microphoneAndSystem
            settings.saveTranscriptsLocally = false
            try SettingsRepository(database: database).saveSettings(settings)
            let permissions = CombinedGrantedPermissions()
            let systemPermissions = SystemAudioPermissionController(permissions: permissions,
                initialSnapshot: permissions.snapshot(), probe: {
                    .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                        streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
                }, stopProbe: {})
            let actual = AppState(database: database, permissionService: permissions,
                systemAudioPermissions: systemPermissions,
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                systemAudioCaptureService: fixture.capture, dialogueDefaults: defaults)
            app = actual
            let session = try actual.sessionRepository.createSession(mode: .microphone)
            let stream = try await fixture.provider.startTranscription(config: fixture.config(session.id))
            actual.currentSession = session
            actual.activeASRProviderRuntime = fixture.provider
            actual.markActiveASRProvider(.localParakeet)
            actual.markSystemAudioCaptureRuntimeOwnedForTesting(true)
            actual.liveState = .listening
            actual.currentCaptureRuntimeState = .listening
            actual.consumeParakeetSegments(stream, provider: fixture.provider,
                sessionID: session.id, startupID: UUID())
            transcription = actual.transcriptionTask
            startup = actual.captureStartupTask
            actual.systemAudioErrorDidObserve = { [events = fixture.events] error in
                if error?.contains("Synthetic system source failed") == true {
                    events.continuation.yield(.appObservedSystemError)
                }
            }
            fixture.native.holdStop()
            fixture.capture.receiveStreamFailure(CombinedChannelFailure.system, from: fixture.native)
            try await fixture.waitFor(.appObservedSystemError)
            #expect(actual.lastSystemAudioError != nil,
                "A failed source remains visible even while its selected peer runs.")
            #expect(actual.liveState == .listening)
            #expect(actual.currentCaptureRuntimeState == .listening,
                "The real lastError sink must not label healthy Combined capture as fully failed.")
            #expect(fixture.runtime.running)
            #expect(actual.activeASRProviderRuntime === fixture.provider)
            #expect(actual.latestActionFeedback(for: ActionID.startInterview)?.kind == .warning,
                "Source degradation needs a visible non-blocking explanation.")
            actual.systemAudioErrorDidObserve = nil
            fixture.native.release()
            #expect(await actual.shutdownResources())
            await startup?.value
            await transcription?.value
            try await fixture.cleanup()
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        } catch {
            fixture.native.release()
            app?.systemAudioErrorDidObserve = nil
            _ = await app?.shutdownResources()
            startup?.cancel(); transcription?.cancel()
            await startup?.value; await transcription?.value
            try? await fixture.cleanup()
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
    }
}

private enum CombinedFailedChannel: String, CaseIterable, Sendable {
    case microphone, system
    var other: Self { self == .microphone ? .system : .microphone }
    var source: AudioSourceType { self == .microphone ? .microphone : .systemAudio }
    var failure: CombinedChannelFailure { self == .microphone ? .microphone : .system }
}
private enum CombinedChannelFailure: Error, LocalizedError, Equatable {
    case microphone, system
    var errorDescription: String? {
        self == .microphone ? "Synthetic microphone source failed" : "Synthetic system source failed"
    }
}
private enum CombinedChannelEvent: Sendable, Equatable {
    case appObservedSystemError, nativeStopEntered, explicitCapturedStopJoined, providerStopReturned
}
@MainActor
private struct CombinedCapturedDelegates {
    let microphone: any AudioEngineBufferDelegate
    let system: any SystemAudioBufferDelegate
    let capture: ScreenCaptureKitSystemAudioCaptureService
    func append(_ source: CombinedFailedChannel, buffer: AVAudioPCMBuffer) {
        let time = AVAudioTime(sampleTime: 0, atRate: 16000)
        if source == .microphone { microphone.audioEngineManager(.shared, didReceive: buffer, at: time) }
        else { system.systemAudioCaptureService(capture, didReceive: buffer, at: time) }
    }
    func fail(_ source: CombinedFailedChannel, capture: ScreenCaptureKitSystemAudioCaptureService) {
        if source == .microphone { microphone.audioEngineManager(.shared, didFailWith: source.failure) }
        else { system.systemAudioCaptureService(capture, didFailWithError: source.failure) }
    }
}
@MainActor
private final class CombinedChannelFixture {
    let runtime = CombinedChannelRuntime()
    let native = CombinedChannelNativeStream()
    let capture: ScreenCaptureKitSystemAudioCaptureService
    let buffer: AVAudioPCMBuffer
    let events = AsyncStream<CombinedChannelEvent>.makeStream()
    var delegates: [CombinedCapturedDelegates] = []
    private var consumers: [Task<[TranscriptSegment], Error>] = []
    private let trace = TestEventWaitTrace(label: "combined.real-callback-boundary")
    private let nativeSystem: Bool
    private let providerOwnsNativeStop: Bool
    private let nativeJoinObserver: CombinedNativeJoinObserver
    lazy var provider = LocalParakeetASRProvider(modelManager: CombinedChannelInstalledModel(),
        runtimeClient: runtime, systemAudioCaptureService: capture,
        startOwnedCapture: { [weak self] mode, onOwned in
            guard let self else { throw CancellationError() }
            #expect(mode == .microphoneAndSystem)
            if self.nativeSystem {
                let receiver = try #require(self.delegates.last)
                self.capture.register(receiver.system)
                let owned = self.capture.beginSystemAudioCapture(onOwned: onOwned)
                try await self.capture.finishStartingSystemAudioCapture(
                    capturedStart: owned.startup, capturedReceipt: owned.receipt)
            }
        }, stopCapture: legacyStopOverride, captureDelegatesObserver: { [weak self] microphone, system in
            guard let self else { return }
            self.delegates.append(.init(microphone: microphone, system: system, capture: self.capture))
        })
    private var legacyStopOverride: (() -> Void)? {
        guard !providerOwnsNativeStop else { return nil }
        return { [weak self] in
            guard let self else { return }
            if self.nativeSystem {
                if let receiver = self.delegates.last { self.capture.unregister(receiver.system) }
                self.capture.stopSystemAudioCapture()
            }
        }
    }
    init(nativeSystem: Bool = false, providerOwnsNativeStop: Bool = false,
        releaseOnExplicitNativeJoin: Bool = false) {
        self.nativeSystem = nativeSystem
        self.providerOwnsNativeStop = providerOwnsNativeStop
        let stream = native
        let ownedEvents = events
        let joins = CombinedNativeJoinObserver(stream: stream, events: ownedEvents,
            releaseOnExplicitJoin: releaseOnExplicitNativeJoin)
        nativeJoinObserver = joins
        if releaseOnExplicitNativeJoin {
            stream.onStopEntered = { ownedEvents.continuation.yield(.nativeStopEntered) }
        }
        capture = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { stream },
            onFinishStoppingEntered: { joins.entered() })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        for frame in 0..<8 { buffer.floatChannelData![0][frame] = 0.025 }
    }
    func armDegradedNativeJoin() {
        native.holdStop()
        nativeJoinObserver.arm()
    }
    func config(_ session: String) -> ASRConfig { .init(sessionID: session, captureMode: .microphoneAndSystem) }
    func consume(_ stream: AsyncThrowingStream<TranscriptSegment, Error>) -> Task<[TranscriptSegment], Error> {
        let task = Task {
            var values: [TranscriptSegment] = []
            for try await value in stream { values.append(value) }
            return values
        }
        consumers.append(task)
        return task
    }
    func waitFor(_ event: CombinedChannelEvent) async throws {
        while try await trace.nextEvent(in: events.stream, event: "app-observation") != event { }
    }
    func nextControlEvent() async throws -> CombinedChannelEvent {
        try await trace.nextEvent(in: events.stream, event: "native-stop-order")
    }
    func cleanup() async throws {
        native.release()
        runtime.finish()
        consumers.forEach { $0.cancel() }
        await provider.stopTranscription()
        for task in consumers { _ = await task.result }
        try await capture.finishStoppingSystemAudioCapture()
        events.continuation.finish()
    }
}
@MainActor
private final class CombinedChannelNativeStream: SystemAudioCaptureStream {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = true
    var onStopEntered: (@MainActor () -> Void)?
    private(set) var stopCalls = 0
    private(set) var stopExited = false
    func holdStop() {
        precondition(stopCalls == 0 && continuations.isEmpty)
        released = false
    }
    func startCapture() async throws { }
    func stopCapture() async throws {
        stopCalls += 1
        onStopEntered?()
        if !released { await withCheckedContinuation { continuations.append($0) } }
        stopExited = true
    }
    func release() {
        released = true
        let owned = continuations; continuations.removeAll()
        owned.forEach { $0.resume() }
    }
}
@MainActor
private final class CombinedNativeJoinObserver {
    let stream: CombinedChannelNativeStream
    let events: AsyncStream<CombinedChannelEvent>.Continuation
    let releaseOnExplicitJoin: Bool
    private var joins = 0
    private var armed = false
    init(stream: CombinedChannelNativeStream,
        events: (stream: AsyncStream<CombinedChannelEvent>, continuation: AsyncStream<CombinedChannelEvent>.Continuation),
        releaseOnExplicitJoin: Bool) {
        self.stream = stream
        self.events = events.continuation
        self.releaseOnExplicitJoin = releaseOnExplicitJoin
    }
    func arm() {
        joins = 0
        armed = true
    }
    func entered() {
        guard armed else { return }
        joins += 1
        guard releaseOnExplicitJoin, joins == 2 else { return }
        events.yield(.explicitCapturedStopJoined)
        stream.release()
    }
}
@MainActor
private final class CombinedChannelRuntime: ParakeetRuntimeClient {
    private(set) var running = false
    private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
    private nonisolated let appends = OSAllocatedUnfairLock(initialState: [String: Int]())
    func isRuntimeAvailable() async -> Bool { true }
    func probeModel(at modelDirectory: URL) async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
        continuation = pair.continuation; running = true
        appends.withLock { $0.removeAll() }
        return pair.stream
    }
    func emit(_ source: CombinedFailedChannel, id: String) {
        continuation?.yield(.init(segmentId: id, text: "Synthetic selected-source speech.", isFinal: true,
            startTime: nil, endTime: nil, audioSource: source.source.rawValue))
    }
    func finish() { continuation?.finish() }
    func stop() async { continuation?.finish(); continuation = nil; running = false }
    nonisolated func appendCount(_ source: CombinedFailedChannel) -> Int {
        appends.withLock { $0[source.rawValue, default: 0] }
    }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        let key = source == .microphone ? CombinedFailedChannel.microphone.rawValue : CombinedFailedChannel.system.rawValue
        appends.withLock { $0[key, default: 0] += 1 }
    }
}
private final class CombinedChannelInstalledModel: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func deleteModel(_ model: LocalModelDescriptor) async throws { }
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-combined-channel-model") }
}
private final class CombinedGrantedPermissions: PermissionService {
    override func snapshot() -> PermissionSnapshot { .init(microphone: .granted, speechRecognition: .granted, screenRecording: .granted, systemAudioCapture: .granted) }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .authorized }
    override func requestMicrophonePermission() async -> MicrophonePermissionState { .authorized }
    override func speechStatus() -> PermissionState { .granted }
    override func requestSpeechRecognition() async -> PermissionState { .granted }
}
