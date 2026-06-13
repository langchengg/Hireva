# InterviewCopilotMac Code Map

This document maps the live interview pipeline and the boundaries that should
stay intact during future refactors.

## High-Level Architecture

InterviewCopilotMac is a native macOS interview copilot. The product flow is:

`audio -> transcript -> question detection -> prompt/context -> RAG -> DeepSeek -> suggestion -> alignment -> UI/DB`

The normal UI should present human states such as Ready, Listening, Generating
first answer, Expanding answer, Needs attention, and Stopped. Technical names
such as ASR task, Stage A, Stage B, RAG scores, and Keychain details belong in
Diagnostics.

## File Responsibility Map

- `AppState.swift`: MainActor source of truth for observable UI state and the
  remaining generation orchestration method.
- `AppState+Audio.swift`: start/stop/restart for continuous capture and audio
  diagnostics.
- `AppState+Transcript.swift`: ASR segment ingestion, attribution, persistence,
  detection gating, and speculative RAG precompute.
- `AppState+QuestionDetection.swift`: local multi-question segmentation,
  provider question detection, duplicate suppression, and generation trigger.
- `AppState+Generation.swift`: active-generation guards, fallbacks, alignment
  checks, streaming UI publication, task registration, and diagnostics.
- `AppState+RAG.swift`: RAG cache keys, realtime context trimming, compact
  document summaries, and embedding-provider resolution.
- `AppState+ManualCapture.swift`: push-to-ask recording/transcription workflow.
- `AppState+Providers.swift`: provider settings, API-key save/status, and
  provider connection tests.
- `AppState+Diagnostics.swift`: developer diagnostics, capture events, latency
  labels, and heartbeat.
- `GenerationCoordinator.swift`: skeleton dependency/pure-helper boundary for
  future generation extraction. It does not own UI or tasks yet.
- `PromptContextBuilder.swift`: immutable prompt snapshot construction.
- `GenerationRequestSnapshot.swift`: prompt/generation snapshot data models.
- `GenerationExecutionContext.swift`: typed frozen inputs for one generation.
- `GenerationProviderRequest.swift`: typed provider request plus redacted
  diagnostics.
- `GenerationProviderResult.swift`: typed provider output/status data.
- `QuestionIntentPromptPolicy.swift`: deterministic intent, context filtering,
  and fallback answer policy.
- `QuestionAnswerAlignment.swift`: safety guard that validates answer relevance
  before display/persistence.
- `AnswerRelevancePolicy.swift`: stable facade over prompt/intent/relevance
  helpers.
- `SuggestionGenerationService.swift`: provider calls and response parsing for
  suggestion cards.
- `KeychainService.swift`: stable Keychain service/account storage for provider
  keys.

## Live Pipeline

1. `AppState+Audio.startListening` selects a capture path from
   `settings.audioCaptureMode`.
2. `AppleSpeechTranscriptionService` emits `TranscriptSegment` values.
3. `AppState+Transcript.handleTranscriptSegment` persists transcript text,
   updates diagnostics, filters candidate speech, and defers partial ASR when
   needed.
4. `AppState+QuestionDetection` either splits system-audio transcripts locally
   or calls provider-backed detection.
5. Accepted `DetectedQuestion` values are saved, duplicate-checked, and handed
   to `generateSuggestion(...)`.
6. `generateSuggestion(...)` activates a new generation ID, starts watchdogs,
   retrieves context, freezes a prompt snapshot, and starts Stage A/Stage B work.
7. DeepSeek streaming or local fallback produces the first visible `say_first`.
8. Stage B expands key points/follow-up when available.
9. `displaySuggestionIfAligned(...)` verifies question binding and semantic
   relevance before the card can become current UI state.
10. The final card and retrieved chunks are persisted to the local database.

## Critical Invariants

- System Audio Only must not request microphone permission or start microphone
  capture.
- Microphone Only must not start system audio capture.
- Starting generation must not stop continuous capture.
- Candidate microphone speech must not auto-trigger answers unless the explicit
  setting allows it.
- Partial ASR may update live UI, but final ASR should win for answer
  generation.
- Truncated fragments such as "why do you want" should not become final
  questions if a longer final segment arrives.
- Current question must be one clean question, not a merged transcript.
- Duplicate suppression must not leave the UI in a loading state.
- `question_text` should equal `prompt_primary_question` for generated cards.
- Previous transcript and RAG context are background only; they must not replace
  the primary question.
- Old Stage B/provider callbacks must not update the current UI after a newer
  generation becomes active.
- Visible `say_first` must be independently relevant and complete.
- Clear technical/model-comparison questions should not accept
  `alignment_verdict = unknown`.
- Fallback answers must directly answer the current question, not describe what
  to say.
- Raw API keys must never be logged or shown.
- Keychain service/account names are persisted identifiers and should only
  change with an explicit migration.
- Ad-hoc signing can trigger repeated Keychain/macOS permission prompts because
  the app CDHash changes after rebuilds.

## Where To Modify Safely

- Capture-mode routing: `AppState+Audio.swift` and
  `AppleSpeechTranscriptionService`.
- Transcript filtering and ASR partial/final handling:
  `AppState+Transcript.swift`.
- Question segmentation and duplicate suppression:
  `AppState+QuestionDetection.swift`.
- Prompt wording and context placement: `PromptContextBuilder.swift`.
- Intent-specific context and fallback answers:
  `QuestionIntentPromptPolicy.swift`.
- Answer relevance safety: `QuestionAnswerAlignment.swift`.
- Provider request/response plumbing: `SuggestionGenerationService.swift`,
  `GenerationProviderRequest.swift`, and future `GenerationCoordinator` phases.
- API-key storage/status: `KeychainService.swift` and `AppState+Providers.swift`.
- Developer-only runtime details: `AppState+Diagnostics.swift` and diagnostics
  views.

## What Not To Touch Casually

- Do not move generation task ownership out of AppState unless the phase
  explicitly says so and tests cover consecutive-question races.
- Do not change prompt-primary-question behavior without alignment and runtime
  DB verification.
- Do not let RAG context decide the answer target.
- Do not mix manual capture with continuous capture lifecycle.
- Do not add raw key logs for debugging.
- Do not change DB schema in documentation/comment-only work.
- Do not use Accessibility automation for GUI verification.
