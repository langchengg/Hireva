import Foundation

enum ActionFeedbackKind: String, Codable, Hashable {
    case info
    case loading
    case success
    case warning
    case error

    var isTerminal: Bool {
        switch self {
        case .success, .warning, .error:
            return true
        case .info, .loading:
            return false
        }
    }
}

struct ActionFeedback: Identifiable, Codable, Hashable {
    let id: UUID
    let actionID: String
    let title: String
    let message: String
    let kind: ActionFeedbackKind
    let createdAt: Date
    let autoDismissAfter: TimeInterval?

    init(
        id: UUID = UUID(),
        actionID: String,
        title: String,
        message: String,
        kind: ActionFeedbackKind,
        createdAt: Date = Date(),
        autoDismissAfter: TimeInterval? = nil
    ) {
        self.id = id
        self.actionID = actionID
        self.title = title
        self.message = message
        self.kind = kind
        self.createdAt = createdAt
        self.autoDismissAfter = autoDismissAfter
    }
}

enum ActionID {
    static let startInterview = "home.startInterview"
    static let stopListening = "home.stopListening"
    static let runReadiness = "home.runReadiness"
    static let showFloatingPanel = "home.showFloatingPanel"
    static let generateAnswer = "answer.generate"
    static let switchCaptureMode = "home.switchCaptureMode"
    static let clearLiveSession = "home.clearLiveSession"
    static let restartAudioInput = "audio.restartInput"
    static let openPermissions = "permissions.open"

    static let testDeepSeek = "settings.testDeepSeek"
    static let saveSettings = "settings.save"
    static let saveEmbeddingKey = "settings.saveEmbeddingKey"
    static let rebuildCleanRAG = "rag.rebuildClean"
    static let rebuildEmbeddings = "rag.rebuildEmbeddings"
    static let clearLocalData = "settings.clearLocalData"

    static let floatingCopy = "floating.copy"
    static let floatingRegenerate = "floating.regenerate"
    static let floatingDisplayMode = "floating.displayMode"

    static let manualRecord = "manual.record"
    static let manualStopTranscribe = "manual.stopTranscribe"
    static let manualCancel = "manual.cancel"
    static let manualGenerate = "manual.generate"
    static let manualClear = "manual.clear"

    static let providerSwitch = "provider.switch"
    static let providerTest = "provider.test"
    static let providerSave = "provider.save"
    static let providerSaveKey = "provider.saveKey"
    static let providerDelete = "provider.delete"

    static let diagnosticsRefresh = "diagnostics.refresh"
    static let diagnosticsCopy = "diagnostics.copy"
    static let sessionDelete = "sessions.delete"
    static let sessionRecap = "sessions.recap"
    static let sessionExport = "sessions.export"

    static func saveDocument(_ type: DocumentType) -> String {
        "documents.save.\(type.rawValue)"
    }

    static func previewDocument(_ type: DocumentType) -> String {
        "documents.preview.\(type.rawValue)"
    }

    static func clearDocument(_ type: DocumentType) -> String {
        "documents.clear.\(type.rawValue)"
    }

    static func readiness(_ action: ReadinessAction) -> String {
        "readiness.\(action.rawValue)"
    }

    static func provider(_ prefix: String, _ providerID: UUID) -> String {
        "\(prefix).\(providerID.uuidString)"
    }
}
