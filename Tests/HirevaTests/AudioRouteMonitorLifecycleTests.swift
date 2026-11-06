import Foundation
import Combine
import Testing
@testable import Hireva

@MainActor
struct AudioRouteMonitorLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func oldRecoveryCompletionCannotClearTheNewRoute() async throws {
        let delay = RouteMonitorHeldDelay()
        let monitor = makeMonitor(delay: delay)
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        do {
            monitor.handleRouteChange(reason: "Synthetic old route")
            captured += monitor.ownedRecoveryTasksForTesting
            let first = try await trace.nextEvent(in: delay.entries.stream, event: "old_monitor_delay")
            monitor.handleRouteChange(reason: "Synthetic replacement route")
            let replacement = monitor.ownedRecoveryTasksForTesting
            captured += replacement
            let second = try await trace.nextEvent(in: delay.entries.stream, event: "replacement_monitor_delay")
            await delay.release(first)
            await captured.first?.value
            #expect(monitor.isRecoveringAudioRoute,
                "A completed old reset must not publish false for a newer route identity.")
            #expect(monitor.routeChangeReason == "Synthetic replacement route")
            await delay.release(second)
            for task in replacement { await task.value }
            #expect(!monitor.isRecoveringAudioRoute)
            await cleanup(delay, captured)
        } catch { await cleanup(delay, captured); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompletedRecoveryRetiresItsOwnHandle() async throws {
        let delay = RouteMonitorHeldDelay()
        let monitor = makeMonitor(delay: delay)
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        do {
            monitor.handleRouteChange(reason: "Synthetic route")
            captured = monitor.ownedRecoveryTasksForTesting
            let id = try await trace.nextEvent(in: delay.entries.stream, event: "monitor_delay")
            await delay.release(id)
            for task in captured { await task.value }
            #expect(!monitor.hasOwnedRecoveryWork,
                "Completed work must not remain registered as an active resource.")
            await cleanup(delay, captured)
        } catch { await cleanup(delay, captured); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingAMonitorDoesNotLeaveItsDelayedWorkerRetainingIt() async throws {
        let delay = RouteMonitorHeldDelay()
        var monitor: AudioDeviceRouteMonitor? = makeMonitor(delay: delay)
        weak var weakMonitor = monitor
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        do {
            monitor?.handleRouteChange(reason: "Synthetic disposable route")
            captured = monitor?.ownedRecoveryTasksForTesting ?? []
            _ = try await trace.nextEvent(in: delay.entries.stream, event: "owned_monitor_delay")
            monitor = nil
            #expect(weakMonitor == nil,
                "The delay worker must not keep an otherwise discarded monitor alive.")
            await cleanup(delay, captured)
        } catch { monitor = nil; await cleanup(delay, captured); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func appShutdownClosesOnlyItsOwnRouteMonitor() async throws {
        let delayA = RouteMonitorHeldDelay(), delayB = RouteMonitorHeldDelay()
        let monitorA = makeMonitor(delay: delayA), monitorB = makeMonitor(delay: delayB)
        let databaseA = try AppDatabase(inMemory: true), databaseB = try AppDatabase(inMemory: true)
        let appA = makeApp(database: databaseA, monitor: monitorA)
        let appB = makeApp(database: databaseB, monitor: monitorB)
        let trace = TestEventWaitTrace(label: #function)
        var capturedA: [Task<Void, Never>] = [], capturedB: [Task<Void, Never>] = []
        do {
            monitorA.handleRouteChange(reason: "Synthetic A initial")
            capturedA += monitorA.ownedRecoveryTasksForTesting
            let id = try await trace.nextEvent(in: delayA.entries.stream, event: "app_a_initial_delay")
            await delayA.release(id)
            for task in capturedA { await task.value }
            await appA.shutdownForTesting()
            #expect(!monitorA.hasOwnedRecoveryWork)
            monitorA.handleRouteChange(reason: "Late notification for terminated A")
            capturedA += monitorA.ownedRecoveryTasksForTesting
            #expect(!monitorA.hasOwnedRecoveryWork,
                "The actual App shutdown must close its own monitor's admission.")
            monitorB.handleRouteChange(reason: "Synthetic B still owns its route")
            capturedB += monitorB.ownedRecoveryTasksForTesting
            #expect(monitorB.hasOwnedRecoveryWork,
                "A.shutdown must not close shared/global or another App's route recovery.")
            _ = try await trace.nextEvent(in: delayB.entries.stream, event: "app_b_still_admitted")
            await cleanupApps(delayA, delayB, capturedA, capturedB, appA, appB)
        } catch {
            await cleanupApps(delayA, delayB, capturedA, capturedB, appA, appB)
            try databaseA.close(); try databaseB.close(); throw error
        }
        try databaseA.close(); try databaseB.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func appMicrophoneDiagnosticsUsesItsOwnedRouteMetadata() async throws {
        let input = RouteMonitorPresentationInput()
        let initialName = "Synthetic owned route " + UUID().uuidString
        input.name = initialName
        let delay = RouteMonitorHeldDelay()
        let monitor = AudioDeviceRouteMonitor(dependencies: .init(
            inputDevice: { (input.name, "synthetic-owned-route") },
            requestRecovery: { _ in nil }, recoveryState: { "Active" },
            observeEngineConfiguration: { center, body in
                center.addObserver(forName: .init("HirevaFixtureOwnedRouteMetadata"), object: nil, queue: .main) { _ in body() }
            }, delay: delay, center: NotificationCenter(), observeExternalNotifications: false))
        let database = try await TestSupport.makeInMemoryDatabase()
        let suite = "com.langcheng.Hireva.tests.owned-route-metadata." + UUID().uuidString
        let defaults: UserDefaults
        do { defaults = try #require(UserDefaults(suiteName: suite)) }
        catch { try? database.close(); throw error }
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), audioDeviceRouteMonitor: monitor,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults)

        // Only booleans enter failure diagnostics; the old implementation may
        // read native metadata, whose actual device name must not be recorded.
        let initialRefreshUsesOwnedRoute = app.microphoneDiagnostics.selectedInputDeviceName == initialName
        #expect(initialRefreshUsesOwnedRoute)
        #expect(!app.microphoneDiagnostics.isRunning)

        input.name = "Synthetic replacement owned route"
        app.refreshPermissions(automaticallyProbe: false)
        let metadataRemainsTheCommittedRoute = app.microphoneDiagnostics.selectedInputDeviceName == initialName
        #expect(metadataRemainsTheCommittedRoute)
        monitor.refreshInputDevice()
        app.refreshPermissions(automaticallyProbe: false)
        let refreshedMetadataUsesOwnedRoute = app.microphoneDiagnostics.selectedInputDeviceName == input.name
        #expect(refreshedMetadataUsesOwnedRoute)

        monitor.closeAdmission()
        input.name = "Synthetic rejected closed-route update"
        monitor.refreshInputDevice()
        app.refreshPermissions(automaticallyProbe: false)
        let closedMonitorRetainsItsLastMetadata = monitor.currentInputDeviceName == "Synthetic replacement owned route" &&
            app.microphoneDiagnostics.selectedInputDeviceName == monitor.currentInputDeviceName
        #expect(closedMonitorRetainsItsLastMetadata)
        #expect(!monitor.hasOwnedRecoveryWork)
        #expect(!app.microphoneDiagnostics.isRunning)
        #expect(app.microphoneDiagnostics.pendingCallbackTaskCount == 0)
        await app.shutdownForTesting()
        try database.close()
    }

    /// Preserves application recovery feedback with an injected route and a finite
    /// held delay. No native observer, engine or capture starts.
    @Test(.timeLimit(.minutes(1)), arguments: ["Active", "Failed"])
    func applicationRouteCompatibilityKeepsRecoveryFeedback(recoveryState: String) async throws {
        let input = RouteMonitorPresentationInput()
        let delay = RouteMonitorHeldDelay()
        let monitor = AudioDeviceRouteMonitor(dependencies: .init(
            inputDevice: { (input.name, "synthetic-route-input") },
            requestRecovery: { _ in nil }, recoveryState: { recoveryState },
            observeEngineConfiguration: { center, body in
                center.addObserver(forName: .init("HirevaFixtureRoutePresentation"), object: nil, queue: .main) { _ in body() }
            }, delay: delay, center: NotificationCenter(), observeExternalNotifications: false))
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.route-presentation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), audioDeviceRouteMonitor: monitor,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults)
        let events = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let reconnecting = "Audio device changed. Reconnecting..."
        let terminal = recoveryState == "Active" ? "Audio input restored."
            : "Could not restore audio input. Try Stop Listening and Start Listening again."
        let observation = app.$audioRouteError.sink { message in
            if let message, message == reconnecting || message == terminal { events.continuation.yield(message) }
        }
        defer { observation.cancel(); events.continuation.finish() }
        let trace = TestEventWaitTrace(label: #function + recoveryState)
        var captured: [Task<Void, Never>] = []
        func close() async throws {
            monitor.closeAdmission()
            await delay.releaseAll()
            for task in captured { await task.value }
            await app.shutdownForTesting()
            defaults.removePersistentDomain(forName: suite)
            try database.close()
        }
        do {
            #expect(app.currentInputDeviceName == monitor.currentInputDeviceName)
            #expect(!app.isRecoveringAudioRoute)
            input.name = "Synthetic replacement input"
            monitor.handleRouteChange(reason: "Synthetic route presentation")
            captured = monitor.ownedRecoveryTasksForTesting
            let id = try await trace.nextEvent(in: delay.entries.stream, event: "owned_route_delay")
            let start = try await trace.nextEvent(in: events.stream, event: "application_recovery_feedback")
            #expect(start == reconnecting)
            #expect(app.isRecoveringAudioRoute == monitor.isRecoveringAudioRoute)
            #expect(app.isRecoveringAudioRoute)
            #expect(app.noAudioWarningVisible)
            await delay.release(id)
            for task in captured { await task.value }
            let result = try await trace.nextEvent(in: events.stream, event: "application_terminal_feedback")
            #expect(result == terminal)
            #expect(app.currentInputDeviceName == "Synthetic replacement input")
            #expect(app.currentInputDeviceName == monitor.currentInputDeviceName)
            #expect(app.isRecoveringAudioRoute == monitor.isRecoveringAudioRoute)
            #expect(!app.isRecoveringAudioRoute)
            #expect(app.noAudioWarningVisible == (recoveryState == "Failed"))
            #expect(!monitor.hasOwnedRecoveryWork)
            try await close()
        } catch { try? await close(); throw error }
    }

    private func makeMonitor(delay: RouteMonitorHeldDelay) -> AudioDeviceRouteMonitor {
        AudioDeviceRouteMonitor(dependencies: .init(inputDevice: { ("Synthetic Input", "fixture-input") },
            requestRecovery: { _ in nil }, recoveryState: { "Active" },
            observeEngineConfiguration: { center, body in
                center.addObserver(forName: .init("HirevaFixtureEngineConfiguration"), object: nil, queue: .main) { _ in body() }
            }, delay: delay, center: NotificationCenter(), observeExternalNotifications: false))
    }

    private func makeApp(database: AppDatabase, monitor: AudioDeviceRouteMonitor) -> AppState {
        AppState(database: database, permissionService: HermeticPermissionService(),
            audioDeviceRouteMonitor: monitor,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
    }

    private func cleanup(_ delay: RouteMonitorHeldDelay, _ tasks: [Task<Void, Never>]) async {
        let cleanup = Task { @MainActor in
            await delay.releaseAll()
            for task in tasks { await task.value }
        }
        await cleanup.value
    }

    private func cleanupApps(_ delayA: RouteMonitorHeldDelay, _ delayB: RouteMonitorHeldDelay,
        _ tasksA: [Task<Void, Never>], _ tasksB: [Task<Void, Never>], _ appA: AppState, _ appB: AppState) async {
        let cleanup = Task { @MainActor in
            await delayA.releaseAll(); await delayB.releaseAll()
            for task in tasksA + tasksB { await task.value }
            await appA.shutdownForTesting(); await appB.shutdownForTesting()
        }
        await cleanup.value
    }
}

@MainActor
private final class RouteMonitorPresentationInput {
    var name = "Synthetic initial input"
}

/// Each case owns every non-cooperative waiter and releases all of them before
/// joining its captured workers. AsyncStream entry waits end on parent cancel.
private actor RouteMonitorHeldDelay: DelayProvider {
    nonisolated let entries = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(8))
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var closed = false
    func sleep(nanoseconds: UInt64) async throws {
        guard !closed else { return }
        nextID += 1
        let id = nextID
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            entries.continuation.yield(id)
        }
    }
    func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        closed = true
        let owned = Array(waiters.values)
        waiters.removeAll()
        owned.forEach { $0.resume() }
        entries.continuation.finish()
    }
}
