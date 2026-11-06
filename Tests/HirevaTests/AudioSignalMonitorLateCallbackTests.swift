import Foundation
import Testing
@testable import Hireva

@MainActor
struct AudioSignalMonitorLateCallbackTests {
    // Requires only the separate narrow Timer factory seam. The fixture stores
    // the ACTUAL owner callback supplied to the same native Timer factory.
    // It never copies the epoch rule or runs a fake clock/capture provider.
    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func capturedOldNativeCallbackCannotPublishAfterReplacement(order: Int) async throws {
        var ticks = 0
        let source = CapturedNativeTimerFactory()
        let owner = AudioSignalMonitor(tick: { ticks += 1 }, scheduleTimer: source.schedule)
        let oldWorker = await owner.start()
        var replacementWorker: Task<Void, Never>?
        do {
            let oldTimer = try #require(owner.currentTimer)
            let oldCallback = try #require(source.callbacks.first)
            if order % 2 == 0 { owner.stop(); owner.stop() }
            replacementWorker = await owner.start()
            let newTimer = try #require(owner.currentTimer)
            let newCallback = try #require(source.callbacks.last)
            #expect(source.callbacks.count == 2)
            await oldWorker?.value
            #expect(!oldTimer.isValid)
            #expect(newTimer.timeInterval == 1.0 && newTimer.isValid)
            let before = ticks
            // 20 fixed traces: stop/direct-replace, callback ordering, and
            // one through five already-captured stale invocations.
            if order % 4 < 2 { newTimer.fire() }
            for _ in 0..<(order / 4 + 1) { oldCallback(oldTimer) }
            if order % 4 >= 2 { newCallback(newTimer) }
            #expect(ticks == before + 1)
            #expect(owner.currentTimer === newTimer)
            #expect(owner.hasPendingWork)
            owner.stop()
            let after = ticks
            newCallback(newTimer)
            #expect(ticks == after, "An already captured callback loses admission synchronously on stop.")
            await replacementWorker?.value
            #expect(!owner.hasPendingWork)
            await owner.shutdown()
        } catch {
            owner.stop(); await oldWorker?.value; await replacementWorker?.value
            await owner.shutdown(); throw error
        }
    }
}

@MainActor
private final class CapturedNativeTimerFactory {
    var callbacks: [AudioSignalMonitor.TimerCallback] = []
    func schedule(_ callback: @escaping AudioSignalMonitor.TimerCallback) -> Timer {
        callbacks.append(callback)
        return Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: callback)
    }
}
