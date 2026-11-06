import Darwin
import Dispatch
import Foundation
import Testing
import os
@testable import Hireva

/// Real owned synthetic Process boundaries only; never invokes codesign,
/// accesses signing identities, permissions, microphones or production data.
@MainActor
struct CodeSigningInvocationResourceTests {
    @Test(.timeLimit(.minutes(1)))
    nonisolated func cancelledActualPermissionDiagnosticStopsItsExactProcessAndSkipsTheSecondQuery() async throws {
        let fixture = try SigningProcessFixture(mode: .held)
        let invocation = fixture.invocation()
        let service = await PermissionService(codeSigningInvocation: invocation)
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            let launch = try await fixture.nextLaunch()
            try await fixture.waitUntilHelperReady(launch.process)
            try #require(launch.process.isRunning, "Cancel must target an in-flight query, before the fixture safety escape.")
            fixture.trace.mark("caller.cancel.enter")
            task.cancel()
            let status = await task.value
            fixture.trace.mark("caller.cancel.joined")
            #expect(status.localizedCaseInsensitiveContains("cancelled"))
            #expect(fixture.launchedPhases == ["identity"],
                "Cancellation must not start a second codesign query.")
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aControlledBusinessDeadlineStopsItsOwnedProcessBeforeASecondQuery() async throws {
        let fixture = try SigningProcessFixture(mode: .held)
        let invocation = fixture.invocation(delay: ImmediateSigningDeadline())
        let service = PermissionService(codeSigningInvocation: invocation)
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status.localizedCaseInsensitiveContains("timed out"))
            #expect(fixture.launchedPhases == ["identity"])
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    nonisolated func exactThreeSecondBusinessDeadlineIsControlledAndJoinsItsProcess() async throws {
        let fixture = try SigningProcessFixture(mode: .held)
        let clock = ControlledGenerationWatchdogClock(trace: fixture.trace)
        let service = await PermissionService(codeSigningInvocation: fixture.invocation(delay: clock))
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            _ = try await fixture.nextLaunch()
            try await clock.waitUntilPending(nanoseconds: 3_000_000_000)
            #expect(clock.pendingNanoseconds == [3_000_000_000])
            clock.advance(by: 3_000_000_000)
            let status = await task.value
            #expect(status.localizedCaseInsensitiveContains("timed out"))
            #expect(fixture.launchedPhases == ["identity"])
            #expect(fixture.allLaunchedProcessesExited)
            #expect(clock.pendingCount == 0)
            try await fixture.cleanup(task: task)
            clock.cancelAll()
        } catch {
            clock.cancelAll()
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func requirementStderrIsDrainedAndCannotBecomeAFalseSuccessfulSignature() async throws {
        let fixture = try SigningProcessFixture(mode: .requirementFlood)
        let service = PermissionService(codeSigningInvocation: fixture.invocation())
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status.localizedCaseInsensitiveContains("output") &&
                !status.hasPrefix("Identifier="),
                "The second query's oversized stderr must be bounded, drained and reported.")
            #expect(fixture.launchedPhases == ["identity", "requirement"])
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func normalSyntheticIdentityAndRequirementKeepTheExistingPresentation() async throws {
        let fixture = try SigningProcessFixture(mode: .normal)
        let service = PermissionService(codeSigningInvocation: fixture.invocation())
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status == "Identifier=synthetic.fixture\nSignature=adhoc\nDesignated Requirement: identifier synthetic.fixture")
            #expect(fixture.launchedPhases == ["identity", "requirement"])
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func everySuccessfulQueryExplicitlyClosesItsFourOwnedPipeHandles() async throws {
        let fixture = try SigningProcessFixture(mode: .normal)
        let closed = OSAllocatedUnfairLock(initialState: [String]())
        let invocation = fixture.invocation(closeFileHandle: { label, handle in
            try handle.close()
            closed.withLock { $0.append(label) }
        })
        let task = Task { await PermissionService(codeSigningInvocation: invocation).fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status.hasPrefix("Identifier=synthetic.fixture"))
            #expect(closed.withLock { $0.sorted() } == Self.expectedPipeClosures(phases: ["identity", "requirement"]))
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHandleCloseFailureIsRetainedAndCannotLaunchAnotherQueryOrCheck() async throws {
        let fixture = try SigningProcessFixture(mode: .normal)
        let failed = OSAllocatedUnfairLock(initialState: [FileHandle]())
        let attempts = OSAllocatedUnfairLock(initialState: [String]())
        let invocation = fixture.invocation(closeFileHandle: { label, handle in
            attempts.withLock { $0.append(label) }
            if label == "identity.stderr-reader" {
                failed.withLock { $0.append(handle) }
                throw SigningFixtureFailure.injectedHandleClose
            }
            try handle.close()
        })
        let task = Task { await PermissionService(codeSigningInvocation: invocation).fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status.localizedCaseInsensitiveContains("handle close failed") &&
                status.localizedCaseInsensitiveContains("cleanup incomplete"))
            let repeated = await invocation.run(bundlePath: "synthetic.fixture")
            #expect(repeated.localizedCaseInsensitiveContains("previous codesign cleanup incomplete"))
            #expect(fixture.launchedPhases == ["identity"])
            #expect(attempts.withLock { $0.sorted() } == Self.expectedPipeClosures(phases: ["identity"]))
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
            // The fixture owns the deliberately injected failed closure resource.
            // Release its exact handle even though production correctly retained it.
            for handle in failed.withLock({ $0 }) { try handle.close() }
        } catch {
            try? await fixture.cleanup(task: task)
            for handle in failed.withLock({ $0 }) { try? handle.close() }
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedLaunchAlsoClosesItsFourOwnedPipeHandles() async throws {
        let fixture = try SigningProcessFixture(mode: .normal)
        let closed = OSAllocatedUnfairLock(initialState: [String]())
        let invocation = fixture.invocation(executableURL: fixture.directory.appendingPathComponent("missing-executable"),
            closeFileHandle: { label, handle in
                try handle.close()
                closed.withLock { $0.append(label) }
            })
        let task = Task { await PermissionService(codeSigningInvocation: invocation).fetchCodeSigningStatus() }
        do {
            let status = await task.value
            #expect(status.hasPrefix("Could not check:"))
            #expect(fixture.launchedPhases.isEmpty)
            #expect(closed.withLock { $0.sorted() } == Self.expectedPipeClosures(phases: ["identity"]))
            try await fixture.cleanup(task: task)
        } catch {
            try? await fixture.cleanup(task: task)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func applicationShutdownJoinsItsActualDiagnosticProcessBeforeReturning() async throws {
        let fixture = try SigningProcessFixture(mode: .held)
        let service = HermeticPermissionService(codeSigningInvocation: fixture.invocation())
        let environment = try await HirevaTestEnvironment(prefix: "SigningShutdown", permissionService: service)
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            let launch = try await fixture.nextLaunch()
            try await fixture.waitUntilHelperReady(launch.process)
            let stopped = await environment.appState.shutdownResources()
            #expect(stopped)
            #expect(fixture.allLaunchedProcessesExited,
                "Application cleanup must join its real diagnostic subprocess.")
            #expect(fixture.launchedPhases == ["identity"])
            try await fixture.cleanup(task: task)
            try await environment.shutdown()
        } catch {
            try? await fixture.cleanup(task: task)
            try? await environment.shutdown()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func applicationShutdownCannotApproveAnUnreleasedDiagnosticHandle() async throws {
        let fixture = try SigningProcessFixture(mode: .normal)
        let failed = OSAllocatedUnfairLock(initialState: [FileHandle]())
        let service = HermeticPermissionService(codeSigningInvocation: fixture.invocation(closeFileHandle: { label, handle in
            if label == "identity.stderr-reader" {
                failed.withLock { $0.append(handle) }
                throw SigningFixtureFailure.injectedHandleClose
            }
            try handle.close()
        }))
        let environment = try await HirevaTestEnvironment(prefix: "SigningUnreleasedHandle", permissionService: service)
        let task = Task { await service.fetchCodeSigningStatus() }
        do {
            _ = await task.value
            #expect(await environment.appState.shutdownResources() == false)
            #expect(await environment.appState.shutdownResources() == false)
            #expect(fixture.allLaunchedProcessesExited)
            try await fixture.cleanup(task: task)
            for handle in failed.withLock({ $0 }) { try handle.close() }
            try await environment.shutdown()
        } catch {
            try? await fixture.cleanup(task: task)
            for handle in failed.withLock({ $0 }) { try? handle.close() }
            try? await environment.shutdown()
            throw error
        }
    }

    private static func expectedPipeClosures(phases: [String]) -> [String] {
        phases.flatMap { phase in
            ["stdout-reader", "stderr-reader", "stdout-writer", "stderr-writer"].map { "\(phase).\($0)" }
        }.sorted()
    }
}

private struct ImmediateSigningDeadline: DelayProvider {
    func sleep(nanoseconds: UInt64) async throws { try Task.checkCancellation() }
}
private enum SigningHelperMode: String { case held, requirementFlood, normal }
private struct SigningLaunch: Sendable { let phase: String; let process: Process }

private final class SigningProcessFixture: Sendable {
    let directory: URL
    let executable: URL
    private let launches = OSAllocatedUnfairLock(initialState: [SigningLaunch]())
    private let watchdogs = OSAllocatedUnfairLock(initialState: [SigningFixtureWatchdog]())
    private let events = AsyncStream<SigningLaunch>.makeStream()
    let trace = TestEventWaitTrace(label: "codesign.owned-synthetic-process")
    private let businessClock = ControlledGenerationWatchdogClock()

    init(mode: SigningHelperMode) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Hireva-code-signing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        executable = directory.appendingPathComponent("synthetic-codesign.pl")
        // Perl executes as the Process itself, with no shell/child descendants.
        // A retained DispatchSource watchdog bounds legacy RED independently
        // of this helper, including when it is blocked writing a full pipe.
        // The business deadline remains controlled by DelayProvider.
        let root = directory.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = """
        #!/usr/bin/perl
        use strict; use warnings;
        my $root = '\(root)';
        my $mode = '\(mode.rawValue)';
        my $requirement = grep { $_ eq '-r-' } @ARGV;
        $SIG{TERM} = 'IGNORE';
        open(my $ready, '>', "$root/ready-$$") or die "ready";
        print $ready "ready"; close $ready;
        if ($mode eq 'held') {
            until (-e "$root/release") { select(undef, undef, undef, 0.01); }
        }
        if ($requirement) {
            if ($mode eq 'requirementFlood') { print STDERR ('Z' x 1048576); }
            print STDOUT "identifier synthetic.fixture\\n";
        } else {
            print STDERR "Identifier=synthetic.fixture\\nSignature=adhoc\\n";
        }
        exit 0;
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    var launchedPhases: [String] { launches.withLock { $0.map(\.phase) } }
    var allLaunchedProcessesExited: Bool {
        launches.withLock { owned in
            owned.allSatisfy { launch in
                !launch.process.isRunning && Darwin.kill(launch.process.processIdentifier, 0) == -1 && errno == ESRCH
            }
        }
    }
    func invocation(delay: (any DelayProvider)? = nil, executableURL: URL? = nil,
        closeFileHandle: (@Sendable (String, FileHandle) throws -> Void)? = nil) -> CodeSigningDiagnosticsInvocation {
        let owned = launches, events = events, watchdogs = watchdogs, trace = trace
        return CodeSigningDiagnosticsInvocation(executableURL: executableURL ?? executable, delayProvider: SigningDiagnosticDelayTrace(base: delay ?? businessClock, trace: trace),
            onLaunched: { phase, process in
                trace.mark("process.\(phase).launched.pid.\(process.processIdentifier)")
                let launch = SigningLaunch(phase: phase, process: process)
                let watchdog = SigningFixtureWatchdog(process: process, trace: trace)
                watchdogs.withLock { $0.append(watchdog) }
                owned.withLock { $0.append(launch) }
                events.continuation.yield(launch)
            }, closeFileHandle: closeFileHandle)
    }
    func nextLaunch() async throws -> SigningLaunch {
        try await trace.nextEvent(in: events.stream, event: "process-launched")
    }
    func waitUntilHelperReady(_ process: Process) async throws {
        trace.mark("helper.ready.requested")
        defer { trace.mark("helper.ready.return") }
        let path = directory.appendingPathComponent("ready-\(process.processIdentifier)").path
        while !FileManager.default.fileExists(atPath: path) {
            try Task.checkCancellation()
            guard process.isRunning else { trace.mark("helper.exited.before.ready"); throw SigningFixtureFailure.exitedBeforeReady }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func cleanup(task: Task<String, Never>) async throws {
        // Cleanup is retained and joined independently of test cancellation.
        // A cancelled safety scope still must release and reap exact owned PIDs.
        let cleanup = Task {
            try Data().write(to: directory.appendingPathComponent("release"))
            task.cancel()
            let owned = launches.withLock { $0 }
            for launch in owned where launch.process.isRunning {
                _ = Darwin.kill(launch.process.processIdentifier, SIGKILL)
            }
            _ = await task.value
            // A legacy worker might launch its second query after cleanup began.
            // Every actual launch installs its own retained watchdog before
            // emitting the launch event, so blocked writes remain releasable.
            let all = launches.withLock { $0 }
            for launch in all where launch.process.isRunning {
                _ = Darwin.kill(launch.process.processIdentifier, SIGKILL)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while all.contains(where: { $0.process.isRunning }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let allWatchdogs = watchdogs.withLock { $0 }
            for watchdog in allWatchdogs { await watchdog.cancelAndJoin() }
            #expect(allLaunchedProcessesExited, "Every precise fixture PID must be reaped before cleanup.")
            #expect(businessClock.pendingCount == 0, "The actual operation must cancel and join its business timer.")
            businessClock.cancelAll()
            events.continuation.finish()
            try FileManager.default.removeItem(at: directory)
        }
        try await cleanup.value
    }
}
private enum SigningFixtureFailure: Error { case exitedBeforeReady, injectedHandleClose }

/// Independent test safety only. This checked Sendable owner stores the source
/// behind the SDK lock; handlers capture only the exact Process and continuation.
/// Cancel-handler completion joins any in-flight timer handler before teardown.
private final class SigningFixtureWatchdog: Sendable {
    private let source: OSAllocatedUnfairLock<any DispatchSourceTimer>
    private let completion: AsyncStream<Void>

    init(process: Process, trace: TestEventWaitTrace) {
        let done = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        completion = done.stream
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
            label: "Hireva.tests.codesign-safety.\(process.processIdentifier).\(UUID().uuidString)"))
        source = OSAllocatedUnfairLock(initialState: timer)
        timer.setEventHandler {
            trace.mark("safety.fired.pid.\(process.processIdentifier).running.\(process.isRunning)")
            if process.isRunning {
                let pid = process.processIdentifier
                print("[SigningFixture] safety deadline terminating exact owned PID=\(pid)")
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        timer.setCancelHandler {
            trace.mark("safety.cancelled.pid.\(process.processIdentifier)")
            done.continuation.yield(()); done.continuation.finish()
        }
        trace.mark("safety.installed.pid.\(process.processIdentifier)")
        timer.schedule(deadline: .now() + .seconds(10), repeating: .never)
        timer.activate()
    }

    func cancelAndJoin() async {
        source.withLock { $0.cancel() }
        for await _ in completion {}
    }
}

/// Diagnostics only: preserve the original delay and record scheduler boundaries.
private struct SigningDiagnosticDelayTrace: DelayProvider {
    let base: any DelayProvider
    let trace: TestEventWaitTrace
    func sleep(nanoseconds: UInt64) async throws {
        trace.mark("business.deadline.requested")
        do {
            try await base.sleep(nanoseconds: nanoseconds)
            trace.mark("business.deadline.returned")
        } catch {
            trace.mark("business.deadline.cancelled.or.failed")
            throw error
        }
    }
}
