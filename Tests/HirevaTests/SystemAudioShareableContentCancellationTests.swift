import Foundation
import os
import Testing
@testable import Hireva

/// The same callback seam drives the original continuation bridge and the owned
/// request. The old bridge receives exactly one escape callback, never two.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioShareableContentCancellationTests {
    @Test
    func cancellationReleasesSwiftWaitBeforeNativeCallback() async throws {
        let query = SingleShareableContentCallback()
        try await withTaskCancellationHandler {
            let call = Task<Void, Error> { @MainActor in
                _ = try await NativeSystemAudioCaptureStream.shareableContent(permissionAdmission: .production, fetch: query.install)
            }
            query.retain(call)
            do {
                try #require(await query.waitUntilInstalled())
                call.cancel()
                switch await call.result {
                case .success: Issue.record("Cancelled enumeration published a successful result")
                case .failure(let error): #expect(error is CancellationError)
                }
                #expect(!query.escapeFired,
                    "Swift cancellation must release its waiter before the native escape callback")
                #expect(query.callbackCount == 0,
                    "Native completion is not required to cancel the Swift waiter")
            } catch {
                call.cancel()
                query.completeOnce(code: 98)
                _ = await call.result
                query.close()
                throw error
            }
            call.cancel()
            query.completeOnce(code: 99)
            _ = await call.result
            query.close()
        } onCancel: { query.releaseForOwningTestCancellation() }
    }
}

private final class SingleShareableContentCallback: Sendable {
    private struct State: Sendable {
        var completion: NativeShareableContentCompletion?
        var callbacks = 0
        var escaped = false
        var ownedCall: Task<Void, Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let installed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var callbackCount: Int { state.withLock { $0.callbacks } }
    var escapeFired: Bool { state.withLock { $0.escaped } }

    func retain(_ call: Task<Void, Error>) {
        let alreadyCancelled = state.withLock { value in
            value.ownedCall = call
            return value.escaped
        }
        if alreadyCancelled { call.cancel() }
    }

    func install(_ completion: @escaping NativeShareableContentCompletion) {
        let alreadyCancelled = state.withLock { value in
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

    func completeOnce(code: Int) {
        let completion = state.withLock { value -> NativeShareableContentCompletion? in
            guard let completion = value.completion else { return nil }
            value.completion = nil
            value.callbacks += 1
            return completion
        }
        completion?(nil, NSError(domain: "Hireva.SyntheticSingleContentCallback", code: code))
    }

    // Whole-test cancellation is a failure fallback, not a semantic deadline.
    // The callback is removed atomically, so even the original continuation
    // bridge receives exactly one release callback on a failing test path.
    func releaseForOwningTestCancellation() {
        let call = state.withLock { value in
            value.escaped = true
            return value.ownedCall
        }
        call?.cancel()
        completeOnce(code: 97)
        installed.continuation.finish()
    }

    func close() {
        state.withLock { $0.completion = nil; $0.ownedCall = nil }
        installed.continuation.finish()
    }
}

