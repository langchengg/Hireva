import Dispatch
import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct ParakeetOutputBackpressureTests {
    @Test
    func recognizerConfigurationRejectsForeignIdentityAndPrivateFields() throws {
        var fields: [String: LocalJSONValue] = [
            "type": .string("recognizer_configuration"), "schemaVersion": .number(1),
            "configurationScope": .string("submitted_after_successful_create"), "creationSucceeded": .boolean(true),
            "helperPID": .number(777), "sessionID": .string("synthetic-config"), "captureMode": .string("systemAudioOnly"),
            "decodingMethod": .string("modified_beam_search"), "maxActivePaths": .number(4), "numThreads": .number(2),
            "modelType": .string("nemo_transducer"), "modelingUnit": .string("bpe"), "hotwordsScore": .number(2.5),
            "hasHotwordsConfiguration": .boolean(true), "hasBPEVocabulary": .boolean(true)]
        func sanitize(_ fields: [String: LocalJSONValue]) throws -> String? {
            let line = String(decoding: try JSONEncoder().encode(LocalJSONValue.object(fields)), as: UTF8.self)
            return ParakeetSidecarRuntimeClient.redactedConfigurationAcknowledgement(line,
                sessionID: "synthetic-config", captureMode: "systemAudioOnly", helperPID: 777)
        }
        let safe = try #require(try sanitize(fields))
        #expect(try JSONDecoder().decode(LocalJSONValue.self, from: Data(safe.utf8)) == .object(fields))
        let invalid: [(String, LocalJSONValue)] = [
            ("sessionID", .string("retired-session")), ("helperPID", .number(778)),
            ("captureMode", .string("microphoneOnly")), ("creationSucceeded", .boolean(false)),
            ("schemaVersion", .boolean(true)), ("modelingUnit", .string("private-path")),
            ("numThreads", .number(1.5)), ("hotwordsScore", .number(3.1)),
            ("hasBPEVocabulary", .boolean(false)), ("decodingMethod", .string("greedy_search")),
            ("terms", .array([.string("private-term")])), ("path", .string("private-path"))]
        for (key, value) in invalid {
            var bad = fields; bad[key] = value
            #expect(try sanitize(bad) == nil, "Reject unsafe config field: \(key)")
        }
        fields["decodingMethod"] = .string("greedy_search")
        fields["modelingUnit"] = .null; fields["hotwordsScore"] = .number(0)
        fields["hasHotwordsConfiguration"] = .boolean(false); fields["hasBPEVocabulary"] = .boolean(false)
        #expect(try sanitize(fields) != nil)
        #expect(ParakeetSidecarRuntimeClient.redactedConfigurationAcknowledgement(String(repeating: "x", count: 2049),
            sessionID: "synthetic-config", captureMode: "systemAudioOnly", helperPID: 777) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func configurationStderrPreservesActualTranscriptAndOwnedDrain() async throws {
        let stdout = try encodedEvents(count: 1)
        let stderr = Data(("{\"type\":\"recognizer_configuration\",\"path\":\"private-field-is-not-a-transcript\",\"padding\":\""
            + String(repeating: "x", count: 300) + "\"}\n{\"type\":\"ready\"}\n").utf8)
        let helper = try FiniteOutputHelper(stdout: stdout, stderr: stderr)
        let checkpoint = OutputReadCheckpoint(channel: "stderr", expectedBytes: stderr.count,
            helperDeadlineExpired: { helper.deadlineExpired })
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            outputReadCheckpoint: { checkpoint.receive($0, $1, $2, $3) })
        try await withTaskCancellationHandler {
            do {
                let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "configuration-stderr", captureMode: .systemAudioOnly))
                let trace = TestEventWaitTrace(label: #function)
                let observed = try await trace.nextEvent(in: checkpoint.completed.stream, event: "configuration_stderr_processed")
                #expect(!observed.finished && !observed.helperDeadlineExpired)
                helper.release(); await runtime.stop()
                let collected = await collectStoppedOutput(stream, trace: trace)
                #expect(collected.failure == nil && collected.values == [event(index: 0)])
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0 && runtime.audioWriterDiagnostics().pendingBytes == 0)
                checkpoint.finish(); try helper.removeAfterOwnedStop()
            } catch {
                helper.release(); checkpoint.finish(); await runtime.stop(); throw error
            }
        } onCancel: { checkpoint.releaseForOwningTestCancellation(); helper.release() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["queue", "stdout", "stderr"])
    func outputOverflowFailsClosedBeforePausedConsumerResumes(mode: String) async throws {
        let stdout: Data, stderr: Data
        if mode == "queue" {
            stdout = try encodedEvents(count: 65); stderr = Data()
        } else if mode == "stdout" {
            stdout = try JSONEncoder().encode(event(index: 0, text: String(repeating: "X", count: 65_537)))
            stderr = Data()
        } else {
            stdout = Data(); stderr = Data(repeating: 0x78, count: 65_537)
        }
        let helper = try FiniteOutputHelper(stdout: stdout, stderr: stderr)
        let checkpoint = OutputReadCheckpoint(channel: mode == "stderr" ? "stderr" : "stdout",
            expectedBytes: mode == "stderr" ? stderr.count : stdout.count,
            helperDeadlineExpired: { helper.deadlineExpired })
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            outputReadCheckpoint: { checkpoint.receive($0, $1, $2, $3) })
        try await withTaskCancellationHandler {
            do {
                let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "bounded-\(mode)", captureMode: .systemAudioOnly))
                // Read checkpoint runs after the actual reader/parser/yield.
                // No transcript consumer runs until the finite payload has
                // reached that boundary, so buffer admission is deterministic.
                let trace = TestEventWaitTrace(label: #function)
                let result = try await trace.nextEvent(in: checkpoint.completed.stream,
                    event: "finite_native_output_processed")
                trace.mark("caller.main_actor.resumed.finite_native_output")
                #expect(!result.helperDeadlineExpired,
                    "Readable output must be processed while the helper keeps its pipe open.")
                #expect(result.finished, "Business overflow must terminate output while the consumer is paused.")
                #expect(result.maximumReadBytes <= 65_536)
                helper.release()
                trace.mark("caller.owned_stop.requested")
                await runtime.stop()
                trace.mark("caller.owned_stop.returned")
                let collected = await collectStoppedOutput(stream, trace: trace)
                let received = collected.values
                let failure = collected.failure
                if mode == "queue" {
                    #expect(received.map(\.segmentId) == (0..<64).map { "segment-\($0)" },
                        "Already admitted partial/final events remain in order before the overflow error.")
                    #expect(received.map(\.isFinal) == (0..<64).map { $0.isMultiple(of: 2) })
                    #expect(failure == "Parakeet transcript output buffer overflow (64 events).")
                } else {
                    #expect(received.isEmpty)
                    #expect(failure == "Parakeet \(mode) line exceeded 65536 bytes.")
                }
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
                #expect(runtime.audioWriterDiagnostics().pendingBytes == 0)
                // A successful fresh launch proves the existing exact Process
                // owner no longer retains an incomplete previous cleanup.
                try helper.clearPayloads()
                let restarted = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "bounded-restart", captureMode: .systemAudioOnly))
                helper.release()
                trace.mark("caller.owned_stop.requested")
                await runtime.stop()
                trace.mark("caller.owned_stop.returned")
                withExtendedLifetime(restarted) {}
                checkpoint.finish()
                try helper.removeAfterOwnedStop()
            } catch {
                helper.release()
                checkpoint.finish()
                await runtime.stop()
                // Preserve the isolated files if source cleanup failed; the
                // test never signals an inferred PID or an unrelated process.
                throw error
            }
            #expect(!checkpoint.cancellationReleaseUsed)
        } onCancel: {
            checkpoint.releaseForOwningTestCancellation()
            helper.release()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exactEventBudgetPreservesUTF8PartialFinalAndNormalDrain() async throws {
        let stdout = try encodedEvents(count: 64)
        let helper = try FiniteOutputHelper(stdout: stdout, stderr: Data())
        let checkpoint = OutputReadCheckpoint(channel: "stdout", expectedBytes: stdout.count,
            helperDeadlineExpired: { helper.deadlineExpired })
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            outputReadCheckpoint: { checkpoint.receive($0, $1, $2, $3) })
        try await withTaskCancellationHandler {
            do {
                let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "exact-output-budget", captureMode: .systemAudioOnly))
                let trace = TestEventWaitTrace(label: #function)
                let observed = try await trace.nextEvent(in: checkpoint.completed.stream,
                    event: "exact_native_output_processed")
                trace.mark("caller.main_actor.resumed.exact_native_output")
                #expect(!observed.helperDeadlineExpired,
                    "A short readable payload must not wait for helper EOF to fill the read budget.")
                #expect(!observed.finished, "The exact count budget is usable; it is not overflow.")
                helper.release()
                trace.mark("caller.owned_stop.requested")
                await runtime.stop()
                trace.mark("caller.owned_stop.returned")
                let collected = await collectStoppedOutput(stream, trace: trace)
                let values = collected.values
                #expect(collected.failure == nil, "Normal stopped output must drain without a transcript error.")
                #expect(values.map(\.segmentId) == (0..<64).map { "segment-\($0)" })
                #expect(values.map(\.text) == (0..<64).map { "Synthetic 中文🙂 \($0)" })
                #expect(values.map(\.isFinal) == (0..<64).map { $0.isMultiple(of: 2) })
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
                checkpoint.finish()
                try helper.removeAfterOwnedStop()
            } catch {
                helper.release(); checkpoint.finish()
                await runtime.stop()
                throw error
            }
            #expect(!checkpoint.cancellationReleaseUsed)
        } onCancel: { checkpoint.releaseForOwningTestCancellation(); helper.release() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["stdout", "stderr"])
    func exactStopJoinsAnAlreadyAdmittedNativeReader(channel: String) async throws {
        let stdout = channel == "stdout" ? try encodedEvents(count: 1) : Data()
        let stderr = channel == "stderr" ? Data("Synthetic reader held\n".utf8) : Data()
        let helper = try FiniteOutputHelper(stdout: stdout, stderr: stderr)
        let callback = HeldOutputReadCallback(channel: channel)
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            outputReadCheckpoint: { callback.receive($0, $1, $2, $3) },
            outputReaderDrainDidWait: { callback.readerDrainDidWait($0) })
        var stopTask: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "owned-reader-\(channel)", captureMode: .systemAudioOnly))
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: callback.entered.stream, event: "native_callback_held")
                #expect(!callback.hasExited)
                // The test owns only this marker and callback latch. The
                // runtime remains the sole owner that terminates/reaps Process.
                helper.release()
                let exactStop = Task {
                    await runtime.stop()
                    callback.stopReturned()
                }
                stopTask = exactStop
                let first = try await trace.nextEvent(in: callback.lifecycle.stream,
                    event: "reader_drain_wait_or_stop_return")
                // The seam observes an actual registered drain waiter only in
                // the repaired implementation. On the seam-only baseline,
                // stop returns while the native callback is still held.
                #expect(first == .readerDrainWaiting,
                    "Stop must retain its exact native reader until the callback exits.")
                #expect(!callback.hasExited)
                callback.release()
                await callback.finishHeldCallback()
                await exactStop.value
                #expect(callback.hasExited)
                await runtime.stop()
                // Restart is attempted only after the old callback and its
                // exact stop have both exited, even when the RED assertion fails.
                try helper.clearPayloads()
                let restarted = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "reader-restart", captureMode: .systemAudioOnly))
                await runtime.stop()
                withExtendedLifetime((stream, restarted)) {}
                callback.finish()
                try helper.removeAfterOwnedStop()
            } catch {
                callback.release()
                helper.release()
                await callback.finishHeldCallback()
                await stopTask?.value
                await runtime.stop()
                callback.finish()
                throw error
            }
            #expect(!callback.cancellationReleaseUsed)
        } onCancel: {
            // Registered before native start. This synchronous escape never
            // requires MainActor and always releases the exact owned callback.
            callback.releaseForOwningCancellation()
            helper.release()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["stderrOverflow", "exitStatus"])
    func stdoutEOFDoesNotHideLaterStderrOrNonzeroExit(mode: String) async throws {
        let stderr = mode == "stderrOverflow"
            ? Data(repeating: 0x78, count: 65_537)
            : Data("Synthetic nonzero exit\n".utf8)
        let helper = try FiniteOutputHelper(stdout: Data(), stderr: stderr,
            emitStderrAfterStdoutEOF: true, exitStatus: mode == "exitStatus" ? 42 : 0)
        let checkpoint = StdoutEOFCheckpoint(emitStderr: { helper.emitStderr() })
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            outputReadCheckpoint: { checkpoint.receive($0, $1, $2, $3) })
        try await withTaskCancellationHandler {
            do {
                let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                    config: .init(sessionID: "stdout-eof-\(mode)", captureMode: .systemAudioOnly))
                let trace = TestEventWaitTrace(label: #function)
                let finishedAtStdoutEOF = try await trace.nextEvent(in: checkpoint.completed.stream,
                    event: "stdout_eof_before_stderr_and_process_exit")
                #expect(!finishedAtStdoutEOF,
                    "Stdout EOF cannot establish success before stderr and exact Process exit.")
                var received: [ParakeetTranscriptEvent] = []
                var failure: String?
                do { for try await value in stream { received.append(value) } }
                catch { failure = error.localizedDescription }
                helper.release()
                await runtime.stop()
                #expect(received.isEmpty)
                #expect(failure == (mode == "stderrOverflow"
                    ? "Parakeet stderr line exceeded 65536 bytes."
                    : "Parakeet sidecar exited with code 42."))
                #expect(!helper.deadlineExpired)
                checkpoint.finish()
                try helper.removeAfterOwnedStop()
            } catch {
                helper.release()
                checkpoint.finish()
                await runtime.stop()
                throw error
            }
            #expect(!checkpoint.cancellationReleaseUsed)
        } onCancel: {
            checkpoint.releaseForOwningCancellation()
            helper.release()
        }
    }

    // These values are already copied and the native owner has stopped.
    // Collect them off MainActor in one bounded operation; the real runtime
    // start/stop and every admission/order/error assertion remain unchanged.
    private nonisolated func collectStoppedOutput(
        _ stream: AsyncThrowingStream<ParakeetTranscriptEvent, Error>, trace: TestEventWaitTrace
    ) async -> (values: [ParakeetTranscriptEvent], failure: String?) {
        trace.mark("collector.nonisolated.entered")
        var values: [ParakeetTranscriptEvent] = []
        var failure: String?
        do {
            for try await value in stream {
                values.append(value)
                if values.count == 1 || values.count == 64 { trace.mark("collector.count.\(values.count)") }
                // One extra value is retained as an assertion-failing witness;
                // a broken stream cannot make the test accumulate without bound.
                if values.count > ParakeetSidecarRuntimeClient.maximumPendingTranscriptEvents {
                    trace.mark("collector.unexpected_extra_value")
                    break
                }
            }
        } catch { failure = error.localizedDescription }
        trace.mark("collector.return.count.\(values.count).failed.\(failure != nil)")
        return (values, failure)
    }

    private func event(index: Int, text: String? = nil) -> ParakeetTranscriptEvent {
        .init(segmentId: "segment-\(index)", text: text ?? "Synthetic 中文🙂 \(index)",
            isFinal: index.isMultiple(of: 2), startTime: nil, endTime: nil,
            audioSource: "systemAudio", speaker: nil)
    }
    private func encodedEvents(count: Int) throws -> Data {
        var bytes = Data()
        for index in 0..<count { bytes.append(try JSONEncoder().encode(event(index: index))); bytes.append(0x0A) }
        return bytes
    }
}

private struct OutputReadResult: Sendable {
    let finished: Bool
    let maximumReadBytes: Int
    let helperDeadlineExpired: Bool
}
private final class OutputReadCheckpoint: Sendable {
    private struct State: Sendable {
        var generation: Int?
        var readBytes = 0
        var maximumReadBytes = 0
        var delivered = false
        var cancellationReleaseUsed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let channel: String
    private let expectedBytes: Int
    private let helperDeadlineExpired: @Sendable () -> Bool
    private let trace = TestEventWaitTrace(label: "Parakeet-output-read-boundary")
    let completed = AsyncStream<OutputReadResult>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(channel: String, expectedBytes: Int, helperDeadlineExpired: @escaping @Sendable () -> Bool) {
        self.channel = channel; self.expectedBytes = expectedBytes
        self.helperDeadlineExpired = helperDeadlineExpired
    }
    var cancellationReleaseUsed: Bool { state.withLock { $0.cancellationReleaseUsed } }
    func receive(_ generation: Int, _ channel: String, _ bytes: Int, _ finished: Bool) {
        guard channel == self.channel else { return }
        let result = state.withLock { value -> (finished: Bool, maximumReadBytes: Int)? in
            guard !value.delivered else { return nil }
            if value.generation == nil { value.generation = generation }
            guard value.generation == generation else { return nil }
            value.readBytes += bytes
            value.maximumReadBytes = max(value.maximumReadBytes, bytes)
            // Overflow itself is the actionable boundary; cleanup may close
            // readers before the rest of an already rejected payload drains.
            guard value.readBytes >= expectedBytes || finished else { return nil }
            value.delivered = true
            return (finished, value.maximumReadBytes)
        }
        if let result {
            // Capture the helper's finite escape marker on the actual native
            // producer boundary, outside the ordinary lock. A delayed UI test
            // continuation cannot relabel an earlier successful read as slow.
            let observed = OutputReadResult(finished: result.finished,
                maximumReadBytes: result.maximumReadBytes, helperDeadlineExpired: helperDeadlineExpired())
            trace.mark("producer.ready.channel.\(channel).deadline_expired.\(observed.helperDeadlineExpired)")
            completed.continuation.yield(observed); completed.continuation.finish()
        }
    }
    func finish() { completed.continuation.finish() }
    func releaseForOwningTestCancellation() {
        state.withLock { $0.cancellationReleaseUsed = true }
        finish()
    }
}

/// One test-owned interpreter, no subprocesses or model. Only the production
/// runtime owns Process termination/reaping; cancellation releases this fixture.
private final class FiniteOutputHelper: Sendable {
    let directory: URL
    let executable: URL
    private let releaseURL: URL
    var deadlineExpired: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("deadline-expired").path)
    }
    init(stdout: Data, stderr: Data, emitStderrAfterStdoutEOF: Bool = false, exitStatus: Int32 = 0) throws {
        _ = try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaBoundedOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        executable = directory.appendingPathComponent("synthetic-helper")
        releaseURL = directory.appendingPathComponent("release")
        try stdout.write(to: directory.appendingPathComponent("stdout"))
        try stderr.write(to: directory.appendingPathComponent("stderr"))
        let root = directory.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = #"""
        #!/usr/bin/perl
        use strict;
        use warnings;
        use IO::Select;
        my $root = '__ROOT__';
        binmode(STDOUT); binmode(STDERR);
        for my $channel ('stdout', 'stderr') {
            open(my $source, '<:raw', "$root/$channel") or die $!;
            while (read($source, my $data, 257)) {
                my $output = $channel eq 'stdout' ? \*STDOUT : \*STDERR;
                my $position = 0;
                while ($position < length($data)) {
                    my $count = syswrite($output, $data, length($data) - $position, $position);
                    die 'Synthetic output write failed' unless defined($count) && $count > 0;
                    $position += $count;
                }
            }
            close($source);
            if ($channel eq 'stdout' && __DEFER_STDERR__) {
                close(STDOUT);
                my $phase_deadline = time() + 30;
                while (!-e "$root/emit-stderr" && !-e "$root/release" && time() < $phase_deadline) {
                    select(undef, undef, undef, 0.01);
                }
                if (time() >= $phase_deadline) {
                    open(my $marker, '>', "$root/deadline-expired") or die $!;
                    close($marker);
                }
                last if -e "$root/release" || time() >= $phase_deadline;
            }
        }
        # The deferred branch deliberately ignores the stop line until its
        # own EOF checkpoint releases stderr. It then exits finitely.
        exit __EXIT_STATUS__ if __DEFER_STDERR__;
        my $select = IO::Select->new(\*STDIN);
        my $input = '';
        my $deadline = time() + 30;
        while (time() < $deadline && !-e "$root/release") {
            if ($select->can_read(0.01)) {
                my $count = sysread(STDIN, my $data, 65536);
                last if !defined($count) || $count == 0;
                $input .= $data;
                last if $input =~ /"type"\s*:\s*"stop"/;
            }
        }
        if (time() >= $deadline) {
            open(my $marker, '>', "$root/deadline-expired") or die $!;
            close($marker);
        }
        exit 0;
        """#.replacingOccurrences(of: "__ROOT__", with: root)
            .replacingOccurrences(of: "__DEFER_STDERR__", with: emitStderrAfterStdoutEOF ? "1" : "0")
            .replacingOccurrences(of: "__EXIT_STATUS__", with: String(exitStatus))
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func release() { _ = FileManager.default.createFile(atPath: releaseURL.path, contents: Data()) }
    func emitStderr() {
        _ = FileManager.default.createFile(atPath: directory.appendingPathComponent("emit-stderr").path, contents: Data())
    }
    func clearPayloads() throws {
        try Data().write(to: directory.appendingPathComponent("stdout"))
        try Data().write(to: directory.appendingPathComponent("stderr"))
    }
    func removeAfterOwnedStop() throws { try FileManager.default.removeItem(at: directory) }
}

/// The actual stdout EOF callback releases only this helper's stderr marker.
/// It never waits on MainActor or requires concurrent stdout/stderr callbacks.
private final class StdoutEOFCheckpoint: Sendable {
    private struct State: Sendable {
        var delivered = false
        var cancellationReleaseUsed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let emitStderr: @Sendable () -> Void
    let completed = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(emitStderr: @escaping @Sendable () -> Void) { self.emitStderr = emitStderr }
    var cancellationReleaseUsed: Bool { state.withLock { $0.cancellationReleaseUsed } }
    func receive(_: Int, _ channel: String, _ bytes: Int, _ finished: Bool) {
        guard channel == "stdout", bytes == 0 else { return }
        let admitted = state.withLock { value in
            guard !value.delivered else { return false }
            value.delivered = true
            return true
        }
        guard admitted else { return }
        emitStderr()
        completed.continuation.yield(finished)
        completed.continuation.finish()
    }
    func finish() { completed.continuation.finish() }
    func releaseForOwningCancellation() {
        state.withLock { $0.cancellationReleaseUsed = true }
        finish()
    }
}

private enum OutputReaderLifecycleEvent: Equatable, Sendable {
    case readerDrainWaiting
    case stopReturned
}

/// A finite native-thread latch around the production callback's existing
/// checkpoint. Only a test-owned cancellation or the test body releases it;
/// no semaphore wait, process wait, or ordinary lock crosses MainActor/await.
private final class HeldOutputReadCallback: Sendable {
    private struct State: Sendable {
        var generation: Int?
        var released = false
        var exited = false
        var cancellationReleaseUsed = false
        var completionWaiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let channel: String
    let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let lifecycle = AsyncStream<OutputReaderLifecycleEvent>.makeStream(bufferingPolicy: .bufferingOldest(2))
    init(channel: String) { self.channel = channel }
    var hasExited: Bool { state.withLock { $0.exited } }
    var cancellationReleaseUsed: Bool { state.withLock { $0.cancellationReleaseUsed } }

    func receive(_ generation: Int, _ channel: String, _ bytes: Int, _: Bool) {
        guard channel == self.channel, bytes > 0 else { return }
        let admitted = state.withLock { value in
            guard value.generation == nil else { return false }
            value.generation = generation
            return true
        }
        guard admitted else { return }
        entered.continuation.yield(generation)
        entered.continuation.finish()
        // This method is invoked by the actual FileHandle callback, never UI.
        releaseSemaphore.wait()
        let ready = state.withLock { value -> CheckedContinuation<Void, Never>? in
            value.exited = true
            let ready = value.completionWaiter
            value.completionWaiter = nil
            return ready
        }
        ready?.resume()
    }

    func finishHeldCallback() async {
        await withCheckedContinuation { continuation in
            let waiting = state.withLock { value in
                guard value.generation != nil, !value.exited else { return false }
                precondition(value.completionWaiter == nil)
                value.completionWaiter = continuation
                return true
            }
            if !waiting { continuation.resume() }
        }
    }
    func readerDrainDidWait(_ generation: Int) {
        guard state.withLock({ $0.generation == generation }) else { return }
        lifecycle.continuation.yield(.readerDrainWaiting)
    }
    func stopReturned() { lifecycle.continuation.yield(.stopReturned) }
    func release() {
        let signal = state.withLock { value in
            guard !value.released else { return false }
            value.released = true
            return true
        }
        if signal { releaseSemaphore.signal() }
    }
    func releaseForOwningCancellation() {
        state.withLock { $0.cancellationReleaseUsed = true }
        release()
        finish()
    }
    func finish() {
        entered.continuation.finish()
        lifecycle.continuation.finish()
    }
}
