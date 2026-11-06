import Combine
import Foundation
import os
import Testing
@testable import Hireva

/// Exercises AppState's existing public-in-module cleanup entry. All native
/// capabilities are per-fixture synthetic operations; no process or audio starts.
@MainActor
struct AppStateShutdownRetryTests {
    @Test
    func failedResourceCanRecoverWithoutRepeatingSuccessfulOwnerStops() async throws {
        let fixture = try AppStateShutdownRetryFixture()
        let documents = fixture.app.documentsState
        #expect(await fixture.app.shutdownResources() == false)
        let closedImportID = documents.importID
        #expect(fixture.app.isShuttingDown)
        #expect(fixture.app.activeASRProviderRuntime == nil)
        #expect(fixture.provider.stopCalls == 1)
        #expect(fixture.permissions.cleanupCalls == 1)

        fixture.permissions.remainingResult = true
        #expect(await fixture.app.shutdownResources() == true,
            "A completed false Task is a failed attempt, not a permanent resource receipt.")
        #expect(fixture.permissions.cleanupCalls == 2)
        #expect(fixture.provider.stopCalls == 1,
            "The successfully released original ASR must not stop again on quit retry.")
        #expect(documents.importID == closedImportID,
            "A successfully joined import owner must not close/revise again on unrelated failure retry.")
        #expect(fixture.app.isShuttingDown)
        #expect(await fixture.app.shutdownResources() == true)
        #expect(fixture.permissions.cleanupCalls == 2,
            "A successful cleanup receipt is idempotent, including a third caller.")
        await fixture.cleanup()
    }

    @Test
    func repeatedFailureRemainsVisibleAndNeverReopensApplicationAdmission() async throws {
        let fixture = try AppStateShutdownRetryFixture()
        fixture.permissions.remainingResult = false
        #expect(await fixture.app.shutdownResources() == false)
        let closedImportID = fixture.app.documentsState.importID
        #expect(await fixture.app.shutdownResources() == false)
        #expect(await fixture.app.shutdownResources() == false)
        #expect(fixture.permissions.cleanupCalls == 3,
            "Each explicit completed-failure retry must consult the same retained failure owner.")
        #expect(fixture.provider.stopCalls == 1)
        #expect(fixture.app.documentsState.importID == closedImportID)
        #expect(fixture.app.isShuttingDown)
        fixture.app.startListening(mode: .mock)
        #expect(fixture.app.captureStartupTask == nil)
        let rejected = fixture.app.generationCoordinator.beginRequest(triggerPath: .manualGenerate)
        #expect(!fixture.app.generationCoordinator.isCurrentRequest(rejected))
        #expect(fixture.app.documentsState.pendingImportTaskCount == 0)
        #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        await fixture.cleanup()
    }

    @Test(.timeLimit(.minutes(1)))
    func borrowerCanRetryFailureBeforeOriginalWaiterFinishesItsResultObservation() async throws {
        let fixture = try AppStateShutdownRetryFixture()
        let gate = AppStateShutdownRetirementGate()
        var observedResults = 0
        fixture.app.shutdownResultDidAwaitForTesting = {
            observedResults += 1
            if observedResults == 1 {
                gate.originalWaiting.continuation.yield(())
                await gate.wait()
            }
        }
        @MainActor func cleanup() async {
            gate.release()
            for call in gate.ownedCalls { _ = await call.value }
            fixture.app.shutdownResultDidAwaitForTesting = nil
            await fixture.cleanup()
            gate.closeAfterJoin()
        }
        try await withTaskCancellationHandler {
            do {
                let original = Task { @MainActor in await fixture.app.shutdownResources() }
                gate.retainOriginal(original)
                let trace = TestEventWaitTrace(label: #function)
                _ = try await trace.nextEvent(in: gate.originalWaiting.stream,
                    event: "original_waiter_result_observation")
                let closedImportID = fixture.app.documentsState.importID
                let borrower = Task { @MainActor in
                    _ = await fixture.app.shutdownResources()
                    let retry = await fixture.app.shutdownResources()
                    gate.borrowerResult.continuation.yield(retry)
                    return retry
                }
                gate.retainBorrower(borrower)
                let retried = try await trace.nextEvent(in: gate.borrowerResult.stream,
                    event: "borrower_immediate_retry_terminal")
                #expect(retried,
                    "A failed attempt must be retired by its Task before any borrower can retry, even while its original waiter is held.")
                #expect(fixture.permissions.cleanupCalls == 2)
                #expect(fixture.provider.stopCalls == 1)
                #expect(fixture.app.documentsState.importID == closedImportID)
                #expect(fixture.app.isShuttingDown)
                gate.release()
                #expect(await original.value == false,
                    "The original caller retains its attempt's false result after another caller succeeds.")
                #expect(await borrower.value == true)
                #expect(await fixture.app.shutdownResources() == true)
                #expect(!gate.escaped)
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
            #expect(!gate.escaped)
        } onCancel: { gate.cancelOwningTest() }
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentRetryCallersJoinOneExactAttemptEvenWhenOneWaiterIsCancelled() async throws {
        let fixture = try AppStateShutdownRetryFixture()
        let gate = fixture.permissions.retryGate
        try await withTaskCancellationHandler {
            #expect(await fixture.app.shutdownResources() == false)
            fixture.permissions.remainingResult = true
            fixture.permissions.holdRetries = true
            let trace = TestEventWaitTrace(label: #function)
            let retry = Task { @MainActor in
                let result = await fixture.app.shutdownResources()
                gate.retryEvents.continuation.yield(.completed(result))
                return result
            }
            gate.retainRetry(retry)
            var waiter: Task<Bool, Never>?
            do {
                let entered = try await trace.nextEvent(in: gate.retryEvents.stream, event: "retry_resource_entry_or_terminal")
                try #require(entered == .entered(2),
                    "The retry must consult the failed resource before it can return a terminal result.")
                let borrower = Task { @MainActor in
                    gate.waiterEntered.continuation.yield(())
                    return await fixture.app.shutdownResources()
                }
                waiter = borrower
                gate.retainBorrower(borrower)
                _ = try await trace.nextEvent(in: gate.waiterEntered.stream, event: "shutdown_borrower_entered")
                borrower.cancel()
                gate.release()
                #expect(await retry.value == true)
                #expect(await borrower.value == true)
                #expect(!gate.escaped,
                    "Owning-test cancellation is a failed fixture fallback, never a success path.")
                #expect(fixture.permissions.cleanupCalls == 2,
                    "Concurrent callers own one retry; cancellation of a borrower must not cancel cleanup.")
                #expect(fixture.provider.stopCalls == 1)
                #expect(fixture.app.isShuttingDown)
            } catch {
                gate.release()
                retry.cancel()
                waiter?.cancel()
                _ = await retry.value
                _ = await waiter?.value
                await fixture.cleanup()
                gate.closeAfterJoin()
                throw error
            }
            gate.release()
            _ = await retry.value
            _ = await waiter?.value
            await fixture.cleanup()
            gate.closeAfterJoin()
            #expect(!gate.escaped)
        } onCancel: { gate.releaseForOwningTestCancellation() }
    }
}

@MainActor
private final class AppStateShutdownRetryPermissions: PermissionService {
    var cleanupCalls = 0
    var remainingResult = true
    var holdRetries = false
    nonisolated let retryGate = AppStateShutdownRetryGate()
    var retryEntered: (stream: AsyncStream<Int>, continuation: AsyncStream<Int>.Continuation) {
        retryGate.retryEntered
    }

    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .denied, speechRecognition: .denied,
            screenRecording: .denied, systemAudioCapture: .denied)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .denied }
    override func speechStatus() -> PermissionState { .denied }
    override func requestMicrophonePermission() async -> MicrophonePermissionState { .denied }
    override func requestSpeechRecognition() async -> PermissionState { .denied }
    override func shutdownCodeSigningDiagnostics() async -> Bool {
        cleanupCalls += 1
        if cleanupCalls == 1 { return false }
        retryEntered.continuation.yield(cleanupCalls)
        retryGate.retryEvents.continuation.yield(.entered(cleanupCalls))
        if holdRetries { await retryGate.wait() }
        return remainingResult
    }
    func release() { retryGate.release() }
}

/// Owns only the controlled test latch and its two exact caller handles. It is
/// synchronous and checked Sendable so cancellation needs no MainActor turn.
private final class AppStateShutdownRetryGate: Sendable {
    enum RetryEvent: Sendable, Equatable { case entered(Int); case completed(Bool) }
    private struct State: Sendable {
        var released = false
        var escaped = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var retry: Task<Bool, Never>?
        var borrower: Task<Bool, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let retryEntered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(4))
    let retryEvents = AsyncStream<RetryEvent>.makeStream(bufferingPolicy: .bufferingOldest(4))
    let waiterEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var escaped: Bool { state.withLock { $0.escaped } }

    func retainRetry(_ call: Task<Bool, Never>) {
        let cancelled = state.withLock { $0.retry = call; return $0.escaped }
        if cancelled { call.cancel() }
    }
    func retainBorrower(_ call: Task<Bool, Never>) {
        let cancelled = state.withLock { $0.borrower = call; return $0.escaped }
        if cancelled { call.cancel() }
    }
    func wait() async {
        await withCheckedContinuation { waiter in
            let alreadyReleased = state.withLock { value in
                if value.released { return true }
                value.waiters.append(waiter)
                return false
            }
            if alreadyReleased { waiter.resume() }
        }
    }
    func release() {
        let owned = state.withLock { value in
            value.released = true
            let owned = value.waiters
            value.waiters.removeAll()
            return owned
        }
        owned.forEach { $0.resume() }
    }
    func releaseForOwningTestCancellation() {
        let calls = state.withLock { value in
            value.escaped = true
            return (value.retry, value.borrower)
        }
        // No cancellation or continuation resumption while holding the lock.
        calls.0?.cancel()
        calls.1?.cancel()
        release()
        retryEntered.continuation.finish()
        retryEvents.continuation.finish()
        waiterEntered.continuation.finish()
    }
    func closeAfterJoin() {
        state.withLock { $0.retry = nil; $0.borrower = nil }
        retryEntered.continuation.finish()
        retryEvents.continuation.finish()
        waiterEntered.continuation.finish()
    }
}

/// Owns the deliberately held result observer and two exact API callers.
/// Cancellation releases synchronous checked state without a MainActor turn.
private final class AppStateShutdownRetirementGate: Sendable {
    private struct State: Sendable {
        var released = false
        var escaped = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var original: Task<Bool, Never>?
        var borrower: Task<Bool, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let originalWaiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let borrowerResult = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var escaped: Bool { state.withLock { $0.escaped } }
    var ownedCalls: [Task<Bool, Never>] {
        state.withLock { [$0.original, $0.borrower].compactMap { $0 } }
    }
    func retainOriginal(_ task: Task<Bool, Never>) {
        let cancel = state.withLock { $0.original = task; return $0.escaped }
        if cancel { task.cancel() }
    }
    func retainBorrower(_ task: Task<Bool, Never>) {
        let cancel = state.withLock { $0.borrower = task; return $0.escaped }
        if cancel { task.cancel() }
    }
    func wait() async {
        await withCheckedContinuation { waiter in
            let released = state.withLock { value in
                if value.released { return true }
                value.waiters.append(waiter)
                return false
            }
            if released { waiter.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { value in
            value.released = true
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
    func cancelOwningTest() {
        state.withLock { $0.escaped = true }
        let calls = ownedCalls
        release()
        originalWaiting.continuation.finish()
        borrowerResult.continuation.finish()
        calls.forEach { $0.cancel() }
    }
    func closeAfterJoin() {
        state.withLock { $0.original = nil; $0.borrower = nil }
        originalWaiting.continuation.finish()
        borrowerResult.continuation.finish()
    }
}

@MainActor
private final class AppStateShutdownRetryASR: ASRProvider {
    nonisolated let id: ASRProviderID = .localWhisper
    nonisolated let displayName = "Synthetic shutdown receipt fixture"
    private(set) var stopCalls = 0
    func isAvailable() async -> Bool { false }
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        throw CancellationError()
    }
    func stopTranscription() async { stopCalls += 1 }
}

@MainActor
private final class AppStateShutdownRetryFixture {
    let database: AppDatabase
    let suiteName = "com.langcheng.Hireva.tests.shutdown-retry." + UUID().uuidString
    let defaults: UserDefaults
    let permissions = AppStateShutdownRetryPermissions()
    let provider = AppStateShutdownRetryASR()
    let app: AppState
    init() throws {
        database = try AppDatabase(inMemory: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        var settings = AppSettings.default
        settings.audioCaptureMode = .systemAudioOnly
        settings.manualCaptureSource = .systemAudio
        settings.saveTranscriptsLocally = false
        try SettingsRepository(database: database).saveSettings(settings)
        let owner = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), probe: { throw CancellationError() }, stopProbe: {})
        let audio = ManualCaptureCapabilities.Audio(start: { _, _, _, _ in throw CancellationError() },
            stop: { .init(buffers: [], bufferCount: 0, lastBufferTimestamp: nil, drain: nil) },
            cancel: { nil }, finishStop: { if let owned = $0 { try await owned.task.value } },
            retryStop: { try await $0.task.value },
            duration: { 0 }, level: { 0 }, decibels: { -90 }, bufferCount: { 0 }, lastBufferTimestamp: { nil },
            changes: Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher())
        let speech = ManualCaptureCapabilities.Speech(start: { _, _, _ in throw CancellationError() },
            append: { _ in }, finalize: { _ in throw CancellationError() }, cancel: {})
        app = AppState(database: database, permissionService: permissions,
            systemAudioPermissions: owner,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService(),
            dialogueDefaults: defaults, manualCaptureCapabilities: .init(audio: audio, speech: speech))
        app.activeASRProviderRuntime = provider
    }
    func cleanup() async {
        permissions.remainingResult = true
        permissions.release()
        _ = await app.shutdownResources()
        await app.generationCoordinator.drainRetiredTasks()
        permissions.retryEntered.continuation.finish()
        defaults.removePersistentDomain(forName: suiteName)
        try? database.close()
    }
}
