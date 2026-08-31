import Foundation

protocol TranscriptionProvider: AnyObject {
    var providerName: String { get }
    var segments: AsyncStream<TranscriptSegment> { get }
    func start(sessionID: String) async throws
    func stop()
}

enum TranscriptionError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

final class MockTranscriptionService: TranscriptionProvider {
    private struct State {
        var continuation: AsyncStream<TranscriptSegment>.Continuation?
        var currentSessionID: String?
        var startBarrier: (() async -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var selectedMockSpeaker: SpeakerRole = .interviewer
    }

    let providerName = "Mock Interview Mode"
    private let stateLock = NSLock()
    private var state = State()

    var startBarrier: (() async -> Void)? {
        get { stateLock.withLock { state.startBarrier } }
        set { stateLock.withLock { state.startBarrier = newValue } }
    }

    var startCallCount: Int {
        stateLock.withLock { state.startCallCount }
    }

    var stopCallCount: Int {
        stateLock.withLock { state.stopCallCount }
    }

    // Allows user to manually select a speaker role for mock inputs
    var selectedMockSpeaker: SpeakerRole {
        get { stateLock.withLock { state.selectedMockSpeaker } }
        set { stateLock.withLock { state.selectedMockSpeaker = newValue } }
    }

    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { [weak self] continuation in
        self?.stateLock.withLock {
            self?.state.continuation = continuation
        }
    }

    func start(sessionID: String) async throws {
        // Snapshot the optional test barrier while holding the lock, but never
        // keep a blocking primitive held across an async suspension point.
        let barrier = stateLock.withLock { () -> (() async -> Void)? in
            state.startCallCount += 1
            return state.startBarrier
        }
        await barrier?()
        stateLock.withLock {
            state.currentSessionID = sessionID
        }
    }

    func submit(_ text: String, speaker: SpeakerRole? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let snapshot = stateLock.withLock {
            (
                sessionID: state.currentSessionID,
                speaker: speaker ?? state.selectedMockSpeaker,
                continuation: state.continuation
            )
        }
        guard let currentSessionID = snapshot.sessionID else { return }

        snapshot.continuation?.yield(
            TranscriptSegment(
                id: UUID().uuidString,
                sessionID: currentSessionID,
                source: .mock,
                speaker: snapshot.speaker,
                text: trimmed,
                startTime: nil,
                endTime: nil,
                createdAt: Date(),
                inputDeviceName: "Mock Input",
                outputDeviceName: "Mock Output",
                deviceID: "mock_id",
                confidence: 1.0
            )
        )
    }

    func stop() {
        stateLock.withLock {
            state.stopCallCount += 1
            state.currentSessionID = nil
        }
    }
}
