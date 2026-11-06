import Darwin
import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct FileLocalModelTarCancellationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledPreflightCannotLaunchMoreArchiveProcesses(ignoreTermination: Bool) async throws {
        let fixture = try OwnedTarCancellationFixture(ignoreTermination: ignoreTermination)
        do {
            fixture.startConsumer()
            let pid = try await fixture.trace.nextEvent(in: fixture.ready, event: "ownedTarEntered")
            fixture.ownedPID = pid
            #expect(fixture.matchesRunningHelper(pid))
            #expect(fixture.factoryCallCount == 1)
            #expect(fixture.manager.pendingDownloadProducerCount == 1)

            let consumer = try #require(fixture.consumer)
            consumer.cancel()
            switch await consumer.result {
            case .success: Issue.record("Cancelled archive consumer returned success.")
            case .failure(let error): #expect(error is CancellationError)
            }
            fixture.manager.closeDownloadAdmission()
            // The original sync implementation is deliberately releasable.
            // This test proves no post-cancel archive process is started. It
            // does not claim prompt child exit before this explicit release.
            fixture.releaseHelper()
            #expect(await fixture.manager.finishStoppingDownloadProducers())
            #expect(fixture.factoryCallCount == 1,
                "A cancelled preflight launched another type-preflight/extraction process.")
            #expect(fixture.manager.pendingDownloadProducerCount == 0)
            #expect(!fixture.firstProcess.isRunning)
            let absent = Darwin.kill(pid, 0)
            let reason = errno
            #expect(absent == -1)
            #expect(reason == ESRCH)
            #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.modelRoot.path)
                .allSatisfy { !$0.contains(".archive.") && !$0.contains(".staging.") })
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationReapsHeldArchiveProcessBeforeFixtureRelease(ignoreTermination: Bool) async throws {
        let fixture = try OwnedTarCancellationFixture(ignoreTermination: ignoreTermination)
        do {
            fixture.startConsumer()
            let pid = try await fixture.trace.nextEvent(in: fixture.ready, event: "ownedTarEntered")
            fixture.ownedPID = pid
            #expect(fixture.matchesRunningHelper(pid))
            let consumer = try #require(fixture.consumer)
            consumer.cancel()
            switch await consumer.result {
            case .success: Issue.record("Cancelled archive consumer returned success.")
            case .failure(let error): #expect(error is CancellationError)
            }
            fixture.manager.closeDownloadAdmission()
            let stopped = try await fixture.trace.nextEvent(in: fixture.beginDrain(), event: "ownedTarDrainReturned")
            // No fixture release has occurred: this result requires the real
            // owned process TERM/KILL exit and reader closure path.
            #expect(!fixture.helperWasReleased)
            #expect(stopped)
            #expect(fixture.factoryCallCount == 1)
            #expect(fixture.manager.pendingDownloadProducerCount == 0)
            #expect(!fixture.firstProcess.isRunning)
            let absent = Darwin.kill(pid, 0)
            let reason = errno
            #expect(absent == -1)
            #expect(reason == ESRCH)
            #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.modelRoot.path)
                .allSatisfy { !$0.contains(".archive.") && !$0.contains(".staging.") })
            await fixture.cleanup()
        } catch {
            // The retained drain remains releasable even if this case's outer
            // deadline cancels its logical event wait on the old sync code.
            await fixture.cleanup()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func oversizedMergedArchiveOutputFailsAndReapsOwnedProcess(toStderr: Bool) async throws {
        let fixture = try OwnedTarCancellationFixture(ignoreTermination: false, overflowToStderr: toStderr)
        do {
            fixture.startConsumer()
            let pid = try await fixture.trace.nextEvent(in: fixture.ready, event: "ownedTarEntered")
            fixture.ownedPID = pid
            #expect(fixture.matchesRunningHelper(pid))
            fixture.releaseHelper()
            let result = try await fixture.trace.nextEvent(in: fixture.consumerFinished, event: "archiveOutputFailure")
            switch result {
            case .success: Issue.record("Oversized archive output was accepted.")
            case .failure(let error):
                let message = error.localizedDescription
                #expect(message == "Archive output exceeded 1048576 bytes"
                    || message == "Archive output event buffer overflow")
                #expect(!(error is CancellationError))
            }
            fixture.manager.closeDownloadAdmission()
            #expect(try await fixture.trace.nextEvent(in: fixture.beginDrain(), event: "archiveFailureDrainReturned"))
            #expect(fixture.factoryCallCount == 1)
            #expect(fixture.manager.pendingDownloadProducerCount == 0)
            #expect(!fixture.firstProcess.isRunning)
            let absent = Darwin.kill(pid, 0)
            let reason = errno
            #expect(absent == -1)
            #expect(reason == ESRCH)
            #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.modelRoot.path)
                .allSatisfy { !$0.contains(".archive.") && !$0.contains(".staging.") })
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }
    // Mixed-seam regression: the existing manager/producer/tar owner executes
    // real cleanup; only its already admitted synthetic reader and request
    // registration are controlled. No copied stop algorithm is exercised.
    @Test(.timeLimit(.minutes(1)))
    func concurrentManagerDrainsBorrowOneRetainedArchiveCleanupAttempt() async throws {
        let gate = ConcurrentArchiveDrainGate()
        let fixture = try OwnedTarCancellationFixture(ignoreTermination: false,
            archiveReadWillBegin: { gate.holdReadCallback() },
            archiveCleanupWillBegin: { await gate.holdExplicitCleanup() },
            archiveCleanupRequestDidRegister: { gate.requestRegistered(joined: $0) })
        var first: Task<Bool, Never>?
        var second: Task<Bool, Never>?
        try await withTaskCancellationHandler {
            do {
                fixture.startConsumer()
                let pid = try await fixture.trace.nextEvent(in: fixture.ready, event: "concurrent_tar_ready")
                fixture.ownedPID = pid
                #expect(fixture.matchesRunningHelper(pid))
                // Only the test's own finite helper is released. It emits the
                // synthetic listing and exits; its output callback stays held.
                fixture.releaseHelper()
                _ = try await fixture.trace.nextEvent(in: gate.readerEntered.stream,
                    event: "archive_reader_callback_admitted")
                fixture.consumer?.cancel()
                fixture.manager.closeDownloadAdmission()
                _ = await fixture.consumer?.result
                first = Task { await fixture.manager.finishStoppingDownloadProducers() }
                _ = try await fixture.trace.nextEvent(in: gate.explicitCleanupEntered.stream,
                    event: "retained_archive_explicit_cleanup_entered")
                // The producer's actual original 500 ms reader-stop deadline
                // failed while the callback was held. The exact command/key
                // remain in the manager's existing producer record.
                #expect(fixture.manager.pendingDownloadProducerCount == 1)
                second = Task { await fixture.manager.finishStoppingDownloadProducers() }
                let joined = try await fixture.trace.nextEvent(in: gate.thirdRequest.stream,
                    event: "second_manager_drain_registered")
                #expect(joined,
                    "A concurrent manager drain started another native cleanup attempt instead of borrowing its exact owner.")
                gate.releaseAll()
                #expect(await first!.value)
                #expect(await second!.value)
                #expect(gate.cleanupBodyCount == 2,
                    "Only the initial failed cleanup and one joined explicit recovery may execute.")
                #expect(fixture.factoryCallCount == 1)
                #expect(fixture.manager.pendingDownloadProducerCount == 0)
                #expect(!fixture.firstProcess.isRunning)
                #expect(try Data(contentsOf: fixture.destination) == fixture.oldPayload)
                await fixture.cleanup()
                gate.finishEvents()
            } catch {
                gate.releaseAll()
                fixture.releaseHelper()
                _ = await fixture.consumer?.result
                _ = await first?.value
                _ = await second?.value
                await fixture.cleanup()
                gate.finishEvents()
                throw error
            }
            #expect(!gate.cancellationReleaseUsed)
        } onCancel: {
            // This release needs no MainActor turn. Normal and throwing paths
            // still join every exact manager drain before fixture destruction.
            gate.releaseForOwningCancellation()
            fixture.releaseHelper()
        }
    }

}

private struct TarFixtureReaderState: Sendable {
    let descriptor: Int32
    var closed = false
    var bytes = Data()
}
private enum TarFixtureReadResult: Sendable { case none, ready(Int32), failed(String) }
private struct TarFixtureReleaseState: Sendable { let descriptor: Int32; var released = false; var closed = false }

@MainActor
private final class OwnedTarCancellationFixture {
    let root: URL
    let modelRoot: URL
    let model: LocalModelDescriptor
    let manager: FileLocalModelManager
    let firstProcess: Process
    let trace: TestEventWaitTrace
    let ready: AsyncStream<Int32>
    let readyContinuation: AsyncStream<Int32>.Continuation
    let consumerFinished: AsyncStream<Result<Void, Error>>
    private let consumerFinishedContinuation: AsyncStream<Result<Void, Error>>.Continuation
    private let nonce: String
    private let helper: URL
    private let startupURL: URL
    private let reader: OSAllocatedUnfairLock<TarFixtureReaderState>
    private let release: OSAllocatedUnfairLock<TarFixtureReleaseState>
    private let readinessHandle: FileHandle
    private let inputHandle: FileHandle
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var consumer: Task<Void, Error>?
    private var drainTask: Task<Void, Never>?
    var ownedPID: Int32?
    let oldPayload = Data([1, 2, 3])
    var destination: URL { manager.fileURL(for: model) }
    var factoryCallCount: Int { calls.withLock { $0 } }
    var helperWasReleased: Bool { release.withLock { $0.released } }

    init(ignoreTermination: Bool, overflowToStderr: Bool? = nil,
         archiveReadWillBegin: (@Sendable () -> Void)? = nil,
         archiveCleanupWillBegin: (@Sendable () async -> Void)? = nil,
         archiveCleanupRequestDidRegister: (@Sendable (Bool) -> Void)? = nil) throws {
        _ = try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        nonce = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaOwnedTar-\(nonce)", isDirectory: true)
        modelRoot = root.appendingPathComponent("models", isDirectory: true)
        helper = root.appendingPathComponent("tar-helper-\(nonce)")
        startupURL = root.appendingPathComponent("startup.ready")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let readyFIFO = root.appendingPathComponent("ready.fifo")
        let releaseFIFO = root.appendingPathComponent("release.fifo")
        guard mkfifo(readyFIFO.path, 0o600) == 0, mkfifo(releaseFIFO.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "OwnedTarFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create owned handshake pipes."])
        }
        let readyFD = open(readyFIFO.path, O_RDWR | O_NONBLOCK)
        let releaseFD = open(releaseFIFO.path, O_RDWR)
        guard readyFD >= 0, releaseFD >= 0 else {
            if readyFD >= 0 { close(readyFD) }; if releaseFD >= 0 { close(releaseFD) }
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "OwnedTarFixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open owned handshake pipes."])
        }
        reader = OSAllocatedUnfairLock(initialState: TarFixtureReaderState(descriptor: readyFD))
        release = OSAllocatedUnfairLock(initialState: TarFixtureReleaseState(descriptor: releaseFD))
        readinessHandle = FileHandle(fileDescriptor: readyFD, closeOnDealloc: false)
        inputHandle = FileHandle(fileDescriptor: releaseFD, closeOnDealloc: false)
        let pair = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        ready = pair.stream; readyContinuation = pair.continuation
        let finished = AsyncStream<Result<Void, Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        consumerFinished = finished.stream; consumerFinishedContinuation = finished.continuation
        trace = TestEventWaitTrace(label: overflowToStderr.map { $0 ? "file-model.tar.stderr-overflow" : "file-model.tar.stdout-overflow" }
            ?? (ignoreTermination ? "file-model.tar.ignore-term" : "file-model.tar.cancel"))
        let source = root.appendingPathComponent("source.tar.bz2")
        do {
            try Data([4, 5, 6]).write(to: source)
            try Data([1, 2, 3]).write(to: modelRoot.appendingPathComponent("synthetic.bin"))
            let script = #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            my ($fifo, $startup, $nonce) = @ARGV;
            __TERM__
            open(my $marker, '>', "$startup.pending") or die $!;
            print $marker "$nonce\n$$\n";
            close($marker);
            rename("$startup.pending", $startup) or die $!;
            open(my $ready, '>', $fifo) or die $!;
            print $ready "$nonce\n$$\n";
            close($ready);
            my $release;
            read(STDIN, $release, 1) == 1 or die 'owned release missing';
            __OUTPUT__
            exit 0;
            """#.replacingOccurrences(of: "__TERM__", with: ignoreTermination ? "$SIG{TERM} = 'IGNORE';" : "")
                .replacingOccurrences(of: "__OUTPUT__", with: overflowToStderr.map {
                    $0 ? "print STDERR ('x' x 2097152);" : "print STDOUT ('x' x 2097152);"
                } ?? "print \"bundle/model.bin\\n\";")
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            close(readyFD); close(releaseFD)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        model = LocalModelDescriptor(id: "synthetic-owned-tar", displayName: "Synthetic Owned Tar",
            kind: .transcription, sizeBytes: 3, downloadURL: source, checksum: nil,
            storageRelativePath: "synthetic.bin", archiveRootDirectory: "bundle")
        firstProcess = Process()
        firstProcess.executableURL = helper
        firstProcess.arguments = [readyFIFO.path, startupURL.path, nonce]
        firstProcess.standardInput = inputHandle
        let calls = calls
        let firstProcess = firstProcess
        manager = FileLocalModelManager(rootDirectory: modelRoot, tarProcessFactory: { _ in
            let first = calls.withLock { count -> Bool in count += 1; return count == 1 }
            if first { return firstProcess }
            // Fail immediately if the original implementation continues past
            // cancellation. No second held helper or synthetic extraction.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
            return process
        }, archiveReadWillBeginForTesting: archiveReadWillBegin,
            archiveCleanupWillBeginForTesting: archiveCleanupWillBegin,
            archiveCleanupRequestDidRegisterForTesting: archiveCleanupRequestDidRegister)
        let reader = reader
        let trace = trace
        let nonce = nonce
        readinessHandle.readabilityHandler = { handle in
            let result = reader.withLock { state -> TarFixtureReadResult in
                guard !state.closed else { return .none }
                var bytes = [UInt8](repeating: 0, count: 256)
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(state.descriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return .none }
                    return .failed("Owned tar handshake read failed.")
                }
                if count == 0 { return .none }
                state.bytes.append(contentsOf: bytes.prefix(count))
                guard state.bytes.count <= 256 else { return .failed("Owned tar handshake exceeded its bound.") }
                guard let text = String(data: state.bytes, encoding: .utf8) else { return .failed("Invalid handshake UTF-8.") }
                let fields = text.split(separator: "\n")
                guard fields.count == 2, fields[0] == nonce, let pid = Int32(fields[1]) else { return .none }
                return .ready(pid)
            }
            switch result {
            case .none: return
            case .ready(let pid):
                handle.readabilityHandler = nil
                trace.mark("producer.tar.handshake")
                pair.continuation.yield(pid); pair.continuation.finish()
            case .failed(let message):
                handle.readabilityHandler = nil
                trace.mark("producer.tar.handshake_failed")
                print("[OwnedTarFixture] \(message)")
                pair.continuation.finish()
            }
        }
    }

    func startConsumer() {
        let stream = manager.repairModel(model)
        consumer = Task { @MainActor in
            do {
                for try await _ in stream {}
                try Task.checkCancellation()
                consumerFinishedContinuation.yield(.success(())); consumerFinishedContinuation.finish()
            } catch {
                consumerFinishedContinuation.yield(.failure(error)); consumerFinishedContinuation.finish()
                throw error
            }
        }
    }

    func beginDrain() -> AsyncStream<Bool> {
        precondition(drainTask == nil)
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        drainTask = Task { @MainActor in
            let stopped = await manager.finishStoppingDownloadProducers()
            trace.mark("producer.tar.drain_returned")
            pair.continuation.yield(stopped); pair.continuation.finish()
        }
        return pair.stream
    }

    nonisolated func releaseHelper() {
        release.withLock { state in
            guard !state.closed, !state.released else { return }
            state.released = true
            // This FIFO retains the parent's own reader endpoint. A one-byte
            // release cannot raise SIGPIPE or fill its empty owned buffer.
            var byte: UInt8 = 1
            if Darwin.write(state.descriptor, &byte, 1) != 1 {
                Issue.record("Could not release owned tar helper.")
            }
        }
    }

    func matchesRunningHelper(_ pid: Int32) -> Bool {
        guard firstProcess.isRunning, firstProcess.processIdentifier == pid, Darwin.kill(pid, 0) == 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var count = bytes.count
        let result = mib.withUnsafeMutableBufferPointer { name in
            bytes.withUnsafeMutableBytes { buffer in
                sysctl(name.baseAddress, UInt32(name.count), buffer.baseAddress, &count, nil, 0)
            }
        }
        guard result == 0, count > MemoryLayout<Int32>.size else { return false }
        let arguments = bytes.prefix(count).dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        return arguments.contains { $0.elementsEqual(helper.path.utf8) }
            && arguments.contains { $0.elementsEqual(nonce.utf8) }
    }

    func cleanup() async {
        manager.closeDownloadAdmission(); consumer?.cancel()
        releaseHelper()
        if let text = try? String(contentsOf: startupURL, encoding: .utf8) {
            let fields = text.split(separator: "\n")
            if fields.count == 2, fields[0] == nonce, let pid = Int32(fields[1]), matchesRunningHelper(pid) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        _ = await consumer?.result
        // A logical wait can be cancelled independently of this retained drain.
        // Release/KILL above precedes joining, including the old blocking path.
        await drainTask?.value
        let joined = await manager.finishStoppingDownloadProducers()
        readinessHandle.readabilityHandler = nil
        reader.withLock { state in if !state.closed { state.closed = true; close(state.descriptor) } }
        release.withLock { state in if !state.closed { state.closed = true; close(state.descriptor) } }
        readyContinuation.finish()
        consumerFinishedContinuation.finish()
        guard joined else {
            Issue.record("Owned tar producer cleanup incomplete; kept fixture directory.")
            return
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove owned tar fixture: \(error)") }
    }
}


/// The only blocking latch lives on the controlled Dispatch reader queue.
/// Swift cleanup gates use resumable continuations and never hold a lock over
/// await. The owning test's cancellation releases both before any join.
private final class ConcurrentArchiveDrainGate: Sendable {
    private struct State: Sendable {
        var readerReleased = false
        var cleanupReleased = false
        var cancellationReleaseUsed = false
        var cleanupBodies = 0
        var requests = 0
        var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readerGate = DispatchSemaphore(value: 0)
    let readerEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let explicitCleanupEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let thirdRequest = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var cleanupBodyCount: Int { state.withLock { $0.cleanupBodies } }
    var cancellationReleaseUsed: Bool { state.withLock { $0.cancellationReleaseUsed } }

    func holdReadCallback() {
        guard !state.withLock({ $0.readerReleased }) else { return }
        readerEntered.continuation.yield(())
        readerEntered.continuation.finish()
        readerGate.wait()
    }
    func holdExplicitCleanup() async {
        await withCheckedContinuation { continuation in
            let admission = state.withLock { state -> (hold: Bool, firstExplicit: Bool) in
                state.cleanupBodies += 1
                guard state.cleanupBodies >= 2, !state.cleanupReleased else { return (false, false) }
                state.cleanupWaiters.append(continuation)
                return (true, state.cleanupBodies == 2)
            }
            if admission.firstExplicit {
                explicitCleanupEntered.continuation.yield(())
                explicitCleanupEntered.continuation.finish()
            }
            if !admission.hold { continuation.resume() }
        }
    }
    func requestRegistered(joined: Bool) {
        let third = state.withLock { state in state.requests += 1; return state.requests == 3 }
        if third { thirdRequest.continuation.yield(joined); thirdRequest.continuation.finish() }
    }
    func releaseAll() {
        let release = state.withLock { state -> (reader: Bool, swift: [CheckedContinuation<Void, Never>]) in
            let reader = !state.readerReleased
            state.readerReleased = true
            state.cleanupReleased = true
            let waiting = state.cleanupWaiters
            state.cleanupWaiters.removeAll()
            return (reader, waiting)
        }
        if release.reader { readerGate.signal() }
        release.swift.forEach { $0.resume() }
    }
    func releaseForOwningCancellation() {
        state.withLock { $0.cancellationReleaseUsed = true }
        releaseAll()
        finishEvents()
    }
    func finishEvents() {
        readerEntered.continuation.finish()
        explicitCleanupEntered.continuation.finish()
        thirdRequest.continuation.finish()
    }
}
