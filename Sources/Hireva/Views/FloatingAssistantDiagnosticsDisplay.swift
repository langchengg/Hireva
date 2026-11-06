import Foundation

/// Formatting inputs for the Floating diagnostic rows. Every member is an
/// immutable display string assembled from existing owners; it performs no
/// routing, publication or resource decisions and is never a mutable store.
struct FloatingAssistantDiagnosticsDisplay {
    let providerConfigured: String
    let deepSeekConfigured: String
    let credentialSource: String
    let keyExists: String
    let keyLengthCategory: String
    let keychainService: String
    let keychainAccount: String
    let generationConfigSource: String
    let settingsConfigSource: String
    let lastProviderConfigError: String
    let generationStateTitle: String
    let activeGenerationID: String
    let activeQuestionID: String
    let activeTriggerPath: String
    let activeElapsedMs: String
    let activeTaskSummary: String
    let previousGenerationID: String
    let regenerate_questionId: String
    let regenerate_sourceTextKind: String
    let regenerate_oldGenerationId: String
    let regenerate_newGenerationId: String
    let regenerate_rejectionReason: String
    let currentSpinnerVisible: String
    let fallbackWatchdogActive: String
    let stageBTaskActive: String
    let lastProviderError: String
    let lastJSONParseError: String
    let lastDBError: String
    let cancelledGenerationCount: String
    let staleCallbackDiscardCount: String
    let duplicateSuppressionCount: String
    let heartbeatDelayMs: String
    let lastSQLiteOperation: String
    let lastRAGOperation: String
    let lastProviderOperation: String
    let ragRetrievalLatencyMS: String
    let deepseekFirstVisibleMS: String
    let softFallbackUsed: String
    let retrievalMode: String
    let latexPollutedChunkCount: String
    let captureMode: String
    let currentCaptureRuntimeState: String
    let stopReason: String
    let recognitionRequestActive: String
    let recognitionTaskActive: String
    let systemASRTaskActive: String
    let micASRTaskActive: String
}
