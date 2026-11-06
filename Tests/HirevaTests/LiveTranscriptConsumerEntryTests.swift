import Foundation
import Combine
import os
import Testing
@testable import Hireva

/// These are real AppState.consumeSegments entry tests with per-instance stream
/// senders and isolated data. Apple cases use the real service's existing
/// diagnostic simulator and injected stop I/O; they never start a device.
@MainActor
struct LiveTranscriptConsumerEntryTests {
    @Test(.timeLimit(.minutes(1)), arguments: LegacyConsumerReplacement.allCases)
    func retiredLegacyProviderCannotPublishIntoCurrentWorkspace(change: LegacyConsumerReplacement) async throws {
        let fixture = try await TranscriptConsumerFixture()
        let oldSender = TranscriptConsumerSender()
        let currentSender = TranscriptConsumerSender()
        let old = TranscriptConsumerProvider(sender: oldSender)
        let current = TranscriptConsumerProvider(sender: currentSender)
        var owned: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                let session = try fixture.app.sessionRepository.createSession(mode: .mock)
                fixture.app.currentSession = session
                fixture.app.liveState = .listening
                fixture.app.activeTranscriptionProvider = old
                fixture.app.consumeSegments(from: old)
                owned.append(try #require(fixture.app.transcriptionTask))
                _ = try await fixture.trace.nextEvent(in: oldSender.observed.stream,
                    event: "old_exact_stream_snapshot_observed")
                let targetSession: InterviewSession
                if change.changesSession {
                    targetSession = try fixture.app.sessionRepository.createSession(mode: .mock)
                    fixture.app.currentSession = targetSession
                } else { targetSession = session }
                if change.replacesProvider {
                    fixture.app.activeTranscriptionProvider = current
                    fixture.app.consumeSegments(from: current)
                    owned.append(try #require(fixture.app.transcriptionTask))
                    _ = try await fixture.trace.nextEvent(in: currentSender.observed.stream,
                        event: "replacement_exact_stream_snapshot_observed")
                }
                let late = TranscriptSegment(id: "retired-legacy-event", sessionID: session.id,
                    source: .mock, speaker: .unknown, text: "Synthetic retired capture statement.")
                oldSender.emit(late)
                oldSender.finish()
                await owned[0].value
                #expect(!fixture.app.transcriptSegments.contains { $0.id == late.id },
                    "A replaced provider or foreign session must not append a late segment to the current workspace.")
                #expect(fixture.app.lastTranscriptSnippet != late.text)
                #expect(fixture.app.currentSession?.id == targetSession.id)
                #expect(fixture.app.currentSession?.endedAt == nil)
                currentSender.finish()
                for task in owned { await task.value }
                await fixture.cleanup()
            } catch {
                oldSender.finish()
                currentSender.finish()
                for task in owned { task.cancel(); await task.value }
                await fixture.cleanup()
                oldSender.closeAfterJoin(); currentSender.closeAfterJoin()
                throw error
            }
            oldSender.closeAfterJoin(); currentSender.closeAfterJoin()
            #expect(!oldSender.escaped && !currentSender.escaped)
        } onCancel: {
            oldSender.cancelOwningTest()
            currentSender.cancelOwningTest()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: AppleConsumerReplacement.allCases)
    func actualAppleDiagnosticStreamCannotPublishAfterProviderOrSessionReplacement(change: AppleConsumerReplacement) async throws {
        let fixture = try await TranscriptConsumerFixture()
        let currentSender = TranscriptConsumerSender()
        let current = TranscriptConsumerProvider(sender: currentSender)
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
        var owned: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                let session = try fixture.app.sessionRepository.createSession(mode: .mock)
                fixture.app.currentSession = session
                fixture.app.liveState = .listening
                service.startDiagnosticSystemAudioSession(sessionID: session.id)
                let exactSession = try #require(service.systemAudioSession)
                #expect(service.microphoneSession == nil)
                #expect(exactSession.simulatedTaskActive)
                fixture.app.appleSpeechService = service
                fixture.app.activeTranscriptionProvider = service
                fixture.app.consumeSegments(from: service)
                owned.append(try #require(fixture.app.transcriptionTask))
                let targetSession: InterviewSession
                if change == .session {
                    targetSession = try fixture.app.sessionRepository.createSession(mode: .mock)
                    fixture.app.currentSession = targetSession
                } else {
                    targetSession = session
                    fixture.app.activeTranscriptionProvider = current
                    fixture.app.consumeSegments(from: current)
                    owned.append(try #require(fixture.app.transcriptionTask))
                    _ = try await fixture.trace.nextEvent(in: currentSender.observed.stream,
                        event: "replacement_apple_consumer_stream_snapshot_observed")
                }
                let late = "Synthetic obsolete Apple recognition statement."
                exactSession.simulateEmit(text: late, isFinal: true)
                service.stop()
                await owned[0].value
                #expect(!fixture.app.transcriptSegments.contains { $0.text == late },
                    "The real Apple service's final event cannot publish through a retired session/provider consumer.")
                #expect(fixture.app.lastTranscriptSnippet != late)
                #expect(fixture.app.currentSession?.id == targetSession.id)
                #expect(fixture.app.currentSession?.endedAt == nil)
                currentSender.finish()
                for task in owned { await task.value }
                await service.finishStoppingAudioInput()
                await fixture.cleanup()
            } catch {
                currentSender.finish()
                service.stop()
                for task in owned { task.cancel(); await task.value }
                await service.finishStoppingAudioInput()
                await fixture.cleanup()
                currentSender.closeAfterJoin()
                throw error
            }
            currentSender.closeAfterJoin()
            #expect(!currentSender.escaped)
        } onCancel: { currentSender.cancelOwningTest() }
    }

    @Test(.timeLimit(.minutes(1)))
    func applicationShutdownOwnsReplacedConsumerUntilItsExactStreamTerminates() async throws {
        let fixture = try await TranscriptConsumerFixture()
        let oldSender = TranscriptConsumerSender()
        let currentSender = TranscriptConsumerSender()
        let old = TranscriptConsumerProvider(sender: oldSender)
        let current = TranscriptConsumerProvider(sender: currentSender)
        var owned: [Task<Void, Never>] = []
        let readiness = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let publication = fixture.app.liveInterview.$lastTranscriptSnippet.sink { value in
            if value == "Synthetic old consumer readiness." || value == "Synthetic new consumer readiness." {
                readiness.continuation.yield(value)
            }
        }
        defer { publication.cancel(); readiness.continuation.finish() }
        try await withTaskCancellationHandler {
            do {
                let session = try fixture.app.sessionRepository.createSession(mode: .mock)
                fixture.app.currentSession = session
                fixture.app.activeTranscriptionProvider = old
                fixture.app.consumeSegments(from: old)
                let first = try #require(fixture.app.transcriptionTask)
                owned.append(first)
                _ = try await fixture.trace.nextEvent(in: oldSender.observed.stream,
                    event: "old_awaiting_stream_snapshot_observed")
                oldSender.emit(TranscriptSegment(id: "consumer-readiness-old", sessionID: session.id,
                    source: .mock, speaker: .unknown, text: "Synthetic old consumer readiness."))
                let oldReady = try await fixture.trace.nextEvent(in: readiness.stream,
                    event: "old_exact_iterator_accepted_first_segment")
                #expect(oldReady == "Synthetic old consumer readiness.")
                fixture.app.activeTranscriptionProvider = current
                fixture.app.consumeSegments(from: current)
                owned.append(try #require(fixture.app.transcriptionTask))
                _ = try await fixture.trace.nextEvent(in: currentSender.observed.stream,
                    event: "new_awaiting_stream_snapshot_observed")
                currentSender.emit(TranscriptSegment(id: "consumer-readiness-current", sessionID: session.id,
                    source: .mock, speaker: .unknown, text: "Synthetic new consumer readiness."))
                let currentReady = try await fixture.trace.nextEvent(in: readiness.stream,
                    event: "new_exact_iterator_accepted_first_segment")
                #expect(currentReady == "Synthetic new consumer readiness.")
                let released = await fixture.app.shutdownResources()
                #expect(released)
                #expect(first.isCancelled,
                    "Overwriting the visible Task slot must not discard cancellation ownership of the old consumer.")
                #expect(oldSender.terminated,
                    "Shutdown cannot return while the old exact AsyncStream iteration remains open.")
                #expect(currentSender.terminated)
                // Release every sender even on RED. The controlled old source
                // is not allowed to remain waiting in the test host.
                oldSender.finish(); currentSender.finish()
                for task in owned { await task.value }
                await fixture.cleanup()
            } catch {
                oldSender.finish(); currentSender.finish()
                for task in owned { task.cancel(); await task.value }
                await fixture.cleanup()
                oldSender.closeAfterJoin(); currentSender.closeAfterJoin()
                throw error
            }
            oldSender.closeAfterJoin(); currentSender.closeAfterJoin()
            #expect(!oldSender.escaped && !currentSender.escaped)
        } onCancel: {
            oldSender.cancelOwningTest()
            currentSender.cancelOwningTest()
            readiness.continuation.finish()
        }
    }
}

enum LegacyConsumerReplacement: String, CaseIterable, Sendable {
    case provider, session, both
    var changesSession: Bool { self != .provider }
    var replacesProvider: Bool { self != .session }
}
enum AppleConsumerReplacement: String, CaseIterable, Sendable { case provider, session }

@MainActor
private final class TranscriptConsumerProvider: TranscriptionProvider {
    let providerName = "Synthetic isolated transcript sender"
    let sender: TranscriptConsumerSender
    init(sender: TranscriptConsumerSender) { self.sender = sender }
    var segments: AsyncStream<TranscriptSegment> {
        sender.observed.continuation.yield(())
        return sender.values.stream
    }
    func start(sessionID: String) async throws {}
    func stop() { sender.finish() }
}

/// Records exact source termination with synchronous checked state. Its
/// onTermination handler never waits for an actor, task, semaphore or I/O.
private final class TranscriptConsumerSender: Sendable {
    private struct State: Sendable { var terminated = false; var escaped = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let values = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .bufferingOldest(4))
    let observed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
    var terminated: Bool { state.withLock { $0.terminated } }
    var escaped: Bool { state.withLock { $0.escaped } }
    init() {
        let state = self.state
        values.continuation.onTermination = { _ in state.withLock { $0.terminated = true } }
    }
    func emit(_ value: TranscriptSegment) { values.continuation.yield(value) }
    func finish() { values.continuation.finish() }
    func cancelOwningTest() {
        state.withLock { $0.escaped = true }
        finish()
        observed.continuation.finish()
    }
    func closeAfterJoin() { observed.continuation.finish() }
}

@MainActor
private final class TranscriptConsumerFixture {
    let database: AppDatabase
    let defaults: UserDefaults
    let suite = "com.langcheng.Hireva.tests.live-consumer." + UUID().uuidString
    let trace = TestEventWaitTrace(label: "actual-live-transcript-consumer-entry")
    let app: AppState
    init() async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        defaults = try #require(UserDefaults(suiteName: suite))
        var settings = AppSettings.default
        settings.saveTranscriptsLocally = false
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = false
        settings.manualOnlyMode = true
        try SettingsRepository(database: database).saveSettings(settings)
        app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService(), dialogueDefaults: defaults)
        app.transcriptSegments = []
        app.lastTranscriptSnippet = ""
    }
    func cleanup() async {
        await app.shutdownForTesting()
        defaults.removePersistentDomain(forName: suite)
        try? database.close()
    }
}
