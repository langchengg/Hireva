import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

/// Characterizes the new requirement through the actual Manual owner. All I/O
/// is a per-instance capability; no recognizer, device or permission prompt runs.
@MainActor
struct ManualASRRequirementSnapshotTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func manualCapturesRequirementBeforeAuthorizationAwait(required: Bool) async throws {
        let fixture = ManualASRPolicyFixture()
        var submitted = ManualCaptureController.Configuration(source: .microphone, maxDuration: 12,
            showTranscriptBeforeSending: true, autoSendAfterTranscription: false,
            requiresOnDeviceRecognition: required)
        do {
            fixture.controller.start(configuration: submitted)
            let owned = try #require(fixture.controller.startupTask)
            _ = try await fixture.trace.nextEvent(in: fixture.permission.entered, event: "permission_entered")
            submitted = .init(source: .systemAudio, maxDuration: 90,
                showTranscriptBeforeSending: false, autoSendAfterTranscription: true,
                requiresOnDeviceRecognition: !required)
            await fixture.permission.release()
            await owned.value
            try Task.checkCancellation()
            #expect(fixture.speechRequirements == [required])
            #expect(fixture.audioSources == [.microphone])
            #expect(fixture.controller.state == .recording)
            #expect(submitted.requiresOnDeviceRecognition != required)
            try await fixture.cleanup()
        } catch {
            try await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func manualLegacyCapabilityCannotStartARequiredDeviceOnlyRound() async throws {
        let fixture = ManualASRPolicyFixture(implementsLocalContract: false)
        do {
            fixture.controller.start(configuration: .init(source: .microphone, maxDuration: 12,
                showTranscriptBeforeSending: true, autoSendAfterTranscription: false,
                requiresOnDeviceRecognition: true))
            let owned = try #require(fixture.controller.startupTask)
            await fixture.permission.release()
            await owned.value
            try Task.checkCancellation()
            #expect(fixture.speechRequirements.isEmpty)
            #expect(fixture.audioSources.isEmpty)
            if case .error(let message) = fixture.controller.state {
                #expect(message.contains("on-device"))
            } else { Issue.record("A legacy capability accepted required on-device recognition.") }
            try await fixture.cleanup()
        } catch {
            try await fixture.cleanup()
            throw error
        }
    }
}

private actor ManualASRPolicyPermissionGate {
    nonisolated let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entered = pair.stream; continuation = pair.continuation
    }
    func wait() async {
        continuation.yield(())
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() {
        released = true; waiter?.resume(); waiter = nil; continuation.finish()
    }
}
private final class ManualASRPolicyPermissions: PermissionService {
    let gate: ManualASRPolicyPermissionGate
    init(gate: ManualASRPolicyPermissionGate) { self.gate = gate }
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: .granted,
            screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        await gate.wait(); return .authorized
    }
    override func requestSpeechRecognition() async -> PermissionState { .granted }
}
@MainActor
private final class ManualASRPolicyFixture {
    let permission = ManualASRPolicyPermissionGate()
    let trace = TestEventWaitTrace(label: "asrPolicy.manual")
    private(set) var speechRequirements: [Bool] = []
    private(set) var audioSources: [ManualCaptureSource] = []
    private(set) var controller: ManualCaptureController!
    init(implementsLocalContract: Bool = true) {
        let permissions = ManualASRPolicyPermissions(gate: permission)
        let system = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), probe: { throw CancellationError() }, stopProbe: {})
        let changes = PassthroughSubject<Void, Never>()
        let local: (@MainActor (@escaping @Sendable (String) -> Void,
            @escaping @Sendable (String) -> Void, @escaping @Sendable (String) -> Void) async throws -> Void)?
        if implementsLocalContract {
            local = { [weak self] _, _, _ in self?.speechRequirements.append(true) }
        } else { local = nil }
        let speech = ManualCaptureCapabilities.Speech(
            start: { [weak self] _, _, _ in self?.speechRequirements.append(false) },
            append: { _ in }, finalize: { _ in "Synthetic reviewed question." }, cancel: {},
            startOnDevice: local)
        let audio = ManualCaptureCapabilities.Audio(start: { [weak self] source, _, _, _ in
            self?.audioSources.append(source)
        }, stop: { .init(buffers: [], bufferCount: 0, lastBufferTimestamp: nil, drain: nil) },
            cancel: { nil }, finishStop: { if let owned = $0 { try await owned.task.value } },
            retryStop: { try await $0.task.value }, duration: { 0 }, level: { 0 },
            decibels: { -90 }, bufferCount: { 0 }, lastBufferTimestamp: { nil },
            changes: changes.eraseToAnyPublisher())
        controller = ManualCaptureController(dependencies: .init(permissions: permissions,
            systemPermissions: system, audio: audio, speech: speech,
            prepareLiveTeardown: { nil }, feedback: { _ in }, clearFeedback: { _ in }, onReady: { _, _ in }))
    }
    func cleanup() async throws {
        await permission.release() // Release this deliberately non-cooperative gate before joining.
        try await controller.shutdown()
        #expect(!controller.hasUnreleasedResources)
    }
}
