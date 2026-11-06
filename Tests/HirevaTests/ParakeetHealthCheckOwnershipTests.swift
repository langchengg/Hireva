import Darwin
import Foundation
import Testing
@testable import Hireva

struct ParakeetHealthCheckOwnershipTests {
    @Test(arguments: [OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0),
                      OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 9)])
    @MainActor
    func unsupportedBundledRuntimeNeverSpawnsForHealthProbeOrTranscription(version: OperatingSystemVersion) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaCompatibility-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Hireva.app")
        let executable = bundle.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        let marker = root.appendingPathComponent("unexpected-launch")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 1\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let clock = ControlledGenerationWatchdogClock()
        let runtime = ParakeetSidecarRuntimeClient(executableURLProvider: { executable },
            runtimeCompatibilityError: { ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(
                executableURL: $0, bundleURL: bundle, operatingSystemVersion: version) }, healthCheckDelayProvider: clock)
        let expected = try #require(ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(
            executableURL: executable, bundleURL: bundle, operatingSystemVersion: version))
        let diagnostics = await runtime.runtimeDiagnostics()
        #expect(diagnostics.healthStatus == "failed" && diagnostics.lastHealthError == expected)
        #expect(await runtime.probeModel(at: root) == false)
        await #expect(throws: ParakeetSidecarError.healthCheckFailed(expected)) {
            _ = try await runtime.startTranscription(modelDirectory: root,
                config: ASRConfig(sessionID: "synthetic-old-system", captureMode: .systemAudioOnly))
        }
        let cancelledStart = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                _ = try await runtime.startTranscription(modelDirectory: root,
                    config: ASRConfig(sessionID: "synthetic-cancelled-old-system", captureMode: .systemAudioOnly))
            }
        }
        await cancelledStart.value
        await runtime.stop()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(clock.pendingCount == 0)
    }

    @Test
    func compatibilityPolicyPreservesSupportedAndExternalHelperPaths() {
        let bundle = URL(fileURLWithPath: "/synthetic/Hireva.app")
        let canonical = bundle.appendingPathComponent("Contents/Helpers/parakeet_asr_helper")
        for version in [OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0),
                        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)] {
            #expect(ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(executableURL: canonical,
                bundleURL: bundle, operatingSystemVersion: version) == nil)
        }
        let older = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        #expect(ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(
            executableURL: URL(fileURLWithPath: "/synthetic/external/parakeet_asr_helper"),
            bundleURL: bundle, operatingSystemVersion: older) == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func parentCancellationReapsOnlyItsHealthHelper(beforeLaunch: Bool) async throws {
        try await ParakeetHealthCheckTestFixture.verifyCancellation(beforeLaunch: beforeLaunch)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func validHealthAndModelProbeDrainBothPipesAndCancelDeadline(probe: Bool) async throws {
        try await ParakeetHealthCheckTestFixture.verifyValidResponse(probe: probe)
    }

    @Test(.timeLimit(.minutes(1)))
    func modelProbeKeepsIts15SecondDeadlineAndReapsItsHelper() async throws {
        try await ParakeetHealthCheckTestFixture.verifyProbeDeadline()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func outputOverflowIsVisibleAndItsHelperIsReaped(stderr: Bool) async throws {
        try await ParakeetHealthCheckTestFixture.verifyOverflow(stderr: stderr)
    }
}

/// One synthetic interpreter, one startup nonce, and one retained runtime call.
/// The safety deadline bounds a broken fixture; it never advances the health clock.
enum ParakeetHealthCheckTestFixture {
    private enum Scenario: Equatable {
        case deadline, cancelAfterReady, cancelBeforeLaunch, probeDeadline, validHealth, validProbe, overflow(Bool)

        var probesModel: Bool { self == .probeDeadline || self == .validProbe }
        var timesOut: Bool { self == .deadline || self == .probeDeadline }
        var releasesOutput: Bool {
            switch self {
            case .validHealth, .validProbe, .overflow: return true
            default: return false
            }
        }
    }
    private enum Event {
        case ready(Int32)
        case timerRegistered
        case completed(ParakeetRuntimeDiagnostics)
        case probeCompleted(Bool)
        case gateFailed(String)
    }

    static func verifyDeadline() async throws { try await verify(.deadline) }

    static func verifyCancellation(beforeLaunch: Bool) async throws {
        try await verify(beforeLaunch ? .cancelBeforeLaunch : .cancelAfterReady)
    }

    static func verifyValidResponse(probe: Bool) async throws { try await verify(probe ? .validProbe : .validHealth) }
    static func verifyProbeDeadline() async throws { try await verify(.probeDeadline) }
    static func verifyOverflow(stderr: Bool) async throws { try await verify(.overflow(stderr)) }

    private static func verify(_ scenario: Scenario) async throws {
        let trace = TestEventWaitTrace(label: "parakeet.health.\(scenario)")
        let helper = try Helper(scenario: scenario)
        let clock = ControlledGenerationWatchdogClock()
        let executable = helper.executable
        let runtime = await ParakeetSidecarRuntimeClient(
            executableURLProvider: { executable },
            runtimeCompatibilityError: { ParakeetSidecarRuntimeClient.bundledRuntimeCompatibilityError(
                executableURL: $0, bundleURL: URL(fileURLWithPath: "/synthetic/ExternalHelper.app"),
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)) },
            healthCheckDelayProvider: clock
        )
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let request = Task<Void, Never> {
            trace.mark("request.entered")
            if scenario == .cancelBeforeLaunch {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            if scenario.probesModel {
                let ready = await runtime.probeModel(at: helper.directory.appendingPathComponent("synthetic-model"))
                pair.continuation.yield(.probeCompleted(ready))
            } else {
                let diagnostics = await runtime.runtimeDiagnostics()
                pair.continuation.yield(.completed(diagnostics))
            }
        }
        let readiness = Task {
            do { pair.continuation.yield(.ready(try await helper.waitForReady())) }
            catch {
                if !Task.isCancelled { pair.continuation.yield(.gateFailed("Helper readiness failed: \(error)")) }
            }
        }
        let registration = Task {
            do {
                try await clock.waitUntilScheduled()
                pair.continuation.yield(.timerRegistered)
            } catch {
                if !Task.isCancelled { pair.continuation.yield(.gateFailed("Health timer registration failed: \(error)")) }
            }
        }

        do {
            func exercise() async throws {
                var ownedPID: Int32?
                var timerRegistered = false
                var actionTaken = scenario == .cancelBeforeLaunch
                for await event in pair.stream {
                    try Task.checkCancellation()
                    switch event {
                    case .ready(let pid):
                        ownedPID = pid
                        #expect(helper.matchesRunningHelper(pid))
                        if scenario == .cancelAfterReady {
                            request.cancel()
                            actionTaken = true
                        }
                    case .timerRegistered:
                        timerRegistered = true
                    case .gateFailed(let reason):
                        throw fixtureError(reason)
                    case .completed(let diagnostics):
                        _ = try #require(actionTaken,
                            "Health returned before the owned helper and injected deadline gates: \(diagnostics.lastHealthError ?? "none")")
                        if scenario == .validHealth {
                            #expect(diagnostics.healthStatus == "ok")
                            #expect(diagnostics.modelStatus == "ready")
                            #expect(diagnostics.lastHealthError == nil)
                            #expect(diagnostics.runtimeVersion == "synthetic-owned-health")
                        } else {
                            #expect(diagnostics.healthStatus == "failed")
                            if scenario == .deadline {
                                #expect(diagnostics.lastHealthError == "Health check timed out")
                            } else if case .overflow = scenario {
                                #expect(diagnostics.lastHealthError == "Health check output exceeded 1048576 bytes"
                                    || diagnostics.lastHealthError == "Health check output event buffer overflow")
                            } else {
                                #expect(diagnostics.lastHealthError == "Health check cancelled")
                            }
                        }
                        if scenario == .cancelBeforeLaunch {
                            #expect(!FileManager.default.fileExists(atPath: helper.readyURL.path),
                                "An already-cancelled health call launched a helper")
                        } else {
                            let pid = try #require(ownedPID)
                            let result = Darwin.kill(pid, 0)
                            let failure = errno
                            #expect(result == -1, "Health returned before its exact helper PID exited and was reaped")
                            #expect(failure == ESRCH)
                        }
                        #expect(clock.pendingCount == 0)
                        return
                    case .probeCompleted(let ready):
                        _ = try #require(actionTaken, "Probe returned before the owned helper and injected deadline gates")
                        #expect(ready == (scenario == .validProbe))
                        let pid = try #require(ownedPID)
                        let result = Darwin.kill(pid, 0)
                        let failure = errno
                        #expect(result == -1, "Probe returned before its helper exited and was reaped")
                        #expect(failure == ESRCH)
                        #expect(clock.pendingCount == 0)
                        let arguments = try String(contentsOf: helper.directory.appendingPathComponent("arguments"), encoding: .utf8)
                        #expect(arguments.split(separator: "\n").map(String.init) == ["--health", "--probe-model", "--model-dir",
                            helper.directory.appendingPathComponent("synthetic-model").path])
                        return
                    }
                    if scenario.timesOut, !actionTaken, timerRegistered, let pid = ownedPID {
                        _ = try #require(helper.matchesRunningHelper(pid), "Helper exited before its controlled deadline")
                        let deadline: UInt64 = scenario.probesModel ? 15_000_000_000 : 3_000_000_000
                        #expect(clock.requestedNanoseconds == [deadline])
                        clock.advance(by: deadline - 1)
                        #expect(clock.pendingCount == 1)
                        #expect(helper.matchesRunningHelper(pid))
                        clock.advance(by: 1)
                        actionTaken = true
                    } else if scenario.releasesOutput, !actionTaken, timerRegistered, let pid = ownedPID {
                        _ = try #require(helper.matchesRunningHelper(pid), "Helper exited before its controlled output release")
                        #expect(clock.requestedNanoseconds == [scenario.probesModel ? 15_000_000_000 : 3_000_000_000])
                        helper.release()
                        actionTaken = true
                    }
                }
                try Task.checkCancellation()
                throw fixtureError("Health completion stream ended without a result")
            }
            try await exercise()
        } catch {
            await cleanup(helper: helper, clock: clock, request: request,
                readiness: readiness, registration: registration, continuation: pair.continuation)
            throw error
        }
        await cleanup(helper: helper, clock: clock, request: request,
            readiness: readiness, registration: registration, continuation: pair.continuation)
    }

    private static func cleanup(
        helper: Helper, clock: ControlledGenerationWatchdogClock,
        request: Task<Void, Never>, readiness: Task<Void, Never>, registration: Task<Void, Never>,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        request.cancel()
        readiness.cancel()
        registration.cancel()
        clock.cancelAll()
        continuation.finish()
        // The original runtime may ignore cancellation. Release its private
        // helper, and send KILL only after the nonce and live argv both match.
        helper.release()
        if let pid = helper.readyPID(), helper.matchesRunningHelper(pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }
        await request.value
        await readiness.value
        await registration.value
        if let pid = helper.readyPID(), helper.matchesRunningHelper(pid) {
            Issue.record("The retained health call left its owned helper alive after fixture cleanup")
        }
        try? FileManager.default.removeItem(at: helper.directory)
    }

    private static func fixtureError(_ message: String) -> NSError {
        NSError(domain: "ParakeetHealthCheckFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private struct Helper {
        let directory: URL
        let executable: URL
        let readyURL: URL
        private let nonce: String

        init(scenario: Scenario) throws {
            _ = try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
            nonce = UUID().uuidString
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaHealth-\(nonce)")
            executable = directory.appendingPathComponent("health-helper-\(nonce)")
            readyURL = directory.appendingPathComponent("startup.ready")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let root = directory.path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let output: String
            switch scenario {
            case .validHealth, .validProbe:
#if arch(arm64)
                let architecture = "arm64"
#elseif arch(x86_64)
                let architecture = "x86_64"
#else
                let architecture = "unknown"
#endif
                output = "print STDERR 'synthetic stderr drain'; print '{\"status\":\"ok\",\"runtimeMode\":\"bundled_native\",\"runtimeVersion\":\"synthetic-owned-health\",\"sherpaVersion\":\"synthetic\",\"onnxRuntimeVersion\":\"synthetic\",\"architecture\":\"\(architecture)\",\"source\":\"local_parakeet_asr\",\"modelStatus\":\"ready\"}';"
            case .overflow(let stderr):
                output = "print \(stderr ? "STDERR " : "")('x' x 1114112);"
            default: output = ""
            }
            let script = #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            my $root = '__ROOT__';
            $SIG{TERM} = 'IGNORE';
            open(my $arguments, '>', "$root/arguments") or die $!;
            print $arguments join("\n", @ARGV);
            close($arguments);
            open(my $ready, '>', "$root/startup.pending") or die $!;
            print $ready "__NONCE__\n$$";
            close($ready);
            rename("$root/startup.pending", "$root/startup.ready") or die $!;
            my $safety = time() + 12;
            while (!-e "$root/release" && time() < $safety) {
                select(undef, undef, undef, 0.01);
            }
            __OUTPUT__
            exit 0;
            """#.replacingOccurrences(of: "__ROOT__", with: root)
                .replacingOccurrences(of: "__NONCE__", with: nonce)
                .replacingOccurrences(of: "__OUTPUT__", with: output)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func readyPID() -> Int32? {
            guard let text = try? String(contentsOf: readyURL, encoding: .utf8) else { return nil }
            let fields = text.split(separator: "\n")
            guard fields.count == 2, fields[0] == nonce else { return nil }
            return Int32(fields[1])
        }

        func waitForReady() async throws -> Int32 {
            // Logical startup is bounded by the owning test, rather than a
            // private wall clock while the runtime is queued on MainActor.
            while true {
                try Task.checkCancellation()
                if let pid = readyPID() {
                    _ = try #require(matchesRunningHelper(pid), "Readiness PID does not belong to this helper startup")
                    return pid
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func matchesRunningHelper(_ pid: Int32) -> Bool {
            guard Darwin.kill(pid, 0) == 0 else { return false }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var bytes = [UInt8](repeating: 0, count: 16_384)
            var count = bytes.count
            let status = mib.withUnsafeMutableBufferPointer { name in
                bytes.withUnsafeMutableBytes { buffer in
                    sysctl(name.baseAddress, UInt32(name.count), buffer.baseAddress, &count, nil, 0)
                }
            }
            guard status == 0, count > MemoryLayout<Int32>.size else { return false }
            let arguments = bytes.prefix(count).dropFirst(MemoryLayout<Int32>.size)
            return arguments.split(separator: 0).contains { $0.elementsEqual(executable.path.utf8) }
        }

        func release() {
            _ = FileManager.default.createFile(atPath: directory.appendingPathComponent("release").path, contents: Data())
        }
    }
}
