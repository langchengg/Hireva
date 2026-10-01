# Hireva Code Map

This document maps the live interview pipeline and the boundaries that should
stay intact during future refactors.

## High-Level Architecture

Hireva is a native macOS interview copilot. The product flow is:

`audio -> selected ASR -> transcript -> question detection -> frozen context/RAG -> selected answer provider -> alignment -> UI/DB`

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
2. `AppleSpeechTranscriptionService` or the bundled Local Parakeet helper emits
   source-tagged `TranscriptSegment` values. Parakeet is final-only.
3. `AppState+Transcript.handleTranscriptSegment` persists transcript text,
   updates diagnostics, filters candidate speech, and defers partial ASR when
   needed.
4. `AppState+QuestionDetection` either splits system-audio transcripts locally
   or calls provider-backed detection.
5. Accepted `DetectedQuestion` values are saved, duplicate-checked, and handed
   to `generateSuggestion(...)`.
6. `generateSuggestion(...)` activates a new generation ID, starts watchdogs,
   retrieves context, freezes a prompt snapshot, and starts Stage A/Stage B work.
7. Local Qwen through Ollama, optional DeepSeek, or an explicit aligned fallback
   produces the first visible `say_first`.
8. Stage B expands key points/follow-up when available.
9. `displaySuggestionIfAligned(...)` verifies question binding and semantic
   relevance before the card can become current UI state.
10. The final card and retrieved chunks are persisted to the local database.

## Critical Invariants

- System Audio Only must not request microphone permission or start microphone
  capture.
- Microphone Only must not start system audio capture.
- Apple Speech requires Speech Recognition for every capture mode; Local
  Parakeet never requests Speech Recognition.
- Microphone and system-audio Parakeet samples and metadata must stay isolated.
- Starting generation must not stop continuous capture.
- Microphone-source speech must not auto-trigger answers unless the explicit
  setting allows it. Capture source does not prove candidate/interviewer identity;
  channel-only ASR events remain unknown.
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
- For model-comparison questions, visible `say_first` must directly compare
  diffusion and autoregressive behavior rather than saying what the candidate
  would explain.
- Clear technical/model-comparison questions should not accept
  `alignment_verdict = unknown`.
- Fallback answers must directly answer the current question, not describe what
  to say.
- RAG fallback is acceptable when provider output is missing, late, or invalid,
  but it still has to pass answer-quality and alignment checks.
- Raw API keys must never be logged or shown.
- Runtime trace defaults to off. Metadata-only traces must not contain
  transcript, question, answer, or reversible duplicate-key text.
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
  `OllamaQwenProvider.swift`, `GenerationProviderRequest.swift`, and future
  `GenerationCoordinator` phases.
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
- GUI acceptance uses the canonical `.app` with visible native UI and isolated synthetic data; CLI injection alone does not establish UI usability.

## Current Known Limitations

- The app is currently ad-hoc signed unless an Apple Development identity is
  configured. Because the CDHash changes after each rebuild, macOS may ask for
  Keychain or Screen/System Audio permission again.
- Stage B full-card expansion can time out. This is acceptable when the visible
  first answer or RAG template fallback is complete, aligned, and directly
  answers the current question. Do not optimize Stage B timeout in
  documentation-only work.
- `generateSuggestion(...)` still remains in `AppState.swift`. Moving lifecycle
  ownership into `GenerationCoordinator` should be Phase 2D/2E work and must be
  done one responsibility at a time with consecutive-question regression tests.

## Preparation and Practice Boundaries

- `InterviewTaskDescriptor` / `InterviewQuestionRouter`: frozen task, four-way
  personal-evidence requirement, answer basis, conversation relation and input
  revisions. Local structured classification is separate from domain and manual
  task selection. `AppState+QuestionDetection` freezes a parent before queueing;
  regeneration preserves it. Partial ASR does not invoke the router.
- `PromptContextBuilder` applies the frozen evidence policy. Every publication
  path still validates personal claims, including no-snapshot and general tasks.
  Displayed/persisted citations come from the filtered prompt snapshot. A missing
  personal-fact notice is a needs-input state, not a successful answer latency.
- `OllamaQwenProvider`: ordinary chat streaming remains `/api/chat`; non-thinking
  JSON-schema requests use `/api/generate` and the server-owned model template.
  This avoids the verified Ollama 0.24.0 Qwen 3.5 chat grammar activation defect.
  Both paths share cancellation, response accumulation and metadata diagnostics.
- `MaterialExtractionService`: bounded PDFKit/Vision/ZIPFoundation/XMLParser
  extraction; native OCR cancellation is linked to task cancellation. Document
  originals, hashes and locations live in `document_sources` through
  `DocumentRepository`; import/reprocess ownership stays in `AppState+Documents`.
- `PracticeController` / `PracticeSession` / `PracticeRepository`: finite practice
  lifecycle, local-only evaluation, exact-quote/rubric validation, microphone/TTS
  exclusion, frozen attempts/material metadata, explicit FSRS ratings. The
  controller cancels underlying streams and owns a 90-second evaluation deadline.
- `PracticeView`: formal answer-before-feedback navigation; the older transcript
  injection routines are diagnostic helpers, not a simulated interview.
- `StoryCardsView`: editable, separately saved drafts derived from usable evidence;
  generated drafts never become `ProfileEvidence` automatically.
- `DocumentsView` / `ProfileEvidence`: reviewable boundary drafts include team
  ownership, contribution, completion, environment, baseline/system and metric
  conditions. Saving a draft does not confirm it; unrelated rebuilds preserve
  edits, while generation only reads usable evidence.
- `SessionHistoryEditor` / `HistoryCorrectionRepository`: original ASR plus
  corrected text, speaker and question boundaries; explicit versioned re-evaluation
  of practice attempts; old feedback remains labelled with its input version.
  Assisted history and explicit FSRS ratings survive corrections. Recap caches
  bind source, rubric, provider and revision so only changed units recompute.
- `RecapGenerationService`: bounded question-boundary units, exact source/quote
  validation, deterministic unknown-speaker coverage, and all-attempt practice
  recap. `AppState+Sessions` owns a distinct cancellable recap task; deleting an
  unrelated session cannot cancel live generation.
- `PreparationView` / `PreparationRepository`: user-triggered public URL and SQL
  results with history-setting checks and explicit cache deletion.
- `PublicRoleBriefService`: checked public IPv4 pinned to a bounded system-curl
  request, no redirects/cookies/proxy inheritance; SwiftSoup parses actual HTML.
- `PracticeSQLService`: separate in-memory SQLite connection with authorizer,
  single-statement/read-only checks, function allowlist and resource/cancel limits.
- `HomeView` opens the existing `LiveInterviewView.manualCaptureWorkspace` in a
  bounded sheet; source selection is disabled during capture, Close cancels.
- `AppState+ManualCapture`: the same frozen router, prompt citations and claim
  publication checks as continuous mode; selected local Qwen stays local. Temporary
  sessions never backfill on later opt-in; new saved operations create their own
  durable session. Retry/clear cancel capture and generation ownership together.
- `ManualQuestionTranscriptionService`: request revisions bind Speech callbacks,
  finalize continuations and timeout; cancellation resumes the old waiter. The
  ScreenCaptureKit start fence stops a late-started stream after cancellation.
- `PersistenceConsent`: generation controllers and synchronous history snapshots
  carry their original ticket into writes. Revocable tickets prevent queued history writes after
  privacy changes/deletion. Source deletion redacts copied evidence and previews;
  it does not claim physical-media secure erasure.
- Additive migrations v17–v20 cover material sources, practice/review state,
  preparation records and frozen question tasks. Older Codable payloads use
  optional defaults; synthetic v16 upgrades are regression tested.
- Migration v21 adds history corrections, session/recap input versions and recap
  unit cache. The populated synthetic v20 migration test covers rollback, reopen,
  attachment/review preservation and deletion; it does not rebuild an empty DB.

`GenerationCoordinator` remains a helper boundary; this work does not move live
ownership into a new agent framework. See `workflow-acceptance.md` for current
verification limits, including cancellation/resource-contention measurements.
