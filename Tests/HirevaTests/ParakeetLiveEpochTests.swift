import Foundation
import Testing
@testable import Hireva

@Suite("Parakeet Live capture identity", .serialized)
@MainActor
struct ParakeetLiveEpochTests {
    @Test
    func oldProviderFailureCannotStopNewProviderInSameSession() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        let session = try app.sessionRepository.createSession(mode: .microphone)
        app.currentSession = session
        let oldProvider = HermeticTestASRProvider()
        let currentProvider = HermeticTestASRProvider()
        app.activeASRProviderRuntime = oldProvider
        app.markActiveASRProvider(.localParakeet)
        let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        app.consumeParakeetSegments(pair.stream, provider: oldProvider, sessionID: session.id, startupID: UUID())
        let oldConsumer = app.transcriptionTask
        app.activeASRProviderRuntime = currentProvider
        #expect(app.captureStartupID == nil) // No startup is pending for the current provider.
        app.liveState = .listening
        app.currentCaptureRuntimeState = .listening

        pair.continuation.finish(throwing: FixtureError.failed)
        await oldConsumer?.value

        #expect((app.activeASRProviderRuntime as AnyObject?) === currentProvider)
        #expect(app.liveState == .listening)
        #expect(app.currentCaptureRuntimeState == .listening)
        app.stopListening()
        await app.captureTeardownTask?.value
    }

    @Test
    func oldSessionEventsAndNormalFinishCannotChangeCurrentCapture() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        let oldSession = try app.sessionRepository.createSession(mode: .microphone)
        let currentSession = try app.sessionRepository.createSession(mode: .microphone)
        let provider = HermeticTestASRProvider()
        app.currentSession = oldSession
        app.activeASRProviderRuntime = provider
        app.markActiveASRProvider(.localParakeet)
        let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        app.consumeParakeetSegments(pair.stream, provider: provider, sessionID: oldSession.id, startupID: UUID())
        let oldConsumer = app.transcriptionTask
        app.currentSession = currentSession
        #expect(app.captureStartupID == nil)
        app.liveState = .listening
        app.currentCaptureRuntimeState = .listening

        pair.continuation.yield(.init(id: "old-capture-event", sessionID: oldSession.id, source: .systemAudio, speaker: .unknown, text: "what did you learn from comp", asrSource: .localParakeetASR, asrFinalizationReason: "final", recognitionIsFinal: true))
        pair.continuation.finish()
        await oldConsumer?.value

        #expect(app.transcriptSegments.isEmpty)
        #expect((app.activeASRProviderRuntime as AnyObject?) === provider)
        #expect(app.liveState == .listening)
        #expect(app.currentSession?.id == currentSession.id)
        #expect(app.currentSession?.endedAt == nil)
        app.stopListening()
        await app.captureTeardownTask?.value
    }

    @Test
    func newerPendingStartupInvalidatesTerminationFromCurrentRuntime() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        let session = try app.sessionRepository.createSession(mode: .microphone)
        let provider = HermeticTestASRProvider()
        app.currentSession = session
        app.activeASRProviderRuntime = provider
        app.markActiveASRProvider(.localParakeet)
        app.captureLifecycle.start { _ in }
        #expect(app.captureStartupID != nil)
        app.liveState = .listening

        app.handleParakeetStreamTermination(error: FixtureError.failed, provider: provider, sessionID: session.id, startupID: UUID())

        #expect(app.activeASRProviderRuntime === provider)
        #expect(app.liveState == .listening)
        app.stopListening()
        await app.captureTeardownTask?.value
    }

    @Test
    func completedStartupStillAcceptsCurrentRuntimeFailure() async throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let app = AppState(database: database)
        let session = try app.sessionRepository.createSession(mode: .microphone)
        let provider = HermeticTestASRProvider()
        app.currentSession = session
        app.activeASRProviderRuntime = provider
        app.markActiveASRProvider(.localParakeet)
        #expect(app.captureStartupID == nil)
        app.liveState = .listening

        app.handleParakeetStreamTermination(error: FixtureError.failed, provider: provider, sessionID: session.id, startupID: UUID())

        #expect(app.activeASRProviderRuntime == nil)
        if case .error = app.liveState {} else { Issue.record("Current runtime failure was incorrectly discarded") }
        await app.captureTeardownTask?.value
    }

    private enum FixtureError: Error { case failed }
}
