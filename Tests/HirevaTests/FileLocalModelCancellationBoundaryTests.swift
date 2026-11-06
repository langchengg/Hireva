import Foundation
import Testing
@testable import Hireva

struct FileLocalModelCancellationBoundaryTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledConsumerCannotInstallAfterNoncooperativeSmokeReturns(repair: Bool) async throws {
        let fixture = try CancelledModelInstallFixture(repair: repair)
        let consumer = fixture.startConsumer()
        do {
            let stagedURL = try await fixture.gate.waitUntilEntered()
            #expect(try Data(contentsOf: stagedURL) == fixture.newPayload)
            #expect(FileManager.default.fileExists(atPath: fixture.destination.path) == repair)
            if repair {
                #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
            }

            consumer.cancel()
            // This observes cancellation of the actual private producer through
            // its injected smoke operation, before allowing that operation out.
            try await fixture.gate.waitUntilProducerCancelled()
            let result = await consumer.result
            switch result {
            case .success:
                Issue.record("The cancelled model stream consumer returned success")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(await fixture.gate.isHeld)

            await fixture.gate.release()
            // modelStatus can return active progress without taking the gate.
            // verifyModel always takes the real install operation gate. Its
            // return is a filesystem-mutation barrier, not a private Task join.
            let verified = try await fixture.manager.verifyModel(fixture.model)
            #expect(verified == repair)
            #expect(await fixture.manager.modelStatus(fixture.model) == (repair ? .installed : .notInstalled))
            #expect(FileManager.default.fileExists(atPath: fixture.destination.path) == repair)
            if repair {
                #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.rollback.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.modelRoot.path)
                .allSatisfy { !$0.contains(".staging.") && !$0.contains(".retired-rollback.") })
            await fixture.cleanup(consumer: consumer)
        } catch {
            await fixture.cleanup(consumer: consumer)
            throw error
        }
    }
}

private struct CancelledModelInstallFixture {
    let root: URL
    let modelRoot: URL
    let repairing: Bool
    let model: LocalModelDescriptor
    let manager: FileLocalModelManager
    let gate: CancelledModelSmokeGate
    let newPayload = Data([4, 5, 6])
    let oldPayload = Data([1, 2, 3])

    var destination: URL { manager.fileURL(for: model) }
    var rollback: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).rollback")
    }

    init(repair: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaCancelledModelInstall-\(UUID().uuidString)", isDirectory: true)
        let modelRoot = root.appendingPathComponent("models", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        do {
            try Data([4, 5, 6]).write(to: source)
            if repair {
                try Data([1, 2, 3]).write(to: modelRoot.appendingPathComponent("synthetic.bin"))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let model = LocalModelDescriptor(
            id: "synthetic-cancelled-install",
            displayName: "Synthetic Cancelled Install",
            kind: .transcription,
            sizeBytes: 3,
            downloadURL: source,
            checksum: nil,
            storageRelativePath: "synthetic.bin"
        )
        let gate = CancelledModelSmokeGate(label: repair ? "file-model.repair" : "file-model.install")
        self.root = root
        self.modelRoot = modelRoot
        self.repairing = repair
        self.model = model
        self.gate = gate
        manager = FileLocalModelManager(rootDirectory: modelRoot, modelSmokeValidator: { _, stagedURL in
            await gate.validate(stagedURL: stagedURL)
        })
    }

    func startConsumer() -> Task<Void, Error> {
        let stream = repairing ? manager.repairModel(model) : manager.downloadModel(model)
        return Task {
            for try await _ in stream {}
            try Task.checkCancellation()
        }
    }

    func cleanup(consumer: Task<Void, Error>) async {
        consumer.cancel()
        await gate.release()
        _ = await consumer.result
        // Cleanup also waits for the actual protected filesystem scope. A
        // cancelled test must release the noncooperative smoke gate first.
        do {
            _ = try await manager.verifyModel(model)
        } catch {
            Issue.record("Could not establish model filesystem cleanup barrier: \(error)")
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Could not remove owned synthetic model fixture: \(error)")
        }
    }
}

private actor CancelledModelSmokeGate {
    nonisolated let trace: TestEventWaitTrace
    nonisolated let enteredEvents: AsyncStream<URL>
    nonisolated let cancellationEvents: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<URL>.Continuation
    private let cancellationContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    var isHeld: Bool { releaseContinuation != nil && !released }

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        var entered: AsyncStream<URL>.Continuation!
        enteredEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { entered = $0 }
        enteredContinuation = entered
        var cancellation: AsyncStream<Void>.Continuation!
        cancellationEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cancellation = $0 }
        cancellationContinuation = cancellation
    }

    func validate(stagedURL: URL) async {
        let cancellation = cancellationContinuation
        let trace = trace
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
                trace.mark("producer.smoke.entered")
                enteredContinuation.yield(stagedURL)
            }
        } onCancel: {
            trace.mark("producer.smoke.cancelled")
            cancellation.yield(())
        }
        trace.mark("producer.smoke.returned")
    }

    nonisolated func waitUntilEntered() async throws -> URL {
        try await trace.nextEvent(in: enteredEvents, event: "smokeEntered")
    }

    nonisolated func waitUntilProducerCancelled() async throws {
        _ = try await trace.nextEvent(in: cancellationEvents, event: "producerCancelled")
    }

    func release() {
        guard !released else { return }
        released = true
        trace.mark("test.smoke.release")
        releaseContinuation?.resume()
        releaseContinuation = nil
        enteredContinuation.finish()
        cancellationContinuation.finish()
    }
}
