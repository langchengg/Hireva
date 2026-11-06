import Foundation
import Testing
@testable import Hireva

/// Exercises the actual Live permission/dispatch path. The injected observer
/// throws before any backend, capture device or model can start.
@Suite
@MainActor
struct LiveASRSelectionBoundaryTests {
    @Test(arguments: LiveSelectionCaptureModeCase.allCases)
    func unavailableWhisperIsRejectedWithoutAppleFallbackOrPermissionRequests(mode: LiveSelectionCaptureModeCase) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "Hireva.LiveASRSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let permissions = SelectionPermissionFixture()
        let app = AppState(database: database,
            permissionService: permissions,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        app.localLLMProviderOverride = HermeticUnavailableLocalProvider()
        app.setSelectedASRProvider(.localWhisper)
        var settings = app.settings
        settings.audioCaptureMode = mode.value
        settings.saveTranscriptsLocally = false
        app.saveSettings(settings)
        var observed: [ObservedSelection] = []
        app.liveASRWillStart = { provider, mode in
            observed.append(.init(provider: provider, mode: mode))
            throw SelectionFixtureError.backendMustNotStart
        }
        app.startListening(mode: .microphone)
        let startup = app.captureStartupTask
        await startup?.value

        #expect(observed.isEmpty, "Unsupported Whisper must fail before dispatching any other backend")
        #expect(app.activeASRProviderID == nil)
        #expect(permissions.microphoneRequests == 0)
        #expect(permissions.speechRequests == 0)
        #expect(permissions.screenRequests == 0)
        if case .error(let message) = app.liveState {
            #expect(message.localizedCaseInsensitiveContains("Whisper"))
        } else {
            Issue.record("Unsupported Whisper selection must have an explicit failure")
        }

        await app.shutdownForTesting()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: LiveSelectionChangedProvider.allCases)
    func permissionAwaitCannotAuthorizeAChangedProviderOrCaptureMode(changedProvider: LiveSelectionChangedProvider) async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "Hireva.LiveASRSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let gate = SelectionPermissionGate()
        let entered = AsyncStream<Void>.makeStream()
        let permissions = SelectionPermissionFixture(speechGate: gate,
            speechRequestEntered: { entered.continuation.yield(()) })
        let app = AppState(database: database,
            permissionService: permissions,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        app.localLLMProviderOverride = HermeticUnavailableLocalProvider()
        app.setSelectedASRProvider(.appleSpeech)
        var settings = app.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.saveTranscriptsLocally = false
        app.saveSettings(settings)
        var observed: [ObservedSelection] = []
        app.liveASRWillStart = { provider, mode in
            observed.append(.init(provider: provider, mode: mode))
            throw SelectionFixtureError.backendMustNotStart
        }
        var startup: Task<Void, Never>?
        @MainActor func cleanup() async {
            await gate.release()
            entered.continuation.finish()
            startup?.cancel()
            await startup?.value
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
        }
        do {
            app.startListening(mode: .microphone)
            startup = app.captureStartupTask
            guard startup != nil else {
                Issue.record("The actual Live startup task was not scheduled")
                throw SelectionFixtureError.startupNotScheduled
            }
            let enteredStream = entered.stream
            // This is a fixture scheduling barrier, not the application's
            // permission deadline. Owning-test cancellation releases it and
            // cleanup joins the exact startup after opening the Speech gate.
            let scheduledStartup = try #require(startup)
            try await withTaskCancellationHandler {
                var iterator = enteredStream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            } onCancel: {
                entered.continuation.finish()
                scheduledStartup.cancel()
            }
            #expect(permissions.speechRequests == 1)
            // These are real public setting actions while the actual startup
            // awaits Speech authorization. No synthetic copy of dispatch is used.
            settings.audioCaptureMode = .microphoneOnly
            app.saveSettings(settings)
            app.setSelectedASRProvider(changedProvider.value)
            await gate.release()
            await startup?.value

            #expect(observed.isEmpty || observed == [.init(provider: .appleSpeech, mode: .systemAudioOnly)],
                "A suspended startup must keep its original selection or be invalidated")
            #expect(permissions.microphoneRequests == 0)
            #expect(permissions.screenRequests == 0)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

private struct ObservedSelection: Equatable {
    let provider: ASRProviderID
    let mode: AudioCaptureMode
}

enum LiveSelectionCaptureModeCase: String, CaseIterable, Sendable {
    case microphone, systemAudio, combined
    var value: AudioCaptureMode {
        switch self {
        case .microphone: return .microphoneOnly
        case .systemAudio: return .systemAudioOnly
        case .combined: return .microphoneAndSystem
        }
    }
}

enum LiveSelectionChangedProvider: String, CaseIterable, Sendable {
    case whisper, parakeet
    var value: ASRProviderID {
        switch self {
        case .whisper: return .localWhisper
        case .parakeet: return .localParakeet
        }
    }
}

private enum SelectionFixtureError: Error { case backendMustNotStart, startupNotScheduled }

private final class SelectionPermissionFixture: PermissionService {
    private let lock = NSLock()
    private var microphoneRequestCount = 0
    private var speechRequestCount = 0
    private var screenRequestCount = 0
    private var microphoneState = MicrophonePermissionState.notDetermined
    private var speechState = PermissionState.notDetermined
    private let speechGate: SelectionPermissionGate?
    private let speechRequestEntered: (() -> Void)?
    var microphoneRequests: Int { lock.withLock { microphoneRequestCount } }
    var speechRequests: Int { lock.withLock { speechRequestCount } }
    var screenRequests: Int { lock.withLock { screenRequestCount } }

    init(speechGate: SelectionPermissionGate? = nil, speechRequestEntered: (() -> Void)? = nil) {
        self.speechGate = speechGate
        self.speechRequestEntered = speechRequestEntered
        super.init()
    }

    override func checkMicrophonePermission() -> MicrophonePermissionState {
        lock.withLock { microphoneState }
    }
    override func speechStatus() -> PermissionState { lock.withLock { speechState } }
    override func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(microphone: checkMicrophonePermission().legacyState,
            speechRecognition: speechStatus(), screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        lock.withLock { microphoneRequestCount += 1; microphoneState = .authorized }
        return .authorized
    }
    override func requestSpeechRecognition() async -> PermissionState {
        lock.withLock { speechRequestCount += 1 }
        speechRequestEntered?()
        await speechGate?.wait()
        lock.withLock { speechState = .granted }
        return .granted
    }
    override func requestScreenRecording() { lock.withLock { screenRequestCount += 1 } }
}

private actor SelectionPermissionGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
