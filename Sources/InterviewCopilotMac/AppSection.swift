import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case documents
    case sessions
    case readinessCheck
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home / Interview"
        case .documents: return "Documents"
        case .sessions: return "Sessions"
        case .readinessCheck: return "Readiness Check"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .documents: return "doc.text"
        case .sessions: return "clock.arrow.circlepath"
        case .readinessCheck: return "checklist.checked"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}
