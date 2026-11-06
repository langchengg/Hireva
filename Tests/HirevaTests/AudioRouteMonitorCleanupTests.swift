import AppKit
import Foundation
import Testing
@testable import Hireva

@MainActor
struct AudioRouteMonitorCleanupTests {
    @Test(.timeLimit(.minutes(1)))
    func shutdownJoinsTheRetiringResetAndTheCapturedNativeJob() async throws {
        let reset = MonitorCleanupGate(), native = MonitorCleanupGate()
        let jobs = MonitorCleanupJobs()
        let calls = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let monitor = AudioDeviceRouteMonitor(dependencies: .init(
            inputDevice: { ("Synthetic input", "fixture") },
            requestRecovery: { _ in
                let task = Task { await native.wait() }
                jobs.tasks.append(task)
                return task
            }, recoveryState: { "Active" },
            observeEngineConfiguration: { center, body in
                center.addObserver(forName: .init("MonitorCleanupFixture"), object: nil, queue: .main) { _ in body() }
            }, delay: reset, center: NotificationCenter(), observeExternalNotifications: false))
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        var shutdown: Task<Void, Never>?
        var returned = false
        do {
            monitor.handleRouteChange(reason: "Synthetic old")
            captured += monitor.ownedRecoveryTasksForTesting
            _ = try await trace.nextEvent(in: reset.entered.stream, event: "old_reset_entered")
            _ = try await trace.nextEvent(in: native.entered.stream, event: "old_native_entered")
            monitor.handleRouteChange(reason: "Synthetic current")
            captured += monitor.ownedRecoveryTasksForTesting
            _ = try await trace.nextEvent(in: reset.entered.stream, event: "current_reset_entered")
            _ = try await trace.nextEvent(in: native.entered.stream, event: "current_native_entered")
            shutdown = Task { @MainActor in
                calls.continuation.yield(())
                await monitor.shutdown()
                returned = true
            }
            _ = try await trace.nextEvent(in: calls.stream, event: "shutdown_submitted")
            #expect(!returned)
            #expect(monitor.hasOwnedRecoveryWork)
            monitor.handleRouteChange(reason: "Rejected after admission closes")
            #expect(monitor.routeChangeReason == "Synthetic current")
            await reset.releaseAll()
            // Reset exit cannot by itself discharge either exact native job.
            #expect(!returned)
            await native.releaseAll()
            await shutdown?.value
            #expect(returned)
            #expect(!monitor.hasOwnedRecoveryWork)
            await cleanup(reset, native, captured + jobs.tasks, shutdown, monitor)
        } catch {
            await cleanup(reset, native, captured + jobs.tasks, shutdown, monitor)
            calls.continuation.finish()
            throw error
        }
        calls.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitShutdownSynchronouslyRemovesItsNotificationRegistrations() async throws {
        let center = NotificationCenter()
        let counter = MonitorInputReads()
        let monitor = AudioDeviceRouteMonitor(dependencies: .init(
            inputDevice: { counter.value += 1; return ("Synthetic input", "fixture") },
            requestRecovery: { _ in nil }, recoveryState: { "Idle" },
            observeEngineConfiguration: { center, body in
                center.addObserver(forName: .init("MonitorCleanupFixture"), object: nil, queue: .main) { _ in body() }
            }, delay: RealDelayProvider(), center: center, observeExternalNotifications: true))
        // Delivery uses the actual NotificationCenter main operation queue; the
        // monitored device closure is synthetic and no native device is queried.
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(counter.value == 2)
        await monitor.shutdown()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        center.post(name: .init("MonitorCleanupFixture"), object: nil)
        #expect(counter.value == 2)
        #expect(!monitor.hasOwnedRecoveryWork)
    }

    private func cleanup(_ reset: MonitorCleanupGate, _ native: MonitorCleanupGate,
        _ tasks: [Task<Void, Never>], _ shutdown: Task<Void, Never>?, _ monitor: AudioDeviceRouteMonitor) async {
        let cleanup = Task { @MainActor in
            await reset.releaseAll(); await native.releaseAll()
            await shutdown?.value
            await monitor.shutdown()
            for task in tasks { await task.value }
        }
        await cleanup.value
    }
}

@MainActor private final class MonitorCleanupJobs { var tasks: [Task<Void, Never>] = [] }
@MainActor private final class MonitorInputReads { var value = 0 }

private actor MonitorCleanupGate: DelayProvider {
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(8))
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    func sleep(nanoseconds: UInt64) async throws { await wait() }
    func wait() async {
        guard !closed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            entered.continuation.yield(())
        }
    }
    func releaseAll() {
        closed = true
        let owned = waiters; waiters.removeAll()
        owned.forEach { $0.resume() }
        entered.continuation.finish()
    }
}
