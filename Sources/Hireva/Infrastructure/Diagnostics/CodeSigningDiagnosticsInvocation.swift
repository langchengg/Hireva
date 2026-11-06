import Darwin
import Foundation
import os

/// Owns only read-only codesign diagnostics. Each caller has an exact task;
/// cancellation joins its processes, pipe readers and deadlines before return.
actor CodeSigningDiagnosticsInvocation {
    private struct Configuration: Sendable {
        let executableURL: URL
        let delayProvider: any DelayProvider
        let timeoutNanoseconds: UInt64
        let maximumOutputBytes: Int
        let onLaunched: (@Sendable (String, Process) -> Void)?
        let closeFileHandle: (@Sendable (String, FileHandle) throws -> Void)?
    }
    private struct UnreleasedProcess: Sendable {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
        let stdoutWriter: FileHandle
        let stderrWriter: FileHandle
        let stdoutLifetime: ReaderLifetime
        let stderrLifetime: ReaderLifetime
    }
    private struct Outcome: Sendable {
        let text: String
        var unreleased: [UnreleasedProcess] = []
    }
    private let configuration: Configuration
    private var operations: [UUID: Task<Outcome, Never>] = [:]
    private var unreleased: [UnreleasedProcess] = []
    private var closed = false

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/codesign"),
        delayProvider: any DelayProvider = RealDelayProvider(),
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        maximumOutputBytes: Int = 65_536,
        onLaunched: (@Sendable (String, Process) -> Void)? = nil,
        closeFileHandle: (@Sendable (String, FileHandle) throws -> Void)? = nil) {
        configuration = .init(executableURL: executableURL, delayProvider: delayProvider,
            timeoutNanoseconds: timeoutNanoseconds,
            maximumOutputBytes: max(maximumOutputBytes, 1), onLaunched: onLaunched,
            closeFileHandle: closeFileHandle)
    }

    func run(bundlePath: String) async -> String {
        guard !closed, !Task.isCancelled else { return "Code signing check cancelled" }
        guard unreleased.isEmpty else { return "Could not check: previous codesign cleanup incomplete" }
        let id = UUID(), configuration = configuration
        let task = Task { await Self.execute(bundlePath: bundlePath, configuration: configuration) }
        operations[id] = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        operations[id] = nil
        retainUnreleased(outcome.unreleased)
        return outcome.text
    }

    /// Application shutdown rejects new checks, cancels and joins every caller.
    /// A failed bounded cleanup remains owned and is never reported as released.
    func shutdown() async -> Bool {
        closed = true
        let captured = operations
        captured.values.forEach { $0.cancel() }
        for (id, task) in captured {
            let outcome = await task.value
            operations[id] = nil
            retainUnreleased(outcome.unreleased)
        }
        return operations.isEmpty && unreleased.isEmpty
    }

    private func retainUnreleased(_ resources: [UnreleasedProcess]) {
        for resource in resources where !unreleased.contains(where: { $0.process === resource.process }) {
            unreleased.append(resource)
        }
    }

    private enum Event: Sendable {
        case bytes(Data, isError: Bool), eof(isError: Bool), exited(Int32), deadline
    }
    private enum Failure: Error, LocalizedError {
        case timedOut, outputLimit, eventOverflow, incompleteOutput, readerCleanupTimeout
        case commandFailed(Int32, String)
        case cleanupIncomplete(String, processExited: Bool, readersStopped: Bool, handlesClosed: Bool)
        var errorDescription: String? {
            switch self {
            case .timedOut: return "Code signing check timed out"
            case .outputLimit: return "Code signing output exceeded its byte limit"
            case .eventOverflow: return "Code signing output event buffer overflow"
            case .incompleteOutput: return "Code signing output ended before process exit and pipe drain"
            case .readerCleanupTimeout: return "Code signing readers did not finish within their cleanup deadline"
            case .commandFailed(let status, let text): return "Code signing query failed (\(status)): \(text)"
            case .cleanupIncomplete(let cause, let exited, let stopped, let closed):
                return "\(cause); codesign cleanup incomplete (process exited=\(exited), readers stopped=\(stopped), handles closed=\(closed))"
            }
        }
    }
    private struct Query: Sendable {
        var stdout = Data()
        var stderr = Data()
        var failure: Error?
        var unreleased: [UnreleasedProcess] = []
    }

    private nonisolated static func execute(bundlePath: String, configuration: Configuration) async -> Outcome {
        let identity = await query(arguments: ["-dvvvv", bundlePath], phase: "identity", configuration: configuration)
        if let failure = identity.failure {
            return .init(text: message(for: failure), unreleased: identity.unreleased)
        }
        guard !Task.isCancelled else { return .init(text: "Code signing check cancelled") }
        let requirement = await query(arguments: ["-d", "-r-", bundlePath], phase: "requirement", configuration: configuration)
        if let failure = requirement.failure {
            return .init(text: message(for: failure), unreleased: requirement.unreleased)
        }
        guard !Task.isCancelled else { return .init(text: "Code signing check cancelled") }
        let output = String(data: identity.stdout + identity.stderr, encoding: .utf8) ?? ""
        let reqOutput = String(data: requirement.stdout, encoding: .utf8) ?? ""
        var relevant = output.components(separatedBy: "\n").filter {
            $0.hasPrefix("Identifier=") || $0.hasPrefix("Authority=") ||
            $0.hasPrefix("TeamIdentifier=") || $0.hasPrefix("Signature=") || $0.contains("code signature")
        }
        if !reqOutput.isEmpty {
            relevant.append("Designated Requirement: \(reqOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if relevant.isEmpty {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(text: trimmed.isEmpty ? "Not signed" : String(trimmed.prefix(200)))
        }
        return .init(text: relevant.joined(separator: "\n"))
    }
    private nonisolated static func message(for failure: Error) -> String {
        failure is CancellationError ? "Code signing check cancelled" : "Could not check: \(failure.localizedDescription)"
    }

    private nonisolated static func query(arguments: [String], phase: String,
        configuration: Configuration) async -> Query {
        guard !Task.isCancelled else { return .init(failure: CancellationError()) }
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = stdout.fileHandleForReading, errorOutput = stderr.fileHandleForReading
        let events = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let outputLifetime = ReaderLifetime(), errorLifetime = ReaderLifetime()
        let owned = UnreleasedProcess(process: process, stdout: output, stderr: errorOutput,
            stdoutWriter: stdout.fileHandleForWriting, stderrWriter: stderr.fileHandleForWriting,
            stdoutLifetime: outputLifetime, stderrLifetime: errorLifetime)
        attachReader(output, isError: false, events: events.continuation, lifetime: outputLifetime)
        attachReader(errorOutput, isError: true, events: events.continuation, lifetime: errorLifetime)
        process.terminationHandler = { exited in
            if case .dropped = events.continuation.yield(.exited(exited.terminationStatus)) {
                events.continuation.finish(throwing: Failure.eventOverflow)
            }
        }
        defer {
            process.terminationHandler = nil
            events.continuation.finish()
        }
        do { try Task.checkCancellation(); try process.run() }
        catch {
            return await finishQuery(.init(failure: error), owned: owned, phase: phase,
                exit: nil, configuration: configuration)
        }
        configuration.onLaunched?(phase, process)
        let deadline = Task<Void, Never> {
            do {
                try await configuration.delayProvider.sleep(nanoseconds: configuration.timeoutNanoseconds)
                try Task.checkCancellation()
                if case .dropped = events.continuation.yield(.deadline) {
                    events.continuation.finish(throwing: Failure.eventOverflow)
                }
            } catch is CancellationError {} catch { events.continuation.finish(throwing: error) }
        }
        var query = Query()
        var exit: Int32?, stdoutClosed = false, stderrClosed = false
        await withTaskCancellationHandler {
            do {
                for try await event in events.stream {
                    try Task.checkCancellation()
                    switch event {
                    case .bytes(let data, let isError):
                        guard data.count <= configuration.maximumOutputBytes - query.stdout.count - query.stderr.count else {
                            throw Failure.outputLimit
                        }
                        if isError { query.stderr.append(data) } else { query.stdout.append(data) }
                    case .eof(let isError):
                        if isError { stderrClosed = true } else { stdoutClosed = true }
                    case .exited(let status): exit = status
                    case .deadline: throw Failure.timedOut
                    }
                    if exit != nil, stdoutClosed, stderrClosed { break }
                }
                try Task.checkCancellation()
                guard exit != nil, stdoutClosed, stderrClosed else { throw Failure.incompleteOutput }
            } catch { query.failure = error }
        } onCancel: { events.continuation.finish(throwing: CancellationError()) }
        deadline.cancel()
        await deadline.value
        events.continuation.finish()
        return await finishQuery(query, owned: owned, phase: phase,
            exit: exit, configuration: configuration)
    }

    private nonisolated static func finishQuery(_ initial: Query, owned: UnreleasedProcess,
        phase: String, exit: Int32?, configuration: Configuration) async -> Query {
        var query = initial
        // The retained cleanup is joined even when the caller was cancelled.
        // Close is allowed only after exact exit and reader access has ceased.
        let cleanup = Task {
            let exited = await stopExactProcess(owned.process)
            owned.stdoutLifetime.stopAdmission(to: owned.stdout)
            owned.stderrLifetime.stopAdmission(to: owned.stderr)
            let stopped = await joinReaders(outputDone: owned.stdoutLifetime.done,
                errorDone: owned.stderrLifetime.done)
            var closeErrors: [String] = []
            if exited && stopped {
                let handles = [("stdout-reader", owned.stdout), ("stderr-reader", owned.stderr),
                    ("stdout-writer", owned.stdoutWriter), ("stderr-writer", owned.stderrWriter)]
                for (label, handle) in handles {
                    do {
                        if let close = configuration.closeFileHandle {
                            try close("\(phase).\(label)", handle)
                        } else { try handle.close() }
                    } catch { closeErrors.append("\(label): \(error.localizedDescription)") }
                }
            }
            return (exited, stopped, closeErrors)
        }
        let (exited, stopped, closeErrors) = await cleanup.value
        let closed = exited && stopped && closeErrors.isEmpty
        if !closed {
            query.unreleased = [owned]
            let cause = closeErrors.isEmpty
                ? (query.failure?.localizedDescription ?? "Code signing check failed")
                : "Code signing handle close failed: \(closeErrors.joined(separator: "; "))"
            query.failure = Failure.cleanupIncomplete(cause,
                processExited: exited, readersStopped: stopped, handlesClosed: closed)
        } else if Task.isCancelled {
            query.failure = CancellationError()
        } else if query.failure == nil, let exit, exit != 0 {
            let text = String(decoding: query.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            query.failure = Failure.commandFailed(exit, String(text.prefix(200)))
        }
        return query
    }

    private nonisolated static func attachReader(_ handle: FileHandle, isError: Bool,
        events: AsyncThrowingStream<Event, Error>.Continuation,
        lifetime: ReaderLifetime) {
        handle.readabilityHandler = { handle in
            guard lifetime.beginCallback() else { return }
            defer { lifetime.endCallback() }
            do {
                let data = try handle.read(upToCount: 8_192) ?? Data()
                if data.isEmpty { lifetime.stopAdmission(to: handle) }
                let event: Event = data.isEmpty ? .eof(isError: isError) : .bytes(data, isError: isError)
                if case .dropped = events.yield(event) { events.finish(throwing: Failure.eventOverflow) }
            } catch {
                lifetime.stopAdmission(to: handle)
                events.finish(throwing: error)
            }
        }
    }
    /// Admission closes before the handler is removed. Already queued callbacks
    /// cannot touch the handle; in-flight accesses acknowledge only at final defer.
    private final class ReaderLifetime: Sendable {
        private struct State { var accepting = true; var active = 0; var acknowledged = false }
        private let state = OSAllocatedUnfairLock(initialState: State())
        let done = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))

        func beginCallback() -> Bool {
            state.withLock { value in
                guard value.accepting else { return false }
                value.active += 1
                return true
            }
        }
        func endCallback() {
            let acknowledge = state.withLock { value in
                value.active -= 1
                guard !value.accepting, value.active == 0, !value.acknowledged else { return false }
                value.acknowledged = true
                return true
            }
            if acknowledge { done.continuation.yield(()); done.continuation.finish() }
        }
        func stopAdmission(to handle: FileHandle) {
            let acknowledge = state.withLock { value in
                value.accepting = false
                guard value.active == 0, !value.acknowledged else { return false }
                value.acknowledged = true
                return true
            }
            handle.readabilityHandler = nil
            if acknowledge { done.continuation.yield(()); done.continuation.finish() }
        }
    }
    private nonisolated static func joinReaders(
        outputDone: (stream: AsyncThrowingStream<Void, Error>, continuation: AsyncThrowingStream<Void, Error>.Continuation),
        errorDone: (stream: AsyncThrowingStream<Void, Error>, continuation: AsyncThrowingStream<Void, Error>.Continuation)
    ) async -> Bool {
        let deadline = Task<Void, Never> {
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                outputDone.continuation.finish(throwing: Failure.readerCleanupTimeout)
                errorDone.continuation.finish(throwing: Failure.readerCleanupTimeout)
            } catch is CancellationError {} catch {
                outputDone.continuation.finish(throwing: error)
                errorDone.continuation.finish(throwing: error)
            }
        }
        var stdoutDone = false, stderrDone = false
        do {
            for try await _ in outputDone.stream { stdoutDone = true }
            for try await _ in errorDone.stream { stderrDone = true }
        } catch {}
        deadline.cancel()
        await deadline.value
        return stdoutDone && stderrDone
    }
    private nonisolated static func stopExactProcess(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForExit(process) { return true }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return await waitForExit(process)
    }
    private nonisolated static func waitForExit(_ process: Process) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while process.isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return !process.isRunning
    }
}
