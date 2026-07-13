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
    let providerName = "Mock Interview Mode"
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var currentSessionID: String?

    // Allows user to manually select a speaker role for mock inputs
    var selectedMockSpeaker: SpeakerRole = .interviewer

    lazy var segments: AsyncStream<TranscriptSegment> = AsyncStream { continuation in
        self.continuation = continuation
    }

    func start(sessionID: String) async throws {
        currentSessionID = sessionID
    }

    func submit(_ text: String, speaker: SpeakerRole? = nil) {
        guard let currentSessionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let finalSpeaker = speaker ?? selectedMockSpeaker

        continuation?.yield(
            TranscriptSegment(
                id: UUID().uuidString,
                sessionID: currentSessionID,
                source: .mock,
                speaker: finalSpeaker,
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
        currentSessionID = nil
    }
}
