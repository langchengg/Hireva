import Foundation
import Testing
@testable import Hireva

/// New ASR policy characterization through production bridge/controller methods.
/// These inject service/provider values and permission closures; no Speech
/// recognizer, native capture, permissions, model or network task is started.
@MainActor
struct ASRRequirementSnapshotTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func productionBridgeForwardsTheFrozenASRRequirement(required: Bool) async throws {
        let service = PolicyRecordingSpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        do {
            _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-policy",
                captureMode: .systemAudioOnly, requiresOnDeviceRecognition: required))
            #expect(service.legacyStarts == 0)
            #expect(service.requirements == [required])
            await provider.stopTranscription()
            #expect(!provider.hasOwnedTranscriptionWork)
        } catch {
            await provider.stopTranscription()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyAdapterCannotAcceptAnUnsupportedLocalOnlyContract() async throws {
        let service = LegacyPolicySpeechService()
        let provider = AppleSpeechASRProvider(service: service)
        do {
            _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-legacy-policy",
                captureMode: .systemAudioOnly, requiresOnDeviceRecognition: true))
            Issue.record("A legacy adapter without a local-only contract accepted it.")
        } catch {
            #expect(error is TranscriptionError)
        }
        #expect(service.starts == 0)
        await provider.stopTranscription()
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func practiceCapturesASRRequirementBeforePermissionSuspension(required: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let permission = PolicyPermissionGate()
        let provider = PolicyASRProvider()
        var currentRequirement = required
        let controller = PracticeController(dependencies: PracticeDependencies(
            repository: PracticeRepository(database: database),
            sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database),
            contexts: InterviewContextRepository(database: database),
            persistenceConsent: PersistenceConsent(),
            context: {
                .init(historyEnabled: false,
                    selection: .init(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general),
                    temporarySnapshotID: nil, requiresOnDeviceRecognition: currentRequirement)
            },
            evaluationConfiguration: { throw ASRPolicyFixtureError.unexpectedEvaluation },
            selectedASRProvider: { .appleSpeech },
            isLiveCaptureActive: { false }, prepareForPractice: {},
            requestAudioPermissions: { _ in await permission.request() },
            makeAudioProvider: { _ in provider }, historyDidChange: { _ in },
            delayProvider: RealDelayProvider()))
        func cleanup() async throws {
            controller.stopMicrophone()
            await permission.release()
            await controller.shutdown()
            try database.close()
        }
        do {
            controller.start(kind: .generalKnowledge, question: "Explain a bounded retry policy.",
                language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.startMicrophone()
            _ = try await permission.trace.nextEvent(in: permission.entered, event: "permission_entered")
            currentRequirement = !required
            await permission.release()
            _ = try await provider.trace.nextEvent(in: provider.started, event: "asr_started")
            let configurations = await provider.configurations
            #expect(configurations.count == 1)
            #expect(configurations.first?.requiresOnDeviceRecognition == required)
            #expect(configurations.first?.captureMode == .microphoneOnly)
            try await cleanup()
            #expect(!controller.recording)
            #expect(!controller.microphoneStarting)
            #expect(await provider.running == false)
        } catch {
            try await cleanup()
            throw error
        }
    }
}

private enum ASRPolicyFixtureError: Error { case unexpectedEvaluation }

@MainActor
private final class PolicyRecordingSpeechService: AppleSpeechProviderService {
    private let pair = AsyncStream<TranscriptSegment>.makeStream()
    var segments: AsyncStream<TranscriptSegment> { pair.stream }
    var terminalError: Error? { nil }
    private(set) var legacyStarts = 0
    private(set) var requirements: [Bool] = []
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws { legacyStarts += 1 }
    func start(sessionID: String, captureMode: AudioCaptureMode,
        requiresOnDeviceRecognition: Bool) async throws { requirements.append(requiresOnDeviceRecognition) }
    func stop() { pair.continuation.finish() }
}

@MainActor
private final class LegacyPolicySpeechService: AppleSpeechProviderService {
    private let pair = AsyncStream<TranscriptSegment>.makeStream()
    var segments: AsyncStream<TranscriptSegment> { pair.stream }
    var terminalError: Error? { nil }
    private(set) var starts = 0
    func start(sessionID: String, captureMode: AudioCaptureMode) async throws { starts += 1 }
    func stop() { pair.continuation.finish() }
}

private actor PolicyPermissionGate {
    nonisolated let trace = TestEventWaitTrace(label: "asrPolicy.permission")
    nonisolated let entered: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entered = pair.stream; continuation = pair.continuation
    }
    func request() async {
        continuation.yield(())
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() {
        released = true; waiter?.resume(); waiter = nil; continuation.finish()
    }
}

private actor PolicyASRProvider: ASRProvider {
    nonisolated let id = ASRProviderID.appleSpeech
    nonisolated let displayName = "Synthetic ASR policy provider"
    nonisolated let trace = TestEventWaitTrace(label: "asrPolicy.capture")
    nonisolated let started: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    private(set) var configurations: [ASRConfig] = []
    private(set) var running = false
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = pair.stream; startContinuation = pair.continuation
    }
    func isAvailable() async -> Bool { true }
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        configurations.append(config)
        let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        continuation = pair.continuation; running = true
        startContinuation.yield(())
        return pair.stream
    }
    func stopTranscription() async {
        running = false; continuation?.finish(); continuation = nil
        startContinuation.finish()
    }
}
