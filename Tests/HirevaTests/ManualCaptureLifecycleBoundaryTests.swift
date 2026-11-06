import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Calls the existing AppState recording/stop/shutdown path through an injected
/// I/O boundary. All permission/recognizer/device work is synthetic except the
/// fourth test's real bounded recorder, whose SCK stream is a separate fake.
@Suite @MainActor
struct ManualCaptureLifecycleBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func practiceStartRejectsAnOwnedManualCapture(blockPermissions: Bool) async throws {
        let fixture = try ManualLifecycleFixture(blockPermissions: blockPermissions)
        do {
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            if blockPermissions { try await fixture.waitFor(.permissionRequested) }
            else { try await fixture.waitForOwnedExit("startup") }
            let practice = fixture.app.practiceController
            practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
            #expect(practice.run == nil, "Manual still owns its permission or recording epoch.")
            #expect(practice.error != nil)
            #expect(fixture.app.manualCaptureState == (blockPermissions ? .waitingForPermission : .recording))
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func manualEntryReservesAdmissionBeforePausingPractice() async throws {
        let fixture = try ManualLifecycleFixture()
        let practice = fixture.app.practiceController
        practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
            language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        var reentered = false
        let observation = practice.runUpdates.sink { run in
            guard !reentered, run?.phase == .paused else { return }
            reentered = true
            practice.start(kind: .generalKnowledge, question: "Synthetic replacement must wait.",
                language: "en", criteria: ["Wait"], maxFollowUps: 0)
        }
        defer { observation.cancel() }
        do {
            fixture.app.startManualCapture()
            #expect(reentered)
            #expect(practice.run?.phase == .paused)
            #expect(practice.run?.task.question == "Explain bounded retries.")
            try fixture.captureOwnedOperation("startup")
            try await fixture.waitForOwnedExit("startup")
            #expect(fixture.audioStarts.count == 1)
            try await fixture.cleanup()
        } catch {
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func manualStartupWaitsForPracticeAudioProducerExit() async throws {
        let fixture = try ManualLifecycleFixture()
        let stopGate = ManualLifecycleGate(open: false)
        let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let provider = ManualPracticeHeldASR(stopGate: stopGate, stopped: stopped.continuation)
        let d = fixture.app.practiceController.dependencies
        // Reuse the actual application admission policy; replace only device I/O.
        let practice = PracticeController(dependencies: .init(repository: d.repository,
            sessions: d.sessions, questions: d.questions, contexts: d.contexts,
            persistenceConsent: d.persistenceConsent, context: d.context,
            evaluationConfiguration: d.evaluationConfiguration, selectedASRProvider: { .localParakeet },
            isLiveCaptureActive: d.isLiveCaptureActive, prepareForPractice: d.prepareForPractice,
            requestAudioPermissions: { _ in }, makeAudioProvider: { _ in provider },
            historyDidChange: d.historyDidChange, delayProvider: d.delayProvider))
        fixture.app.practiceController = practice
        let recording = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let observation = practice.$recording.sink { value in
            if value { recording.continuation.yield(()); recording.continuation.finish() }
        }
        defer { observation.cancel(); recording.continuation.finish(); stopped.continuation.finish() }
        do {
            practice.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
            practice.beginAnswer()
            practice.startMicrophone() // Injected provider; no native microphone or permissions.
            _ = try await TestEventWaitTrace(label: "manual-practice.recording")
                .nextEvent(in: recording.stream, event: "synthetic.recording")
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            #expect(practice.run?.phase == .paused)
            // Also release the old implementation on RED, so the test never
            // leaves a live synthetic stream or an unowned waiter behind.
            practice.stopMicrophone()
            _ = try await TestEventWaitTrace(label: "manual-practice.stop")
                .nextEvent(in: stopped.stream, event: "synthetic.stop.entered")
            #expect(fixture.audioStarts.isEmpty, "New recorder admission must await the captured Practice stop.")
            #expect(fixture.app.manualCaptureState == .waitingForPermission)
            await stopGate.release()
            try await fixture.waitForOwnedExit("startup")
            #expect(fixture.audioStarts.count == 1)
            #expect(!practice.recording && !practice.microphoneStarting)
            try await fixture.cleanup()
        } catch {
            await stopGate.release()
            try? await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualCancelIdlePublicationKeepsLaterManualCaptureRound() async throws {
        let fixture = try ManualLifecycleFixture(blockPermissions: true)
        let owner = fixture.app.manualCaptureController
        var observation: AnyCancellable?
        var restarted = false
        do {
            owner.transcript = "Synthetic old reviewed question."
            owner.state = .transcriptReady
            observation = owner.stateUpdates.dropFirst().sink { state in
                guard !restarted, state == .idle else { return }
                restarted = true
                fixture.app.startManualCapture()
            }
            fixture.app.cancelManualCapture()
            observation?.cancel(); observation = nil
            #expect(restarted && owner.state == .waitingForPermission)
            #expect(fixture.app.isActionLoading(ActionID.manualRecord))
            try fixture.captureOwnedOperation("startup")
            await fixture.releaseAll()
            try await fixture.waitForOwnedExit("startup")
            #expect(owner.state == .recording)
            #expect(fixture.audioStarts.count == 1)
            #expect(fixture.audioStarts.first?.source == .microphone,
                "Only the injected synthetic capability is used; no real microphone is opened.")
        } catch {
            observation?.cancel(); try? await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func startupStatePublicationRetainsOnlyReentrantManualIntent(newRound: Bool) async throws {
        let fixture = try ManualLifecycleFixture(blockPermissions: true)
        let owner = fixture.app.manualCaptureController
        var observation: AnyCancellable?
        var reentered = false
        do {
            observation = owner.stateUpdates.dropFirst().sink { state in
                guard !reentered, state == .waitingForPermission else { return }
                reentered = true
                if newRound {
                    owner.start(configuration: .init(source: .systemAudio, maxDuration: 19,
                        showTranscriptBeforeSending: true, autoSendAfterTranscription: false))
                } else {
                    fixture.app.cancelManualCapture()
                }
            }
            fixture.app.startManualCapture()
            observation?.cancel(); observation = nil
            #expect(reentered)
            if newRound {
                // Same state enum, distinct real recorder round. The old tail
                // cannot relabel the newer source or launch an unowned worker.
                #expect(owner.state == .waitingForPermission)
                #expect(owner.source == ManualCaptureSource.systemAudio.rawValue)
                try fixture.captureOwnedOperation("startup")
                await fixture.releaseAll()
                try await fixture.waitForOwnedExit("startup")
                #expect(owner.state == .recording)
                #expect(fixture.audioStarts.count == 1)
                #expect(fixture.audioStarts.first?.source == .systemAudio)
                #expect(fixture.audioStarts.first?.duration == 19)
            } else {
                #expect(owner.state == .idle)
                #expect(owner.startupTask == nil)
                #expect(!fixture.app.isActionLoading(ActionID.manualRecord))
                #expect(fixture.audioStarts.isEmpty)
                #expect(owner.transcript.isEmpty && owner.suggestion == nil)
            }
        } catch {
            observation?.cancel()
            try? await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownInvalidatesAndJoinsManualPermissionStartup() async throws {
        let fixture = try ManualLifecycleFixture(blockPermissions: true)
        var shutdown: Task<Bool, Never>?
        var returned = false
        do {
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            try await fixture.waitFor(.permissionRequested)
            shutdown = Task { @MainActor in
                let result = await fixture.app.shutdownResources()
                returned = true
                fixture.events.continuation.yield(.shutdownReturned)
                return result
            }
            let first = try await fixture.nextEvent()
            #expect(first == .audioCancelled,
                "Shutdown must close the manual owner before waiting for pending permission startup")
            #expect(!returned, "A non-cooperative permission request remains owned until it returns")
            await fixture.releaseAll()
            _ = await shutdown?.value
            try await fixture.waitForOwnedExit("startup")
            #expect(fixture.audioStarts.isEmpty, "Permission granted after shutdown cannot start a recorder")
            #expect(fixture.app.manualCaptureState != .recording)
            #expect(fixture.app.manualCaptureTranscript.isEmpty)
        } catch {
            try? await fixture.cleanup(shutdown: shutdown)
            throw error
        }
        try await fixture.cleanup(shutdown: shutdown)
    }

    @Test(.timeLimit(.minutes(1)))
    func submissionFreezesRecordingSourceAndMaximumDuration() async throws {
        let fixture = try ManualLifecycleFixture(blockPermissions: true)
        do {
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            try await fixture.waitFor(.permissionRequested)
            var settings = fixture.app.settings
            settings.manualCaptureSource = .systemAudio
            settings.maxManualCaptureSeconds = 90
            fixture.app.saveSettings(settings)
            await fixture.releaseAll()
            try await fixture.waitForOwnedExit("startup")
            #expect(fixture.audioStarts.count == 1)
            #expect(fixture.audioStarts.first?.source == .microphone)
            #expect(fixture.audioStarts.first?.duration == 12,
                "Recorder duration belongs to the submitted round, not later settings")
            fixture.app.stopAndTranscribeManualCapture()
            try fixture.captureOwnedOperation("finalizer")
            try await fixture.waitForOwnedExit("finalizer")
            #expect(fixture.app.manualCaptureSource == ManualCaptureSource.microphone.rawValue,
                "Stopping cannot relabel already-recorded microphone PCM as system audio")
            #expect(fixture.app.manualCaptureState == .transcriptReady)
        } catch {
            try? await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownRejectsLateFinalizerAndRetainsItsExit() async throws {
        let fixture = try ManualLifecycleFixture(blockFinalize: true)
        var shutdown: Task<Bool, Never>?
        var returned = false
        do {
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            try await fixture.waitForOwnedExit("startup")
            fixture.app.stopAndTranscribeManualCapture()
            try fixture.captureOwnedOperation("finalizer")
            try await fixture.waitFor(.finalizeEntered)
            shutdown = Task { @MainActor in
                let result = await fixture.app.shutdownResources()
                returned = true
                fixture.events.continuation.yield(.shutdownReturned)
                return result
            }
            let first = try await fixture.nextEvent()
            #expect(first == .audioCancelled)
            #expect(!returned, "Application cleanup cannot discard a running manual finalizer")
            await fixture.releaseAll()
            _ = await shutdown?.value
            try await fixture.waitForOwnedExit("finalizer")
            #expect(fixture.app.manualCaptureTranscript.isEmpty,
                "A finalize result from the revoked round must not restore transcriptReady after shutdown")
            #expect(fixture.app.manualCaptureState != .transcriptReady)
            #expect(fixture.app.manualCaptureSuggestion == nil)
        } catch {
            try? await fixture.cleanup(shutdown: shutdown)
            throw error
        }
        try await fixture.cleanup(shutdown: shutdown)
    }

    @Test(.timeLimit(.minutes(1)))
    func actualRecorderOverflowFailsManualUIInsteadOfLeavingRecording() async throws {
        let fixture = try ManualLifecycleFixture(realRecorderCapacity: 16)
        let changed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = fixture.app.manualCaptureController.stateUpdates.sink { state in
            if case .error = state { changed.continuation.yield(()) }
        }
        defer { observation.cancel(); changed.continuation.finish() }
        do {
            fixture.app.startManualCapture()
            try fixture.captureOwnedOperation("startup")
            try await fixture.waitForOwnedExit("startup")
            let recorder = try #require(fixture.recorder)
            #expect(fixture.app.manualCaptureState == .recording)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            buffer.frameLength = 8 // Actual 32-byte PCM exceeds this isolated 16-byte recorder.
            for frame in 0..<8 { buffer.floatChannelData?[0][frame] = 0 }
            recorder.systemAudioCaptureService(fixture.audioService, didReceive: buffer,
                at: AVAudioTime(sampleTime: 0, atRate: 16000))
            // Await the actual recorder publication before checking AppState.
            // The actual owner must handle this recorder onFailure control event.
            try await fixture.waitFor(.recorderFailed)
            _ = try await TestEventWaitTrace(label: "manual-lifecycle.actual-overflow-ui")
                .nextEvent(in: changed.stream, event: "manual-error")
            #expect(!recorder.isRecording)
            #expect(fixture.app.manualCaptureState != .recording)
            #expect(fixture.app.manualCaptureError != nil)
            #expect(!fixture.app.isActionLoading(ActionID.manualRecord))
            #expect(fixture.app.manualCaptureSuggestion == nil)
        } catch {
            try? await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }
}

private enum ManualLifecycleEvent: String, Sendable {
    case permissionRequested, audioStarted, audioCancelled, finalizeEntered
    case shutdownReturned, recorderFailed
}
private actor ManualLifecycleGate {
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { self.open = open }
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let owned = waiters; waiters.removeAll()
        owned.forEach { $0.resume() }
    }
}
private final class ManualLifecyclePermissions: PermissionService {
    let gate: ManualLifecycleGate
    let requested: AsyncStream<ManualLifecycleEvent>.Continuation
    init(gate: ManualLifecycleGate, requested: AsyncStream<ManualLifecycleEvent>.Continuation) {
        self.gate = gate; self.requested = requested
    }
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: .granted,
            screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .authorized }
    override func speechStatus() -> PermissionState { .granted }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        requested.yield(.permissionRequested)
        await gate.wait() // Deliberately ignores cancellation; fixture always releases.
        return .authorized
    }
    override func requestSpeechRecognition() async -> PermissionState { .granted }
}
private actor ManualLifecycleNativeStream: SystemAudioCaptureStream {
    @MainActor func startCapture() async throws { }
    @MainActor func stopCapture() async throws { }
}

private actor ManualPracticeHeldASR: ASRProvider {
    nonisolated let id = ASRProviderID.localParakeet
    nonisolated let displayName = "Synthetic held Practice audio"
    let stopGate: ManualLifecycleGate
    let stopped: AsyncStream<Void>.Continuation
    private let stream = HermeticTestASRProvider()
    private var stopObserved = false
    init(stopGate: ManualLifecycleGate, stopped: AsyncStream<Void>.Continuation) {
        self.stopGate = stopGate; self.stopped = stopped
    }
    func isAvailable() async -> Bool { true }
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        try await stream.startTranscription(config: config)
    }
    func stopTranscription() async {
        if !stopObserved { stopObserved = true; stopped.yield(()); stopped.finish() }
        await stopGate.wait()
        await stream.stopTranscription()
    }
}

@MainActor
private final class ManualLifecycleFixture {
    struct Start { let source: ManualCaptureSource; let duration: Int }
    let database: AppDatabase
    let defaults: UserDefaults
    let suiteName: String
    let events = AsyncStream<ManualLifecycleEvent>.makeStream()
    let permissionGate: ManualLifecycleGate
    let finalizeGate: ManualLifecycleGate
    let permissions: ManualLifecyclePermissions
    let audioService: ScreenCaptureKitSystemAudioCaptureService
    let recorder: ManualQuestionCaptureService?
    private(set) var app: AppState!
    private(set) var audioStarts: [Start] = []
    private(set) var audioCancelCalls = 0
    private var operations: [String: [Task<Void, Never>]] = [:]
    private var recorderObservation: AnyCancellable?

    init(blockPermissions: Bool = false, blockFinalize: Bool = false,
        realRecorderCapacity: Int? = nil) throws {
        database = try AppDatabase(inMemory: true)
        suiteName = "com.langcheng.Hireva.tests.manual-lifecycle.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        permissionGate = ManualLifecycleGate(open: !blockPermissions)
        finalizeGate = ManualLifecycleGate(open: !blockFinalize)
        permissions = ManualLifecyclePermissions(gate: permissionGate, requested: events.continuation)
        let syntheticAudio = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { ManualLifecycleNativeStream() })
        audioService = syntheticAudio
        recorder = realRecorderCapacity.map {
            ManualQuestionCaptureService(systemAudioCaptureService: syntheticAudio, maximumStoredBytes: $0)
        }
        var settings = AppSettings.default
        settings.audioCaptureMode = .microphoneOnly
        settings.manualCaptureSource = recorder == nil ? .microphone : .systemAudio
        settings.maxManualCaptureSeconds = 12
        settings.showTranscriptBeforeSending = true
        settings.autoSendAfterTranscription = false
        settings.saveTranscriptsLocally = false
        try SettingsRepository(database: database).saveSettings(settings)
        let permissionOwner = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), probe: {
                .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
            }, stopProbe: {})
        let changes = PassthroughSubject<Void, Never>()
        let audio: ManualCaptureCapabilities.Audio
        if let recorder {
            audio = ManualCaptureCapabilities.existingAudioAdapter(recorder: recorder)
            recorderObservation = recorder.$captureFailure.sink { [events] in
                if $0 != nil { events.continuation.yield(.recorderFailed) }
            }
        } else {
            audio = .init(start: { [weak self] source, duration, _, _ in
                guard let self else { throw CancellationError() }
                audioStarts.append(.init(source: source, duration: duration))
                events.continuation.yield(.audioStarted)
            }, stop: { .init(buffers: [], bufferCount: 0, lastBufferTimestamp: nil, drain: nil) },
                cancel: { [weak self] in
                    self?.audioCancelCalls += 1
                    self?.events.continuation.yield(.audioCancelled)
                    return nil
                }, finishStop: { if let owned = $0 { try await owned.task.value } },
            retryStop: { try await $0.task.value },
                duration: { 0 }, level: { 0 }, decibels: { -90 }, bufferCount: { 0 }, lastBufferTimestamp: { nil },
                changes: changes.eraseToAnyPublisher())
        }
        let speech = ManualCaptureCapabilities.Speech(start: { _, _, _ in }, append: { _ in },
            finalize: { [finalizeGate, events] _ in
                events.continuation.yield(.finalizeEntered)
                await finalizeGate.wait() // Releasable, deliberately non-cooperative.
                return "Synthetic late manual transcript."
            }, cancel: {}, startOnDevice: { _, _, _ in })
        let capabilities = ManualCaptureCapabilities(audio: audio, speech: speech)
        app = AppState(database: database, permissionService: permissions,
            systemAudioPermissions: permissionOwner,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: audioService, dialogueDefaults: defaults,
            manualCaptureCapabilities: capabilities)
        app.automaticContextReadiness = .ready
    }

    func nextEvent() async throws -> ManualLifecycleEvent {
        let stream = events.stream
        return try await TestEventWaitTrace(label: "manual-lifecycle.readiness")
            .nextEvent(in: stream, event: "actual-capability")
    }
    func waitFor(_ expected: ManualLifecycleEvent) async throws {
        while try await nextEvent() != expected { }
    }
    func captureOwnedOperation(_ phase: String) throws {
        let owner = app.manualCaptureController
        let task = phase == "startup" ? owner.startupTask : owner.finalizationTask
        let owned = try #require(task, "The owner must retain its actual task before submission returns")
        operations[phase, default: []].append(owned)
    }
    func waitForOwnedExit(_ phase: String) async throws {
        let owned = try #require(operations[phase]?.last,
            "The fixture must retain the exact submitted owner task")
        await owned.value
        try Task.checkCancellation()
    }
    func releaseAll() async {
        await permissionGate.release()
        await finalizeGate.release()
    }
    func cleanup(shutdown: Task<Bool, Never>? = nil) async throws {
        await releaseAll()
        app.cancelManualCapture()
        // Opened gates precede every join, including an already cancelled case.
        // These immutable handles are the actual owner tasks, not observers.
        let owned = operations.values.flatMap { $0 }
        owned.forEach { $0.cancel() }
        for task in owned { await task.value }
        _ = await shutdown?.value
        await app.shutdownForTesting()
        if let recorder { try await recorder.shutdown() }
        audioService.stopSystemAudioCapture()
        try await audioService.finishStoppingSystemAudioCapture()
        recorderObservation?.cancel()
        events.continuation.finish()
        defaults.removePersistentDomain(forName: suiteName)
        try database.close()
    }
}
