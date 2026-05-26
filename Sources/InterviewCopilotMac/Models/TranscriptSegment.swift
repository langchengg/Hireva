import Foundation

enum SpeakerRole: String, CaseIterable, Identifiable, Codable {
    case interviewer
    case candidate
    case system
    case audioInput = "audio_input"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .interviewer:
            return "Interviewer"
        case .candidate:
            return "Candidate"
        case .system:
            return "System"
        case .audioInput:
            return "Interviewer / Audio Input"
        }
    }
}

struct TranscriptSegment: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var speaker: SpeakerRole
    var text: String
    var startTime: TimeInterval?
    var endTime: TimeInterval?
    var createdAt: Date

    static func system(_ text: String, sessionID: String = "ephemeral") -> TranscriptSegment {
        TranscriptSegment(
            id: UUID().uuidString,
            sessionID: sessionID,
            speaker: .system,
            text: text,
            startTime: nil,
            endTime: nil,
            createdAt: Date()
        )
    }
}
