import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Actual AppState entry points with independent synthetic capabilities. The
/// Live observer throws before any ASR, microphone or native capture can start.
@MainActor
struct ManualLiveResourceBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func practiceReplacementDuringLivePreparationCannotReacquireAudio() async throws {
        let fixture = try await ManualLiveFixture()
        let practice = fixture.app.practiceController
        practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
            language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        fixture.prepareLive()
        var reentered = false
        let observation = practice.runUpdates.sink { run in
            guard !reentered, run?.phase == .paused else { return }
            reentered = true
            practice.start(kind: .generalKnowledge, question: "Synthetic replacement must wait.",
                language: "en", criteria: ["Wait"], maxFollowUps: 0)
        }
        defer { observation.cancel() }
        do {
            fixture.app.startListening(mode: .microphone)
            let startup = fixture.app.captureStartupTask
            await startup?.value
            #expect(reentered)
            #expect(practice.run?.phase == .paused)
            #expect(practice.run?.task.question == "Explain bounded retries.")
            #expect(practice.error != nil)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func manualReplacementDuringLivePreparationKeepsLatestIntent(replaceDuringLoading: Bool) async throws {
        let fixture = try await ManualLiveFixture()
        let practice = fixture.app.practiceController
        practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
            language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        fixture.prepareLive()
        var manualStartup: Task<Void, Never>?
        var liveStartup: Task<Void, Never>?
        var reentered = false
        func replace() {
            guard !reentered else { return }
            reentered = true
            liveStartup = fixture.app.captureStartupTask
            fixture.app.startManualCapture()
            manualStartup = fixture.app.manualCaptureController.startupTask
        }
        let observation: AnyCancellable
        if replaceDuringLoading {
            observation = fixture.app.actionLoadingStatesUpdates.dropFirst().sink { values in
                if values[ActionID.startInterview] == true { replace() }
            }
        } else {
            observation = practice.runUpdates.sink { run in
                if run?.phase == .paused { replace() }
            }
        }
        defer { observation.cancel() }
        do {
            fixture.app.startListening(mode: .microphone)
            let submitted = fixture.app.captureStartupTask
            await submitted?.value
            await liveStartup?.value
            #expect(reentered)
            #expect(liveStartup != nil, "Live must retain its startup before a synchronous observer can replace it.")
            let manual = try #require(manualStartup)
            await manual.value
            #expect(fixture.liveDispatches == 0, "An older Live tail cannot acquire audio after a later Manual intent.")
            #expect(fixture.manualAudioStarts == 1)
            #expect(fixture.app.manualCaptureState == .recording)
            #expect(!fixture.app.isActionLoading(ActionID.startInterview))
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func startupIsRetainedBeforeManualLoadingPublication(replaceWithLive: Bool) async throws {
        let fixture = try await ManualLiveFixture()
        var capturedStartup: Task<Void, Never>?
        var liveStartup: Task<Void, Never>?
        var reentered = false
        let observation = fixture.app.actionLoadingStatesUpdates.dropFirst().sink { values in
            guard !reentered, values[ActionID.manualRecord] == true else { return }
            reentered = true
            capturedStartup = fixture.app.manualCaptureController.startupTask
            #expect(capturedStartup != nil,
                "Cancellation from loading feedback must see the retained handoff waiter.")
            if replaceWithLive {
                fixture.prepareLive()
                fixture.app.startListening(mode: .microphone)
                liveStartup = fixture.app.captureStartupTask
            } else {
                fixture.app.cancelManualCapture()
            }
        }
        defer { observation.cancel() }
        do {
            fixture.app.startManualCapture()
            #expect(reentered)
            #expect(fixture.app.manualCaptureState == .idle)
            await capturedStartup?.value
            await liveStartup?.value
            #expect(fixture.manualAudioStarts == 0)
            #expect(fixture.liveDispatches == (replaceWithLive ? 1 : 0))
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func practicePauseObserverCanReplaceManualWithLiveWithoutAnOldStop() async throws {
        let fixture = try await ManualLiveFixture()
        let practice = fixture.app.practiceController
        practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
            language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        var liveStartup: Task<Void, Never>?
        var reentered = false
        let observation = practice.runUpdates.sink { run in
            guard !reentered, run?.phase == .paused else { return }
            reentered = true
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            liveStartup = fixture.app.captureStartupTask
        }
        defer { observation.cancel() }
        do {
            fixture.app.startManualCapture()
            #expect(reentered)
            #expect(fixture.app.manualCaptureController.startupTask == nil)
            #expect(fixture.app.manualCaptureState == .idle)
            let currentLive = try #require(liveStartup)
            await currentLive.value
            #expect(fixture.liveDispatches == 1)
            #expect(fixture.manualAudioStarts == 0)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func liveReentryRevokesManualBeforeItsStartupTaskIsRegistered() async throws {
        let fixture = try await ManualLiveFixture()
        var liveStartup: Task<Void, Never>?
        var reentered = false
        let observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
            guard !reentered, state == .waitingForPermission else { return }
            reentered = true
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            liveStartup = fixture.app.captureStartupTask
        }
        defer { observation.cancel() }
        do {
            fixture.app.startManualCapture()
            #expect(reentered)
            #expect(fixture.app.manualCaptureController.startupTask == nil)
            #expect(fixture.app.manualCaptureState == .idle)
            let currentLive = try #require(liveStartup)
            await currentLive.value
            #expect(fixture.liveDispatches == 1,
                "The old Manual tail must not stop the replacement Live intent.")
            #expect(fixture.manualAudioStarts == 0)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func manualAuthorizationUpdatesTheAuthoritativePermissionSnapshot() async throws {
        let fixture = try await ManualLiveFixture(initialPermissionMissing: true)
        do {
            #expect(fixture.app.permissionSnapshot.microphone == .notDetermined)
            #expect(fixture.app.permissionSnapshot.speechRecognition == .notDetermined)
            fixture.app.startManualCapture()
            let startup = try fixture.captureStartup()
            await startup.value
            try Task.checkCancellation()
            #expect(fixture.app.manualCaptureState == .recording)
            #expect(fixture.permissions.snapshot().microphone == .granted)
            #expect(fixture.permissions.snapshot().speechRecognition == .granted)
            #expect(fixture.app.permissionSnapshot.microphone == .granted,
                "Manual authorization must refresh the sole observed snapshot.")
            #expect(fixture.app.permissionSnapshot.speechRecognition == .granted)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func liveStartupInvalidatesAndJoinsPendingManualAuthorization() async throws {
        let fixture = try await ManualLiveFixture(blockPermission: true)
        do {
            fixture.app.startManualCapture()
            let manualStartup = try fixture.captureStartup()
            try await fixture.waitFor(.permissionEntered)
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            let liveStartup = try fixture.captureLiveStartup()
            // Green emits synchronous cancellation before the held request
            // returns. Red dispatches Live first; release follows the assertion.
            let first = try await fixture.nextEvent()
            #expect(first == .manualAudioCancelled,
                "Live must revoke the pending Manual owner before awaiting it.")
            #expect(fixture.liveDispatches == 0,
                "The new backend cannot acquire resources while Manual still owns permission startup.")
            await fixture.releaseAll()
            await manualStartup.value
            await liveStartup.value
            try Task.checkCancellation()
            #expect(fixture.manualAudioStarts == 0)
            #expect(fixture.liveDispatches == 1)
            #expect(fixture.app.manualCaptureState == .idle)
            #expect(fixture.app.manualCaptureTranscript.isEmpty)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func liveStartupJoinsManualFinalizationAndRejectsItsLateTranscript() async throws {
        let fixture = try await ManualLiveFixture(blockFinalizer: true)
        do {
            fixture.app.startManualCapture()
            let manualStartup = try fixture.captureStartup()
            await manualStartup.value
            fixture.app.stopAndTranscribeManualCapture()
            let finalizer = try fixture.captureFinalizer()
            try await fixture.waitFor(.finalizerEntered)
            fixture.prepareLive()
            fixture.app.startListening(mode: .microphone)
            let liveStartup = try fixture.captureLiveStartup()
            let first = try await fixture.nextEvent()
            #expect(first == .manualAudioCancelled)
            #expect(fixture.liveDispatches == 0,
                "Live cannot acquire resources until the exact old finalizer exits.")
            await fixture.releaseAll()
            await finalizer.value
            await liveStartup.value
            try Task.checkCancellation()
            #expect(fixture.liveDispatches == 1)
            #expect(fixture.app.manualCaptureState == .idle)
            #expect(fixture.app.manualCaptureTranscript.isEmpty,
                "The revoked finalizer cannot restore a transcript in the Live workspace.")
            #expect(fixture.app.manualCaptureSuggestion == nil)
            #expect(!fixture.app.isActionLoading(ActionID.manualStopTranscribe))
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }
}

private enum ManualLiveEvent: Sendable, Equatable {
    case permissionEntered, permissionExited, finalizerEntered, finalizerExited
    case manualAudioStarted, manualAudioCancelled, liveDispatched
}
private enum ManualLiveFailure: Error { case backendMustNotStart }
private actor ManualLiveGate {
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
private final class ManualLivePermissions: PermissionService {
    private struct State { var microphone: PermissionState; var speech: PermissionState }
    private let lock = NSLock()
    private var state: State
    let gate: ManualLiveGate
    let events: AsyncStream<ManualLiveEvent>.Continuation
    init(missing: Bool, gate: ManualLiveGate, events: AsyncStream<ManualLiveEvent>.Continuation) {
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
private actor ManualLiveStream: SystemAudioCaptureStream {
    @MainActor func startCapture() async throws { }
    @MainActor func stopCapture() async throws { }
}
@MainActor
private final class ManualLiveFixture {
    let database: AppDatabase
    let suite: String
    let defaults: UserDefaults
    let events = AsyncStream<ManualLiveEvent>.makeStream()
    let permissionGate: ManualLiveGate
    let finalizerGate: ManualLiveGate
    let permissions: ManualLivePermissions
    private(set) var app: AppState!
    private(set) var manualAudioStarts = 0
    private(set) var liveDispatches = 0
    private var owned: [Task<Void, Never>] = []
    private let trace = TestEventWaitTrace(label: "manual-live.actual-app-boundary")
    init(blockPermission: Bool = false, blockFinalizer: Bool = false,
        initialPermissionMissing: Bool = false) async throws {
        let preparedDatabase = try await TestSupport.makeInMemoryDatabase()
        database = preparedDatabase
        suite = "com.langcheng.Hireva.tests.manual-live.\(UUID().uuidString)"
        do { defaults = try #require(UserDefaults(suiteName: suite)) }
        catch { try? preparedDatabase.close(); throw error }
        permissionGate = ManualLiveGate(released: !blockPermission)
        finalizerGate = ManualLiveGate(released: !blockFinalizer)
        permissions = ManualLivePermissions(missing: initialPermissionMissing,
            gate: permissionGate, events: events.continuation)
        var settings = AppSettings.default
        settings.audioCaptureMode = .microphoneOnly
        settings.manualCaptureSource = .microphone
        settings.showTranscriptBeforeSending = true
        settings.autoSendAfterTranscription = false
        settings.saveTranscriptsLocally = false
        do { try SettingsRepository(database: database).saveSettings(settings) }
        catch {
            defaults.removePersistentDomain(forName: suite)
            try? preparedDatabase.close()
            throw error
        }
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
            cancel: { [events] in events.continuation.yield(.manualAudioCancelled); return nil },
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
            systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService(streamFactory: { ManualLiveStream() }),
            dialogueDefaults: defaults, manualCaptureCapabilities: .init(audio: audio, speech: speech))
        app.automaticContextReadiness = .ready
        app.localLLMProviderOverride = HermeticUnavailableLocalProvider()
        app.setSelectedASRProvider(.appleSpeech)
        app.liveASRWillStart = { [weak self] provider, mode in
            guard let self else { throw CancellationError() }
            #expect(provider == .appleSpeech)
            #expect(mode == .systemAudioOnly)
            self.liveDispatches += 1; self.events.continuation.yield(.liveDispatched)
            throw ManualLiveFailure.backendMustNotStart
        }
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
    func nextEvent() async throws -> ManualLiveEvent {
        try await trace.nextEvent(in: events.stream, event: "capability")
    }
    func waitFor(_ expected: ManualLiveEvent) async throws {
        while try await nextEvent() != expected { }
    }
    func releaseAll() async {
        await permissionGate.release(); await finalizerGate.release()
    }
    func cleanup() async throws {
        await releaseAll() // No await of an owned task may precede fixture latch release.
        app.cancelManualCapture()
        owned.forEach { $0.cancel() }
        for task in owned { await task.value }
        #expect(await app.shutdownResources())
        events.continuation.finish()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }
}
