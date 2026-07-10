import Foundation

enum InterviewMode: String, CaseIterable, Identifiable, Codable {
    case mock
    case microphone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mock:
            return "Mock Transcript"
        case .microphone:
            return "Microphone"
        }
    }
}

struct InterviewSession: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var company: String?
    var role: String?
    var startedAt: Date
    var endedAt: Date?
    var mode: InterviewMode
    var createdAt: Date
    var contextSnapshotID: String? = nil
}
