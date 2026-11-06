import Foundation
import Testing
@testable import Hireva

/// The smallest prerequisite is an injected, stored SystemAudioPermissionController
/// in AppState's initializer. For RED, keep existing refresh/start/shutdown
/// behavior. These tests exercise real AppState calls; they do not claim native
/// TCC, microphone, ScreenCaptureKit, model, or Apple local-processing evidence.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppStatePermissionBoundaryTests {
    @Test(arguments: ["replacement", "revision", "none"])
    func contextBiasCannotCrossASelectionChangeDuringTheActualPermissionProbe(change: String) async throws {
        let fixture = try AppPermissionBoundaryFixture(captureMode: .systemAudioOnly)
        let evidence = ProfileEvidence(id: "selected-role-skill", statement: "idempotency", confidence: 1,
            evidenceType: .requiredSkill, explicitness: .explicit)
        var opportunity = OpportunityContext(id: "selected-role", title: "Synthetic role", opportunityType: .job,
            responsibilities: [], requiredSkills: [evidence], preferredSkills: [], researchTopics: [],
            evaluationCriteria: [], sourceDocumentIDs: [], version: 1, updatedAt: .now)
        try fixture.app.interviewContextRepository.saveOpportunityContext(opportunity)
        try fixture.app.interviewContextState.reload(sessionSnapshotID: nil)
        fixture.app.selectOpportunityContext(opportunity.id)
        #expect(ASRConfig.opportunityTerms(fixture.app.activeOpportunityContext) == ["idempotency"])
        fixture.app.setSelectedASRProvider(.localParakeet)
        fixture.app.settingsState.setParakeetContextBiasEnabled(true)
        var startup: Task<Void, Never>?
        do {
            fixture.app.startListening(mode: .microphone)
            startup = fixture.app.captureStartupTask
            #expect(try await fixture.nextEvent() == .probeStarted)
            if change == "none" {
                fixture.app.selectOpportunityContext(nil)
            } else {
                if change == "replacement" { opportunity.id = "replacement-role" }
                opportunity.version += 1
                opportunity.requiredSkills[0].statement = "data replication"
                try fixture.app.interviewContextRepository.saveOpportunityContext(opportunity)
                try fixture.app.interviewContextState.reload(sessionSnapshotID: nil)
                fixture.app.selectOpportunityContext(opportunity.id)
            }
            fixture.releaseAll()
            await startup?.value
            #expect(fixture.actualASRAdmissions == 0)
            #expect(fixture.app.currentSession == nil)
            if case .error(let message) = fixture.app.liveState {
                #expect(message.contains("context changed"))
            } else { Issue.record("A stale context vocabulary must require an explicit restart.") }
        } catch {
            await fixture.cleanup(startup: startup)
            throw error
        }
        await fixture.cleanup(startup: startup)
    }

    @Test(arguments: [false, true])
    func unavailableStreamDoesNotBecomePermissionDenial(preflightGranted: Bool) async throws {
        let message = "No capture display available; system audio stream probe was not attempted."
        let result = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: preflightGranted, shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: false, errorDescription: message, likelyIdentityMismatch: false)
        let fixture = try AppPermissionBoundaryFixture(captureMode: .systemAudioOnly, probeResult: result)
        fixture.releaseAll()
        fixture.app.startListening(mode: .microphone)
        let startup = fixture.app.captureStartupTask
        await startup?.value
        #expect(fixture.actualASRAdmissions == 0)
        #expect(fixture.permissions.screenAuthorizationRequests == 0)
        #expect(fixture.app.permissionSnapshot.screenRecording == .unknown)
        #expect(fixture.app.permissionSnapshot.systemAudioCapture == .unknown)
        #expect(fixture.app.liveState != .permissionDenied)
        if case .error(let detail) = fixture.app.liveState {
            #expect(detail.contains(message))
        } else {
            Issue.record("An unavailable stream must publish the actual capture failure")
        }
        await fixture.cleanup(startup: startup)
    }

    @Test
    func permissionDisplaysFollowOneInjectedAuthorityDuringMicrophoneOnlyRefresh() async throws {
        let fixture = try AppPermissionBoundaryFixture(initialResult: .rejected)
        fixture.app.refreshPermissions()
        #expect(fixture.nativeProbeCalls == 0)
        #expect(fixture.app.microphonePermissionState == .authorized)
        #expect(fixture.app.systemAudioPermissionState == .permissionMissing)
        #expect(fixture.app.permissionSnapshot.systemAudioCapture == .denied)
        #expect(fixture.app.systemAudioProbeResult == fixture.owner.probeResult)
        await fixture.cleanup()
    }

    @Test
    func liveStartJoinsOwnedPermissionProbeBeforeActualASRAdmission() async throws {
        let fixture = try AppPermissionBoundaryFixture()
        var pendingProbe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var startup: Task<Void, Never>?
        do {
            pendingProbe = fixture.owner.refresh(captureMode: .systemAudioOnly)
            #expect(try await fixture.nextEvent() == .probeStarted)
            fixture.app.startListening(mode: .microphone)
            startup = fixture.app.captureStartupTask
            let first = try await fixture.nextEvent()
            #expect(first == .probeStopEntered, "Live must join its prior permission probe before entering ASR")
            #expect(fixture.actualASRAdmissions == 0)
            fixture.releaseAll()
            await startup?.value
            _ = await pendingProbe?.result
            #expect(fixture.actualASRAdmissions == 1)
            #expect(!fixture.owner.hasOwnedProbeWork)
            #expect(fixture.owner.probeResult == nil, "A cancelled probe result cannot revive permissions")
        } catch {
            await fixture.cleanup(probe: pendingProbe, startup: startup)
            throw error
        }
        await fixture.cleanup(probe: pendingProbe, startup: startup)
    }

    @Test
    func completedOldTeardownCannotClearReplacementAndCompletedCurrentHandleIsRemoved() async throws {
        let fixture = try AppPermissionBoundaryFixture()
        let old = AppPermissionBoundaryASR()
        let replacement = AppPermissionBoundaryASR()
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        @MainActor func cleanup() async {
            old.stopGate.release()
            replacement.stopGate.release()
            await first?.value
            await second?.value
            old.stopEntered.continuation.finish()
            replacement.stopEntered.continuation.finish()
            await fixture.cleanup()
        }
        do {
            fixture.app.activeASRProviderRuntime = old
            fixture.app.stopListening()
            first = fixture.app.captureTeardownTask
            try await waitForAppPermissionBoundaryStop(old.stopEntered.stream, trace: old.trace)
            fixture.app.activeASRProviderRuntime = replacement
            fixture.app.stopListening()
            second = fixture.app.captureTeardownTask
            old.stopGate.release()
            try await waitForAppPermissionBoundaryStop(replacement.stopEntered.stream, trace: replacement.trace)
            #expect(fixture.app.captureTeardownTask == second,
                "Old completion must not clear the pending replacement stop")
            replacement.stopGate.release()
            await first?.value
            await second?.value
            #expect(fixture.app.captureTeardownTask == nil,
                "An exited cleanup handle cannot indefinitely block idle diagnostics")
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test(arguments: AppPermissionBoundaryDeniedState.allCases)
    func actualCompositionCannotUpgradeInjectedSystemDenialToSyntheticGrant(state: AppPermissionBoundaryDeniedState) async throws {
        let permissions = AppPermissionBoundaryDeniedService(state: state.value)
        let owner = AppComposition.makeSystemAudioPermissions(permissions: permissions, isTestProcess: true)
        do {
            #expect(owner.permissionSnapshot.systemAudioCapture != .granted)
            #expect(owner.systemAudioPermissionState != .granted)
            let result = try await owner.probeNow()
            #expect(!result.streamAudioProbeSucceeded)
            #expect(owner.permissionSnapshot.systemAudioCapture != .granted)
            #expect(owner.systemAudioPermissionState != .granted)
            try await owner.shutdown()
        } catch {
            try? await owner.shutdown()
            throw error
        }
    }

    @Test
    func applicationShutdownClosesProbeAdmissionAndJoinsNativeStop() async throws {
        let fixture = try AppPermissionBoundaryFixture()
        var pendingProbe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var shutdown: Task<Bool, Never>?
        var returned = false
        do {
            pendingProbe = fixture.owner.refresh(captureMode: .systemAudioOnly)
            #expect(try await fixture.nextEvent() == .probeStarted)
            shutdown = Task { @MainActor in
                let result = await fixture.app.shutdownResources()
                returned = true
                fixture.events.continuation.yield(.shutdownReturned)
                return result
            }
            let first = try await fixture.nextEvent()
            #expect(first == .probeStopEntered, "Shutdown must retain and join pending permission cleanup")
            #expect(!returned)
            #expect(fixture.owner.refresh(captureMode: .systemAudioOnly) == nil)
            fixture.releaseAll()
            #expect(await shutdown?.value == true)
            _ = await pendingProbe?.result
            #expect(!fixture.owner.hasOwnedProbeWork)
            #expect(fixture.owner.refresh(captureMode: .systemAudioOnly) == nil)
        } catch {
            await fixture.cleanup(probe: pendingProbe, shutdown: shutdown)
            throw error
        }
        await fixture.cleanup(probe: pendingProbe, shutdown: shutdown)
    }
}

private enum AppPermissionBoundaryEvent: Sendable, Equatable {
    case probeStarted, probeStopEntered, actualASRAdmission, shutdownReturned
}
private enum AppPermissionBoundaryError: Error { case nativeBackendMustNotStart }

@MainActor
private final class AppPermissionBoundaryGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class AppPermissionBoundaryService: PermissionService {
    private(set) var screenAuthorizationRequests = 0
    override func requestScreenRecording() { screenAuthorizationRequests += 1 }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .authorized }
    override func speechStatus() -> PermissionState { .granted }
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: .granted,
            screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func requestMicrophonePermission() async -> MicrophonePermissionState { .authorized }
    override func requestSpeechRecognition() async -> PermissionState { .granted }
}

@MainActor
private final class AppPermissionBoundaryFixture {
    let database: AppDatabase
    let suiteName: String
    let defaults: UserDefaults
    let permissions = AppPermissionBoundaryService()
    let trace = TestEventWaitTrace(label: "permission.app-boundary.control")
    let events = AsyncStream<AppPermissionBoundaryEvent>.makeStream()
    let probeGate = AppPermissionBoundaryGate()
    let stopGate = AppPermissionBoundaryGate()
    private(set) var nativeProbeCalls = 0
    private(set) var actualASRAdmissions = 0
    private(set) var owner: SystemAudioPermissionController!
    private(set) var app: AppState!

    init(initialResult: ScreenSystemAudioPermissionProbeResult? = nil,
        captureMode: AudioCaptureMode = .microphoneOnly,
        probeResult: ScreenSystemAudioPermissionProbeResult = .granted) throws {
        database = try AppDatabase(inMemory: true)
        suiteName = "com.langcheng.Hireva.tests.permission-boundary.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        var settings = AppSettings.default
        settings.audioCaptureMode = captureMode
        settings.manualCaptureSource = .microphone
        settings.saveTranscriptsLocally = false
        try SettingsRepository(database: database).saveSettings(settings)
        owner = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), initialProbeResult: initialResult,
            probe: { [weak self] in
                guard let self else { throw CancellationError() }
                nativeProbeCalls += 1
                events.continuation.yield(.probeStarted)
                await probeGate.wait()
                return probeResult
            }, stopProbe: { [weak self] in
                guard let self else { throw CancellationError() }
                events.continuation.yield(.probeStopEntered)
                await stopGate.wait()
            })
        app = AppState(database: database, permissionService: permissions,
            systemAudioPermissions: owner,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        app.localLLMProviderOverride = HermeticUnavailableLocalProvider()
        app.setSelectedASRProvider(.appleSpeech)
        app.liveASRWillStart = { [weak self] _, _ in
            guard let self else { throw CancellationError() }
            actualASRAdmissions += 1
            events.continuation.yield(.actualASRAdmission)
            throw AppPermissionBoundaryError.nativeBackendMustNotStart
        }
    }

    func nextEvent() async throws -> AppPermissionBoundaryEvent {
        try await trace.nextEvent(in: events.stream, event: "control")
    }
    func releaseAll() { probeGate.release(); stopGate.release() }
    func cleanup(probe: Task<ScreenSystemAudioPermissionProbeResult, Error>? = nil,
        startup: Task<Void, Never>? = nil, shutdown: Task<Bool, Never>? = nil) async {
        releaseAll()
        owner.cancelProbe()
        startup?.cancel()
        _ = await probe?.result
        await startup?.value
        _ = await shutdown?.value
        await app.shutdownForTesting()
        try? await owner.shutdown()
        events.continuation.finish()
        defaults.removePersistentDomain(forName: suiteName)
        try? database.close()
    }
}

private extension ScreenSystemAudioPermissionProbeResult {
    static var granted: Self {
        .init(preflightGranted: true, shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
    }
    static var rejected: Self {
        .init(preflightGranted: false, shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false, errorDescription: "Synthetic denial", likelyIdentityMismatch: false)
    }
}

@MainActor
private final class AppPermissionBoundaryASR: ASRProvider {
    nonisolated let id: ASRProviderID = .localParakeet
    nonisolated let displayName = "Synthetic lifecycle fixture"
    let trace = TestEventWaitTrace(label: "permission.app-boundary.asr-stop")
    let stopGate = AppPermissionBoundaryGate()
    let stopEntered = AsyncStream<Void>.makeStream()
    func isAvailable() async -> Bool { true }
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        throw AppPermissionBoundaryError.nativeBackendMustNotStart
    }
    func stopTranscription() async {
        stopEntered.continuation.yield(())
        await stopGate.wait()
    }
}

private func waitForAppPermissionBoundaryStop(_ stream: AsyncStream<Void>, trace: TestEventWaitTrace) async throws {
    _ = try await trace.nextEvent(in: stream, event: "stop")
}

enum AppPermissionBoundaryDeniedState: String, CaseIterable, Sendable {
    case denied, restricted, notDetermined, unknown
    var value: PermissionState {
        switch self {
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .unknown: return .unknown
        }
    }
}

private final class AppPermissionBoundaryDeniedService: PermissionService {
    private let state: PermissionState
    init(state: PermissionState) { self.state = state; super.init() }
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: .granted,
            screenRecording: state, systemAudioCapture: state)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
}
