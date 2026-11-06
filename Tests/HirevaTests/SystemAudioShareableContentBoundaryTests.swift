import Foundation
import os
import Testing
@testable import Hireva

/// Uses the actual SDK adapter with controlled completion callbacks. No SDK
/// content is constructed, enumerated, captured, or sent through a Task result.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioShareableContentBoundaryTests {
    @Test
    func nilContentRemainsAnError() async {
        var callbacks = 0
        do {
            _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: { completion in
                callbacks += 1
                completion(nil, nil)
            })
            Issue.record("Missing SDK content was accepted")
        } catch {
            #expect((error as NSError).domain == "ScreenCaptureKitSystemAudioCaptureService")
            #expect((error as NSError).code == -2)
        }
        #expect(callbacks == 1)
    }

    @Test
    func nativeErrorIsPreservedAndDuplicateCallbacksCannotReplaceIt() async {
        let query = ControlledShareableContentQuery()
        do {
            _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: { completion in
                query.install(completion)
                query.complete(code: 41)
                query.complete(code: 42)
            })
            Issue.record("SDK failure was accepted")
        } catch {
            #expect((error as NSError).domain == "Hireva.SyntheticShareableContent")
            #expect((error as NSError).code == 41)
        }
        query.complete(code: 43)
        #expect(query.fetchCount == 1)
        #expect(query.callbackCount == 3)
        query.close()
    }

    @Test
    func arbitraryNativeCallbackQueueDeliversItsErrorOnTheControlExecutor() async {
        let query = ControlledShareableContentQuery()
        await withTaskCancellationHandler {
            let queue = DispatchQueue(label: "Hireva.SyntheticShareableContent.\(UUID().uuidString)")
            do {
                _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: { completion in
                    query.install(completion)
                    queue.async { query.complete(code: 44) }
                })
                Issue.record("Background SDK error was accepted")
            } catch {
                #expect((error as NSError).domain == "Hireva.SyntheticShareableContent")
                #expect((error as NSError).code == 44)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { continuation.resume() }
            }
            #expect(query.callbackThreads == [false])
            #expect(!query.escapeFired)
            query.close()
        } onCancel: { query.releaseForOwningTestCancellation() }
    }

    @Test
    func cancellationBeforeEntryDoesNotIssueANativeRequest() async {
        let query = ControlledShareableContentQuery()
        await withTaskCancellationHandler {
            let call = Task<Void, Error> { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: query.install)
            }
            query.retain(call)
            expectShareableContentCancellation(await call.result)
            #expect(query.fetchCount == 0)
            query.close()
        } onCancel: { query.releaseForOwningTestCancellation() }
    }

    /// Four fixed orders, each repeated five times. These are controlled actor
    /// turns, not twenty distinct races or proof that arbitrary schedules pass.
    @Test(arguments: 0..<20)
    func cancellationAndCallbackHaveOneTerminalResult(schedule: Int) async throws {
        let query = ControlledShareableContentQuery()
        try await withTaskCancellationHandler {
            let call = Task<Void, Error> { @MainActor in
                _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: query.install)
            }
            query.retain(call)
            do {
                try #require(await query.waitUntilInstalled())
                switch schedule % 4 {
                case 0:
                    call.cancel()
                    query.complete(code: 51)
                    expectShareableContentCancellation(await call.result)
                case 1:
                    // The child cannot take its result until this MainActor turn
                    // yields. Cancellation therefore wins before consumption.
                    query.complete(code: 52)
                    call.cancel()
                    expectShareableContentCancellation(await call.result)
                case 2:
                    query.complete(code: 53)
                    let result = await call.result
                    expectShareableContentError(result, code: 53)
                    call.cancel()
                    query.complete(code: 54)
                    expectShareableContentError(await call.result, code: 53)
                default:
                    call.cancel()
                    expectShareableContentCancellation(await call.result)
                    #expect(query.callbackCount == 0,
                        "Swift cancellation must finish without a native callback")
                    query.complete(code: 55)
                    query.complete(code: 56)
                }
                #expect(query.fetchCount == 1)
                #expect(!query.escapeFired, "The fixture escape is a failure, never a success path")
            } catch {
                call.cancel()
                query.complete(code: 98)
                _ = await call.result
                query.close()
                throw error
            }
            call.cancel()
            query.complete(code: 99)
            _ = await call.result
            query.close()
        } onCancel: { query.releaseForOwningTestCancellation() }
    }

    @Test
    func lateOldCallbackCannotResolveANewRequest() async throws {
        let old = ControlledShareableContentQuery()
        let fresh = ControlledShareableContentQuery()
        try await withTaskCancellationHandler {
            let oldCall = Task<Void, Error> { @MainActor in
                _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: old.install)
            }
            old.retain(oldCall)
            var freshCall: Task<Void, Error>?
            do {
                try #require(await old.waitUntilInstalled())
                oldCall.cancel()
                expectShareableContentCancellation(await oldCall.result)
                let replacement = Task<Void, Error> { @MainActor in
                    _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: fresh.install)
                }
                freshCall = replacement
                fresh.retain(replacement)
                try #require(await fresh.waitUntilInstalled())
                old.complete(code: 61)
                fresh.complete(code: 62)
                expectShareableContentError(await replacement.result, code: 62)
                #expect(!old.escapeFired)
                #expect(!fresh.escapeFired)
                #expect(old.fetchCount == 1)
                #expect(fresh.fetchCount == 1)
            } catch {
                oldCall.cancel()
                freshCall?.cancel()
                old.complete(code: 98)
                fresh.complete(code: 98)
                _ = await oldCall.result
                _ = await freshCall?.result
                old.close()
                fresh.close()
                throw error
            }
            oldCall.cancel()
            freshCall?.cancel()
            old.complete(code: 99)
            fresh.complete(code: 99)
            _ = await oldCall.result
            _ = await freshCall?.result
            old.close()
            fresh.close()
        } onCancel: { old.releaseForOwningTestCancellation(); fresh.releaseForOwningTestCancellation() }
    }
}

private final class ControlledShareableContentQuery: Sendable {
    private struct State: Sendable {
        var completion: NativeShareableContentCompletion?
        var fetches = 0
        var callbacks = 0
        var escaped = false
        var ownedCall: Task<Void, Error>?
        var callbackThreads: [Bool] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let installed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var fetchCount: Int { state.withLock { $0.fetches } }
    var callbackCount: Int { state.withLock { $0.callbacks } }
    var escapeFired: Bool { state.withLock { $0.escaped } }
    var callbackThreads: [Bool] { state.withLock { $0.callbackThreads } }

    func retain(_ call: Task<Void, Error>) {
        let alreadyCancelled = state.withLock { value in
            value.ownedCall = call
            return value.escaped
        }
        if alreadyCancelled { call.cancel() }
    }

    func install(_ completion: @escaping NativeShareableContentCompletion) {
        let alreadyCancelled = state.withLock { value in
            value.fetches += 1
            value.completion = completion
            return value.escaped
        }
        installed.continuation.yield(())
        installed.continuation.finish()
        if alreadyCancelled { releaseForOwningTestCancellation() }
    }

    func waitUntilInstalled() async -> Bool {
        for await _ in installed.stream { return true }
        return false
    }

    func complete(code: Int) {
        let completion = state.withLock { value -> NativeShareableContentCompletion? in
            guard let completion = value.completion else { return nil }
            value.callbacks += 1
            value.callbackThreads.append(Thread.isMainThread)
            return completion
        }
        completion?(nil, NSError(domain: "Hireva.SyntheticShareableContent", code: code))
    }

    // The existing whole-test timeLimit cancels its owner. This synchronous
    // leaf releases an old bridge without depending on a MainActor turn, and
    // cancels the exact retained call. No two-second timer mutates readiness.
    func releaseForOwningTestCancellation() {
        let captured = state.withLock { value -> (Task<Void, Error>?, NativeShareableContentCompletion?) in
            value.escaped = true
            let completion = value.callbacks == 0 ? value.completion : nil
            if completion != nil {
                value.callbacks += 1
                value.callbackThreads.append(Thread.isMainThread)
            }
            return (value.ownedCall, completion)
        }
        // Cancellation handlers and native callbacks run outside the lock.
        captured.0?.cancel()
        captured.1?(nil, NSError(domain: "Hireva.SyntheticShareableContent", code: 97))
        installed.continuation.finish()
    }

    func close() {
        state.withLock { $0.completion = nil; $0.ownedCall = nil }
        installed.continuation.finish()
    }
}

private func expectShareableContentCancellation(_ result: Result<Void, Error>) {
    switch result {
    case .success: Issue.record("Cancelled content request published success")
    case .failure(let error): #expect(error is CancellationError)
    }
}

private func expectShareableContentError(_ result: Result<Void, Error>, code: Int) {
    switch result {
    case .success: Issue.record("Native content error published success")
    case .failure(let error):
        #expect((error as NSError).domain == "Hireva.SyntheticShareableContent")
        #expect((error as NSError).code == code)
    }
}
