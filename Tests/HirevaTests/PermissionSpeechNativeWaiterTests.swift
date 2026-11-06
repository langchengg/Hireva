import Foundation
import os
import Testing
@testable import Hireva

/// Actual PermissionService bridge tests. Only the SDK callback invoker is
/// replaced; no subclass substitutes requestSpeechRecognition's implementation.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionSpeechNativeWaiterTests {
    @Test
    func cancellationWinsBeforeTheSingleLateNativeCallback() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let service = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let request = Task { @MainActor in await service.requestSpeechRecognition() }
        try await withTaskCancellationHandler {
            do {
                let index = try await callbacks.nextRequest()
                request.cancel()
                callbacks.complete(index, with: .denied)
                #expect(await request.value == .unknown,
                    "Cancelling a Swift waiter must not publish a later SDK authorization result.")
            } catch {
                request.cancel()
                callbacks.releaseAll()
                _ = await request.value
                throw error
            }
            callbacks.releaseAll()
            _ = await request.value
            callbacks.finishEvents()
        } onCancel: {
            request.cancel()
            callbacks.releaseAll()
        }
    }

    @Test
    func cancellationBeforeTheTaskStartsDoesNotInvokeNativeAuthorization() async {
        let callbacks = SpeechNativeCallbackFixture(immediateResult: .denied)
        let service = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        // MainActor cannot run the submitted body before this synchronous cancel.
        let request = Task { @MainActor in await service.requestSpeechRecognition() }
        request.cancel()
        let result = await request.value
        #expect(result == .unknown)
        #expect(callbacks.requestCount == 0,
            "A cancelled queued request must not begin an SDK authorization request.")
        callbacks.releaseAll()
        callbacks.finishEvents()
    }

    // GREEN-only: do not stage duplicate callback invocation against the old
    // checked-continuation bridge, where the duplicate would fatal the host.
    @Test
    func nativeDuplicateCallbackIsInertAfterTheFirstResult() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let service = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let request = Task { @MainActor in await service.requestSpeechRecognition() }
        try await withTaskCancellationHandler {
            do {
                let index = try await callbacks.nextRequest()
                let completion = try #require(callbacks.take(index))
                completion(.granted)
                completion(.denied)
                #expect(await request.value == .granted)
            } catch {
                request.cancel()
                callbacks.releaseAll()
                _ = await request.value
                throw error
            }
            callbacks.releaseAll()
            _ = await request.value
            callbacks.finishEvents()
        } onCancel: {
            request.cancel()
            callbacks.releaseAll()
        }
    }

    @Test
    func cancelledSwiftWaitReturnsBeforeItsNativeCallbackAndLateCallbackCannotAffectANewRequest() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let service = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let first = Task { @MainActor in await service.requestSpeechRecognition() }
        var second: Task<PermissionState, Never>?
        try await withTaskCancellationHandler {
            do {
                let oldIndex = try await callbacks.nextRequest()
                first.cancel()
                #expect(await first.value == .unknown)
                #expect(callbacks.pendingCount == 1,
                    "Swift cancellation leaves the SDK callback pending; it cannot claim to close a dialog.")
                second = Task { @MainActor in await service.requestSpeechRecognition() }
                let newIndex = try await callbacks.nextRequest()
                callbacks.complete(oldIndex, with: .denied)
                callbacks.complete(newIndex, with: .granted)
                #expect(await second?.value == .granted)
                #expect(await first.value == .unknown)
            } catch {
                first.cancel()
                second?.cancel()
                callbacks.releaseAll()
                _ = await first.value
                _ = await second?.value
                throw error
            }
            callbacks.releaseAll()
            _ = await first.value
            _ = await second?.value
            callbacks.finishEvents()
        } onCancel: {
            first.cancel()
            callbacks.releaseAll()
        }
    }

    @Test(arguments: [PermissionState.unknown, .granted, .denied, .restricted, .notDetermined])
    func normalNativeResultPreservesThePermissionState(_ result: PermissionState) async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let service = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let request = Task { @MainActor in await service.requestSpeechRecognition() }
        try await withTaskCancellationHandler {
            do {
                let index = try await callbacks.nextRequest()
                callbacks.complete(index, with: result)
                #expect(await request.value == result)
                #expect(callbacks.requestCount == 1)
            } catch {
                request.cancel()
                callbacks.releaseAll()
                _ = await request.value
                throw error
            }
            callbacks.releaseAll()
            _ = await request.value
            callbacks.finishEvents()
        } onCancel: {
            request.cancel()
            callbacks.releaseAll()
        }
    }
}

private final class SpeechNativeCallbackFixture: Sendable {
    typealias Callback = @Sendable (PermissionState) -> Void
    private struct State: Sendable {
        var requestCount = 0
        var pending: [Int: Callback] = [:]
        var released = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let immediateResult: PermissionState?
    private let requests = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private let trace = TestEventWaitTrace(label: "permission.speech.native-callback")
    init(immediateResult: PermissionState? = nil) { self.immediateResult = immediateResult }
    var requestCount: Int { state.withLock { $0.requestCount } }
    var pendingCount: Int { state.withLock { $0.pending.count } }

    func request(_ callback: @escaping Callback) {
        let admitted = state.withLock { state -> (Int, PermissionState?) in
            state.requestCount += 1
            let index = state.requestCount
            if state.released { return (index, .unknown) }
            if let immediateResult { return (index, immediateResult) }
            state.pending[index] = callback
            return (index, nil)
        }
        requests.continuation.yield(admitted.0)
        if let result = admitted.1 { callback(result) }
    }
    func nextRequest() async throws -> Int {
        try await trace.nextEvent(in: requests.stream, event: "native_callback_registered")
    }
    func take(_ index: Int) -> Callback? { state.withLock { $0.pending.removeValue(forKey: index) } }
    func complete(_ index: Int, with result: PermissionState) { take(index)?(result) }
    func releaseAll() {
        let pending = state.withLock { state -> [Callback] in
            state.released = true
            let callbacks = Array(state.pending.values)
            state.pending.removeAll()
            return callbacks
        }
        // Baseline checked continuations receive at most one callback, even on
        // owning-test cancellation. Never invoke callbacks while holding a lock.
        for callback in pending { callback(.unknown) }
    }
    func finishEvents() { requests.continuation.finish() }
}

#if DEBUG
/// Integration of the actual service bridge with the existing App/controller
/// shutdown owner. These are GREEN contract tests, not a fake-only fix claim.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionSpeechExistingOwnerContractTests {
    @Test
    func actualNativeWaiterIsCancelledAndJoinedByApplicationShutdown() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let permissions = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let environment = try await HirevaTestEnvironment(prefix: "ActualSpeechNativeWaiter", permissionService: permissions,
            systemAudioPermissions: makeSpeechPermissionOwner(permissions))
        let app = environment.appState
        var submitted: Task<Void, Never>?
        app.speechPermissionTaskDidRegisterForTesting = { submitted = $0 }
        try await withTaskCancellationHandler {
            do {
                app.requestSpeechPermission()
                let index = try await callbacks.nextRequest()
                let exact = try #require(submitted)
                #expect(await app.shutdownResources())
                #expect(exact.isCancelled)
                await exact.value
                #expect(!app.systemAudioPermissions.hasOwnedSpeechAuthorizationWork)
                #expect(callbacks.pendingCount == 1,
                    "The Swift waiter exits without claiming the SDK authorization dialog closed.")
                callbacks.complete(index, with: .granted)
                #expect(!app.systemAudioPermissions.hasUnreleasedResources)
            } catch {
                callbacks.releaseAll()
                await submitted?.value
                app.speechPermissionTaskDidRegisterForTesting = nil
                try await environment.shutdown()
                callbacks.finishEvents()
                throw error
            }
            callbacks.releaseAll()
            await submitted?.value
            app.speechPermissionTaskDidRegisterForTesting = nil
            try await environment.shutdown()
            callbacks.finishEvents()
        } onCancel: { callbacks.releaseAll() }
    }

    @Test
    func repeatedExplicitSubmissionBorrowsOneRequestAndCloseRejectsFurtherAdmission() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let permissions = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let owner = makeSpeechPermissionOwner(permissions)
        var completions: [PermissionState] = []
        let first = owner.requestSpeechAuthorization { completions.append($0) }
        let borrower = owner.requestSpeechAuthorization { _ in Issue.record("Borrower created another completion") }
        try await withTaskCancellationHandler {
            do {
                let exact = try #require(first)
                let borrowed = try #require(borrower)
                _ = try await callbacks.nextRequest()
                #expect(exact == borrowed)
                #expect(callbacks.requestCount == 1)
                owner.closeAdmission()
                #expect(owner.requestSpeechAuthorization { _ in Issue.record("Closed callback published") } == nil)
                try await owner.shutdown()
                await first?.value
                await borrower?.value
                #expect(completions.isEmpty)
                #expect(!owner.hasOwnedSpeechAuthorizationWork)
                callbacks.releaseAll()
                #expect(completions.isEmpty)
            } catch {
                callbacks.releaseAll()
                owner.closeAdmission()
                await first?.value
                await borrower?.value
                try await owner.shutdown()
                callbacks.finishEvents()
                throw error
            }
            callbacks.releaseAll()
            owner.closeAdmission()
            await first?.value
            await borrower?.value
            try await owner.shutdown()
            callbacks.finishEvents()
        } onCancel: { callbacks.releaseAll() }
    }

    @Test
    func completionCanSynchronouslySubmitANewRequestAfterTheOldRecordRetires() async throws {
        let callbacks = SpeechNativeCallbackFixture()
        let permissions = PermissionService(speechAuthorizationRequest: { callbacks.request($0) }, permissionAdmission: .production)
        let owner = makeSpeechPermissionOwner(permissions)
        var completions: [PermissionState] = []
        var second: Task<Void, Never>?
        let first = owner.requestSpeechAuthorization { result in
            completions.append(result)
            second = owner.requestSpeechAuthorization { completions.append($0) }
        }
        try await withTaskCancellationHandler {
            do {
                let exact = try #require(first)
                let firstIndex = try await callbacks.nextRequest()
                callbacks.complete(firstIndex, with: .denied)
                await first?.value
                let secondIndex = try await callbacks.nextRequest()
                #expect(callbacks.requestCount == 2)
                let replacement = try #require(second)
                #expect(replacement != exact)
                callbacks.complete(secondIndex, with: .granted)
                await replacement.value
                #expect(completions == [.denied, .granted])
                #expect(!owner.hasOwnedSpeechAuthorizationWork)
            } catch {
                callbacks.releaseAll()
                owner.closeAdmission()
                await first?.value
                await second?.value
                try await owner.shutdown()
                callbacks.finishEvents()
                throw error
            }
            callbacks.releaseAll()
            owner.closeAdmission()
            await first?.value
            await second?.value
            try await owner.shutdown()
            callbacks.finishEvents()
        } onCancel: { callbacks.releaseAll() }
    }
}

@MainActor
private func makeSpeechPermissionOwner(_ permissions: PermissionService) -> SystemAudioPermissionController {
    SystemAudioPermissionController(permissions: permissions,
        probe: {
            .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
        },
        stopProbe: { (_: Bool) in })
}
#endif
