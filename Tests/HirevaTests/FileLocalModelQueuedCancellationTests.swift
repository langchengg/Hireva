import Foundation
import Testing
@testable import Hireva

@MainActor
struct FileLocalModelQueuedCancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledQueuedMutationCannotChangeInstalledFiles(rollback: Bool) async throws {
        let fixture = try QueuedModelMutationFixture(rollback: rollback)
        do {
            fixture.startHolder()
            try await fixture.smoke.waitUntilEntered()
            fixture.startMutation()
            _ = try await fixture.trace.nextEvent(in: fixture.queued, event: "actualWaiterEnqueued")
            #expect(await fixture.waiter.pendingOperationWaiterCount(for: fixture.model) == 1)

            fixture.mutation?.cancel()
            // cancel() invokes cancellation handlers synchronously. Inspect the
            // real queue after it returns, without releasing its unrelated owner.
            #expect(await fixture.waiter.pendingOperationWaiterCount(for: fixture.model) == 0,
                "A cancelled model operation still retained its queued continuation.")
            #expect(await fixture.smoke.isHeld)
            #expect(try Data(contentsOf: fixture.destination) == fixture.installedPayload)

            fixture.consumer?.cancel()
            try await fixture.smoke.waitUntilCancelled()
            await fixture.smoke.release()
            let mutation = try #require(fixture.mutation)
            switch await mutation.result {
            case .success:
                Issue.record("Cancelled queued mutation returned success after the holder released.")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.destination.path),
                "A queued cancelled operation deleted the installed model.")
            if FileManager.default.fileExists(atPath: fixture.destination.path) {
                #expect(try Data(contentsOf: fixture.destination) == fixture.installedPayload,
                    "A queued cancelled operation replaced the installed model.")
            }
            #expect(FileManager.default.fileExists(atPath: fixture.rollbackURL.path))
            if FileManager.default.fileExists(atPath: fixture.rollbackURL.path) {
                #expect(try Data(contentsOf: fixture.rollbackURL) == fixture.rollbackPayload)
            }
            #expect(await fixture.waiter.pendingOperationWaiterCount(for: fixture.model) == 0)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }
}

@MainActor
private final class QueuedModelMutationFixture {
    let root: URL
    let modelRoot: URL
    let model: LocalModelDescriptor
    let trace: TestEventWaitTrace
    let smoke: QueuedModelHolderSmoke
    let holder: FileLocalModelManager
    let waiter: FileLocalModelManager
    let queued: AsyncStream<Void>
    let queuedContinuation: AsyncStream<Void>.Continuation
    let rollback: Bool
    let installedPayload = Data([1, 2, 3])
    let rollbackPayload = Data([7, 8, 9])
    var consumer: Task<Void, Error>?
    var mutation: Task<Void, Error>?
    var destination: URL { holder.fileURL(for: model) }
    var rollbackURL: URL { modelRoot.appendingPathComponent(".synthetic.bin.rollback") }

    init(rollback: Bool) throws {
        self.rollback = rollback
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaQueuedModelCancellation-\(UUID().uuidString)", isDirectory: true)
        modelRoot = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.bin")
        do {
            try Data([4, 5, 6]).write(to: source)
            try Data([1, 2, 3]).write(to: modelRoot.appendingPathComponent("synthetic.bin"))
            try Data([7, 8, 9]).write(to: modelRoot.appendingPathComponent(".synthetic.bin.rollback"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        model = LocalModelDescriptor(id: "synthetic-queued-mutation", displayName: "Synthetic Queued Mutation",
            kind: .transcription, sizeBytes: 3, downloadURL: source, checksum: nil,
            storageRelativePath: "synthetic.bin")
        trace = TestEventWaitTrace(label: rollback ? "file-model.queued.rollback" : "file-model.queued.delete")
        smoke = QueuedModelHolderSmoke(trace: trace)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        queued = pair.stream; queuedContinuation = pair.continuation
        let smoke = smoke
        holder = FileLocalModelManager(rootDirectory: modelRoot,
            modelSmokeValidator: { _, _ in await smoke.hold() })
        let trace = trace
        waiter = FileLocalModelManager(rootDirectory: modelRoot, operationDidQueue: {
            trace.mark("producer.operation.enqueued")
            pair.continuation.yield(())
            pair.continuation.finish()
        })
    }

    func startHolder() {
        let stream = holder.repairModel(model)
        consumer = Task { @MainActor in
            for try await _ in stream {}
            try Task.checkCancellation()
        }
    }

    func startMutation() {
        mutation = Task { @MainActor in
            if rollback { try await waiter.rollbackModel(model) }
            else { try await waiter.deleteModel(model) }
        }
    }

    func cleanup() async {
        mutation?.cancel(); consumer?.cancel()
        holder.closeDownloadAdmission(); waiter.closeDownloadAdmission()
        // Always release the unrelated holder, including a cancelled timeLimit
        // path. This makes the original uncancellable queued operation releasable.
        await smoke.release()
        _ = await consumer?.result
        _ = await mutation?.result
        let holderJoined = await holder.finishStoppingDownloadProducers()
        let waiterJoined = await waiter.finishStoppingDownloadProducers()
        queuedContinuation.finish()
        guard holderJoined, waiterJoined else {
            Issue.record("Owned model producer cleanup incomplete; retained fixture directory.")
            return
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned model cancellation fixture: \(error)") }
    }
}

private actor QueuedModelHolderSmoke {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let entered: AsyncStream<Void>
    nonisolated let cancelled: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let cancelledContinuation: AsyncStream<Void>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    var isHeld: Bool { held != nil && !released }

    init(trace: TestEventWaitTrace) {
        self.trace = trace
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entered = start.stream; enteredContinuation = start.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancelled = cancel.stream; cancelledContinuation = cancel.continuation
    }

    func hold() async {
        let cancel = cancelledContinuation
        let trace = trace
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                if released { pending.resume() } else { held = pending }
                trace.mark("producer.holder.entered")
                enteredContinuation.yield(()); enteredContinuation.finish()
            }
        } onCancel: {
            trace.mark("producer.holder.cancelled")
            cancel.yield(()); cancel.finish()
        }
        trace.mark("producer.holder.returned")
    }

    nonisolated func waitUntilEntered() async throws {
        _ = try await trace.nextEvent(in: entered, event: "holderEntered")
    }
    nonisolated func waitUntilCancelled() async throws {
        _ = try await trace.nextEvent(in: cancelled, event: "holderCancelled")
    }
    func release() {
        guard !released else { return }
        released = true
        trace.mark("test.holder.released")
        held?.resume(); held = nil
        enteredContinuation.finish(); cancelledContinuation.finish()
    }
}
