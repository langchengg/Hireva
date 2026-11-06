# AppState Modularization Architecture

This document records the current ownership boundaries and remaining AppState
compatibility surface. Ownership moves preserve the product identity, database
schema and capture-mode policy. Defect fixes and Practice repair instructions are
separate changes; test results belong in workflow-acceptance.md.

## Extracted File List

- `Sources/Hireva/AppState.swift`
  - Root `@MainActor` observable object.
  - Remaining live/document/settings state, dependency construction, initialization,
    app active observer setup and the main `generateSuggestion()` pipeline.
    History, Diagnostics and generation fields are compatibility projections.
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

## State, task and resource owners

| Owner | Authoritative state / work | Remaining application boundary |
| --- | --- | --- |
| `HistoryState` | Session list, selection, loaded transcript/cards/recap/chunks | Delete, correction and recap action policy in AppState |
| `DiagnosticsState` | Aggregate, sampled ring, trace export/storage | AppState supplies immutable display context and live counters |
| `PracticeController` | Practice run, revision-bound evaluation, consent ticket and audio cleanup | Focused dependencies assembled by `AppComposition` |
| `GenerationCoordinator` | Root request identity/task, generation identity, frozen provider config, five child roles and terminal fence | Request pipeline, UI/DB validation, retries/fallback decisions remain in AppState |
| ASR providers | Per-round startup, bridge, continuation and retained teardown | Live/Manual/Practice coordination remains application policy |
| `ParakeetSidecarRuntimeClient` | Exact helper process, pipes, PCM admission and retained exit/drain cleanup | Health/model probe cancellation remains to be reviewed |

History and generation compatibility properties forward to their owner and have
no parallel stored copy. History views observe `HistoryState`; diagnostic views
observe `DiagnosticsState`. AppState still relays History/coordinator observations
for unmigrated consumers. Remove a compatibility property after its last real
consumer observes or calls the appropriate feature directly.

PracticeController does not retain AppState. Its dependency bundle contains only
used repositories, frozen context/evaluation configuration and audio/policy
closures. AppComposition contains weak application callbacks; it is a focused
Practice assembly entry, not the completed application composition root.

`generateSuggestion(...)`, `refreshAll()`, dependency construction, notification
subscriptions, document/settings state and live output orchestration remain in
AppState. Detached retrieval and summary tasks are not an awaitable resource
retirement mechanism. Guards reject stale results, but guard coverage does not
prove resource exit.

## Compatibility and publication boundaries

The generation task properties exposed by AppState are read-only coordinator
projections. Provider/embedding connection checks use a separate task; they are
not registered as answer generation. A new request invalidates previous request
and generation identities before cancelling their tasks. The answer-mode setter
retains its explicit cancel/consent policy; provider configuration and local model
edits leave an already-frozen active request unchanged.

UI publication and DB persistence keep their own identity/evidence checks. A
usable first answer survives an expansion timeout. Provisional expansion is not
persisted as a terminal card; final/history writes retain their original consent
ticket and business-key deduplication.

A full streaming snapshot does not commit the successful terminal state. The
Stage B application first finishes its awaited validation and persistence
admission, then commits terminal state; otherwise a queued next question can
replace its identity before the first card is admitted. Watchdog callbacks check
their frozen identity and terminal/cancellation fence before any side effect.

## Remaining Large Methods

- `generateSuggestion(...)` in `AppState.swift`, about 900 lines.
- `sendManualCaptureToAI(forceDeepSeek:)` in `AppState+ManualCapture.swift`,
  about 360 lines.
- `startListeningAsync(mode:)` in `AppState+Audio.swift`, about 290 lines.
- `displaySuggestionIfAligned(...)` in `AppState+Generation.swift`, about
  130 lines.

These methods are large because they currently coordinate multiple side effects.
They were not rewritten in this pass to avoid changing runtime behavior.

## Remaining migration work

Continue one protected ownership boundary at a time. Documents, Settings and Live
still have stored state in AppState; feature-owned dependency construction and
startup subscriptions are incomplete. Generation output application and
retry/fallback sequencing still use AppState, and low-level capture stop/callback
ownership is not consolidated. No new parallel coordinator or generic container
is required to finish these moves.

Before moving another boundary, read its real callers and preserve request,
context/revision, consent and late-callback tests. Run the ordinary suite and
canonical isolated bundle validation; real audio, model quality and comparable
performance remain separate acceptance evidence. Historical stage notes do not
prevent a tested ownership migration.
