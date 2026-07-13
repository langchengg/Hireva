import Foundation

public enum DeepSeekModel: String, CaseIterable, Identifiable, Codable {
    case realtime = "deepseek-v4-flash"
    case analysis = "deepseek-v4-pro"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realtime:
            return "deepseek-v4-flash"
        case .analysis:
            return "deepseek-v4-pro"
        }
    }
}

public enum AudioCaptureMode: String, CaseIterable, Identifiable, Codable {
    case microphoneOnly = "microphoneOnly"
    case systemAudioOnly = "systemAudioOnly"
    case microphoneAndSystem = "microphoneAndSystem"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphoneOnly:
            return "Microphone Only (Candidate Only)"
        case .systemAudioOnly:
            return "System Audio Only (Interviewer Only)"
        case .microphoneAndSystem:
            return "Microphone + System Audio (Recommended)"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .microphoneOnly:
            return "Mic"
        case .systemAudioOnly:
            return "System"
        case .microphoneAndSystem:
            return "Mic + System"
        }
    }

    public var userFacingDescription: String {
        switch self {
        case .systemAudioOnly:
            return "Best for testing or when only interviewer audio is needed."
        case .microphoneAndSystem:
            return "Best with headphones. Separates interviewer and candidate."
        case .microphoneOnly:
            return "Practice / voice note mode."
        }
    }
}

public enum FloatingAssistantDisplayMode: String, CaseIterable, Identifiable, Codable {
    case compact
    case normal
    case diagnostic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .diagnostic: return "Diagnostic"
        }
    }
}

public enum ManualCaptureSource: String, CaseIterable, Identifiable, Codable {
    case systemAudio = "systemAudio"
    case microphone = "microphone"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemAudio: return "System Audio"
        case .microphone: return "Microphone"
        }
    }
}

public enum HirevaMode: String, CaseIterable, Identifiable, Codable {
    case autoDetect = "autoDetect"
    case manualCapture = "manualCapture"
    case practiceMock = "practiceMock"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoDetect: return "Auto Detect"
        case .manualCapture: return "Manual Capture"
        case .practiceMock: return "Practice / Mock"
        }
    }
}

public enum EmbeddingProviderKind: String, CaseIterable, Identifiable, Codable {
    case openAICompatibleCloud = "openAICompatibleCloud"
    case customCloud = "customCloud"
    case disabled = "disabled"
    case mock = "mock"
    case localOllama = "localOllama"

    public var id: String { rawValue }
    
    public static var allCases: [EmbeddingProviderKind] {
        [.openAICompatibleCloud, .customCloud, .disabled]
    }

    public var displayName: String {
        switch self {
        case .openAICompatibleCloud: return "Cloud API (OpenAI-compatible)"
        case .customCloud: return "Custom Cloud API"
        case .disabled: return "Disabled"
        case .mock: return "Mock Embedding Provider"
        case .localOllama: return "Legacy Local Embeddings (Disabled)"
        }
    }
}

public struct AppSettings: Hashable, Codable {
    public var realtimeModel: DeepSeekModel
    public var recapModel: DeepSeekModel
    public var automaticQuestionDetectionEnabled: Bool
    public var manualOnlyMode: Bool
    public var saveTranscriptsLocally: Bool
    public var allowQuestionDetectionFromMicrophoneOnly: Bool
    public var audioCaptureMode: AudioCaptureMode
    public var floatingWindowOpacity: Double
    public var compactMode: Bool
    public var floatingAssistantDisplayMode: FloatingAssistantDisplayMode
    public var highContrastFloatingPanel: Bool
    
    // Manual Capture options
    public var manualCaptureSource: ManualCaptureSource
    public var autoSendAfterTranscription: Bool
    public var maxManualCaptureSeconds: Int
    public var showTranscriptBeforeSending: Bool
    public var saveManualClips: Bool

    // Privacy options
    public var dontShowCloudWarningAgain: Bool
    
    // Timeout options
    public var generationRequestTimeoutSeconds: Int

    // RAG Phase 3 Embedding settings
    public var enableVectorRAG: Bool
    public var forceHybridRAG: Bool
    public var embeddingProviderKind: EmbeddingProviderKind
    public var embeddingBaseURL: String
    public var embeddingModelName: String
    public var embeddingApiKeyAccount: String
    public var embeddingDimension: Int
    public var hybridSemanticWeight: Double
    public var hybridKeywordWeight: Double
    public var autoGenerateEmbeddingsOnDocumentSave: Bool
    public var embeddingTimeoutSeconds: Int

    public static let `default` = AppSettings(
        realtimeModel: .realtime,
        recapModel: .analysis,
        automaticQuestionDetectionEnabled: true,
        manualOnlyMode: false,
        saveTranscriptsLocally: true,
        allowQuestionDetectionFromMicrophoneOnly: false,
        audioCaptureMode: .microphoneAndSystem,
        floatingWindowOpacity: 0.82,
        compactMode: false,
        floatingAssistantDisplayMode: .normal,
        highContrastFloatingPanel: false,
        manualCaptureSource: .systemAudio,
        autoSendAfterTranscription: true,
        maxManualCaptureSeconds: 60,
        showTranscriptBeforeSending: false,
        saveManualClips: false,
        dontShowCloudWarningAgain: false,
        generationRequestTimeoutSeconds: 180,
        enableVectorRAG: false,
        forceHybridRAG: false,
        embeddingProviderKind: .disabled,
        embeddingBaseURL: "https://api.openai.com/v1",
        embeddingModelName: "text-embedding-3-small",
        embeddingApiKeyAccount: "openai.embedding.default",
        embeddingDimension: 1536,
        hybridSemanticWeight: 0.7,
        hybridKeywordWeight: 0.3,
        autoGenerateEmbeddingsOnDocumentSave: true,
        embeddingTimeoutSeconds: 60
    )

    enum CodingKeys: String, CodingKey {
        case realtimeModel
        case recapModel
        case automaticQuestionDetectionEnabled
        case manualOnlyMode
        case saveTranscriptsLocally
        case allowQuestionDetectionFromMicrophoneOnly
        case audioCaptureMode
        case floatingWindowOpacity
        case compactMode
        case floatingAssistantDisplayMode
        case highContrastFloatingPanel
        case manualCaptureSource
        case autoSendAfterTranscription
        case maxManualCaptureSeconds
        case showTranscriptBeforeSending
        case saveManualClips
        case dontShowCloudWarningAgain
        case generationRequestTimeoutSeconds
        case ollamaRequestTimeoutSeconds
        
        // RAG keys
        case enableVectorRAG
        case forceHybridRAG
        case embeddingProviderKind
        case embeddingBaseURL
        case embeddingModelName
        case embeddingApiKeyAccount
        case embeddingDimension
        case hybridSemanticWeight
        case hybridKeywordWeight
        case autoGenerateEmbeddingsOnDocumentSave
        case embeddingTimeoutSeconds
    }

    public init(
        realtimeModel: DeepSeekModel,
        recapModel: DeepSeekModel,
        automaticQuestionDetectionEnabled: Bool,
        manualOnlyMode: Bool,
        saveTranscriptsLocally: Bool,
        allowQuestionDetectionFromMicrophoneOnly: Bool,
        audioCaptureMode: AudioCaptureMode,
        floatingWindowOpacity: Double,
        compactMode: Bool,
        floatingAssistantDisplayMode: FloatingAssistantDisplayMode,
        highContrastFloatingPanel: Bool,
        manualCaptureSource: ManualCaptureSource,
        autoSendAfterTranscription: Bool,
        maxManualCaptureSeconds: Int,
        showTranscriptBeforeSending: Bool,
        saveManualClips: Bool,
        dontShowCloudWarningAgain: Bool,
        generationRequestTimeoutSeconds: Int,
        enableVectorRAG: Bool,
        forceHybridRAG: Bool,
        embeddingProviderKind: EmbeddingProviderKind,
        embeddingBaseURL: String,
        embeddingModelName: String,
        embeddingApiKeyAccount: String,
        embeddingDimension: Int,
        hybridSemanticWeight: Double,
        hybridKeywordWeight: Double,
        autoGenerateEmbeddingsOnDocumentSave: Bool,
        embeddingTimeoutSeconds: Int
    ) {
        self.realtimeModel = realtimeModel
        self.recapModel = recapModel
        self.automaticQuestionDetectionEnabled = automaticQuestionDetectionEnabled
        self.manualOnlyMode = manualOnlyMode
        self.saveTranscriptsLocally = saveTranscriptsLocally
        self.allowQuestionDetectionFromMicrophoneOnly = allowQuestionDetectionFromMicrophoneOnly
        self.audioCaptureMode = audioCaptureMode
        self.floatingWindowOpacity = floatingWindowOpacity
        self.compactMode = compactMode
        self.floatingAssistantDisplayMode = floatingAssistantDisplayMode
        self.highContrastFloatingPanel = highContrastFloatingPanel
        self.manualCaptureSource = manualCaptureSource
        self.autoSendAfterTranscription = autoSendAfterTranscription
        self.maxManualCaptureSeconds = maxManualCaptureSeconds
        self.showTranscriptBeforeSending = showTranscriptBeforeSending
        self.saveManualClips = saveManualClips
        self.dontShowCloudWarningAgain = dontShowCloudWarningAgain
        self.generationRequestTimeoutSeconds = generationRequestTimeoutSeconds
        
        // RAG Phase 3
        self.enableVectorRAG = enableVectorRAG
        self.forceHybridRAG = forceHybridRAG
        self.embeddingProviderKind = embeddingProviderKind
        self.embeddingBaseURL = embeddingBaseURL
        self.embeddingModelName = embeddingModelName
        self.embeddingApiKeyAccount = embeddingApiKeyAccount
        self.embeddingDimension = embeddingDimension
        self.hybridSemanticWeight = hybridSemanticWeight
        self.hybridKeywordWeight = hybridKeywordWeight
        self.autoGenerateEmbeddingsOnDocumentSave = autoGenerateEmbeddingsOnDocumentSave
        self.embeddingTimeoutSeconds = embeddingTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.realtimeModel = try container.decodeIfPresent(DeepSeekModel.self, forKey: .realtimeModel) ?? .realtime
        self.recapModel = try container.decodeIfPresent(DeepSeekModel.self, forKey: .recapModel) ?? .analysis
        self.automaticQuestionDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticQuestionDetectionEnabled) ?? true
        self.manualOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .manualOnlyMode) ?? false
        self.saveTranscriptsLocally = try container.decodeIfPresent(Bool.self, forKey: .saveTranscriptsLocally) ?? true
        self.allowQuestionDetectionFromMicrophoneOnly = try container.decodeIfPresent(Bool.self, forKey: .allowQuestionDetectionFromMicrophoneOnly) ?? false
        self.audioCaptureMode = try container.decodeIfPresent(AudioCaptureMode.self, forKey: .audioCaptureMode) ?? .microphoneAndSystem
        self.floatingWindowOpacity = try container.decodeIfPresent(Double.self, forKey: .floatingWindowOpacity) ?? 0.82
        self.compactMode = try container.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false
        self.floatingAssistantDisplayMode = try container.decodeIfPresent(FloatingAssistantDisplayMode.self, forKey: .floatingAssistantDisplayMode)
            ?? (self.compactMode ? .compact : .normal)
        self.highContrastFloatingPanel = try container.decodeIfPresent(Bool.self, forKey: .highContrastFloatingPanel) ?? false
        
        self.manualCaptureSource = try container.decodeIfPresent(ManualCaptureSource.self, forKey: .manualCaptureSource) ?? .systemAudio
        self.autoSendAfterTranscription = try container.decodeIfPresent(Bool.self, forKey: .autoSendAfterTranscription) ?? true
        self.maxManualCaptureSeconds = try container.decodeIfPresent(Int.self, forKey: .maxManualCaptureSeconds) ?? 60
        self.showTranscriptBeforeSending = try container.decodeIfPresent(Bool.self, forKey: .showTranscriptBeforeSending) ?? false
        self.saveManualClips = try container.decodeIfPresent(Bool.self, forKey: .saveManualClips) ?? false
        self.dontShowCloudWarningAgain = try container.decodeIfPresent(Bool.self, forKey: .dontShowCloudWarningAgain) ?? false
        self.generationRequestTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .generationRequestTimeoutSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .ollamaRequestTimeoutSeconds)
            ?? 180
        
        // RAG Phase 3
        self.enableVectorRAG = try container.decodeIfPresent(Bool.self, forKey: .enableVectorRAG) ?? false
        self.forceHybridRAG = try container.decodeIfPresent(Bool.self, forKey: .forceHybridRAG) ?? false
        let decodedEmbeddingKind = try container.decodeIfPresent(EmbeddingProviderKind.self, forKey: .embeddingProviderKind) ?? .disabled
        self.embeddingProviderKind = decodedEmbeddingKind == .localOllama ? .disabled : decodedEmbeddingKind
        let decodedEmbeddingBaseURL = try container.decodeIfPresent(String.self, forKey: .embeddingBaseURL) ?? "https://api.openai.com/v1"
        self.embeddingBaseURL = decodedEmbeddingBaseURL.localizedCaseInsensitiveContains("localhost:11434")
            ? "https://api.openai.com/v1"
            : decodedEmbeddingBaseURL
        let decodedEmbeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModelName) ?? "text-embedding-3-small"
        self.embeddingModelName = decodedEmbeddingModel == "nomic-embed-text" ? "text-embedding-3-small" : decodedEmbeddingModel
        self.embeddingApiKeyAccount = try container.decodeIfPresent(String.self, forKey: .embeddingApiKeyAccount) ?? "openai.embedding.default"
        self.embeddingDimension = try container.decodeIfPresent(Int.self, forKey: .embeddingDimension) ?? 1536
        self.hybridSemanticWeight = try container.decodeIfPresent(Double.self, forKey: .hybridSemanticWeight) ?? 0.7
        self.hybridKeywordWeight = try container.decodeIfPresent(Double.self, forKey: .hybridKeywordWeight) ?? 0.3
        self.autoGenerateEmbeddingsOnDocumentSave = try container.decodeIfPresent(Bool.self, forKey: .autoGenerateEmbeddingsOnDocumentSave) ?? true
        self.embeddingTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .embeddingTimeoutSeconds) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(realtimeModel, forKey: .realtimeModel)
        try container.encode(recapModel, forKey: .recapModel)
        try container.encode(automaticQuestionDetectionEnabled, forKey: .automaticQuestionDetectionEnabled)
        try container.encode(manualOnlyMode, forKey: .manualOnlyMode)
        try container.encode(saveTranscriptsLocally, forKey: .saveTranscriptsLocally)
        try container.encode(allowQuestionDetectionFromMicrophoneOnly, forKey: .allowQuestionDetectionFromMicrophoneOnly)
        try container.encode(audioCaptureMode, forKey: .audioCaptureMode)
        try container.encode(floatingWindowOpacity, forKey: .floatingWindowOpacity)
        try container.encode(floatingAssistantDisplayMode == .compact, forKey: .compactMode)
        try container.encode(floatingAssistantDisplayMode, forKey: .floatingAssistantDisplayMode)
        try container.encode(highContrastFloatingPanel, forKey: .highContrastFloatingPanel)
        try container.encode(manualCaptureSource, forKey: .manualCaptureSource)
        try container.encode(autoSendAfterTranscription, forKey: .autoSendAfterTranscription)
        try container.encode(maxManualCaptureSeconds, forKey: .maxManualCaptureSeconds)
        try container.encode(showTranscriptBeforeSending, forKey: .showTranscriptBeforeSending)
        try container.encode(saveManualClips, forKey: .saveManualClips)
        try container.encode(dontShowCloudWarningAgain, forKey: .dontShowCloudWarningAgain)
        try container.encode(generationRequestTimeoutSeconds, forKey: .generationRequestTimeoutSeconds)
        try container.encode(enableVectorRAG, forKey: .enableVectorRAG)
        try container.encode(forceHybridRAG, forKey: .forceHybridRAG)
        try container.encode(embeddingProviderKind == .localOllama ? .disabled : embeddingProviderKind, forKey: .embeddingProviderKind)
        try container.encode(embeddingBaseURL, forKey: .embeddingBaseURL)
        try container.encode(embeddingModelName == "nomic-embed-text" ? "text-embedding-3-small" : embeddingModelName, forKey: .embeddingModelName)
        try container.encode(embeddingApiKeyAccount, forKey: .embeddingApiKeyAccount)
        try container.encode(embeddingDimension, forKey: .embeddingDimension)
        try container.encode(hybridSemanticWeight, forKey: .hybridSemanticWeight)
        try container.encode(hybridKeywordWeight, forKey: .hybridKeywordWeight)
        try container.encode(autoGenerateEmbeddingsOnDocumentSave, forKey: .autoGenerateEmbeddingsOnDocumentSave)
        try container.encode(embeddingTimeoutSeconds, forKey: .embeddingTimeoutSeconds)
    }
}
