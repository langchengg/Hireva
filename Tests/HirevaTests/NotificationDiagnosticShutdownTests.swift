import Combine
import Foundation
import Testing
@testable import Hireva

#if DEBUG
@MainActor
struct NotificationDiagnosticShutdownTests {
    @Test
    func closedRefreshDoesNotPublishDeviceMetadata() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        await app.shutdownForTesting()
        var publications = 0
        let observation = app.microphoneDiagnostics.$selectedInputDeviceName.dropFirst().sink { _ in
            publications += 1 // Never retain, print or export the real device name.
        }
        app.refreshPermissions(automaticallyProbe: false)
        #expect(publications == 0)
        #expect(!app.systemAudioPermissions.hasOwnedProbeWork)
        withExtendedLifetime(observation) {}
        try database.close()
    }

    @Test
    func closedDiagnosticCannotCreateSessionOrReachSpeechConstruction() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        var hookCalls = 0
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            hookCalls += 1
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        await app.shutdownForTesting()
        let ids = try app.sessionRepository.listSessions().map(\.id)
        let state = app.liveState
        let traceCount = app.recentTranscriptRuntimeEvents.count
        await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic incomplete diagnostic input")
        #expect(hookCalls == 0)
        #expect(try app.sessionRepository.listSessions().map(\.id) == ids)
        #expect(app.currentSession == nil)
        #expect(app.liveState == state)
        #expect(app.recentTranscriptRuntimeEvents.count == traceCount)
        #expect(app.appleSpeechService == nil)
        #expect(app.transcriptionTask == nil)
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
        await app.shutdownForTesting()
        try database.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownJoinsTheActualDiagnosticInvocationBeforeReturning() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        let gate = DiagnosticFixtureGate()
        let events = AsyncStream<DiagnosticFixtureEvent>.makeStream()
        let trace = TestEventWaitTrace(label: "legacy-diagnostic-shutdown")
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            events.continuation.yield(.entered)
            await withTaskCancellationHandler {
                await gate.wait() // Owned gate ignores the diagnostic's cancellation until released.
            } onCancel: { events.continuation.yield(.cancelled) }
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        var invocation: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        try await withTaskCancellationHandler {
            do {
                invocation = Task { await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic held input") }
                #expect(try await trace.nextEvent(in: events.stream, event: "entered") == .entered)
                let state = app.liveState
                shutdown = Task {
                    let released = await app.shutdownResources()
                    events.continuation.yield(.shutdownReturned)
                    return released
                }
                // Old code returns shutdown before the unretained script exits.
                // New code signals script cancellation while retaining its real await.
                #expect(try await trace.nextEvent(in: events.stream, event: "cancel.or.return") == .cancelled)
                gate.release()
                await invocation?.value
                #expect(await shutdown?.value == true)
                #expect(app.liveState == state)
                #expect(app.appleSpeechService == nil)
                #expect(app.transcriptionTask == nil)
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await gate.finish()
                events.continuation.finish()
                try database.close()
            } catch {
                gate.release()
                invocation?.cancel(); shutdown?.cancel()
                await invocation?.value
                _ = await shutdown?.value
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try? database.close()
                throw error
            }
        } onCancel: { gate.release() }
    }

    @Test(.timeLimit(.minutes(1)))
    func overlappingDiagnosticIsExplicitlyRejectedWithoutReplacingFirstWork() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        let gate = DiagnosticFixtureGate()
        let events = AsyncStream<DiagnosticFixtureEvent>.makeStream()
        let trace = TestEventWaitTrace(label: "legacy-diagnostic-busy")
        var hookCalls = 0
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            hookCalls += 1
            events.continuation.yield(hookCalls == 1 ? .entered : .secondEntered)
            await gate.wait()
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                first = Task { await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic first held input") }
                #expect(try await trace.nextEvent(in: events.stream, event: "first.entered") == .entered)
                second = Task {
                    await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic second input")
                    events.continuation.yield(.secondReturned)
                }
                #expect(try await trace.nextEvent(in: events.stream, event: "second.outcome") == .secondReturned)
                #expect(hookCalls == 1)
                #expect(app.lastDetectionSkipReason == "diagnostic_busy")
                gate.release()
                await first?.value
                await second?.value
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try database.close()
            } catch {
                gate.release()
                first?.cancel(); second?.cancel()
                await first?.value; await second?.value
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try? database.close()
                throw error
            }
        } onCancel: { gate.release() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DiagnosticSupersession.allCases)
    fileprivate func oldDiagnosticCatchCannotReplaceLaterSessionOrProviderUI(change: DiagnosticSupersession) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        let gate = DiagnosticFixtureGate()
        let events = AsyncStream<DiagnosticFixtureEvent>.makeStream()
        let trace = TestEventWaitTrace(label: "legacy-diagnostic-stale-\(change)")
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            events.continuation.yield(.entered)
            await gate.wait()
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        let invocation = Task { await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic stale input") }
        try await withTaskCancellationHandler {
            do {
                #expect(try await trace.nextEvent(in: events.stream, event: "entered") == .entered)
                switch change {
                case .session:
                    app.currentSession = try app.createContextBoundSession(mode: .mock, title: "Synthetic replacement")
                case .provider:
                    app.activeTranscriptionProvider = MockTranscriptionService() // Opens no device.
                }
                app.liveState = .listening
                app.errorMessage = nil
                let currentID = app.currentSession?.id
                gate.release()
                await invocation.value
                #expect(app.currentSession?.id == currentID)
                #expect(app.liveState == .listening)
                #expect(app.errorMessage == nil)
                #expect(app.lastDetectionSkipReason != "diagnostic_harness_failed")
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try database.close()
            } catch {
                gate.release(); invocation.cancel()
                await invocation.value
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try? database.close()
                throw error
            }
        } onCancel: { gate.release() }
    }

    @Test(.timeLimit(.minutes(1)))
    func parentCancellationRevokesLateDiagnosticFailure() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        let gate = DiagnosticFixtureGate()
        let events = AsyncStream<DiagnosticFixtureEvent>.makeStream()
        let trace = TestEventWaitTrace(label: "legacy-diagnostic-parent-cancel")
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            events.continuation.yield(.entered)
            await gate.wait()
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        let invocation = Task { await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic cancelled input") }
        try await withTaskCancellationHandler {
            do {
                #expect(try await trace.nextEvent(in: events.stream, event: "entered") == .entered)
                let state = app.liveState
                invocation.cancel()
                gate.release()
                await invocation.value
                #expect(app.liveState == state)
                #expect(app.errorMessage == nil)
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try database.close()
            } catch {
                gate.release(); invocation.cancel()
                await invocation.value
                app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
                await app.shutdownForTesting()
                await gate.finish()
                events.continuation.finish()
                try? database.close()
                throw error
            }
        } onCancel: { gate.release() }
    }

    @Test
    func completedSyntheticFailureRetiresSlotAndAllowsNextDiagnostic() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = makeApp(database)
        var hookCalls = 0
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = {
            hookCalls += 1
            throw DiagnosticFixtureFailure.beforeSpeech
        }
        await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic first completed input")
        await app.runLiveSystemAudioFinalCallbackDiagnostic(question: "Synthetic next completed input")
        #expect(hookCalls == 2)
        #expect(try app.sessionRepository.listSessions().count == 1)
        #expect(app.appleSpeechService == nil)
        #expect(app.transcriptionTask == nil)
        app.liveSystemAudioDiagnosticWillCreateServiceForTesting = nil
        await app.shutdownForTesting()
        try database.close()
    }

    private func makeApp(_ database: AppDatabase) -> AppState {
        AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
    }
}

private enum DiagnosticSupersession: String, CaseIterable, Sendable { case session, provider }
private enum DiagnosticFixtureFailure: Error { case beforeSpeech }
private enum DiagnosticFixtureEvent: Sendable { case entered, cancelled, shutdownReturned, secondEntered, secondReturned }

/// Owns a separate, releasable await so script cancellation alone cannot satisfy
/// join assertions. Test cancellation finishes the Sendable continuation;
/// every success/catch path subsequently awaits the exact gate Task. No timers,
/// native Speech/capture, blocking locks or unmanaged cleanup tasks are used.
private struct DiagnosticFixtureGate: Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>
    init() {
        let pair = AsyncStream<Void>.makeStream()
        continuation = pair.continuation
        task = Task {
            var iterator = pair.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }
    func wait() async { await task.value }
    func release() { continuation.finish() }
    func finish() async { release(); await task.value }
}
#endif
