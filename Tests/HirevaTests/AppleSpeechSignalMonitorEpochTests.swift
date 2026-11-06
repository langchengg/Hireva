import AVFoundation
import Foundation
import Testing
@testable import Hireva

#if DEBUG
private let signalMonitorUsesSimulatedCapture = true
#else
private let signalMonitorUsesSimulatedCapture = false
#endif

/// Actual monitor and existing per-instance simulated Speech/PCM capabilities.
/// No permission request, real microphone, system audio or global meter mutation.
/// Existing service simulation is DEBUG-only; release tests must report SKIP.
@Suite(.enabled(if: signalMonitorUsesSimulatedCapture))
@MainActor
struct AppleSpeechSignalMonitorEpochTests {
    @Test(.timeLimit(.minutes(1)), arguments: NoBufferQuestionClock.allCases, [1.0, 4.0])
    func noBufferDeadlineBelongsToOwnedMicrophoneStart(questionClock: NoBufferQuestionClock, elapsed: Double) async throws {
        let fixture = try SignalMonitorFixture()
        do {
            try await fixture.start()
            let mic = try #require(fixture.service.microphoneSession)
            let startedAt = try #require(mic.sessionStartedAt)
            #expect(mic.lastBufferReceivedAt == nil && mic.totalBuffersAppended == 0)
            // An unrelated prior Live start is not this Speech epoch's clock.
            fixture.app.lastCaptureStartedAt = startedAt.addingTimeInterval(-1000)
            switch questionClock {
            case .absent: fixture.app.lastDetectionAt = nil
            case .recent: fixture.app.lastDetectionAt = startedAt.addingTimeInterval(4)
            case .old: fixture.app.lastDetectionAt = startedAt.addingTimeInterval(-1000)
            }
            fixture.app.monitorAudioSignal(now: startedAt.addingTimeInterval(elapsed))
            #expect(fixture.app.noAudioWarningVisible == (elapsed > 3),
                "No-buffer warning must follow the current microphone epoch, independently of nil/recent/old question timestamps.")
            #expect((fixture.app.audioRouteError == SignalMonitorFixture.noSignal) == (elapsed > 3))
            #expect(mic.lastBufferReceivedAt == nil && mic.totalBuffersAppended == 0)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualCurrentPCMMovesDeadlineAndClearsOnlyItsNoSignalError() async throws {
        let fixture = try SignalMonitorFixture()
        do {
            try await fixture.start()
            let mic = try #require(fixture.service.microphoneSession)
            mic.appendBuffer(try fixture.makeBuffer())
            let lastBuffer = try #require(mic.lastBufferReceivedAt)
            #expect(mic.totalBuffersAppended == 1)
            fixture.app.lastDetectionAt = lastBuffer.addingTimeInterval(-1000)
            fixture.app.audioRouteError = SignalMonitorFixture.noSignal
            fixture.app.noAudioWarningVisible = true
            fixture.app.monitorAudioSignal(now: lastBuffer.addingTimeInterval(1))
            #expect(!fixture.app.noAudioWarningVisible)
            #expect(fixture.app.audioRouteError == "Audio input restored.")
            fixture.app.monitorAudioSignal(now: lastBuffer.addingTimeInterval(4))
            #expect(fixture.app.noAudioWarningVisible)
            #expect(fixture.app.audioRouteError == SignalMonitorFixture.noSignal)
            fixture.app.audioRouteError = "A separate native route failure."
            fixture.app.monitorAudioSignal(now: lastBuffer.addingTimeInterval(1))
            #expect(!fixture.app.noAudioWarningVisible)
            #expect(fixture.app.audioRouteError == "A separate native route failure.")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func restartCannotBorrowOldPCMOrOldCaptureDeadline() async throws {
        let fixture = try SignalMonitorFixture()
        do {
            try await fixture.start()
            let oldMic = try #require(fixture.service.microphoneSession)
            let oldReceiver = fixture.service.microphoneCaptureReceiver
            let buffer = try fixture.makeBuffer()
            oldMic.appendBuffer(buffer)
            let oldBufferAt = try #require(oldMic.lastBufferReceivedAt)
            fixture.app.lastAudioBufferAt = oldBufferAt
            fixture.app.lastCaptureStartedAt = try #require(oldMic.sessionStartedAt).addingTimeInterval(-1000)
            fixture.service.stop()
            await fixture.service.finishStoppingAudioInput()
            try await fixture.start()
            let mic = try #require(fixture.service.microphoneSession)
            let startedAt = try #require(mic.sessionStartedAt)
            #expect(mic !== oldMic && startedAt >= oldBufferAt)
            #expect(mic.lastBufferReceivedAt == nil && mic.totalBuffersAppended == 0)
            // A late callback retains the old receiver and its closed PCM slot.
            oldReceiver.audioEngineManager(fixture.manager, didReceive: buffer,
                at: .init(sampleTime: 1, atRate: 16000))
            #expect(mic.lastBufferReceivedAt == nil && mic.totalBuffersAppended == 0)
            fixture.app.lastDetectionAt = nil
            fixture.app.audioRouteError = SignalMonitorFixture.noSignal
            fixture.app.noAudioWarningVisible = true
            fixture.app.monitorAudioSignal(now: startedAt.addingTimeInterval(1))
            #expect(!fixture.app.noAudioWarningVisible && fixture.app.audioRouteError == nil)
            fixture.app.monitorAudioSignal(now: startedAt.addingTimeInterval(4))
            #expect(fixture.app.noAudioWarningVisible && fixture.app.audioRouteError == SignalMonitorFixture.noSignal)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test(.timeLimit(.minutes(1)), arguments: SignalMonitorInactiveCase.allCases)
    func inactiveOrUnselectedMicrophoneCannotRaiseNoBufferWarning(state: SignalMonitorInactiveCase) async throws {
        let fixture = try SignalMonitorFixture()
        do {
            try await fixture.start(mode: state == .systemOnly ? .systemAudioOnly : .microphoneOnly)
            let startedAt = fixture.service.microphoneSession?.sessionStartedAt ?? Date()
            if state == .notListening { fixture.app.liveState = .stopped }
            if state == .stoppedRecognition { fixture.service.microphoneSession?.stop() }
            fixture.app.lastDetectionAt = startedAt.addingTimeInterval(-1000)
            fixture.app.noAudioWarningVisible = true
            fixture.app.monitorAudioSignal(now: startedAt.addingTimeInterval(4))
            #expect(!fixture.app.noAudioWarningVisible)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

enum NoBufferQuestionClock: CaseIterable, Sendable { case absent, recent, old }
enum SignalMonitorInactiveCase: CaseIterable, Sendable { case systemOnly, notListening, stoppedRecognition }

@MainActor
private final class SignalMonitorFixture {
    static let noSignal = "No microphone signal detected. Check input device or restart audio capture."
    let database: AppDatabase
    let app: AppState
    let service: AppleSpeechTranscriptionService
    let manager: AudioEngineManager
    init() throws {
        database = try AppDatabase(inMemory: true)
        app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        manager = AudioEngineManager(testingOperations: .init(installAndPrepareTap: {}, start: {},
            stop: {}, removeTap: {}, reset: {}, isRunning: { false }))
        app.appleSpeechService = service
    }
    func start(mode: AudioCaptureMode = .microphoneOnly) async throws {
        try await service.start(sessionID: "synthetic-signal-" + UUID().uuidString, captureMode: mode)
        app.liveState = .listening
    }
    func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1; buffer.floatChannelData![0][0] = 0
        return buffer
    }
    func close() async {
        service.stop(); await service.finishStoppingAudioInput()
        app.appleSpeechService = nil
        await app.shutdownForTesting()
        try? database.close()
    }
}
