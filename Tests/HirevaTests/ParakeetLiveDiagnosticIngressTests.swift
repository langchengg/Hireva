import AVFoundation
import Foundation
import os
import Testing
@testable import Hireva

/// Actual per-round PCM receiver -> runtime append -> existing App timer entry.
/// Native-free DI: no ScreenCaptureKit stream, microphone, model or process.
@MainActor
struct ParakeetLiveDiagnosticIngressTests {
    @Test(.timeLimit(.minutes(1)), arguments: [AudioCaptureMode.systemAudioOnly, .microphoneAndSystem])
    func selectedProviderIngressReachesTheExistingRuntimeCountersWithoutRepeatedSampling(mode: AudioCaptureMode) async throws {
        let fixture = try DiagnosticIngressFixture(mode: mode)
        do {
            let old = try await fixture.start()
            fixture.appendSystem(old, count: 3)
            fixture.appendMicrophone(old, count: 7)
            #expect(fixture.runtime.count(.systemAudio) == 3)
            #expect(fixture.runtime.count(.microphone) == (mode == .systemAudioOnly ? 0 : 7))
            fixture.app.monitorAudioSignal()
            let expected = mode == .systemAudioOnly ? 3 : 10
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == expected)
            #expect(fixture.app.transcriptRuntimeDiagnostics.bufferCount(for: .systemAudio) == 3)
            #expect(fixture.app.transcriptRuntimeDiagnostics.bufferCount(for: .microphone) == expected - 3)
            #expect(fixture.app.transcriptRuntimeDiagnostics.lastAudioBufferAt != nil)
            #expect(fixture.app.lastAudioBufferAt != nil)
            #expect(fixture.app.systemASRTaskActive)
            #expect(fixture.app.systemASRTaskRunning)
            #expect(fixture.app.micASRTaskActive == (mode == .microphoneAndSystem))
            // Apple request objects are not fabricated for a local runtime.
            #expect(!fixture.app.recognitionRequestActive)
            fixture.app.monitorAudioSignal()
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == expected)
            fixture.appendSystem(old, count: 2)
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == expected + 2)
            #expect(fixture.app.transcriptRuntimeDiagnostics.bufferCount(for: .systemAudio) == 5)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func sameBusinessSessionNewRoundCannotReuseTheOldAbsoluteCountOrOldReceiver() async throws {
        let fixture = try DiagnosticIngressFixture(mode: .systemAudioOnly)
        do {
            let old = try await fixture.start()
            fixture.appendSystem(old, count: 3)
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == 3)
            let replacement = try await fixture.start()
            fixture.appendSystem(old, count: 20)
            fixture.appendSystem(replacement, count: 2)
            #expect(fixture.runtime.count(.systemAudio) == 2, "Only the replacement receiver can append to this round.")
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == 5,
                "The business-session total retains the old round once and adds the replacement's two ingress buffers.")
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == 5)
            await fixture.provider.stopTranscription(retryFailedResource: false)
            fixture.app.markRuntimeAudioStopped()
            fixture.app.monitorAudioSignal()
            #expect(!fixture.app.systemASRTaskActive)
            #expect(!fixture.app.systemASRTaskRunning)
            #expect(!fixture.app.transcriptRuntimeDiagnostics.audioIsRunning)
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == 5)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func aDifferentBusinessSessionCannotBorrowTheOlderProvidersIngressOrActivity() async throws {
        let fixture = try DiagnosticIngressFixture(mode: .systemAudioOnly)
        do {
            let old = try await fixture.start()
            fixture.appendSystem(old, count: 3)
            var replacement = try #require(fixture.app.currentSession)
            replacement.id = UUID().uuidString
            fixture.app.currentSession = replacement
            fixture.app.monitorAudioSignal()
            #expect(fixture.app.transcriptRuntimeDiagnostics.audioBufferCount == 0)
            #expect(!fixture.app.systemASRTaskActive)
            #expect(!fixture.app.systemASRTaskRunning)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func failureOfOneCombinedSourceChangesOnlyThatSourceActivity() async throws {
        let fixture = try DiagnosticIngressFixture(mode: .microphoneAndSystem)
        do {
            let active = try await fixture.start()
            fixture.appendSystem(active, count: 2)
            fixture.appendMicrophone(active, count: 3)
            active.system.systemAudioCaptureService(fixture.capture, didFailWithError: IngressFixtureError.source)
            fixture.appendSystem(active, count: 40)
            fixture.appendMicrophone(active, count: 2)
            fixture.app.monitorAudioSignal()
            #expect(fixture.runtime.count(.systemAudio) == 2)
            #expect(fixture.runtime.count(.microphone) == 5)
            #expect(fixture.app.transcriptRuntimeDiagnostics.bufferCount(for: .systemAudio) == 2)
            #expect(fixture.app.transcriptRuntimeDiagnostics.bufferCount(for: .microphone) == 5)
            #expect(!fixture.app.systemASRTaskActive)
            #expect(fixture.app.micASRTaskActive)
            #expect(fixture.provider.hasHealthyCaptureSource)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }
}

private enum IngressFixtureError: Error { case source }
private struct IngressFixtureDelegates {
    let microphone: any AudioEngineBufferDelegate
    let system: any SystemAudioBufferDelegate
}
@MainActor
private final class DiagnosticIngressFixture {
    let database: AppDatabase
    let app: AppState
    let runtime = DiagnosticIngressRuntime()
    let capture: ScreenCaptureKitSystemAudioCaptureService
    let manager = AudioEngineManager(testingOperations: .init(installAndPrepareTap: {}, start: {},
        stop: {}, removeTap: {}, reset: {}, isRunning: { false }))
    let mode: AudioCaptureMode
    let buffer: AVAudioPCMBuffer
    private let defaults: UserDefaults
    private let suite: String
    private var delegates: [IngressFixtureDelegates] = []
    private var streams: [AsyncThrowingStream<TranscriptSegment, Error>] = []
    lazy var provider = LocalParakeetASRProvider(modelManager: DiagnosticIngressInstalledModel(),
        runtimeClient: runtime, systemAudioCaptureService: capture, startCapture: { _ in }, stopCapture: {},
        captureDelegatesObserver: { [weak self] microphone, system in
            self?.delegates.append(.init(microphone: microphone, system: system))
        })
    init(mode: AudioCaptureMode) throws {
        self.mode = mode
        let ownedCapture = ScreenCaptureKitSystemAudioCaptureService()
        capture = ownedCapture
        suite = "Hireva.Tests.DiagnosticIngress." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        database = try AppDatabase(inMemory: true)
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: ownedCapture, dialogueDefaults: defaults,
            diagnosticsTraceStore: RuntimeTranscriptTraceStore())
        app.settings.audioCaptureMode = mode
        app.settings.diagnosticTraceMode = .off
        let now = Date()
        app.currentSession = InterviewSession(id: UUID().uuidString, title: "Synthetic ingress", company: nil,
            role: nil, startedAt: now, endedAt: nil, mode: .microphone, createdAt: now)
        app.currentCaptureRuntimeState = .listening
        app.liveState = .listening
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        for index in 0..<8 { buffer.floatChannelData![0][index] = 0.01 }
    }
    func start() async throws -> IngressFixtureDelegates {
        let session = try #require(app.currentSession)
        let stream = try await provider.startTranscription(config: .init(sessionID: session.id, captureMode: mode))
        streams.append(stream) // Keep each real bridge alive until exact explicit cleanup.
        app.activeASRProviderRuntime = provider
        app.markActiveASRProvider(.localParakeet)
        return try #require(delegates.last)
    }
    func appendSystem(_ receiver: IngressFixtureDelegates, count: Int) {
        for offset in 0..<count {
            receiver.system.systemAudioCaptureService(capture, didReceive: buffer,
                at: .init(sampleTime: AVAudioFramePosition(offset * 8), atRate: 16000))
        }
    }
    func appendMicrophone(_ receiver: IngressFixtureDelegates, count: Int) {
        for offset in 0..<count {
            receiver.microphone.audioEngineManager(manager, didReceive: buffer,
                at: .init(sampleTime: AVAudioFramePosition(offset * 8), atRate: 16000))
        }
    }
    func cleanup() async {
        await provider.stopTranscription(retryFailedResource: false)
        await provider.waitForCurrentTranscriptionEnd()
        streams.removeAll()
        app.activeASRProviderRuntime = nil
        app.markActiveASRProvider(nil)
        app.markRuntimeAudioStopped()
        await app.shutdownForTesting()
        try? database.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
@MainActor
private final class DiagnosticIngressRuntime: ParakeetRuntimeClient {
    private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
    private nonisolated let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    func isRuntimeAvailable() async -> Bool { true }
    func probeModel(at modelDirectory: URL) async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
        continuation = pair.continuation
        counts.withLock { $0.removeAll() }
        return pair.stream
    }
    func stop() async { continuation?.finish(); continuation = nil }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        appendAudioBuffer(buffer, at: time, source: .systemAudio)
    }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, source: AudioSourceType) {
        counts.withLock { $0[source.rawValue, default: 0] += 1 }
    }
    nonisolated func count(_ source: AudioSourceType) -> Int { counts.withLock { $0[source.rawValue, default: 0] } }
}
private final class DiagnosticIngressInstalledModel: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-diagnostic-ingress-model") }
}
