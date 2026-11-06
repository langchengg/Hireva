import AVFoundation
import Foundation
import Testing
@testable import Hireva

@MainActor
struct FileLocalModelProducerShutdownTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func setupShutdownWaitsForActualPrivateProducer(activeConsumerAlreadyRetired: Bool) async throws {
        let fixture = try FileProducerShutdownFixture(retired: activeConsumerAlreadyRetired)
        do {
            fixture.owner.downloadTranscriptionModel()
            let consumer = try #require(fixture.owner.operationTasks(for: .downloadTranscription).first)
            fixture.consumer = consumer
            try await fixture.smoke.waitUntilEntered()
            if activeConsumerAlreadyRetired {
                consumer.cancel()
                try await fixture.smoke.waitUntilCancelled()
                await consumer.value
                #expect(fixture.owner.pendingOperationTaskCount == 0)
            }

            fixture.shutdown = Task { @MainActor in
                await fixture.owner.shutdown()
                // Capture the actual boundary before emitting a result that
                // permits the test to release the private producer's gate.
                let wasReleased = await fixture.smoke.isReleased
                #expect(wasReleased, "Setup shutdown returned while its private model producer still held staging.")
                fixture.boundary.yield(.shutdownReturned)
            }
            if !activeConsumerAlreadyRetired { try await fixture.smoke.waitUntilCancelled() }
            let first = try await fixture.trace.nextEvent(in: fixture.events, event: "shutdownBoundary")
            #expect(first == .managerDrainEntered,
                "Shutdown joined only the stream consumer and never entered producer drain.")
            if first == .managerDrainEntered {
                // This is a projection of the actual manager's sole registry,
                // not an extra test/AppState copy of producer ownership.
                #expect(fixture.manager.pendingDownloadProducerCount == 1)
            }
            #expect(await fixture.smoke.isHeld)
            await fixture.smoke.release()
            await fixture.shutdown?.value
            await consumer.value
            #expect(fixture.manager.pendingDownloadProducerCount == 0)
            #expect(fixture.owner.pendingOperationTaskCount == 0)
            #expect(try await fixture.manager.verifyModel(fixture.model) == false)
            #expect(!FileManager.default.fileExists(atPath: fixture.manager.fileURL(for: fixture.model).path))
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }
}

private enum FileProducerShutdownBoundary: Equatable, Sendable { case managerDrainEntered, shutdownReturned }

/// Observes the narrow cleanup call and delegates all real work to the actual
/// file manager. It creates no producer Task or independent task registry.
private final class ObservedFileProducerManager: LocalModelManager {
    let actual: FileLocalModelManager
    let boundary: AsyncStream<FileProducerShutdownBoundary>.Continuation
    init(actual: FileLocalModelManager, boundary: AsyncStream<FileProducerShutdownBoundary>.Continuation) {
        self.actual = actual; self.boundary = boundary
    }
    var pendingDownloadProducerCount: Int { actual.pendingDownloadProducerCount }
    func closeDownloadAdmission() { actual.closeDownloadAdmission() }
    func finishStoppingDownloadProducers() async -> Bool {
        boundary.yield(.managerDrainEntered)
        return await actual.finishStoppingDownloadProducers()
    }
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { await actual.modelStatus(model) }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { actual.downloadModel(model) }
    func repairModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> { actual.repairModel(model) }
    func rollbackModel(_ model: LocalModelDescriptor) async throws { try await actual.rollbackModel(model) }
    func deleteModel(_ model: LocalModelDescriptor) async throws { try await actual.deleteModel(model) }
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { try await actual.verifyModel(model) }
    func fileURL(for model: LocalModelDescriptor) -> URL { actual.fileURL(for: model) }
}

@MainActor
private final class FileProducerShutdownFixture {
    let root: URL
    let model: LocalModelDescriptor
    let smoke: FileProducerShutdownSmokeGate
    let manager: FileLocalModelManager
    let owner: LocalModelsSetupViewModel
    let trace: TestEventWaitTrace
    let events: AsyncStream<FileProducerShutdownBoundary>
    let boundary: AsyncStream<FileProducerShutdownBoundary>.Continuation
    var consumer: Task<Void, Never>?
    var shutdown: Task<Void, Never>?

    init(retired: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaFileProducerShutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        do { try Data([7, 8, 9]).write(to: source) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        model = LocalModelDescriptor(id: "synthetic-shutdown-model", displayName: "Synthetic Shutdown Model",
            kind: .transcription, sizeBytes: 3, downloadURL: source, checksum: nil,
            storageRelativePath: "synthetic.bin")
        trace = TestEventWaitTrace(label: retired ? "file-producer.shutdown.retired" : "file-producer.shutdown.active")
        let pair = AsyncStream<FileProducerShutdownBoundary>.makeStream(bufferingPolicy: .bufferingNewest(2))
        events = pair.stream; boundary = pair.continuation
        let smoke = FileProducerShutdownSmokeGate(trace: trace)
        self.smoke = smoke
        let manager = FileLocalModelManager(rootDirectory: root.appendingPathComponent("models"),
            modelSmokeValidator: { _, _ in await smoke.hold() })
        self.manager = manager
        owner = LocalModelsSetupViewModel(transcriptionModel: model,
            modelManager: ObservedFileProducerManager(actual: manager, boundary: pair.continuation),
            qwenProvider: FileProducerUnusedQwen(), parakeetRuntimeClient: FileProducerUnusedRuntime())
    }

    func cleanup() async {
        owner.closeAdmission()
        manager.closeDownloadAdmission()
        consumer?.cancel(); shutdown?.cancel()
        await smoke.release()
        await consumer?.value
        await shutdown?.value
        await owner.waitForPendingOperations()
        _ = await manager.finishStoppingDownloadProducers()
        // The red seam's default manager cleanup is intentionally inert; this
        // existing gate barrier still prevents fixture deletion during writes.
        do { _ = try await manager.verifyModel(model) }
        catch { Issue.record("Could not establish owned filesystem cleanup barrier: \(error)"); return }
        boundary.finish()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned model shutdown fixture: \(error)") }
    }
}

private actor FileProducerShutdownSmokeGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let started: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isReleased: Bool { released }
    var isHeld: Bool { continuation != nil && !released }
    init(trace: TestEventWaitTrace) {
        self.trace = trace
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = start.stream; startedContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancelled = cancel.stream; cancelledContinuation = cancel.continuation
    }
    func hold() async {
        let cancelled = cancelledContinuation
        let trace = trace
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                if released { pending.resume() } else { continuation = pending }
                trace.mark("producer.smoke.entered")
                startedContinuation.yield(())
                startedContinuation.finish()
            }
        } onCancel: {
            trace.mark("producer.smoke.cancelled")
            cancelled.yield(())
            cancelled.finish()
        }
        trace.mark("producer.smoke.returned")
    }
    func release() {
        guard !released else { return }
        released = true
        trace.mark("test.smoke.released")
        continuation?.resume(); continuation = nil
        startedContinuation.finish(); cancelledContinuation.finish()
    }
    nonisolated func waitUntilEntered() async throws {
        _ = try await trace.nextEvent(in: started, event: "smokeEntered")
    }
    nonisolated func waitUntilCancelled() async throws {
        _ = try await trace.nextEvent(in: cancelled, event: "producerCancelled")
    }
}

private struct FileProducerUnusedQwen: LocalLLMProvider, Sendable {
    let id = "synthetic-unused-qwen"
    let displayName = "Synthetic unused Qwen"
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        LocalLLMHealth(ollamaRunning: false, selectedModel: modelName, modelInstalled: false,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        throw CancellationError()
    }
}
private final class FileProducerUnusedRuntime: ParakeetRuntimeClient {
    func isRuntimeAvailable() async -> Bool { false }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        throw CancellationError()
    }
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func stop() async {}
}
