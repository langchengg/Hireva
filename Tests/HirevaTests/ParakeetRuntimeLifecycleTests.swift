import AVFoundation
import Darwin
import Foundation
import os
import Testing
@testable import Hireva

@Suite("Parakeet helper process lifecycle", .serialized)
struct ParakeetRuntimeLifecycleTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["system", "microphone", "revoked", "default", "cap"])
    func verificationPCMRetainsExactSubmittedPrefixAndJoinsOnce(mode: String) async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let committed = OSAllocatedUnfairLock(initialState: [Data]())
        let commit: ParakeetSidecarRuntimeClient.VerificationPCMCommit = { data, _, truncated, diagnostics in
                #expect(truncated == (mode == "cap"))
                #expect(diagnostics.pendingChunks == 0)
                #expect(diagnostics.droppedChunks == 0)
                #expect(data.count <= ParakeetSidecarRuntimeClient.maximumVerificationPCMBytes)
                committed.withLock { $0.append(data) }
            }
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            verificationPCMCommit: mode == "default" ? nil : commit)
        let captureMode: AudioCaptureMode = mode == "microphone" ? .microphoneOnly : .systemAudioOnly
        let session = "pcm-\(mode)"
        var stopping: Task<Void, Never>?
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                config: .init(sessionID: session, captureMode: captureMode))
            _ = try await helper.pid(for: session)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
            buffer.frameLength = 3
            let samples = try #require(buffer.floatChannelData)[0]
            samples[0] = 0.25; samples[1] = -0.5; samples[2] = 1
            let count = mode == "cap" ? ParakeetSidecarRuntimeClient.maximumVerificationPCMRecords + 1 : 1
            for index in 0..<count {
                runtime.appendAudioBuffer(buffer, at: AVAudioTime(sampleTime: Int64(index * 3), atRate: 48_000),
                    source: mode == "microphone" ? .microphone : .systemAudio)
                if index % 128 == 127 {
                    while runtime.audioWriterDiagnostics().pendingChunks > 0 { try await Task.sleep(for: .milliseconds(1)) }
                }
            }
            if mode == "revoked" { runtime.revokeVerificationPCM() }
            let stopTrace = TestEventWaitTrace(label: "PCMVerificationStop.\(mode)")
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            defer { entered.continuation.finish() }
            stopTrace.mark("stop.task.created")
            stopping = Task { @MainActor in
                stopTrace.mark("stop.main_actor.entered")
                entered.continuation.yield(())
                entered.continuation.finish()
                await runtime.stop()
                stopTrace.mark("stop.returned")
            }
            // Observe the command after its executor admits it, not while it is still queued.
            _ = try await stopTrace.nextEvent(in: entered.stream, event: "stop.admitted")
            try await helper.waitForStopCommand(for: session)
            helper.release(session)
            await stopping?.value
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
            let records = committed.withLock { $0 }
            #expect(records.count == (["system", "cap"].contains(mode) ? 1 : 0))
            if ["system", "cap"].contains(mode), let evidence = records.first {
                let wire = try helper.input(for: session)
                let audioLines = wire.split(separator: "\n").filter {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["type"] as? String == "audio"
                }
                #expect(audioLines.count == count)
                let audio = audioLines.prefix(ParakeetSidecarRuntimeClient.maximumVerificationPCMRecords).joined(separator: "\n") + "\n"
                #expect(evidence == Data(audio.utf8))
                let firstLine = try #require(audioLines.first)
                let object = try #require(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
                #expect(object["sequence"] as? Int == 1)
                #expect(object["sampleRate"] as? Int == 48_000)
                #expect(object["audioSource"] as? String == AudioSourceType.systemAudio.rawValue)
            }
            #expect(await runtime.cleanupFailure == nil)
            withExtendedLifetime(stream) {}
        } catch {
            helper.releaseAll()
            await runtime.stop()
            await stopping?.value
            try await helper.verifyOwnedHelpersExited()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2))) @MainActor
    func competingStartsAfterOneStopFenceCannotReplaceTheVocabularyOwner() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable }, vocabularyRoot: helper.directory)
        var starts: [Task<AsyncThrowingStream<ParakeetTranscriptEvent, Error>, Error>] = []
        let started = ContinuousClock.now
        do {
            let old = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("vocabulary-old"))
            _ = try await helper.pid(for: "vocabulary-old")
            print("[VocabularyGate] old fixture ready elapsed=\(started.duration(to: .now))")
            let entered = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2))
            starts = ["vocabulary-current-a", "vocabulary-current-b"].map { session in
                Task { @MainActor in
                    entered.continuation.yield(session)
                    return try await runtime.startTranscription(modelDirectory: helper.directory,
                        config: .init(sessionID: session, captureMode: .systemAudioOnly, contextualStrings: ["idempotency"]))
                }
            }
            var iterator = entered.stream.makeAsyncIterator()
            _ = await iterator.next(); _ = await iterator.next()
            entered.continuation.finish()
            print("[VocabularyGate] both entrants reached actor elapsed=\(started.duration(to: .now))")
            try await helper.waitForStopCommand(for: "vocabulary-old")
            helper.release("vocabulary-old")
            var streams: [AsyncThrowingStream<ParakeetTranscriptEvent, Error>] = []
            var failures: [Error] = []
            for start in starts {
                switch await start.result {
                case .success(let stream): streams.append(stream)
                case .failure(let error): failures.append(error)
                }
            }
            let directories = try FileManager.default.contentsOfDirectory(at: helper.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("ParakeetVocabulary-") }
            #expect(streams.count == 1 && failures.count == 1)
            #expect(failures.allSatisfy { $0.localizedDescription.contains("has not fully exited and drained") })
            #expect(directories.count == 1)
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
            #expect(runtime.cleanupFailure == nil)
            #expect(directories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            withExtendedLifetime((old, streams)) {}
        } catch {
            helper.releaseAll()
            await runtime.stop()
            for start in starts { _ = await start.result }
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
            throw error
        }
    }

    @Test
    func explicitStopJoinsAutomaticEOFCleanupBeforeReturning() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        var eofConsumer: Task<Void, Error>?
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("eof-old"))
            let consumer = Task { for try await _ in stream {} }
            eofConsumer = consumer
            let pid = try await helper.pid(for: "eof-old")
            try await helper.waitForStopCommand(for: "eof-old")

            await runtime.stop()
            expectForcedEOFExit(await consumer.result)

            #expect(!helper.isAlive(pid), "Awaited stop returned before the helper owned by automatic EOF cleanup exited")
            helper.release("eof-old")
            await runtime.stop()
            try await helper.waitForExit(pid)
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            _ = await eofConsumer?.result
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func newStartJoinsPreviousEOFCleanupAndOldStreamCannotStopNewHelper() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        var eofConsumer: Task<Void, Error>?
        do {
            let old = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("eof-old"))
            let consumer = Task { for try await _ in old {} }
            eofConsumer = consumer
            let oldPID = try await helper.pid(for: "eof-old")
            try await helper.waitForStopCommand(for: "eof-old")

            let current = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("current"))
            let currentPID = try await helper.pid(for: "current")
            expectForcedEOFExit(await consumer.result)
            #expect(!helper.isAlive(oldPID), "New start adopted a helper while the old owned helper was still draining")
            #expect(helper.isAlive(currentPID))

            helper.release("eof-old")
            try await helper.waitForExit(oldPID)
            let oldConsumer = Task { for try await _ in old {} }
            oldConsumer.cancel()
            _ = try? await oldConsumer.value
            #expect(helper.isAlive(currentPID))
            helper.release("current")
            await runtime.stop()
            try await helper.waitForExit(currentPID)
            withExtendedLifetime(current) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            _ = await eofConsumer?.result
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func forcedTerminationIsReapedBeforeAwaitedStopReturns() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("ignores-term"))
            let pid = try await helper.pid(for: "ignores-term")

            await runtime.stop()

            #expect(!helper.isAlive(pid), "Forced termination must be observed and reaped before stop completes")
            try await helper.waitForExit(pid)
            #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func cancellingStopWaiterDoesNotAbandonOwnedCleanup() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable })
        var stopWaiter: Task<Void, Never>?
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("cancelled-waiter"))
            let pid = try await helper.pid(for: "cancelled-waiter")
            stopWaiter = Task { await runtime.stop() }
            try await helper.waitForStopCommand(for: "cancelled-waiter")
            stopWaiter?.cancel()
            helper.release("cancelled-waiter")
            await stopWaiter?.value

            #expect(!helper.isAlive(pid))
            await runtime.stop()
            try await helper.waitForExit(pid)
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            await stopWaiter?.value
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            await stopWaiter?.value
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func stopDrainsAnAdmittedWriteBeforeTheCaptureCallbackReturns() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let gate = AudioCallbackGate()
        defer { gate.release() }
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable }, audioWriteAdmissionHook: {
            gate.pause()
        })
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory, config: config("admitted-write"))
            let pid = try await helper.pid(for: "admitted-write")
            let callback = AsyncStream<Result<Void, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let queue = DispatchQueue(label: "HirevaAdmittedPCMCallback-\(UUID().uuidString)")
            queue.async {
                let result: Result<Void, Error>
                do {
                    // The mutable SDK buffer stays on its creating callback queue.
                    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
                    buffer.frameLength = 8
                    for index in 0..<8 { buffer.floatChannelData?[0][index] = 0 }
                    runtime.appendAudioBuffer(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000))
                    result = .success(())
                } catch { result = .failure(error) }
                callback.continuation.yield(result)
                callback.continuation.finish()
            }
            var stop: Task<Void, Never>?
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var admissionObserved = false
                while !admissionObserved, ContinuousClock.now < deadline {
                    admissionObserved = gate.observeAdmission()
                    if !admissionObserved { try await Task.sleep(for: .milliseconds(10)) }
                }
                _ = try #require(admissionObserved)
                stop = Task { await runtime.stop() }
                try await helper.waitForStopCommand(for: "admitted-write")
                helper.release("admitted-write")
                await stop?.value

                #expect(gate.isPaused(), "The admission gate expired before the intended interleaving was checked")
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0, "Accepted audio must belong to the drained queue before stop returns")
                let input = try helper.input(for: "admitted-write")
                #expect(input.contains("\"type\":\"audio\""), "An admitted audio event was lost behind the stop command")
                #expect(input.contains("\"type\":\"stop\""))
                if let audio = input.range(of: "\"type\":\"audio\""), let stopCommand = input.range(of: "\"type\":\"stop\"") {
                    #expect(audio.lowerBound < stopCommand.lowerBound)
                }
                gate.release()
                for await result in callback.stream { try result.get() }
                await runtime.stop()
                try await helper.waitForExit(pid)
            } catch {
                gate.release()
                for await _ in callback.stream {} // Join on RED as well as success.
                helper.release("admitted-write")
                await runtime.stop()
                await stop?.value
                try? await helper.waitForExit(pid)
                throw error
            }
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func synchronousPCMIngressKeepsTheOwnedCallbackExecutor() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let observed = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            audioWriteAdmissionHook: { observed.continuation.yield(Thread.isMainThread) })
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                config: config("callback-executor"))
            var stop: Task<Void, Never>?
            do {
                let pid = try await helper.pid(for: "callback-executor")
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    observed.continuation.finish()
                }
                let callbackDone = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
                let queue = DispatchQueue(label: "HirevaControlledPCMIngress-\(UUID().uuidString)")
                queue.async {
                    defer {
                        callbackDone.continuation.yield(())
                        callbackDone.continuation.finish()
                    }
                    // The SDK object is created, borrowed and released on this
                    // callback queue. Only a Bool reaches the async test actor.
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8) else {
                        observed.continuation.finish()
                        return
                    }
                    buffer.frameLength = 8
                    for index in 0..<8 { buffer.floatChannelData?[0][index] = 0 }
                    runtime.appendAudioBuffer(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000), source: .systemAudio)
                }
                var wasMainThread: Bool?
                for await value in observed.stream { wasMainThread = value; break }
                deadline.cancel()
                await deadline.value
                observed.continuation.finish()
                for await _ in callbackDone.stream {} // Join the owned synchronous callback.
                #expect(wasMainThread == false, "Runtime control isolation moved synchronous PCM admission onto MainActor")
                stop = Task { await runtime.stop() }
                try await helper.waitForStopCommand(for: "callback-executor")
                helper.release("callback-executor")
                await stop?.value
                try await helper.waitForExit(pid)
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
            } catch {
                helper.release("callback-executor")
                await runtime.stop()
                await stop?.value
                throw error
            }
            await runtime.stop()
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func audioSerializationDoesNotRunOnTheCaptureCallbackCallStack() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let marker = "HirevaCaptureStack-\(UUID().uuidString)"
        let observation = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            audioSerializationCheckpoint: {
                observation.continuation.yield(Thread.current.threadDictionary[marker] as? Bool == true)
            })
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                config: config("serialization-value"))
            var stop: Task<Void, Never>?
            do {
                let pid = try await helper.pid(for: "serialization-value")
                try await appendFromOwnedQueue(runtime: runtime, frames: 8, marker: marker)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    observation.continuation.finish()
                }
                var serializedOnCaptureStack: Bool?
                for await value in observation.stream { serializedOnCaptureStack = value; break }
                deadline.cancel()
                await deadline.value
                observation.continuation.finish()
                #expect(serializedOnCaptureStack == false,
                    "Actual base64/JSON encoder was entered on the SDK capture callback call stack")
                stop = Task { await runtime.stop() }
                try await helper.waitForStopCommand(for: "serialization-value")
                helper.release("serialization-value")
                await stop?.value
                try await helper.waitForExit(pid)
                let input = try helper.input(for: "serialization-value")
                #expect(input.contains("\"type\":\"audio\""))
                #expect(input.contains("\"audioSource\":\"systemAudio\""))
                #expect(input.contains("\"type\":\"stop\""))
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
                #expect(runtime.audioWriterDiagnostics().pendingBytes == 0)
            } catch {
                observation.continuation.finish()
                helper.release("serialization-value")
                await runtime.stop()
                await stop?.value
                throw error
            }
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    @Test
    func overBudgetPCMIsDroppedBeforeTheEncoderRuns() async throws {
        let helper = try ControlledHelper()
        defer { helper.emergencyCleanup() }
        let executable = helper.executable
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let runtime = await ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            audioSerializationCheckpoint: { calls.withLock { $0 += 1 } })
        do {
            let stream = try await runtime.startTranscription(modelDirectory: helper.directory,
                config: config("oversize-value"))
            var stop: Task<Void, Never>?
            do {
                let pid = try await helper.pid(for: "oversize-value")
                let frames = ParakeetSidecarRuntimeClient.maximumPendingAudioBytes / MemoryLayout<Float>.size + 1
                try await appendFromOwnedQueue(runtime: runtime, frames: frames)
                #expect(calls.withLock { $0 } == 0,
                    "An over-budget callback performed base64/JSON work before it was rejected")
                let diagnostics = runtime.audioWriterDiagnostics()
                #expect(diagnostics.droppedChunks == 1)
                #expect(diagnostics.pendingChunks == 0)
                #expect(diagnostics.pendingBytes == 0)
                stop = Task { await runtime.stop() }
                try await helper.waitForStopCommand(for: "oversize-value")
                helper.release("oversize-value")
                await stop?.value
                try await helper.waitForExit(pid)
                #expect(calls.withLock { $0 } == 0, "A rejected snapshot was later encoded on the writer queue")
                let input = try helper.input(for: "oversize-value")
                #expect(!input.contains("\"type\":\"audio\""))
                #expect(input.contains("\"type\":\"stop\""))
                #expect(runtime.audioWriterDiagnostics().pendingChunks == 0)
                #expect(runtime.audioWriterDiagnostics().pendingBytes == 0)
            } catch {
                helper.release("oversize-value")
                await runtime.stop()
                await stop?.value
                throw error
            }
            withExtendedLifetime(stream) {}
            helper.releaseAll()
            await runtime.stop()
            try await helper.verifyOwnedHelpersExited()
        } catch {
            helper.releaseAll()
            await runtime.stop()
            do { try await helper.verifyOwnedHelpersExited() }
            catch let cleanupError {
                Issue.record(error)
                throw cleanupError
            }
            throw error
        }
    }

    private func appendFromOwnedQueue(runtime: ParakeetSidecarRuntimeClient,
        frames: Int, marker: String? = nil) async throws {
        let queue = DispatchQueue(label: "HirevaPCMValueCallback-\(UUID().uuidString)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if let marker { Thread.current.threadDictionary[marker] = true }
                defer { if let marker { Thread.current.threadDictionary.removeObject(forKey: marker) } }
                let result: Result<Void, Error>
                do {
                    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                    buffer.frameLength = AVAudioFrameCount(frames)
                    let channel = try #require(buffer.floatChannelData?[0])
                    for index in 0..<frames { channel[index] = 0 }
                    runtime.appendAudioBuffer(buffer, at: AVAudioTime(sampleTime: 0, atRate: 48_000), source: .systemAudio)
                    result = .success(())
                } catch { result = .failure(error) }
                // A second item on this serial queue resumes only after the
                // SDK callback and its scope/marker cleanup have returned.
                queue.async { continuation.resume(with: result) }
            }
        }
    }

    private func expectForcedEOFExit(_ result: Result<Void, Error>) {
        // This exact fixture closes stdout, ignores TERM and is not released
        // until cleanup has returned. Its real terminal is SIGKILL, not success.
        switch result {
        case .failure(let error):
            #expect(error as? ParakeetSidecarError == .exited(SIGKILL),
                "Only this fixture's exact forced-exit failure is expected")
        case .success:
            Issue.record("A helper requiring SIGKILL was reported as normal transcript EOF")
        }
    }

    private func config(_ sessionID: String) -> ASRConfig {
        ASRConfig(sessionID: sessionID, captureMode: .systemAudioOnly)
    }

    /// Blocking is confined to the controlled synchronous capture callback.
    /// Async test code uses nonblocking observations and always releases it.
    private struct AudioCallbackGate: Sendable {
        private let admitted = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private let returned = DispatchSemaphore(value: 0)

        func pause() {
            admitted.signal()
            _ = released.wait(timeout: .now() + 6)
            returned.signal()
        }
        func observeAdmission() -> Bool { admitted.wait(timeout: .now()) == .success }
        func isPaused() -> Bool { returned.wait(timeout: .now()) == .timedOut }
        func release() { released.signal() }
    }

    /// One interpreter PID, no subprocesses. A stop-command marker proves the
    /// runtime cleanup has started; release files bound failure-path cleanup.
    private final class ControlledHelper {
        let directory: URL
        let executable: URL
        private var owned: [String: Int32] = [:]
        private var completed: Set<String> = []
        private let trace = TestEventWaitTrace(label: "PCMHelperOwnedSynthetic")

        init() throws {
            _ = try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaHelperLifecycle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("synthetic-helper")
            let root = directory.path.replacingOccurrences(of: "'", with: "\\'")
            let script = #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            use IO::Select;
            my $root = '__ROOT__';
            my $session = '';
            for (my $i = 0; $i < scalar @ARGV; $i++) {
                $session = $ARGV[$i + 1] if $ARGV[$i] eq '--session-id';
            }
            die 'Invalid test session' unless $session =~ /^[a-z-]+$/;
            open(my $pid, '>', "$root/$session.pid") or die $!;
            print $pid $$;
            close($pid);
            $SIG{TERM} = 'IGNORE';
            close(STDOUT) if $session =~ /^eof-/;
            my $select = IO::Select->new(\*STDIN);
            my $input = '';
            # PCM preparation is owned by the test; the stop backstop starts on admission.
            my $deadline = $session =~ /^pcm-/ ? undef : time() + ($session =~ /^vocabulary-/ ? 120 : 10);
            my $exit_reason = '';
            while (1) {
                if (defined($deadline) && time() >= $deadline) { $exit_reason = 'resource-deadline'; last; }
                if (-e "$root/$session.release") { $exit_reason = 'released'; last; }
                if ($select->can_read(0.01)) {
                    my $count = sysread(STDIN, my $chunk, 65536);
                    if (defined($count) && $count > 0) {
                        open(my $log, '>>', "$root/$session.input") or die $!;
                        print $log $chunk;
                        close($log);
                        $input .= $chunk;
                        if ($input =~ /"type"\s*:\s*"stop"/) {
                            $deadline = time() + 10 if $session =~ /^pcm-/;
                            open(my $seen, '>', "$root/$session.stop-seen") or die $!;
                            close($seen);
                            $select->remove(\*STDIN);
                        }
                    } else {
                        $select->remove(\*STDIN);
                    }
                }
                select(undef, undef, undef, 0.01) unless $select->count;
            }
            open(my $exit_cause, '>', "$root/$session.exit-cause") or die $!;
            print $exit_cause $exit_reason;
            close($exit_cause);
            exit 0;
            """#.replacingOccurrences(of: "__ROOT__", with: root)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func pid(for session: String) async throws -> Int32 {
            let path = directory.appendingPathComponent("\(session).pid")
            try await waitUntil("PID \(session)") { (try? String(contentsOf: path, encoding: .utf8)).flatMap(Int32.init) != nil }
            let value = try #require(Int32(String(contentsOf: path, encoding: .utf8)))
            owned[session] = value
            trace.mark("helper.\(session).pid.\(value).ready")
            return value
        }

        func waitForStopCommand(for session: String) async throws {
            trace.mark("helper.\(session).stop_marker.observation.requested")
            defer {
                let cause = (try? String(contentsOf: directory.appendingPathComponent("\(session).exit-cause"), encoding: .utf8)) ?? "not-recorded"
                trace.mark("helper.\(session).stop_marker.observation.return.exit_cause.\(cause)")
            }
            let path = directory.appendingPathComponent("\(session).stop-seen")
            try await waitUntil("stop command \(session)") { FileManager.default.fileExists(atPath: path.path) }
        }

        func release(_ session: String) {
            trace.mark("helper.\(session).release")
            _ = FileManager.default.createFile(atPath: directory.appendingPathComponent("\(session).release").path, contents: Data())
        }

        func input(for session: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("\(session).input"), encoding: .utf8)
        }

        func isAlive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }

        func waitForExit(_ pid: Int32) async throws {
            try await waitUntil("owned exit \(pid)") { !self.isAlive(pid) }
            for session in owned.filter({ $0.value == pid }).keys {
                let cause = (try? String(contentsOf: directory.appendingPathComponent("\(session).exit-cause"), encoding: .utf8)) ?? "not-recorded"
                let bytes = (try? Data(contentsOf: directory.appendingPathComponent("\(session).input")).count) ?? 0
                trace.mark("helper.\(session).reaped.exit_cause.\(cause).input_bytes.\(bytes)")
            }
            completed.formUnion(owned.filter { $0.value == pid }.keys)
            owned = owned.filter { $0.value != pid }
        }

        private func waitUntil(_ label: String, _ condition: () -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(6))
            while !condition(), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try #require(condition(), "Controlled helper did not reach \(label) before deadline")
        }

        func releaseAll() {
            for path in pidFiles {
                release(path.deletingPathExtension().lastPathComponent)
            }
        }

        func verifyOwnedHelpersExited() async throws {
            for path in pidFiles {
                let session = path.deletingPathExtension().lastPathComponent
                guard !completed.contains(session) else { continue }
                let text = try String(contentsOf: path, encoding: .utf8)
                let pid = try #require(Int32(text), "Malformed synthetic helper PID marker")
                owned[session] = pid
                try await waitForExit(pid)
            }
        }

        private var pidFiles: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "pid" }
        }

        // Exact Process termination/drain belongs to the awaited runtime stop.
        // This fallback can release only markers in the fixture's unique root.
        func emergencyCleanup() {
            releaseAll()
            let unresolved = pidFiles.contains { path in
                guard let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text) else { return true }
                return isAlive(pid)
            }
            guard !unresolved else {
                Issue.record("Synthetic helper remains alive after awaited runtime cleanup; isolated fixture directory preserved")
                return
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
