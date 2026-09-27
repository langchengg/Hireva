import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case preparation
    case practice
    case documents
    case sessions
    case readinessCheck
    case localModels
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home / Interview"
        case .preparation: return "Prepare / Tools"
        case .practice: return "Practice / Review"
        case .documents: return "Documents"
        case .sessions: return "Sessions"
        case .readinessCheck: return "Readiness Check"
        case .localModels: return "Setup & Local Models"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .preparation: return "wrench.and.screwdriver"
        case .practice: return "person.bubble"
        case .documents: return "doc.text"
        case .sessions: return "clock.arrow.circlepath"
        case .readinessCheck: return "checklist.checked"
        case .localModels: return "square.stack.3d.up"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}
