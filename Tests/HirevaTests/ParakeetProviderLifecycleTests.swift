import AVFoundation
import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet provider lifecycle", .serialized)
@MainActor
struct ParakeetProviderLifecycleTests {
    @Test
    func stopRejectsEventsProducedByRuntimeCleanup() async throws {
        let runtime = ControlledRuntime()
        runtime.emitOnStop = true
        let provider = makeProvider(runtime)
        let stream = try await provider.startTranscription(config: config("stopped-round"))
        let consumer = Task { () throws -> [TranscriptSegment] in
            var received: [TranscriptSegment] = []
            for try await value in stream { received.append(value) }
            return received
        }

        await provider.stopTranscription()
        let received = try await consumer.value
        #expect(received.isEmpty)
        #expect(!runtime.running)
    }

    @Test
    func stopDuringNoncooperativeStartupInvalidatesTheReturnedRound() async throws {
        let runtime = ControlledRuntime()
        let startupGate = Gate()
        runtime.startupGate = startupGate
        let stopEntered = Gate()
        runtime.onStop = { stopEntered.open() }
        var captureStarts = 0
        let provider = makeProvider(runtime, startCapture: { _ in captureStarts += 1 })
        let startup = Task { try await provider.startTranscription(config: config("cancelled-startup")) }
        await startupGate.waitUntilEntered()
        let stop = Task { await provider.stopTranscription() }
        await stopEntered.wait()
        startupGate.open()
        await stop.value
        let result = await startup.result

        if case .success = result { Issue.record("Stopped startup returned a usable stream") }
        if case .failure(let error) = result { #expect(error is CancellationError) }
        #expect(captureStarts == 0)
        #expect(!runtime.running)
        await provider.stopTranscription()
    }

    @Test
    func newStartRetiresThePreviousBridgeBeforeAdoptingRuntime() async throws {
        let runtime = ControlledRuntime()
        let provider = makeProvider(runtime)
        let oldStream = try await provider.startTranscription(config: config("old-round"))
        let newStream = try await provider.startTranscription(config: config("new-round"))
        let oldYield = runtime.emit(sessionID: "old-round", text: "Stale synthetic transcript.")
        if case .some(.terminated) = oldYield {} else { Issue.record("Old upstream bridge still consumes after new start") }
        #expect(!runtime.startedOverActiveRuntime)
        runtime.emit(sessionID: "new-round", text: "Current synthetic transcript.")
        runtime.finish(sessionID: "old-round")
        runtime.finish(sessionID: "new-round")

        var oldValues: [TranscriptSegment] = []
        for try await value in oldStream { oldValues.append(value) }
        var newValues: [TranscriptSegment] = []
        for try await value in newStream { newValues.append(value) }
        #expect(oldValues.isEmpty)
        #expect(newValues.map(\.sessionID) == ["new-round"])
        await provider.stopTranscription()
    }

    @Test
    func consumerCancellationDrainsRuntimeAndBridge() async throws {
        let runtime = ControlledRuntime()
        let provider = makeProvider(runtime)
        let stream = try await provider.startTranscription(config: config("consumer-cancel"))
        let consumer = Task { for try await _ in stream {} }
        consumer.cancel()
        _ = try? await consumer.value
        await provider.waitForCurrentTranscriptionEnd()
        #expect(!runtime.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func sourceFailurePropagatesAfterIdempotentCleanup() async throws {
        let runtime = ControlledRuntime()
        let provider = makeProvider(runtime)
        let stream = try await provider.startTranscription(config: config("source-failure"))
        runtime.finish(sessionID: "source-failure", error: FixtureError.runtime)
        do {
            for try await _ in stream {}
            Issue.record("Source failure was presented as success")
        } catch {
            #expect(error as? FixtureError == .runtime)
        }
        await provider.waitForCurrentTranscriptionEnd()
        let stopCalls = runtime.stopCalls
        await provider.stopTranscription()
        await provider.stopTranscription()
        #expect(runtime.stopCalls == stopCalls)
        #expect(!runtime.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func captureStartupFailureReleasesRuntimeBeforeThrowing() async {
        let runtime = ControlledRuntime()
        let provider = makeProvider(runtime, startCapture: { _ in throw FixtureError.capture })
        do {
            _ = try await provider.startTranscription(config: config("capture-failure"))
            Issue.record("Capture failure did not propagate")
        } catch {
            #expect(error as? FixtureError == .capture)
        }
        #expect(!runtime.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    @Test
    func stopWaitsForNormalFinishCleanupAndBridgeCompletion() async throws {
        let runtime = ControlledRuntime()
        let provider = makeProvider(runtime)
        let stream = try await provider.startTranscription(config: config("normal-drain"))
        let cleanupGate = Gate()
        runtime.stopGate = cleanupGate
        let consumer = Task { for try await _ in stream {} }
        runtime.finish(sessionID: "normal-drain")
        await cleanupGate.waitUntilEntered()
        #expect(provider.hasOwnedTranscriptionWork)
        let stopEntered = Gate()
        let stop = Task {
            stopEntered.open()
            await provider.stopTranscription()
        }
        await stopEntered.wait()
        cleanupGate.open()
        await stop.value
        try await consumer.value
        #expect(!runtime.running)
        #expect(!provider.hasOwnedTranscriptionWork)
    }

    private enum FixtureError: Error, Equatable { case capture, runtime }

    private func makeProvider(
        _ runtime: ControlledRuntime,
        startCapture: @escaping (AudioCaptureMode) async throws -> Void = { _ in }
    ) -> LocalParakeetASRProvider {
        LocalParakeetASRProvider(modelManager: InstalledModelManager(), runtimeClient: runtime, startCapture: startCapture, stopCapture: {})
    }

    private func config(_ sessionID: String) -> ASRConfig {
        ASRConfig(sessionID: sessionID, captureMode: .systemAudioOnly)
    }

    @MainActor
    private final class ControlledRuntime: ParakeetRuntimeClient {
        var startupGate: Gate?
        var stopGate: Gate?
        var onStop: (() -> Void)?
        var emitOnStop = false
        private(set) var running = false
        private(set) var stopCalls = 0
        private(set) var startedOverActiveRuntime = false
        private var currentSessionID: String?
        private var continuations: [String: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation] = [:]

        func isRuntimeAvailable() async -> Bool { true }
        func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
            startedOverActiveRuntime = startedOverActiveRuntime || running
            let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
            continuations[config.sessionID] = pair.continuation
            currentSessionID = config.sessionID
            await startupGate?.wait()
            running = true
            return pair.stream
        }

        @discardableResult
        func emit(sessionID: String, text: String) -> AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation.YieldResult? {
            continuations[sessionID]?.yield(.init(segmentId: UUID().uuidString, text: text, isFinal: true, startTime: nil, endTime: nil, audioSource: "systemAudio", speaker: nil))
        }
        func finish(sessionID: String, error: Error? = nil) { continuations[sessionID]?.finish(throwing: error) }
        func stop() async {
            stopCalls += 1
            onStop?()
            await stopGate?.wait()
            if let currentSessionID {
                if emitOnStop { emit(sessionID: currentSessionID, text: "Late synthetic cleanup transcript.") }
                finish(sessionID: currentSessionID)
            }
            running = false
        }
        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    }

    private final class InstalledModelManager: LocalModelManager {
        func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
        func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
        func deleteModel(_ model: LocalModelDescriptor) async throws {}
        func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
        func fileURL(for model: LocalModelDescriptor) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-parakeet-model") }
    }

    @MainActor
    private final class Gate {
        private var entered = false
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            let entries = entryWaiters; entryWaiters.removeAll(); entries.forEach { $0.resume() }
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
        }
    }
}
