import Foundation
import Testing
@testable import Hireva

@MainActor
struct AudioSignalMonitorOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func actualNativeTimerKeepsOneSecondRepeatingContractAndStopsSynchronously() async throws {
        var ticks = 0
        let owner = AudioSignalMonitor { #expect(Thread.isMainThread); ticks += 1 }
        let worker = await owner.start()
        do {
            let timer = try #require(owner.currentTimer)
            #expect(timer.timeInterval == 1.0)
            #expect(timer.isValid)
            let before = ticks
            timer.fire(); timer.fire()
            #expect(ticks == before + 2,
                "The real Foundation producer invokes the isolated callback without escaping Tasks.")
            #expect(timer.isValid, "Both manual fires must preserve the repeating timer.")
            let stopped = owner.stop()
            #expect(!timer.isValid)
            let after = ticks
            timer.fire()
            #expect(ticks == after)
            await stopped?.value
            #expect(!owner.hasPendingWork)
            await owner.shutdown()
        } catch { owner.stop(); await worker?.value; await owner.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func exactOldTimerAndWorkerCannotClearOrPublishIntoReplacement(order: Int) async throws {
        var ticks = 0
        let owner = AudioSignalMonitor { ticks += 1 }
        let oldWorker = await owner.start()
        var replacementWorker: Task<Void, Never>?
        do {
            let oldTimer = try #require(owner.currentTimer)
            // Alternate explicit user-stop with direct replacement. Both
            // branches use the actual native Timer and real retained waiter.
            if order % 2 == 0 { owner.stop(); owner.stop() }
            replacementWorker = await owner.start()
            let replacementTimer = try #require(owner.currentTimer)
            await oldWorker?.value
            #expect(!oldTimer.isValid)
            #expect(owner.hasPendingWork)
            #expect(owner.currentTimer === replacementTimer)
            let before = ticks
            if order % 4 < 2 { oldTimer.fire(); replacementTimer.fire() }
            else { replacementTimer.fire(); oldTimer.fire() }
            #expect(ticks == before + 1)
            owner.stop(); owner.stop()
            await replacementWorker?.value
            #expect(!owner.hasPendingWork)
            #expect(owner.currentTimer == nil)
            await owner.shutdown()
        } catch {
            owner.stop(); await oldWorker?.value; await replacementWorker?.value
            await owner.shutdown(); throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlreadyCancelledStartDoesNotStopTheCurrentTimer() async throws {
        let owner = AudioSignalMonitor {}
        let worker = await owner.start()
        do {
            let timer = try #require(owner.currentTimer)
            let cancelled = Task { @MainActor in await owner.start() }
            // No suspension between construction and cancel: the submitted
            // MainActor closure has not entered its producer yet.
            cancelled.cancel()
            #expect(await cancelled.value == nil)
            #expect(timer.isValid)
            #expect(owner.currentTimer === timer)
            owner.stop(); await worker?.value; await owner.shutdown()
        } catch { owner.stop(); await worker?.value; await owner.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundLastReleaseUsesTheExistingWorkerForInstallActorCleanup() async throws {
        var owner: AudioSignalMonitor? = AudioSignalMonitor {}
        weak var released = owner
        let worker = await owner?.start()
        do {
            let timer = try #require(owner?.currentTimer)
            let box = SignalMonitorReleaseBox(owner!)
            owner = nil
            await box.release()
            #expect(released == nil, "The waiter must not retain its owner across suspension.")
            #expect(worker?.isCancelled == true,
                "Off-actor ARC must cancel the exact existing worker before fixture rescue cleanup.")
            // Also cancels the retained handle if that ARC assertion failed,
            // so a failing fixture cannot leave its native Timer alive.
            worker?.cancel()
            await worker?.value
            #expect(!timer.isValid,
                "The exact Timer is invalidated by the lexically owning MainActor worker before join returns.")
        } catch {
            owner?.stop(); worker?.cancel(); await worker?.value
            await owner?.shutdown(); throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exactWorkerCancellationFinishesItsNativeTimerBeforeJoin() async throws {
        let owner = AudioSignalMonitor {}
        let worker = await owner.start()
        do {
            let timer = try #require(owner.currentTimer)
            worker?.cancel()
            await worker?.value
            #expect(!timer.isValid)
            #expect(!owner.hasPendingWork)
            #expect(owner.currentTimer == nil)
            await owner.shutdown()
        } catch { owner.stop(); await worker?.value; await owner.shutdown(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualAppShutdownJoinsTheMonitorAndPermanentlyClosesAdmission() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()))
        var worker: Task<Void, Never>?
        do {
            await app.startAudioSignalMonitoring()
            worker = app.audioSignalMonitor.ownedWorker
            let timer = try #require(app.audioSignalMonitoringTimer)
            #expect(worker != nil)
            #expect(await app.shutdownResources())
            await worker?.value
            #expect(!timer.isValid)
            #expect(!app.audioSignalMonitor.hasPendingWork)
            await app.startAudioSignalMonitoring()
            #expect(app.audioSignalMonitoringTimer == nil)
            #expect(await app.audioSignalMonitor.start() == nil)
            await app.shutdownForTesting(); try database.close()
        } catch {
            app.stopAudioSignalMonitoring(); await worker?.value
            await app.shutdownForTesting(); try? database.close(); throw error
        }
    }
}

private actor SignalMonitorReleaseBox {
    private var owner: AudioSignalMonitor?
    init(_ owner: AudioSignalMonitor) { self.owner = owner }
    func release() { #expect(!Thread.isMainThread); owner = nil }
}
