import AVFoundation
import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct AppleSpeechResourceRetirementTests {
    @Test(.timeLimit(.minutes(1)))
    func serviceStopRetainsTheActualPendingInputUntilJoined() async throws {
        let fixture = SpeechResourceFixture()
        do {
            try await fixture.startHeldInput(sessionID: "synthetic-service-drain")
            fixture.service.stop()
            #expect(fixture.session?.hasUnreleasedAudioInput == true)
            #expect(fixture.service.hasUnreleasedAudioInput,
                "The service must retain the exact old Session while its native append is still admitted.")
            #expect(fixture.io.endCount == 0)
            fixture.io.releaseAppend()
            await fixture.worker?.join()
            await fixture.service.finishStoppingAudioInput()
            #expect(!fixture.service.hasUnreleasedAudioInput)
            #expect(fixture.io.endCount == 1)
            await fixture.cleanup()
        } catch { await fixture.cleanup(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ProviderStopPath.allCases)
    fileprivate func providerOwnsExplicitStopAndNormalEOFUntilTheSameInputExits(path: ProviderStopPath) async throws {
        let fixture = SpeechResourceFixture()
        let provider = AppleSpeechASRProvider(service: fixture.service)
        var stop: Task<Void, Never>?
        var consumer: Task<Void, Error>?
        do {
            let stream = try await provider.startTranscription(config: .init(
                sessionID: "synthetic-provider-drain", captureMode: .microphoneOnly))
            consumer = Task { for try await _ in stream {} }
            try await fixture.holdCurrentInput()
            // Observe the real second service.stop call made by either the
            // provider's teardown worker or its normal EOF bridge. Startup is
            // complete before arming, so startup stop calls cannot satisfy it.
            fixture.io.armStopObservation(afterCalls: path == .consumerCancellation ? 1 : 2)
            switch path {
            case .explicitStop: stop = Task { await provider.stopTranscription() }
            case .normalEOF:
                fixture.service.stop()
                stop = Task { await provider.waitForCurrentTranscriptionEnd() }
            case .consumerCancellation:
                consumer?.cancel()
                stop = Task { await provider.waitForCurrentTranscriptionEnd() }
            }
            _ = try await fixture.trace.nextEvent(in: fixture.io.serviceStopped.stream,
                event: "provider_exact_service_stop")
            #expect(provider.hasOwnedTranscriptionWork,
                "Invalidating publication does not mean the held native input has exited.")
            #expect(fixture.service.hasUnreleasedAudioInput)
            #expect(fixture.io.endCount == 0)
            fixture.io.releaseAppend()
            await fixture.worker?.join()
            await stop?.value
            if path == .consumerCancellation { _ = await consumer?.result }
            else { try await consumer?.value }
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(!fixture.service.hasUnreleasedAudioInput)
            #expect(fixture.io.endCount == 1)
            await fixture.cleanup(provider: provider, consumer: consumer, operation: stop)
        } catch {
            await fixture.cleanup(provider: provider, consumer: consumer, operation: stop)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: AppStopPath.allCases)
    fileprivate func actualAppCleanupJoinsTheCapturedAppleInputBeforeReturning(path: AppStopPath) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let fixture = SpeechResourceFixture()
        do {
            try await fixture.startHeldInput(sessionID: "synthetic-app-drain")
            let capturedSession = try #require(fixture.session)
            let drainsBeforeCleanup = fixture.io.drainCount
            app.appleSpeechService = fixture.service
            app.activeTranscriptionProvider = fixture.service
            // This is a per-instance native-I/O release. It runs only when the
            // real App cleanup reaches this exact service's drain method.
            fixture.service.onAudioInputDrainForTesting = { [io = fixture.io] in
                io.observeDrain(); io.releaseAppend()
            }
            switch path {
            case .stopListening:
                app.stopListening()
                await app.captureTeardownTask?.value
            case .shutdownResources:
                let released = await app.shutdownResources()
                #expect(released)
            }
            #expect(fixture.io.drainCount > drainsBeforeCleanup,
                "The App must join its captured Apple service instead of clearing a pointer and returning.")
            #expect(fixture.io.endCount == 1)
            #expect(!capturedSession.hasUnreleasedAudioInput)
            await fixture.cleanup()
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await fixture.cleanup()
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anOldCapturedDrainCannotEndTheReplacementSpeechInput() async throws {
        let fixture = SpeechResourceFixture()
        var oldDrain: Task<Void, Never>?
        var replacement: Task<Void, Error>?
        do {
            try await fixture.startHeldInput(sessionID: "synthetic-old-input")
            fixture.service.stop()
            fixture.io.armDrainObservation()
            oldDrain = Task { await fixture.service.finishStoppingAudioInput() }
            _ = try await fixture.trace.nextEvent(in: fixture.io.drainEntered.stream,
                event: "old_input_drain_entered")
            replacement = Task {
                try await fixture.service.start(sessionID: "synthetic-replacement-input", captureMode: .microphoneOnly)
            }
            // Both red and green are released here. No negative wait or
            // non-cooperative latch is delegated to the test timeLimit.
            fixture.io.releaseAppend()
            await fixture.worker?.join()
            try await replacement?.value
            await oldDrain?.value
            let current = try #require(fixture.service.microphoneSession)
            #expect(current !== fixture.session)
            #expect(current.isRecognitionActive)
            #expect(current.hasUnreleasedAudioInput)
            #expect(fixture.service.hasUnreleasedAudioInput)
            await fixture.cleanup(operation: oldDrain, startup: replacement)
        } catch {
            await fixture.cleanup(operation: oldDrain, startup: replacement)
            throw error
        }
    }
}

private enum ProviderStopPath: CaseIterable, Sendable, Equatable { case explicitStop, normalEOF, consumerCancellation }
private enum AppStopPath: CaseIterable, Sendable { case stopListening, shutdownResources }

@MainActor
private final class SpeechResourceFixture {
    let io: SpeechResourceControlledIO
    let service: AppleSpeechTranscriptionService
    let trace = TestEventWaitTrace(label: "AppleSpeechResourceRetirementTests")
    private(set) var session: AppleSpeechTranscriptionSession?
    private(set) var worker: SpeechResourceAppendThread?

    init() {
        let io = SpeechResourceControlledIO()
        self.io = io
        service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { [io] _ in io.observeServiceStop() },
            unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: io.operations)
        service.onAudioInputDrainForTesting = { [io] in io.observeDrain() }
    }
    func startHeldInput(sessionID: String) async throws {
        try await service.start(sessionID: sessionID, captureMode: .microphoneOnly)
        try await holdCurrentInput()
    }
    func holdCurrentInput() async throws {
        let captured = try #require(service.microphoneSession)
        session = captured
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0
        let worker = SpeechResourceAppendThread(session: captured, buffer: buffer)
        self.worker = worker
        worker.start()
        _ = try await trace.nextEvent(in: io.appendEntered.stream, event: "actual_input_append_held")
        #expect(captured.inFlightPCMAppendsForTesting == 1)
    }
    func cleanup(provider: AppleSpeechASRProvider? = nil, consumer: Task<Void, Error>? = nil,
        operation: Task<Void, Never>? = nil, startup: Task<Void, Error>? = nil) async {
        // A retained, immediately joined task guarantees cleanup is not aborted
        // by cancellation of the owning test before the native gate is released.
        let cleanup = Task { @MainActor in
            io.releaseAppend()
            service.stop()
            startup?.cancel()
            await worker?.join()
            // The captured Session is retained even on the old red Service,
            // which drops it; fixture cleanup still drains its real input.
            await session?.finishStoppingAudioInput()
            await operation?.value
            _ = await startup?.result
            await service.finishStoppingAudioInput()
            await provider?.stopTranscription()
            await provider?.waitForCurrentTranscriptionEnd()
            consumer?.cancel()
            _ = await consumer?.result
            io.finishEvents()
            #expect(!io.fixtureGuardExpired)
        }
        await cleanup.value
    }
}

private final class SpeechResourceControlledIO: Sendable {
    private struct State: Sendable {
        var endCount = 0
        var drainCount = 0
        var drainObservationArmed = false
        var stopCallsUntilEvent: Int?
        var appendActive = false
        var fixtureGuardExpired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    let appendEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let serviceStopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let drainEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    var endCount: Int { state.withLock { $0.endCount } }
    var drainCount: Int { state.withLock { $0.drainCount } }
    var fixtureGuardExpired: Bool { state.withLock { $0.fixtureGuardExpired } }
    var operations: AppleSpeechPCMTestingOperations {
        .init(append: { [self] _ in
            state.withLock { $0.appendActive = true }
            appendEntered.continuation.yield(())
            // Separate native fixture escape, not a business timeout. All
            // normal/error/cancellation exits also release and join this gate.
            let result = gate.wait(timeout: .now() + .seconds(30))
            state.withLock { $0.appendActive = false; $0.fixtureGuardExpired = result == .timedOut }
        }, endAudio: { [self] in state.withLock { $0.endCount += 1 } })
    }
    func observeServiceStop() {
        let emit = state.withLock { value in
            guard let remaining = value.stopCallsUntilEvent else { return false }
            value.stopCallsUntilEvent = remaining - 1
            if remaining == 1 { value.stopCallsUntilEvent = nil; return true }
            return false
        }
        if emit { serviceStopped.continuation.yield(()) }
    }
    func observeDrain() {
        let emit = state.withLock { value in
            value.drainCount += 1
            guard value.drainObservationArmed else { return false }
            value.drainObservationArmed = false
            return true
        }
        if emit { drainEntered.continuation.yield(()) }
    }
    func armDrainObservation() { state.withLock { $0.drainObservationArmed = true } }
    func armStopObservation(afterCalls: Int) { state.withLock { $0.stopCallsUntilEvent = afterCalls } }
    func releaseAppend() { gate.signal() }
    func finishEvents() {
        appendEntered.continuation.finish(); serviceStopped.continuation.finish(); drainEntered.continuation.finish()
    }
}

private final class SpeechResourceAppendThread: NSObject {
    private let session: AppleSpeechTranscriptionSession
    private let buffer: AVAudioPCMBuffer
    private let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    @MainActor private var thread: Thread?
    @MainActor private var started = false
    init(session: AppleSpeechTranscriptionSession, buffer: AVAudioPCMBuffer) {
        self.session = session; self.buffer = buffer
    }
    @MainActor func start() {
        started = true
        thread = Thread(target: self, selector: #selector(run), object: nil)
        thread?.start()
    }
    @objc private func run() {
        session.appendBuffer(buffer)
        completed.continuation.yield(())
        completed.continuation.finish()
    }
    @MainActor func join() async {
        guard started, let thread else { return }
        var iterator = completed.stream.makeAsyncIterator(); _ = await iterator.next()
        for _ in 0..<1000 {
            if thread.isFinished { return }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { Issue.record("Owned PCM Thread join was cancelled."); return }
        }
        Issue.record("Owned synthetic PCM Thread did not exit after work completed.")
    }
}
