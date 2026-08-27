import Foundation
import os

private enum AppLogger {
    static let subsystem = HirevaProductIdentity.bundleIdentifier
    static let app = Logger(subsystem: subsystem, category: "app")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let audio = Logger(subsystem: subsystem, category: "audio")
}

/// Narrow logging boundary for components that process transcript or audio
/// payloads. Callers can supply only reviewed enums, counts, booleans, and
/// error codes; no API here accepts transcript text, file paths, provider
/// responses, or arbitrary log messages.
enum PrivacySafeLogger {
    enum TranscriptStage: String {
        case partial
        case final
    }

    enum FinalizationDecision: String {
        case emptyFinalUsedPartial = "empty_final_used_partial"
        case shorterFinalUsedPartial = "shorter_final_used_partial"
        case acceptedFinal = "accepted_final"
    }

    enum AudioFailureOperation: String {
        case audioTapInstall = "audio_tap_install"
        case audioTapRecovery = "audio_tap_recovery"
        case appleSpeechRecognition = "apple_speech_recognition"
        case appleSpeechMicrophoneRecovery = "apple_speech_microphone_recovery"
        case appleSpeechMicrophoneInput = "apple_speech_microphone_input"
        case appleSpeechSystemAudioCapture = "apple_speech_system_audio_capture"
        case manualAppleSpeech = "manual_apple_speech"
        case parakeetAudioWrite = "parakeet_audio_write"
        case parakeetHelperHealth = "parakeet_helper_health"
        case parakeetHelperLaunch = "parakeet_helper_launch"
        case parakeetMicrophoneCapture = "parakeet_microphone_capture"
        case parakeetSystemAudioCapture = "parakeet_system_audio_capture"
        case screenCaptureCompactStream = "screen_capture_compact_stream"
        case screenCaptureFallbackStream = "screen_capture_fallback_stream"
        case screenCaptureNoSamples = "screen_capture_no_samples"
        case screenCaptureConversion = "screen_capture_conversion"
        case manualQuestionCapture = "manual_question_capture"
    }

    enum DataFailureOperation: String {
        case backgroundEmbedding = "background_embedding"
        case chunkEmbedding = "chunk_embedding"
        case latencyAverages = "latency_averages"
        case filteredLatencyAverages = "filtered_latency_averages"
        case ragPrecompute = "rag_precompute"
        case mockDataSeed = "mock_data_seed"
    }

    enum GenerationFailureOperation: String {
        case answerRewrite = "answer_rewrite"
        case localFallback = "local_fallback"
        case stageAFastAnswer = "stage_a_fast_answer"
        case stageBFullCard = "stage_b_full_card"
    }

    enum PermissionEvent: String {
        case microphoneRequestNotEligible = "microphone_request_not_eligible"
        case screenRequestSuppressedForAutomation = "screen_request_suppressed_for_automation"
    }

    enum VerificationFailureCode: String {
        case eventLogUnavailable = "event_log_unavailable"
    }

    enum TraceFailureOperation: String {
        case write
        case cleanup
    }

    static func appleSpeechSessionStarted(source: AudioSourceType, simulated: Bool) {
        AppLogger.audio.info(
            "Apple Speech session started source=\(source.rawValue, privacy: .public) simulated=\(simulated, privacy: .public)"
        )
    }

    static func appleSpeechTranscriptMetrics(
        stage: TranscriptStage,
        source: AudioSourceType,
        characters: Int,
        words: Int
    ) {
        AppLogger.audio.info(
            "Apple Speech transcript stage=\(stage.rawValue, privacy: .public) source=\(source.rawValue, privacy: .public) characters=\(characters, privacy: .public) words=\(words, privacy: .public)"
        )
    }

    static func appleSpeechFinalization(
        decision: FinalizationDecision,
        characters: Int,
        words: Int,
        firstPartialMS: Int,
        finalMS: Int,
        bestSelectedMS: Int
    ) {
        AppLogger.audio.info(
            "Apple Speech finalization decision=\(decision.rawValue, privacy: .public) characters=\(characters, privacy: .public) words=\(words, privacy: .public) first_partial_ms=\(firstPartialMS, privacy: .public) final_ms=\(finalMS, privacy: .public) best_selected_ms=\(bestSelectedMS, privacy: .public)"
        )
    }

    static func appleSpeechBufferCount(source: AudioSourceType, count: Int) {
        AppLogger.audio.debug(
            "Apple Speech buffers source=\(source.rawValue, privacy: .public) count=\(count, privacy: .public)"
        )
    }

    static func appleSpeechCaptureStarted(mode: AudioCaptureMode) {
        AppLogger.audio.info(
            "Apple Speech capture starting mode=\(mode.rawValue, privacy: .public)"
        )
    }

    static func appleSpeechMicrophoneCaptureStarted() {
        AppLogger.audio.debug("Apple Speech microphone capture starting")
    }

    static func appleSpeechSystemAudioCaptureStarted() {
        AppLogger.audio.debug("Apple Speech system-audio capture starting")
    }

    static func appleSpeechConcurrentSessionGuard(microphoneActive: Bool, systemActive: Bool) {
        AppLogger.audio.error(
            "Apple Speech concurrent-session guard failed microphone_active=\(microphoneActive, privacy: .public) system_active=\(systemActive, privacy: .public)"
        )
    }

    static func appleSpeechMicrophoneRouteChanged() {
        AppLogger.audio.info("Apple Speech microphone route changed; restarting recognition")
    }

    static func audioFailure(operation: AudioFailureOperation, code: Int) {
        AppLogger.audio.error(
            "Audio operation failed operation=\(operation.rawValue, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    static func manualAppleSpeechFinal(characters: Int) {
        AppLogger.audio.info(
            "Manual Apple Speech final characters=\(characters, privacy: .public)"
        )
    }

    static func manualAppleSpeechAudioEnded(timeoutSeconds: Double) {
        AppLogger.audio.debug(
            "Manual Apple Speech audio ended finalization_timeout_seconds=\(timeoutSeconds, privacy: .public)"
        )
    }

    static func manualAppleSpeechTimedOut(partialCharacters: Int) {
        AppLogger.audio.notice(
            "Manual Apple Speech finalization timed out partial_characters=\(partialCharacters, privacy: .public)"
        )
    }

    static func parakeetHelperDiagnostic(byteCount: Int) {
        AppLogger.audio.notice(
            "Parakeet helper diagnostic received bytes=\(byteCount, privacy: .public)"
        )
    }

    static func traceFailure(operation: TraceFailureOperation, code: Int) {
        AppLogger.database.error(
            "Runtime transcript trace failed operation=\(operation.rawValue, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    static func dataFailure(operation: DataFailureOperation, code: Int) {
        AppLogger.database.error(
            "Data operation failed operation=\(operation.rawValue, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    static func generationFailure(operation: GenerationFailureOperation, code: Int) {
        AppLogger.network.error(
            "Generation operation failed operation=\(operation.rawValue, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    static func providerTokenUsage(promptTokens: Int, cachedPromptTokens: Int) {
        AppLogger.network.info(
            "Provider stream usage prompt_tokens=\(promptTokens, privacy: .public) cached_prompt_tokens=\(cachedPromptTokens, privacy: .public)"
        )
    }

    static func screenSystemAudioPermissionProbe(
        preflightGranted: Bool,
        shareableContentSucceeded: Bool,
        streamAudioSucceeded: Bool,
        identityMismatch: Bool
    ) {
        AppLogger.audio.info(
            "Screen/system-audio permission probe preflight=\(preflightGranted, privacy: .public) shareable=\(shareableContentSucceeded, privacy: .public) stream=\(streamAudioSucceeded, privacy: .public) identity_mismatch=\(identityMismatch, privacy: .public)"
        )
    }

    static func mainThreadStall(delayMS: Int) {
        AppLogger.app.error(
            "Main thread stall delay_ms=\(delayMS, privacy: .public)"
        )
    }

    static func permissionEvent(_ event: PermissionEvent) {
        AppLogger.app.notice(
            "Permission event code=\(event.rawValue, privacy: .public)"
        )
    }

    static func microphonePermissionRequestCompleted(granted: Bool) {
        AppLogger.app.info(
            "Microphone permission request completed granted=\(granted, privacy: .public)"
        )
    }

    static func verificationFailure(code: VerificationFailureCode) {
        AppLogger.app.error(
            "Verification bootstrap failed code=\(code.rawValue, privacy: .public)"
        )
    }
}
