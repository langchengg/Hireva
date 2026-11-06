import AVFoundation
import Combine
import Foundation
import Testing
@testable import Hireva

// Requires the reviewed exact-stop injection seam. It drives the real SCK
// callback and provider bridge; no SCStream, devices, helper process or model.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ParakeetNativeSourceFailureTests {
    @Test
    func cancelledStartupCanStopItsNativeStreamBeforeCallerCleanup() async throws {
        let fixture = SourceFixture(startHeld: true)
        let startup = Task {
            try await fixture.provider.startTranscription(config: config("cancelled-startup"))
        }
        do {
            try await fixture.native.startGate.waitUntilEntered()
            startup.cancel()
            fixture.native.startGate.open()
            try await fixture.native.stopGate.waitUntilEntered()
            #expect(!fixture.native.running,
                "Startup rollback must not await a stop latch whose owner is waiting for startup to return.")
            // This independent controller releases even the RED fixture before
            // joining. The regression cannot hang behind its own assertion.
            fixture.openAll()
            switch await startup.result {
            case .failure(let error): #expect(error is CancellationError)
            case .success: Issue.record("Cancelled startup returned an ASR stream")
            }
            await fixture.cleanup()
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
        } catch {
            fixture.openAll()
            startup.cancel()
            _ = await startup.result
            await fixture.cleanup()
            throw error
        }
    }

    @Test
    func currentNativeErrorIsThrownByTheActualProviderStream() async throws {
        let fixture = SourceFixture()
        var consumer: Task<[TranscriptSegment], Error>?
        do {
            let stream = try await fixture.provider.startTranscription(config: config("failed-source"))
            consumer = Task {
                var received: [TranscriptSegment] = []
                for try await value in stream { received.append(value) }
                return received
            }
            fixture.capture.receiveStreamFailure(SourceFailure.capture, from: fixture.native)
            try await fixture.failure.next()
            // Always release the owned noncooperative stop latch before joins.
            // Explicit stop makes legacy RED terminate with EOF, not hang.
            fixture.openAll()
            await fixture.provider.stopTranscription()
            switch await consumer?.result {
            case .some(.failure(let error)):
                #expect(error as? SourceFailure == .capture)
            case .some(.success):
                Issue.record("The source failure became normal provider EOF")
            case .none:
                Issue.record("Lost owned provider consumer")
            }
            #expect(!fixture.runtime.running)
            #expect(!fixture.native.running)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
        } catch {
            fixture.openAll()
            await fixture.cleanup()
            consumer?.cancel()
            _ = await consumer?.result
            throw error
        }
        await fixture.cleanup()
        consumer?.cancel()
        _ = await consumer?.result
    }

    @Test
    func nativeErrorDuringStartupKeepsItsOriginalRoundBoundCause() async throws {
        let fixture = SourceFixture(startHeld: true)
        var startup: Task<AsyncThrowingStream<TranscriptSegment, Error>, Error>?
        do {
            startup = Task { try await fixture.provider.startTranscription(config: config("startup-error")) }
            try await fixture.native.startGate.waitUntilEntered()
            fixture.capture.receiveStreamFailure(SourceFailure.capture, from: fixture.native)
            try await fixture.failure.next()
            // Cancellation cannot release this synthetic SDK startup. The test
            // releases its exact gate before waiting on the owned operation.
            fixture.openAll()
            switch await startup?.result {
            case .some(.failure(let error)):
                #expect(error as? SourceFailure == .capture,
                    "The old round's capture error must survive its cancellation fence")
            case .some(.success):
                Issue.record("Failed native startup returned a usable ASR stream")
            case .none:
                Issue.record("Lost owned provider startup")
            }
            await fixture.provider.stopTranscription()
            #expect(!fixture.runtime.running)
            #expect(!fixture.native.running)
            #expect(!fixture.provider.hasOwnedTranscriptionWork)
        } catch {
            fixture.openAll()
            startup?.cancel()
            _ = await startup?.result
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
        startup?.cancel()
        _ = await startup?.result
    }

    @Test
    func oldNativeErrorCannotTerminateReplacementProviderRound() async throws {
        let old = SourceNativeStream()
        let current = SourceNativeStream()
        old.openAll(); current.openAll()
        var creations = 0
        let capture = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
            creations += 1
            return creations == 1 ? old : current
        })
        old.onStart = { [weak capture] source in
            let activeCapture: ScreenCaptureKitSystemAudioCaptureService = try #require(capture)
            activeCapture.receiveAudioSampleBuffer(try stopRetrySample(), from: source)
        }
        current.onStart = old.onStart
        let runtime = SourceRuntime()
        let provider = LocalParakeetASRProvider(modelManager: SourceInstalledModelManager(),
            runtimeClient: runtime, systemAudioCaptureService: capture)
        do {
            _ = try await provider.startTranscription(config: config("retired-source"))
            let retiredSnapshot = provider.captureIngressSnapshot(forSessionID: "retired-source")
            let retiredIngress: LocalParakeetASRProvider.CaptureIngressSnapshot = try #require(retiredSnapshot)
            let retiredSystem: LocalParakeetASRProvider.CaptureIngressSnapshot.SourceCounters? = retiredIngress.sources[.systemAudio]
            #expect((retiredSystem?.bufferCount ?? 0) > 0)
            #expect((retiredSystem?.frameCount ?? 0) > 0)
            await provider.stopTranscription()
            try await capture.finishStoppingSystemAudioCapture()
            let stream = try await provider.startTranscription(config: config("current-source"))
            let currentSnapshot = provider.captureIngressSnapshot(forSessionID: "current-source")
            let currentIngress: LocalParakeetASRProvider.CaptureIngressSnapshot = try #require(currentSnapshot)
            let currentSystem: LocalParakeetASRProvider.CaptureIngressSnapshot.SourceCounters? = currentIngress.sources[.systemAudio]
            #expect((currentSystem?.bufferCount ?? 0) > 0)
            #expect((currentSystem?.frameCount ?? 0) > 0)
            capture.receiveStreamFailure(SourceFailure.capture, from: old)
            runtime.emit("Synthetic current question")
            runtime.finish()
            var values: [TranscriptSegment] = []
            for try await value in stream { values.append(value) }
            #expect(values.map(\.sessionID) == ["current-source"])
            #expect(values.allSatisfy { $0.speaker == .unknown && $0.source == .systemAudio })
            #expect(current.stopCalls == 1)
            #expect(capture.lastError == nil)
            #expect(!runtime.running)
            await provider.stopTranscription()
        } catch {
            old.openAll(); current.openAll()
            await provider.stopTranscription()
            _ = try? await capture.finishStoppingSystemAudioCapture()
            throw error
        }
        await provider.stopTranscription()
        _ = try? await capture.finishStoppingSystemAudioCapture()
    }

    @Test
    func sourceFailureAndNativeCleanupFailureHaveSeparateOutcomes() async throws {
        let fixture = SourceFixture()
        let environment = try await HirevaTestEnvironment(prefix: "ParakeetSourceFailure")
        var consumer: Task<Void, Error>?
        do {
            let stream = try await fixture.provider.startTranscription(config: config("cleanup-error"))
            consumer = Task { for try await _ in stream {} }
            fixture.native.stopFailure = .nativeStop
            fixture.capture.receiveStreamFailure(SourceFailure.capture, from: fixture.native)
            try await fixture.failure.next()
            fixture.openAll()
            await fixture.provider.stopTranscription()
            switch await consumer?.result {
            case .some(.failure(let error)): #expect(error as? SourceFailure == .capture)
            case .some(.success): Issue.record("Source failure was hidden by normal EOF")
            case .none: Issue.record("Lost owned provider consumer")
            }
            #expect(fixture.provider.captureCleanupFailure as? SourceFailure == .nativeStop)
            #expect(fixture.native.running)
            #expect(!fixture.runtime.running)
            environment.appState.activeASRProviderRuntime = fixture.provider
            #expect(await environment.appState.shutdownResources() == false)
            do {
                _ = try await fixture.provider.startTranscription(config: config("forbidden-after-stop-error"))
                Issue.record("A native cleanup failure permitted replacement resources")
            } catch { #expect(error as? SourceFailure == .nativeStop) }
            #expect(fixture.runtime.startCalls == 1)
        } catch {
            fixture.openAll()
            await fixture.cleanup()
            consumer?.cancel()
            _ = await consumer?.result
            try? await environment.shutdown()
            throw error
        }
        await fixture.cleanup()
        consumer?.cancel()
        _ = await consumer?.result
        try await environment.shutdown()
    }

    private func config(_ session: String) -> ASRConfig {
        ASRConfig(sessionID: session, captureMode: .systemAudioOnly)
    }

    private enum SourceFailure: Error, Equatable { case capture, nativeStop }

    @MainActor
    private final class SourceFixture {
        let native: SourceNativeStream
        let runtime = SourceRuntime()
        let capture: ScreenCaptureKitSystemAudioCaptureService
        let provider: LocalParakeetASRProvider
        let failure: SourceFailureSignal
        init(startHeld: Bool = false) {
            let native = SourceNativeStream()
            if !startHeld { native.startGate.open() }
            let capture = ScreenCaptureKitSystemAudioCaptureService(streamFactory: { native })
            self.native = native; self.capture = capture
            failure = SourceFailureSignal(capture)
            provider = LocalParakeetASRProvider(modelManager: SourceInstalledModelManager(),
                runtimeClient: runtime, systemAudioCaptureService: capture)
        }
        func openAll() { native.openAll() }
        func cleanup() async {
            openAll()
            await provider.stopTranscription()
            _ = try? await capture.finishStoppingSystemAudioCapture()
            native.stopFailure = nil
            if native.running { try? await native.stopCapture() }
            failure.close()
            #expect(!native.running)
            #expect(!runtime.running)
        }
    }

    @MainActor
    private final class SourceFailureSignal {
        private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        private let trace = TestEventWaitTrace(label: "parakeet_native_failure_control")
        private var observation: AnyCancellable?
        init(_ capture: ScreenCaptureKitSystemAudioCaptureService) {
            let continuation = events.continuation
            observation = capture.lastErrorUpdates.sink { value in
                if value != nil { continuation.yield(()) }
            }
        }
        func next() async throws { _ = try await trace.nextEvent(in: events.stream, event: "source_failure_published") }
        func close() { observation?.cancel(); observation = nil; events.continuation.finish() }
    }

    @MainActor
    private final class SourceNativeStream: SystemAudioCaptureStream {
        let startGate = SourceGate()
        let stopGate = SourceGate()
        var stopFailure: SourceFailure?
        var onStart: (@MainActor (SourceNativeStream) throws -> Void)?
        private(set) var running = false
        private(set) var stopCalls = 0
        // These source-error tests hold startup, not native stop. Rollback must
        // be able to finish before the caller gets to its cleanup block.
        init() { stopGate.open() }
        func startCapture() async throws {
            running = true
            await startGate.wait()
            try onStart?(self)
        }
        func stopCapture() async throws {
            stopCalls += 1
            await stopGate.wait()
            if let stopFailure { throw stopFailure }
            running = false
        }
        func openAll() { startGate.open(); stopGate.open() }
    }

    @MainActor
    private final class SourceRuntime: ParakeetRuntimeClient {
        private(set) var running = false
        private(set) var startCalls = 0
        private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
        func isRuntimeAvailable() async -> Bool { true }
        func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
            startCalls += 1; running = true
            let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
            continuation = pair.continuation
            return pair.stream
        }
        func emit(_ text: String) {
            continuation?.yield(.init(segmentId: UUID().uuidString, text: text, isFinal: true,
                startTime: nil, endTime: nil, audioSource: "systemAudio", speaker: nil))
        }
        func finish() { continuation?.finish() }
        func stop() async { continuation?.finish(); running = false }
        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    }

    private final class SourceInstalledModelManager: LocalModelManager {
        func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
        func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
        func deleteModel(_ model: LocalModelDescriptor) async throws {}
        func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
        func fileURL(for model: LocalModelDescriptor) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-native-source-model")
        }
    }

    @MainActor
    private final class SourceGate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private let trace = TestEventWaitTrace(label: "parakeet_native_source_gate")
        func wait() async {
            entry.continuation.yield(()); entry.continuation.finish()
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func waitUntilEntered() async throws { _ = try await trace.nextEvent(in: entry.stream, event: "entered") }
        func open() {
            opened = true
            let values = waiting; waiting.removeAll(); values.forEach { $0.resume() }
        }
    }
}
