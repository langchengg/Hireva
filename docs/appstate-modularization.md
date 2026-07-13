# AppState Modularization Architecture

This document records the current extension-level modularization of `AppState`.
The refactor is behavior-preserving: prompt construction, Keychain behavior, DB
schema, and System Audio capture rules are intentionally unchanged.

## Extracted File List

- `Sources/Hireva/AppState.swift`
  - Root `@MainActor` observable object.
  - Published state storage, dependency construction, initialization, app active
    observer setup, test mock injection, and the main `generateSuggestion()`
    pipeline.
- `Sources/Hireva/AppState+Actions.swift`
  - Action feedback, loading states, and user-facing action notifications.
- `Sources/Hireva/AppState+Audio.swift`
  - Live listening start/stop, live session reset/clear, audio route restart,
    audio signal monitoring, and continuous pipeline stopping.
- `Sources/Hireva/AppState+Diagnostics.swift`
  - Main-thread heartbeat, active task diagnostics, capture event logging, and
    SQLite operation summaries.
- `Sources/Hireva/AppState+Documents.swift`
  - CV/JD/notes saving and document-related refresh hooks.
- `Sources/Hireva/AppState+Generation.swift`
  - Generation lifecycle helpers, active generation guards, fallback cards,
    watchdog registration, streaming section publishing, alignment display
    guards, stale callback accounting, and suggestion persistence helpers.
- `Sources/Hireva/AppState+ManualCapture.swift`
  - Manual push-to-ask recording, transcription, cleanup, retry, and manual
    suggestion generation.
- `Sources/Hireva/AppState+Permissions.swift`
  - macOS permission status refresh, permission probes, and permission actions.
- `Sources/Hireva/AppState+Providers.swift`
  - Provider configuration, provider testing, API key save/delete flow, and
    provider selection.
- `Sources/Hireva/AppState+QuestionDetection.swift`
  - System-audio question extraction, utterance classification, duplicate
    suppression, automatic detection, and automatic suggestion trigger routing.
- `Sources/Hireva/AppState+RAG.swift`
  - RAG cache keys, realtime context trimming, compact document summaries,
    embedding provider resolution, embedding rebuild/cancel, clean RAG rebuild,
    and latency refresh.
- `Sources/Hireva/AppState+Sessions.swift`
  - Session loading, session details, export/delete, floating panel visibility,
    and user-facing error helpers.
- `Sources/Hireva/AppState+Transcript.swift`
  - Transcript ingestion, transcript persistence, source attribution, and RAG
    precompute scheduling.

## Remaining AppState Responsibilities

`AppState.swift` remains the storage and orchestration root. Swift extensions
cannot hold stored properties, so published state, task references, repositories,
services, and injected dependencies stay in the root type.

The main method intentionally left in root is:

- `generateSuggestion(...)`
  - Current size: roughly 900 lines.
  - Reason: it coordinates question binding, capture state, prompt snapshot,
    RAG cache use, provider streaming, Stage A/Stage B tasks, watchdogs,
    fallback behavior, alignment, UI state, and persistence. Moving it safely
    should be a Phase 2 coordinator extraction rather than a file move.

Other root responsibilities:

- `refreshAll()`
- `submitMockQuestion(_:)`
- `injectVerificationMockData()`
- Stored properties and nested stored-state value types.
- Initialization, notification observer registration, and dependency wiring.

## Private To Internal Promotions

The following members were promoted only so `AppState` extension files can access
the same behavior after extraction. Each promotion is marked in source with:
`// internal for AppState extension access only`.

- Generation state setters: `activeGenerationID`, `activeQuestionID`,
  `activeTriggerPath`, `activeGenerationStartedAt`, `previousGenerationID`,
  `cancelledGenerationCount`, `staleCallbackDiscardCount`,
  `staleAnswerDiscardCount`, `answerQuestionMismatchCount`,
  `lastAlignmentError`, `recentSuggestionAlignments`,
  `currentAnswerQuestionIntent`, prompt binding fields, RAG binding fields,
  answer-intent fields, `fallbackWatchdogActive`, `stageBTaskActive`,
  `providerStreamActive`.
- Generation storage and types: `ActiveGenerationController`,
  `activeGenerationController`, `stageBTask`, `softFallbackTask`,
  `fullCardWatchdogTask`, `suggestionGenerationService`.
- Audio storage: `appleSpeechService`, `activeTranscriptionProvider`,
  `ownsSystemAudioCaptureRuntime`, `lastAutoQuestionText`,
  `recentQuestionsFingerprints`, `audioSignalMonitoringTimer`.
- RAG storage: `activeEmbeddingRebuildTask`.
- Detection storage already shared by the question detection extension:
  `pendingIgnoredSystemAudioFallback`, `detectionDebounceTask`,
  `activeDetectionTask`, `lastDetectionAt`, `lastAutoSuggestionAt`,
  `recentQuestionTimestamps`, `autoSuggestionCooldownSeconds`,
  `possibleQuestionConfidenceRange`.
- Cross-extension helpers including generation guards, watchdog registration,
  fallback display, RAG cache keying, realtime context trimming, compact
  summaries, duplicate suppression, and embedding provider ID resolution.

## Remaining Large Methods

- `generateSuggestion(...)` in `AppState.swift`, about 900 lines.
- `sendManualCaptureToAI(forceDeepSeek:)` in `AppState+ManualCapture.swift`,
  about 360 lines.
- `startListeningAsync(mode:)` in `AppState+Audio.swift`, about 290 lines.
- `displaySuggestionIfAligned(...)` in `AppState+Generation.swift`, about
  130 lines.

These methods are large because they currently coordinate multiple side effects.
They were not rewritten in this pass to avoid changing runtime behavior.

## Phase 2 Recommendation

Create coordinator types after runtime acceptance is stable:

1. `GenerationCoordinator`
   - Own active generation controller, task cancellation, watchdog registration,
     stale callback accounting, and generation UI state transitions.
2. `SuggestionDisplayCoordinator`
   - Own `displaySuggestionIfAligned`, semantic fallback, answer relevance
     checks, and suggestion-card binding diagnostics.
3. `PromptContextCoordinator`
   - Own prompt snapshot assembly, current/previous question binding, RAG chunk
     binding, and context bleed risk calculation.
4. `ManualCaptureCoordinator`
   - Own manual capture provider request and persistence flow after the manual
     UI state machine has separate tests.
5. `AudioCaptureCoordinator`
   - Own live capture start/stop orchestration and device/session lifetime once
     real System Audio smoke tests are passing reliably.

Phase 2 should be test-driven and should not start until full tests and manual
runtime smoke tests pass against the rebuilt `dist/Hireva.app`.
