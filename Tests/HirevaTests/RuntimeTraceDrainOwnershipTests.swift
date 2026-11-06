#if DEBUG
import Combine
import Dispatch
import Foundation
import Testing
import os
@testable import Hireva

/// The first two mixed-seam RED cases use the actual writer, Diagnostics.shutdown
/// and AppState.shutdownResources. The seam holds only the private synthetic
/// store's IO and observes the existing diagnostics step; no audio/model starts.
@MainActor
struct RuntimeTraceDrainOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func diagnosticsShutdownJoinsAnAdmittedWriteWithoutBlockingMainActor() async throws {
        let root = try makeRoot()
        let gate = HeldTraceWrite()
        let events = AsyncStream<TraceDrainEvent>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let store = RuntimeTranscriptTraceStore(beforeAppendForTesting: { _ in gate.holdFirstWrite() },
            ownedDrainWaitingForTesting: { events.continuation.yield(.drainWaiting) })
        let owner = DiagnosticsState(traceLogURL: root.appendingPathComponent("trace.jsonl"), traceStore: store)
        var stop: Task<Bool, Never>?
        @MainActor func cleanup() async {
            gate.release()
            _ = await stop?.value
            await owner.shutdown()
            await store.finishPendingOperationsForTesting()
            gate.finishEvents(); events.continuation.finish()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                owner.recordCaptureCleanupResult(sessionID: "synthetic-drain", teardownID: UUID(),
                    released: true, mode: .metadataOnly)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "owned_file_write_held")
                stop = Task { @MainActor in
                    await owner.shutdown()
                    let writerWasStillHeld = !gate.wasReleased
                    events.continuation.yield(.shutdownReturned)
                    return writerWasStillHeld
                }
                // The RED implementation cannot produce drainWaiting: it
                // returns immediately. The GREEN callback observes registration
                // of the real scope's wait while the owned writer is held.
                let first = try await trace.nextEvent(in: events.stream, event: "drain_or_early_return")
                #expect(first == .drainWaiting)
                let heartbeat = Task { @MainActor in true }
                #expect(await heartbeat.value)
                #expect(!gate.writeRanOnMainThread)
                gate.release()
                #expect(await stop!.value == false,
                    "Returning from shutdown while its admitted file IO is held is not a completed trace drain.")
                await store.finishPendingOperationsForTesting()
                let contents = try String(contentsOf: owner.traceLogURL, encoding: .utf8)
                #expect(contents.contains("capture.cleanup.operation.completed"))
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
            #expect(!gate.cancelReleaseUsed)
        } onCancel: {
            gate.releaseForOwningCancellation()
            events.continuation.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func appFinalCleanupWaitsForTraceAdmittedAfterTheDiagnosticsStep() async throws {
        let root = try makeRoot()
        let write = HeldTraceWrite()
        let audit = LateTraceAuditAdmission()
        let events = AsyncStream<TraceDrainEvent>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let store = RuntimeTranscriptTraceStore(beforeAppendForTesting: { _ in write.holdFirstWrite() },
            ownedDrainWaitingForTesting: { events.continuation.yield(.drainWaiting) })
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), diagnosticsTraceStore: store)
        let owner = app.diagnosticsState
        owner.traceLogURL = root.appendingPathComponent("trace.jsonl")
        // This observational seam releases the already registered concrete
        // cleanup only after the actual Diagnostics step has finished.
        owner.shutdownWorkDidFinishForTesting = { audit.release() }
        let teardown = app.captureLifecycle.queueTeardown(after: nil) { teardownID in
            await audit.wait()
            owner.recordCaptureCleanupResult(sessionID: "synthetic-late-cleanup", teardownID: teardownID,
                released: true, mode: .metadataOnly)
            return true
        }
        var quit: Task<(Bool, Bool), Never>?
        @MainActor func cleanup() async {
            audit.release(); write.release()
            _ = await quit?.value
            await teardown.value
            owner.shutdownWorkDidFinishForTesting = nil
            #expect(await app.shutdownResources())
            await store.finishPendingOperationsForTesting()
            write.finishEvents(); events.continuation.finish()
            try? database.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                let trace = TestEventWaitTrace(label: #function)
                quit = Task { @MainActor in
                    let result = await app.shutdownResources()
                    let writerWasStillHeld = !write.wasReleased
                    events.continuation.yield(.shutdownReturned)
                    return (result, writerWasStillHeld)
                }
                _ = try await trace.nextEvent(in: write.entered.stream, event: "late_cleanup_audit_write_held")
                let first = try await trace.nextEvent(in: events.stream, event: "final_drain_or_early_app_return")
                #expect(first == .drainWaiting,
                    "The Diagnostics step precedes native/Generation/History cleanup; its earlier drain cannot finish later audit IO.")
                let heartbeat = Task { @MainActor in true }
                #expect(await heartbeat.value)
                write.release()
                let result = await quit!.value
                #expect(result.0)
                #expect(!result.1)
                await store.finishPendingOperationsForTesting()
                let contents = try String(contentsOf: owner.traceLogURL, encoding: .utf8)
                #expect(contents.contains("synthetic-late-cleanup"))
                #expect(contents.contains("capture.cleanup.operation.completed"))
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
            #expect(!write.cancelReleaseUsed)
        } onCancel: {
            audit.release(); write.releaseForOwningCancellation()
            events.continuation.finish()
        }
    }

    // The following cases exercise the added explicit bounded/seal contracts.
    // They are GREEN-stage contract tests, not claimed as original-API RED.
    @Test(.timeLimit(.minutes(1)))
    func boundedAdmissionIncludesHeldInflightUTF8AndRejectsNewestBeforeEnqueue() async throws {
        let root = try makeRoot()
        let gate = HeldTraceWrite()
        let store = RuntimeTranscriptTraceStore(maxPendingWriteCount: 2, maxPendingWriteBytes: 32,
            beforeAppendForTesting: { _ in gate.holdFirstWrite() })
        let writer = store.makeWriter()
        let url = root.appendingPathComponent("trace.jsonl")
        @MainActor func cleanup() async {
            gate.release()
            await writer.sealAndDrain()
            await store.finishPendingOperationsForTesting()
            gate.finishEvents()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                let first = "中文😀"
                let second = "é"
                #expect(writer.append(line: first, to: url, mode: .fullText) == .admitted)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "utf8_inflight_write_held")
                #expect(writer.append(line: second, to: url, mode: .fullText) == .admitted)
                #expect(writer.append(line: "overflow", to: url, mode: .fullText) == .overflow)
                #expect(writer.append(line: String(repeating: "界", count: 20), to: url, mode: .fullText) == .overflow)
                let bytes = first.utf8.count + second.utf8.count + 2
                #expect(writer.snapshot.pendingWriteCount == 2)
                #expect(writer.snapshot.pendingByteCount == bytes)
                #expect(writer.snapshot.overflowRejectedCount == 2)
                #expect(writer.snapshot.peakPendingWriteCount == 2)
                #expect(writer.snapshot.peakPendingByteCount == bytes)
                let heartbeat = Task { @MainActor in true }
                #expect(await heartbeat.value)
                gate.release()
                await writer.drain()
                #expect(writer.snapshot.pendingWriteCount == 0)
                #expect(writer.snapshot.pendingByteCount == 0)
                #expect(writer.snapshot.completedWriteCount == 2)
                #expect(writer.snapshot.failedWriteCount == 0)
                #expect(try String(contentsOf: url, encoding: .utf8) == first + "\n" + second + "\n")
                await cleanup()
            } catch { await cleanup(); throw error }
            #expect(!gate.cancelReleaseUsed)
        } onCancel: { gate.releaseForOwningCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticFileOverflowKeepsRuntimeFinalsAndMemoryControlEvents() async throws {
        let root = try makeRoot()
        let gate = HeldTraceWrite()
        let store = RuntimeTranscriptTraceStore(maxPendingWriteCount: 2,
            beforeAppendForTesting: { _ in gate.holdFirstWrite() })
        let owner = DiagnosticsState(traceLogURL: root.appendingPathComponent("trace.jsonl"), traceStore: store)
        @MainActor func final(_ sequence: Int) {
            owner.record(.asrFinal(sessionID: "synthetic-overflow", text: "", recognitionTaskID: "synthetic-asr",
                eventSequence: sequence, sourceStartUTF16: 0, sourceEndUTF16: 0, isFinal: true,
                timestamp: Date(timeIntervalSince1970: Double(sequence))), context: .init(), mode: .metadataOnly)
        }
        @MainActor func cleanup() async {
            gate.release()
            await owner.finalizeTraceWritesForShutdown()
            await store.finishPendingOperationsForTesting()
            gate.finishEvents()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                final(0)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "first_file_record_held")
                for sequence in 1..<200 { final(sequence) }
                owner.record(.generationCompleted(sessionID: "synthetic-overflow", questionID: "synthetic-q",
                    generationID: "synthetic-g", question: "", timestamp: Date()), context: .init(), mode: .metadataOnly)
                #expect(owner.runtime.finalTranscriptCount == 200)
                #expect(owner.recentEvents.count == 40)
                #expect(owner.recentEvents.last?.name == "generationCompleted")
                #expect(owner.recentEvents.contains { $0.name == "asrFinal" && $0.recognitionEventSequence == 199 })
                #expect(owner.traceWriteSnapshot.pendingWriteCount == 2)
                #expect(owner.traceWriteSnapshot.overflowRejectedCount == 199)
                gate.release()
                await owner.finalizeTraceWritesForShutdown()
                #expect(owner.traceWriteSnapshot.completedWriteCount == 2)
                #expect(owner.traceWriteSnapshot.pendingWriteCount == 0)
                let lines = try String(contentsOf: owner.traceLogURL, encoding: .utf8).split(separator: "\n")
                #expect(lines.count == 2)
                #expect(owner.runtime.finalTranscriptCount == 200)
                #expect(owner.recentEvents.last?.name == "generationCompleted")
                await cleanup()
            } catch { await cleanup(); throw error }
            #expect(!gate.cancelReleaseUsed)
        } onCancel: { gate.releaseForOwningCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func sealingOneDiagnosticOwnerNeitherJoinsNorClosesAnotherOwnersHeldWrite() async throws {
        let root = try makeRoot()
        let bGate = HeldTraceWrite()
        let bURL = root.appendingPathComponent("b.jsonl")
        let store = RuntimeTranscriptTraceStore(beforeAppendForTesting: { url in
            if url == bURL { bGate.holdFirstWrite() }
        })
        let a = DiagnosticsState(traceLogURL: root.appendingPathComponent("a.jsonl"), traceStore: store)
        let b = DiagnosticsState(traceLogURL: bURL, traceStore: store)
        @MainActor func record(_ owner: DiagnosticsState, _ sessionID: String) {
            owner.recordCaptureCleanupResult(sessionID: sessionID, teardownID: UUID(), released: true, mode: .metadataOnly)
        }
        @MainActor func cleanup() async {
            bGate.release()
            await a.finalizeTraceWritesForShutdown()
            await b.finalizeTraceWritesForShutdown()
            await store.finishPendingOperationsForTesting()
            bGate.finishEvents()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                record(a, "synthetic-a")
                await a.shutdown()
                let originalA = try String(contentsOf: a.traceLogURL, encoding: .utf8)
                record(b, "synthetic-b-one")
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: bGate.entered.stream, event: "unrelated_scope_b_held")
                await a.finalizeTraceWritesForShutdown()
                #expect(!bGate.wasReleased,
                    "Finishing already drained scope A must not wait for the shared store's unrelated scope B.")
                #expect(a.traceWriteSnapshot.isSealed)
                #expect(!b.traceWriteSnapshot.isSealed)
                record(a, "synthetic-late-a")
                record(b, "synthetic-b-two")
                #expect(a.traceWriteSnapshot.sealedRejectedCount == 1)
                #expect(b.traceWriteSnapshot.pendingWriteCount == 2)
                #expect(b.traceWriteSnapshot.sealedRejectedCount == 0)
                bGate.release()
                await b.finalizeTraceWritesForShutdown()
                #expect(try String(contentsOf: a.traceLogURL, encoding: .utf8) == originalA)
                let writtenB = try String(contentsOf: b.traceLogURL, encoding: .utf8)
                #expect(writtenB.contains("synthetic-b-one"))
                #expect(writtenB.contains("synthetic-b-two"))
                await cleanup()
            } catch { await cleanup(); throw error }
            #expect(!bGate.cancelReleaseUsed)
        } onCancel: { bGate.releaseForOwningCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func urlSelectionChangesDoNotForgetPreviouslyAdmittedFileWork() async throws {
        let root = try makeRoot()
        let gate = HeldTraceWrite()
        let store = RuntimeTranscriptTraceStore(beforeAppendForTesting: { _ in gate.holdFirstWrite() })
        let firstURL = root.appendingPathComponent("first.jsonl")
        let secondURL = root.appendingPathComponent("second.jsonl")
        let owner = DiagnosticsState(traceLogURL: firstURL, traceStore: store)
        @MainActor func cleanup() async {
            gate.release()
            await owner.finalizeTraceWritesForShutdown()
            await store.finishPendingOperationsForTesting()
            gate.finishEvents()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                owner.recordCaptureCleanupResult(sessionID: "synthetic-first-url", teardownID: UUID(), released: true, mode: .metadataOnly)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "old_url_write_held")
                owner.traceLogURL = secondURL
                owner.recordCaptureCleanupResult(sessionID: "synthetic-second-url", teardownID: UUID(), released: true, mode: .metadataOnly)
                #expect(owner.traceWriteSnapshot.pendingWriteCount == 2)
                gate.release()
                await owner.finalizeTraceWritesForShutdown()
                #expect(owner.traceWriteSnapshot.completedWriteCount == 2)
                #expect(owner.traceWriteSnapshot.isSealed)
                #expect(try String(contentsOf: firstURL, encoding: .utf8).contains("synthetic-first-url"))
                #expect(try String(contentsOf: secondURL, encoding: .utf8).contains("synthetic-second-url"))
                await cleanup()
            } catch { await cleanup(); throw error }
            #expect(!gate.cancelReleaseUsed)
        } onCancel: { gate.releaseForOwningCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func fileFailureIsVisibleAndItsExitedWriteDoesNotKeepDrainPending() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedDirectory = root.appendingPathComponent("file-is-not-a-directory")
        try Data("synthetic-blocker".utf8).write(to: blockedDirectory)
        let store = RuntimeTranscriptTraceStore()
        let owner = DiagnosticsState(traceLogURL: blockedDirectory.appendingPathComponent("trace.jsonl"), traceStore: store)
        owner.recordCaptureCleanupResult(sessionID: "synthetic-write-failure", teardownID: UUID(), released: true, mode: .metadataOnly)
        await owner.finalizeTraceWritesForShutdown()
        #expect(owner.traceWriteSnapshot.pendingWriteCount == 0)
        #expect(owner.traceWriteSnapshot.pendingByteCount == 0)
        #expect(owner.traceWriteSnapshot.completedWriteCount == 1)
        #expect(owner.traceWriteSnapshot.failedWriteCount == 1)
        #expect(owner.traceWriteSnapshot.isSealed)
        #expect(!FileManager.default.fileExists(atPath: owner.traceLogURL.path))
        owner.recordCaptureCleanupResult(sessionID: "synthetic-after-seal", teardownID: UUID(), released: true, mode: .metadataOnly)
        #expect(owner.traceWriteSnapshot.sealedRejectedCount == 1)
        #expect(owner.traceWriteSnapshot.completedWriteCount == 1)
        #expect(owner.recentEvents.last?.sessionID == "synthetic-after-seal",
            "Trace file closure does not become a business/control event drop.")
        await store.finishPendingOperationsForTesting()
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyAppendHeldWriterHasFiniteAdmissionWithoutChangingItsFileAPI() async throws {
        let root = try makeRoot()
        let gate = HeldTraceWrite()
        let store = RuntimeTranscriptTraceStore(beforeAppendForTesting: { _ in gate.holdFirstWrite() })
        let url = root.appendingPathComponent("trace.jsonl")
        @MainActor func cleanup() async {
            gate.release()
            await store.finishPendingOperationsForTesting()
            gate.finishEvents()
            try? FileManager.default.removeItem(at: root)
        }
        try await withTaskCancellationHandler {
            do {
                store.append(line: "synthetic-0", to: url)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.entered.stream, event: "compatibility_writer_held")
                for sequence in 1..<300 { store.append(line: "synthetic-\(sequence)", to: url) }
                let heartbeat = Task { @MainActor in true }
                #expect(await heartbeat.value)
                gate.release()
                await store.finishPendingOperationsForTesting()
                let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                // This is the proposed 256-write engineering contract, frozen
                // before execution. The old API previously had no pending cap;
                // this RED runs its actual append/IO path, not a copied queue.
                #expect(lines.count == 256,
                    "A held in-flight write plus admitted tail must be bounded; the legacy file API cannot remain a parallel unbounded production path.")
                #expect(lines.first == "synthetic-0")
                #expect(lines.last == "synthetic-255")
                await cleanup()
            } catch { await cleanup(); throw error }
            #expect(!gate.cancelReleaseUsed)
        } onCancel: { gate.releaseForOwningCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func synchronousRecordObserverCannotRedirectAnAdmittedEventToTheNextURL() async throws {
        let root = try makeRoot()
        let store = RuntimeTranscriptTraceStore()
        let firstURL = root.appendingPathComponent("original.jsonl")
        let nextURL = root.appendingPathComponent("next.jsonl")
        let owner = DiagnosticsState(traceLogURL: firstURL, traceStore: store)
        var switched = false
        let observation = owner.objectWillChange.sink {
            if !switched {
                switched = true
                owner.traceLogURL = nextURL
            }
        }
        @MainActor func cleanup() async {
            observation.cancel()
            await owner.shutdown()
            await store.finishPendingOperationsForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        owner.recordCaptureCleanupResult(sessionID: "synthetic-original-scope", teardownID: UUID(),
            released: true, mode: .metadataOnly)
        observation.cancel()
        await store.finishPendingOperationsForTesting()
        #expect(switched)
        #expect(owner.traceLogURL == nextURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path),
            "The original event's write URL must freeze before synchronous publication can select another scope.")
        #expect(!FileManager.default.fileExists(atPath: nextURL.path))
        await cleanup()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaTraceDrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}

private enum TraceDrainEvent: Equatable, Sendable { case drainWaiting, shutdownReturned }

private final class HeldTraceWrite: Sendable {
    private struct State: Sendable {
        var writeCount = 0
        var wasReleased = false
        var writeRanOnMainThread = false
        var cancelReleaseUsed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let hold = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var wasReleased: Bool { state.withLock { $0.wasReleased } }
    var writeRanOnMainThread: Bool { state.withLock { $0.writeRanOnMainThread } }
    var cancelReleaseUsed: Bool { state.withLock { $0.cancelReleaseUsed } }
    func holdFirstWrite() {
        let first = state.withLock {
            $0.writeCount += 1
            $0.writeRanOnMainThread = $0.writeRanOnMainThread || Thread.isMainThread
            return $0.writeCount == 1
        }
        if first {
            entered.continuation.yield(())
            hold.wait() // Only this private store's utility writer queue.
        }
    }
    func release() {
        let signal = state.withLock {
            guard !$0.wasReleased else { return false }
            $0.wasReleased = true
            return true
        }
        if signal { hold.signal() }
    }
    func releaseForOwningCancellation() {
        state.withLock { $0.cancelReleaseUsed = true }
        release(); finishEvents()
    }
    func finishEvents() { entered.continuation.finish() }
}

private final class LateTraceAuditAdmission: Sendable {
    private struct State: Sendable {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumed = state.withLock {
                if $0.released { return true }
                $0.waiter = continuation
                return false
            }
            if resumed { continuation.resume() }
        }
    }
    func release() {
        let owned = state.withLock {
            $0.released = true
            let waiter = $0.waiter
            $0.waiter = nil
            return waiter
        }
        owned?.resume()
    }
}
#endif
