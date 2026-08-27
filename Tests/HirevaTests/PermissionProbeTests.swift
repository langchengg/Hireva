import Foundation
import Testing
import GRDB
@testable import Hireva

private actor ControlledScreenSystemAudioPermissionProbe: ScreenSystemAudioPermissionProbing {
    struct Statistics: Sendable {
        let invocationCount: Int
        let activeCount: Int
        let maximumConcurrentCount: Int
        let completionCount: Int
    }

    private struct CountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var invocationCount = 0
    private var activeCount = 0
    private var maximumConcurrentCount = 0
    private var completionCount = 0
    private var pending = [Int: CheckedContinuation<ScreenSystemAudioPermissionProbeResult, Never>]()
    private var invocationWaiters = [CountWaiter]()
    private var completionWaiters = [CountWaiter]()

    func probe() async -> ScreenSystemAudioPermissionProbeResult {
        invocationCount += 1
        activeCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, activeCount)
        let invocationID = invocationCount

        let result = await withCheckedContinuation { continuation in
            pending[invocationID] = continuation
            resumeSatisfiedInvocationWaiters()
        }

        activeCount -= 1
        completionCount += 1
        resumeSatisfiedCompletionWaiters()
        return result
    }

    func waitForInvocationCount(_ target: Int) async {
        let highestPendingInvocation = pending.keys.max() ?? 0
        guard invocationCount < target || highestPendingInvocation < target else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    func waitForCompletionCount(_ target: Int) async {
        guard completionCount < target else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    @discardableResult
    func resolve(
        invocationID: Int,
        with result: ScreenSystemAudioPermissionProbeResult
    ) -> Bool {
        guard let continuation = pending.removeValue(forKey: invocationID) else {
            return false
        }
        continuation.resume(returning: result)
        return true
    }

    func statistics() -> Statistics {
        Statistics(
            invocationCount: invocationCount,
            activeCount: activeCount,
            maximumConcurrentCount: maximumConcurrentCount,
            completionCount: completionCount
        )
    }

    private func resumeSatisfiedInvocationWaiters() {
        var remaining = [CountWaiter]()
        for waiter in invocationWaiters {
            let highestPendingInvocation = pending.keys.max() ?? 0
            if invocationCount >= waiter.target, highestPendingInvocation >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        invocationWaiters = remaining
    }

    private func resumeSatisfiedCompletionWaiters() {
        var remaining = [CountWaiter]()
        for waiter in completionWaiters {
            if completionCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        completionWaiters = remaining
    }
}

@Suite @MainActor
struct PermissionProbeTests {

    private static let successfulProbeResult = ScreenSystemAudioPermissionProbeResult(
        preflightGranted: true,
        shareableContentProbeSucceeded: true,
        streamAudioProbeSucceeded: true,
        errorDescription: nil,
        likelyIdentityMismatch: false
    )

    private static let failedProbeResult = ScreenSystemAudioPermissionProbeResult(
        preflightGranted: false,
        shareableContentProbeSucceeded: false,
        streamAudioProbeSucceeded: false,
        errorDescription: "Permission unavailable.",
        likelyIdentityMismatch: false
    )

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaPermissionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    @Test
    func testScreenSystemAudioPermissionStateDisplayNames() {
        let grantedState = ScreenSystemAudioPermissionState.granted
        #expect(grantedState.displayName == "Granted")

        let missingState = ScreenSystemAudioPermissionState.permissionMissing
        #expect(missingState.displayName == "Permission Missing")

        let restartState = ScreenSystemAudioPermissionState.restartLikely
        #expect(restartState.displayName == "Restart Required")

        let mismatchState = ScreenSystemAudioPermissionState.identityMismatch
        #expect(mismatchState.displayName == "Identity Mismatch")

        let shareableErrorState = ScreenSystemAudioPermissionState.shareableContentProbeFailed("Demo Error")
        #expect(shareableErrorState.displayName == "Shareable Content Probe Failed: Demo Error")

        let streamErrorState = ScreenSystemAudioPermissionState.streamAudioProbeFailed("Timeout")
        #expect(streamErrorState.displayName == "Stream Audio Probe Failed: Timeout")
    }

    @Test
    func testScreenSystemAudioPermissionProbeResultMapping() throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)

        // Test mapping rules to state:
        // 1. Success case: everything succeeded
        let successResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true,
            errorDescription: nil,
            likelyIdentityMismatch: false
        )
        
        var state = appState.determineProbeState(result: successResult)
        #expect(state == .granted)

        // 2. Missing permission case: preflight denied and probes failed
        let missingResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: false,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Access Denied",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: missingResult)
        #expect(state == .permissionMissing)

        // 3. Restart likely case: preflight granted but shareable failed with no identity mismatch
        let restartResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Service denied",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: restartResult)
        #expect(state == .restartLikely)

        // 4. Mismatch case: likelyIdentityMismatch is true
        let mismatchResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Wrong Bundle ID",
            likelyIdentityMismatch: true
        )
        state = appState.determineProbeState(result: mismatchResult)
        #expect(state == .identityMismatch)

        // 5. Stream audio failed
        let streamFailResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: false,
            errorDescription: "Timeout receiving buffers",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: streamFailResult)
        #expect(state == .streamAudioProbeFailed("Timeout receiving buffers"))
    }

    @Test
    func testColdStartAndPassiveRefreshNeverInvokeActiveProbe() async throws {
        let probe = ControlledScreenSystemAudioPermissionProbe()
        let database = try AppDatabase(inMemory: true)
        let appState = AppState(
            database: database,
            permissionService: HermeticPermissionService(),
            screenSystemAudioPermissionProbe: probe,
            systemAudioPermissionVerificationTimeout: .seconds(30)
        )

        var statistics = await probe.statistics()
        #expect(statistics.invocationCount == 0)
        #expect(appState.systemAudioProbeResult == nil)

        appState.refreshPermissions()
        appState.refreshPermissions()

        statistics = await probe.statistics()
        #expect(statistics.invocationCount == 0)
        #expect(statistics.maximumConcurrentCount == 0)
        #expect(appState.systemAudioPermissionState == .granted)
        #expect(appState.systemAudioProbeResult == nil)

        await appState.shutdownForTesting()
    }

    @Test
    func testExplicitVerificationCoalescesToOneConcurrentProbe() async throws {
        let probe = ControlledScreenSystemAudioPermissionProbe()
        let database = try AppDatabase(inMemory: true)
        let appState = AppState(
            database: database,
            permissionService: HermeticPermissionService(),
            screenSystemAudioPermissionProbe: probe,
            systemAudioPermissionVerificationTimeout: .seconds(30)
        )

        let first = appState.verifySystemAudioPermission()
        let second = appState.verifySystemAudioPermission()
        let third = appState.verifySystemAudioPermission()
        await probe.waitForInvocationCount(1)

        var statistics = await probe.statistics()
        #expect(statistics.invocationCount == 1)
        #expect(statistics.activeCount == 1)
        #expect(statistics.maximumConcurrentCount == 1)
        #expect(appState.isVerifyingSystemAudioPermission)

        #expect(await probe.resolve(invocationID: 1, with: Self.successfulProbeResult))
        await first.value
        await second.value
        await third.value

        statistics = await probe.statistics()
        #expect(statistics.invocationCount == 1)
        #expect(statistics.activeCount == 0)
        #expect(statistics.maximumConcurrentCount == 1)
        #expect(appState.systemAudioPermissionState == .granted)
        #expect(appState.systemAudioProbeResult == Self.successfulProbeResult)
        #expect(!appState.isVerifyingSystemAudioPermission)

        await appState.shutdownForTesting()
    }

    @Test
    func testCancelledVerificationLateResultCannotOverwritePassiveState() async throws {
        let probe = ControlledScreenSystemAudioPermissionProbe()
        let database = try AppDatabase(inMemory: true)
        let appState = AppState(
            database: database,
            permissionService: HermeticPermissionService(),
            screenSystemAudioPermissionProbe: probe,
            systemAudioPermissionVerificationTimeout: .seconds(30)
        )

        let verification = appState.verifySystemAudioPermission()
        await probe.waitForInvocationCount(1)
        let cancelledGeneration = appState.systemAudioPermissionVerificationGeneration

        appState.cancelSystemAudioPermissionVerification()
        await verification.value
        appState.refreshPermissions()
        #expect(appState.systemAudioPermissionState == .granted)
        #expect(appState.systemAudioProbeResult == nil)

        #expect(await probe.resolve(invocationID: 1, with: Self.failedProbeResult))
        await probe.waitForCompletionCount(1)

        // Exercise the same generation gate synchronously so the assertion
        // does not depend on scheduler timing after the late probe returns.
        appState.finishSystemAudioPermissionVerification(
            .result(Self.failedProbeResult),
            generation: cancelledGeneration
        )
        #expect(appState.systemAudioPermissionState == .granted)
        #expect(appState.systemAudioProbeResult == nil)
        #expect(!appState.isVerifyingSystemAudioPermission)

        let statistics = await probe.statistics()
        #expect(statistics.invocationCount == 1)
        #expect(statistics.maximumConcurrentCount == 1)
        await appState.shutdownForTesting()
    }
}
