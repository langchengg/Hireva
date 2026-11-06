import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Actual AppState capture policy with synthetic I/O and retained native stop.
@MainActor
struct ManualLiveAdditionalBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func reviewedManualTextSurvivesLiveResourceHandoff() async throws {
        let fixture = try ManualLiveAdditionalFixture()
        do {
            fixture.app.startManualCapture()
            let startup = try fixture.captureStartup()
            await startup.value
            fixture.app.stopAndTranscribeManualCapture()
            let finalizer = try fixture.captureFinalizer()
            await finalizer.value
            try Task.checkCancellation()
            #expect(fixture.app.manualCaptureState == .transcriptReady)
            // Exercise the same writable review field used by the transcript editor.
            let reviewed = "Synthetic question reviewed by the user."
            fixture.app.manualCaptureTranscript = reviewed
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            let live = try fixture.captureLiveStartup()
            #expect(fixture.app.manualCaptureState == .transcriptReady)
            #expect(fixture.app.manualCaptureTranscript == reviewed)
            await live.value
            try Task.checkCancellation()
            #expect(fixture.liveDispatches == 1)
            #expect(fixture.app.manualCaptureState == .transcriptReady)
            #expect(fixture.app.manualCaptureTranscript == reviewed)
            #expect(fixture.app.manualCaptureSuggestion == nil)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func lateManualCleanupFailureBlocksLiveAndLaterRetry() async throws {
        let fixture = try ManualLiveAdditionalFixture(blockCleanup: true, cleanupFails: true)
        do {
            fixture.app.startManualCapture()
            let startup = try fixture.captureStartup()
            await startup.value
            fixture.app.cancelManualCapture()
            try await fixture.waitFor(.cleanupEntered)
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            let live = try fixture.captureLiveStartup()
            #expect(fixture.liveDispatches == 0)
            #expect(fixture.app.manualCaptureController.hasUnreleasedResources)
            await fixture.releaseAll()
            await live.value
            try Task.checkCancellation()
            #expect(fixture.liveDispatches == 0,
                "An awaited failed native stop cannot authorize the new backend.")
            #expect(fixture.app.manualCaptureController.pendingTaskCount == 0,
                "Completed handles may retire while the cleanup failure remains authoritative.")
            #expect(fixture.app.manualCaptureController.hasUnreleasedResources)
            #expect(fixture.app.latestActionFeedback(for: ActionID.startInterview)?.kind == .error)
            fixture.app.startListening(mode: .microphone)
            let rejected = try fixture.captureLiveStartup()
            #expect(rejected.isCancelled && fixture.app.captureStartupID == nil,
                "Failed cleanup revokes admission while the exact startup remains retained until exit.")
            await rejected.value
            #expect(fixture.app.captureStartupTask == nil)
            #expect(fixture.liveDispatches == 0)
            #expect(fixture.app.latestActionFeedback(for: ActionID.startInterview)?.kind == .error)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }
}

private enum ManualLiveAdditionalEvent: Sendable, Equatable {
    case permissionEntered, permissionExited, finalizerEntered, finalizerExited
    case manualAudioStarted, manualAudioCancelled, liveDispatched, cleanupEntered, cleanupExited
}
private enum ManualLiveAdditionalFailure: Error { case backendMustNotStart, nativeCleanupFailed }
private actor ManualLiveAdditionalGate {
    private var released: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []
    init(released: Bool) { self.released = released }
    func wait() async {
        if !released { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() {
        released = true
        let owned = continuations; continuations.removeAll()
        owned.forEach { $0.resume() }
    }
}
private final class ManualLiveAdditionalPermissions: PermissionService {
    private struct State { var microphone: PermissionState; var speech: PermissionState }
    private let lock = NSLock()
    private var state: State
    let gate: ManualLiveAdditionalGate
    let events: AsyncStream<ManualLiveAdditionalEvent>.Continuation
    init(missing: Bool, gate: ManualLiveAdditionalGate, events: AsyncStream<ManualLiveAdditionalEvent>.Continuation) {
        state = .init(microphone: missing ? .notDetermined : .granted,
            speech: missing ? .notDetermined : .granted)
        self.gate = gate; self.events = events
    }
    override func snapshot() -> PermissionSnapshot {
        lock.withLock { .init(microphone: state.microphone, speechRecognition: state.speech,
            screenRecording: .granted, systemAudioCapture: .granted) }
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func checkMicrophonePermission() -> MicrophonePermissionState {
        snapshot().microphone == .granted ? .authorized : .notDetermined
    }
    override func speechStatus() -> PermissionState { snapshot().speechRecognition }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        events.yield(.permissionEntered)
        await gate.wait() // Fixture owns and always releases this deliberately non-cooperative operation.
        lock.withLock { state.microphone = .granted }
        events.yield(.permissionExited)
        return .authorized
    }
    override func requestSpeechRecognition() async -> PermissionState {
        lock.withLock { state.speech = .granted }
        return .granted
    }
}
private actor ManualLiveAdditionalStream: SystemAudioCaptureStream {
    @MainActor func startCapture() async throws { }
    @MainActor func stopCapture() async throws { }
}
@MainActor
private final class ManualLiveAdditionalFixture {
    let database: AppDatabase
    let suite: String
    let defaults: UserDefaults
    let events = AsyncStream<ManualLiveAdditionalEvent>.makeStream()
    let permissionGate: ManualLiveAdditionalGate
    let finalizerGate: ManualLiveAdditionalGate
    let cleanupGate: ManualLiveAdditionalGate
    let cleanupFails: Bool
    private var ownedStop: Task<Void, Error>?
    let permissions: ManualLiveAdditionalPermissions
    private(set) var app: AppState!
    private(set) var manualAudioStarts = 0
    private(set) var liveDispatches = 0
    private var owned: [Task<Void, Never>] = []
    private let trace = TestEventWaitTrace(label: "manual-live.additional-actual-app-boundary")
    init(blockPermission: Bool = false, blockFinalizer: Bool = false,
        initialPermissionMissing: Bool = false, blockCleanup: Bool = false, cleanupFails: Bool = false) throws {
        database = try AppDatabase(inMemory: true)
        suite = "com.langcheng.Hireva.tests.manual-live-additional.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        permissionGate = ManualLiveAdditionalGate(released: !blockPermission)
        finalizerGate = ManualLiveAdditionalGate(released: !blockFinalizer)
        cleanupGate = ManualLiveAdditionalGate(released: !blockCleanup)
        self.cleanupFails = cleanupFails
        permissions = ManualLiveAdditionalPermissions(missing: initialPermissionMissing,
            gate: permissionGate, events: events.continuation)
        var settings = AppSettings.default
        settings.audioCaptureMode = .microphoneOnly
        settings.manualCaptureSource = .microphone
        settings.showTranscriptBeforeSending = true
        settings.autoSendAfterTranscription = false
        settings.saveTranscriptsLocally = false
        try SettingsRepository(database: database).saveSettings(settings)
        let system = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), probe: {
                .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
            }, stopProbe: {})
        let changes = PassthroughSubject<Void, Never>()
        let audio = ManualCaptureCapabilities.Audio(start: { [weak self] _, _, _, _ in
            guard let self else { throw CancellationError() }
            self.manualAudioStarts += 1; self.events.continuation.yield(.manualAudioStarted)
        }, stop: { .init(buffers: [], bufferCount: 0, lastBufferTimestamp: nil, drain: nil) },
            cancel: { [weak self] in
                guard let self else { return nil }
                self.events.continuation.yield(.manualAudioCancelled)
                return self.captureOwnedStop().map { .controlled($0) }
            },
            finishStop: { if let owned = $0 { try await owned.task.value } },
            retryStop: { try await $0.task.value },
            duration: { 0 }, level: { 0 }, decibels: { -90 }, bufferCount: { 0 },
            lastBufferTimestamp: { nil }, changes: changes.eraseToAnyPublisher())
        let speech = ManualCaptureCapabilities.Speech(start: { _, _, _ in }, append: { _ in },
            finalize: { [events, finalizerGate] _ in
                events.continuation.yield(.finalizerEntered)
                await finalizerGate.wait()
                events.continuation.yield(.finalizerExited)
                return "Synthetic late Manual question."
            }, cancel: {}, startOnDevice: { _, _, _ in })
        app = AppState(database: database, permissionService: permissions,
            systemAudioPermissions: system,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService(streamFactory: { ManualLiveAdditionalStream() }),
            dialogueDefaults: defaults, manualCaptureCapabilities: .init(audio: audio, speech: speech))
        app.automaticContextReadiness = .ready
        app.localLLMProviderOverride = HermeticUnavailableLocalProvider()
        app.setSelectedASRProvider(.appleSpeech)
        app.liveASRWillStart = { [weak self] provider, mode in
            guard let self else { throw CancellationError() }
            #expect(provider == .appleSpeech)
            #expect(mode == .systemAudioOnly)
            self.liveDispatches += 1; self.events.continuation.yield(.liveDispatched)
            throw ManualLiveAdditionalFailure.backendMustNotStart
        }
    }
    private func captureOwnedStop() -> Task<Void, Error>? {
        guard cleanupFails else { return nil }
        if let ownedStop { return ownedStop }
        let events = self.events, gate = cleanupGate
        let task = Task<Void, Error> { @MainActor in
            events.continuation.yield(.cleanupEntered)
            await gate.wait()
            events.continuation.yield(.cleanupExited)
            throw ManualLiveAdditionalFailure.nativeCleanupFailed
        }
        ownedStop = task
        return task
    }
    func captureStartup() throws -> Task<Void, Never> {
        let task = try #require(app.manualCaptureController.startupTask)
        owned.append(task); return task
    }
    func captureFinalizer() throws -> Task<Void, Never> {
        let task = try #require(app.manualCaptureController.finalizationTask)
        owned.append(task); return task
    }
    func captureLiveStartup() throws -> Task<Void, Never> {
        let task = try #require(app.captureStartupTask)
        owned.append(task); return task
    }
    func prepareLive() {
        var settings = app.settings; settings.audioCaptureMode = .systemAudioOnly
        app.saveSettings(settings)
    }
    func nextEvent() async throws -> ManualLiveAdditionalEvent {
        try await trace.nextEvent(in: events.stream, event: "capability")
    }
    func waitFor(_ expected: ManualLiveAdditionalEvent) async throws {
        while try await nextEvent() != expected { }
    }
    func releaseAll() async {
        await permissionGate.release(); await finalizerGate.release(); await cleanupGate.release()
    }
    func cleanup() async throws {
        await releaseAll() // No await of an owned task may precede fixture latch release.
        app.cancelManualCapture()
        owned.forEach { $0.cancel() }
        for task in owned { await task.value }
        #expect(await app.shutdownResources() == !cleanupFails)
        if let ownedStop { do { try await ownedStop.value } catch { } }
        events.continuation.finish()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }
}
