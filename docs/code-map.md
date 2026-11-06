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

- `AppState.swift`: MainActor application policy, pipeline orchestration and UI/DB
  admission. Compatibility properties forward to the authoritative feature owners.
- `App/AppComposition.swift`: database/repository, provider and focused feature
  assembly; constructor-local groups are not retained as feature containers.
- `Features/LiveInterview/LiveInterviewFeature.swift`: shared Live presentation,
  dialogue phase/role/turn rules, generation busy/time state and capture startup
  identity observed by real views. It also owns accepted-question FIFO, transcript
  ingress timing and echo history; floating views read that owner directly.
  Queue notifications follow synchronous admission coordination, so a subscriber's
  stop or replacement cannot be undone by an old producer's remaining work.
  AppState dialogue and queue properties only forward to this owner.
- `Features/Documents/DocumentsState.swift`: imports, cancellation, deletion,
  reprocessing and owned shutdown; embedding/context have their existing owners.
- `Features/Settings/SettingsState.swift`: applied settings and captured provider
  status; the settings view observes this owner through its focused assembly.
- `Features/Preparation/PreparationState.swift`: frozen fetch/SQL requests,
  persistence tickets and current/retiring task cleanup.
- `Features/History/HistoryState.swift`: history snapshots and owned recap
  current/retiring tasks; AppState retains application admission policy.
- `Features/Diagnostics/DiagnosticsFeatureState.swift`: diagnostic aggregate,
  latest retrieval provenance, sampled event ring and privacy-controlled trace persistence. Diagnostic views
  observe this owner directly; high-frequency buffer aggregation is not Published.
  Explicit trace setters retain same-value audit events without storing another trace.
- `Features/Practice/PracticeDependencies.swift`: narrow repository, context,
  evaluator configuration and audio capabilities.
- `Features/Practice/PracticeController.swift`: owns its run,
  work identity and awaitable audio cleanup without depending on AppState;
  primary and critic share the frozen question, answer, rubric, source evidence
  and attachment. The critic receives the application-owned output contract,
  not the primary draft/reference/prose, and regenerates editable feedback.
  Only the source-limited reference notice is fixed; follow-up targets the first
  unmet criterion in the final map.
- `AppState+Audio.swift`: start/stop/restart for continuous capture and audio
  diagnostics. The existing startup task freezes local provider/model and performs
  bounded load-only preparation after permission admission; cancellation and stale
  startup identity are rechecked before session/ASR startup.
- `SessionRepository.endSession`: atomically retains the first stored end time;
  deleted sessions stay deleted. Application shutdown freezes the original session
  and end time before joining resources, then retries that same metadata write if
  needed. Content-saving consent remains a separate boundary.
- `AppState+Transcript.swift`: ASR segment ingestion, attribution, persistence,
  detection gating, and speculative RAG precompute.
- `AppState+QuestionDetection.swift`: local multi-question segmentation,
  provider question detection, duplicate suppression, and generation trigger.
- `AppState+Generation.swift`: active-generation guards, fallbacks, alignment
  checks, streaming UI publication, coordinator task-registration adapters, and diagnostics. Activation
  rechecks identity after stream/card/chunk publication before resetting later
  fields; a synchronous subscriber can already have admitted another generation.
  Failed terminal commits restore capture presentation before draining the FIFO.
  Error publication rechecks the frozen request/session/context across synchronous
  notifications. Answer Fallback, Regenerate and Manual Retry use the existing
  frozen entrypoints; the unreachable legacy retry/fallback pair and its copied
  failure fields have been removed.
- `AppState+RAG.swift`: RAG cache keys, realtime context trimming, compact
  document summaries, and embedding-provider resolution.
- `Features/LiveInterview/ManualCaptureController.swift`: submit-time input freeze
  and owned recording/transcription/generation; AppState adapters apply UI policy.
- `AppState+Providers.swift`: provider settings, API-key save/status, and
  provider connection tests.
- `AppState+Diagnostics.swift`: developer diagnostics, capture events, latency
  labels, and heartbeat.
- `Runtime/Interview/GenerationCoordinator.swift`: authoritative root request, generation identity,
  frozen provider configuration, current/retiring/join, child tasks and terminal fences. AppState exposes
  read-only compatibility projections; UI/DB validation and pipeline orchestration
  still remain in AppState extensions.
- `PromptContextBuilder.swift`: immutable prompt snapshot construction; shared
  answer instructions distinguish explanation from design, while
  `InterviewTaskDescriptor.answerPromptPolicy` qualifies general claims.
  Practice retains its separate task policy.
- `LocalASRProviders.swift`: bundled native helper compatibility is checked before
  probe/start `Process.run`; its packaged runtime requires macOS 15.5, while the
  product deployment target remains 14. External helper paths keep their policy.
- `AppState+VerificationBootstrap.swift`: existing controlled-player admission,
  exact verification run-ID command observation and public request-count event;
  isolated startup validation precedes production storage. Synthetic full-text
  request/formal-output diagnostics retain the original persistence ticket;
  changing saving off and back on cannot revive it.
- `GenerationRequestSnapshot.swift`: prompt/generation snapshot data models.
- `GenerationExecutionContext.swift`: typed frozen inputs for one generation.
- `GenerationProviderRequest.swift`: typed provider request plus redacted
  diagnostics.
- `GenerationProviderResult.swift`: typed provider output/status data.
- `QuestionIntentPromptPolicy.swift`: deterministic intent, context filtering,
  and fallback answer policy.
- `QuestionAnswerAlignment.swift`: safety guard that validates answer relevance
  before display/persistence. Alignment is not independent technical fact
  verification; accepted generated cards must not be described as verified facts.
- `AnswerRelevancePolicy.swift`: stable facade over prompt/intent/relevance
  helpers.
- `SuggestionGenerationService.swift`: provider calls and response parsing for
  suggestion cards.
- `OllamaQwenProvider.swift`: streaming transport and load-only model preparation;
  preparation validates the public load terminal without changing keep-alive,
  generation diagnostics or downloads. Structured generate requests reject input
  truncation and output context shifting; a length terminal is an error even when
  the partial response happens to form closed JSON. Chat streaming keeps its
  existing completion contract.
- `OllamaGenerationDiagnostics.swift`: optional public terminal token/duration
  metadata; no thinking content. Router duration logs are provider-latest scope,
  not exact per-request attribution under concurrent callers.
- `InterviewQuestionRouter.swift`: frozen structured task/evidence decision;
  retrospective performed work remains distinct from a new coding/diagnosis task.
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
6. An accepted request retains its frozen provider/execution inputs in
   `GenerationCoordinator`. `generateSuggestion(...)` registers watchdog/provider
   work with that owner and prepares the context/RAG prompt snapshot while
   rechecking the same identity.
7. Local Qwen through Ollama, optional DeepSeek, or an explicit aligned fallback
   produces the first visible `say_first`.
8. Stage B expands key points/follow-up when available.
9. `displaySuggestionIfAligned(...)` verifies question binding and semantic
   relevance before the card can become current UI state.
10. The admitted final card and chunks enter the database through the original
    persistence ticket and applicable session/question/revision checks. UI
    admission does not renew persistence consent.

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
  `OllamaQwenProvider.swift`, `GenerationProviderRequest.swift`, and the existing
  `GenerationCoordinator` for registered task identity and cleanup. AppState
  extensions retain application policy and UI/DB admission.
- API-key storage/status: `KeychainService.swift` and `AppState+Providers.swift`.
- Developer-only runtime details: `AppState+Diagnostics.swift` and diagnostics
  views.

## What Not To Touch Casually

- Further generation moves must preserve consecutive-request, configuration
  freeze, consent, deadline and late-callback regression coverage. Invalidate
  identity before cancelling; cancellation alone does not reject stale results.
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
- `generateSuggestion(...)` remains application orchestration. The existing
  coordinator owns current/retiring generation tasks and joins; `LiveRAGPrefetch`
  owns speculative retrieval. Controlled ownership tests do not establish every
  actual backend exit or current GUI interleaving.

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
  `AnswerClaimValidator` distinguishes prospective employer-policy questions from
  candidate conditions; an inquiry cannot exempt a coordinated personal request.
  The rule remains heuristic and retains candidate-only support at both boundaries.
- `OllamaQwenProvider`: ordinary chat streaming remains `/api/chat`; non-thinking
  JSON-schema requests use `/api/generate` and the server-owned model template.
  This avoids the verified Ollama 0.24.0 Qwen 3.5 chat grammar activation defect.
  Both paths share cancellation, response accumulation and metadata diagnostics.
  A public done event ends the stream without waiting for HTTP EOF and cancels
  that request's transport task, not the shared URLSession. The Live local-answer
  deadline includes routing and retrieval. An eligible automatic retry reuses
  its frozen routing decision only while model, context and router version match.
- `MaterialExtractionService`: bounded PDFKit/Vision/ZIPFoundation/XMLParser
  extraction; native OCR cancellation is linked to task cancellation. Document
  originals, hashes and locations live in `document_sources` through
  `DocumentRepository`; `DocumentsState` owns import/reprocess cancellation and joins.
- `PracticeController` / `PracticeSession` / `PracticeRepository`: finite practice
  lifecycle, local-only evaluation, exact-quote/rubric validation, microphone/TTS
  exclusion, frozen attempts/material metadata, explicit FSRS ratings. The
  controller cancels underlying streams and owns a 90-second evaluation deadline.
- Saved Practice references retain model-draft/unknown provenance and their input
  revision. Saving or user confirmation does not certify technical truth. The
  independent critic receives the frozen input and application contract, without
  old draft judgments; this input separation does not guarantee correct feedback.
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
  recap. `HistoryState` owns current/retiring recap tasks and their awaited joins;
  deleting an unrelated session cannot cancel live generation.
- `PreparationView` / `PreparationState` / `PreparationRepository`: user-triggered
  public URL and SQL requests with frozen input, consent checks and cache deletion.
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
- Migration v22 stores each card's frozen question decision. Legacy cards remain
  unknown rather than acquiring a later question policy; populated-v21, reopen and
  regeneration behavior is covered by `FrozenCardDecisionPersistenceTests`.

Apple Speech and Parakeet providers own per-round startup, stream bridge and
retained teardown. Old stream termination is identity-bound. The Parakeet sidecar
retains its exact helper until observed process exit and bounded writer drainage; incomplete
cleanup blocks a new helper. Low-level ScreenCaptureKit callbacks/stop and helper
health/model probes have separate controlled lifecycle tests; fresh native GUI
acceptance is still required. Verification requires device-only Apple Speech;
normal product defaults do not establish processing location by provider name.
The optional Parakeet context vocabulary is owned by `SettingsState` and frozen
from the selected opportunity's usable skill evidence at capture startup.
`LocalASRProviders` owns each helper's private vocabulary directory through exit
and pipe drainage; a deletion failure retains the owner for explicit retry.
The native helper uses existing sherpa modified beam search and creates its
approximate BPE vocabulary under the model-use lock. Default greedy decoding,
raw transcript storage and microphone authorization boundaries are unchanged.
The trace writer checks uncached file size for its existing 25 MiB / five-file
rotation and retains the 256-record queue and 1 MiB line limit.

Capture admission preserves unknown permission state when the native audio
stream is unavailable. An unattempted probe reports the missing display or
cancellation; a stream failure reaches the existing live error path before
session/ASR creation and does not request permission as if it had been denied.
Controlled regressions do not establish the cause of historical native startup failures.
The app/helper deployment target remains macOS 14, while the packaged ONNX
Runtime 1.27.0 binary declares a 15.5 minimum. Current host validation does not
establish the native ASR bundle's macOS 14 compatibility.

See `workflow-acceptance.md` for verification limits. Ordinary tests, local model
quality, real system audio, long-session performance and public distribution are
separate gates.
