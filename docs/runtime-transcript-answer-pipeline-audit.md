# Runtime Transcript-to-Answer Pipeline Audit

Date: 2026-06-16

Scope: System Audio runtime path from audio buffer ingestion to visible answer and `suggestion_cards` persistence. Public references (`insidegui/AudioCap`, `argmaxinc/argmax-oss-swift` / WhisperKit, `MacPaw/OpenAI`) were used only as architecture references for capture lifecycle, transcript stream separation, and provider request/session boundaries. No third-party source was copied and no dependencies were added.

Required runtime path:

```text
SystemAudioBuffer
-> ASR partial transcript event
-> transcript UI update
-> ASR final/utterance segment
-> QuestionCandidatePipeline
-> AcceptedQuestionCandidate
-> generateSuggestion(...)
-> visible card
-> DB persistence
```

## 1. Which class receives system audio buffers?

`ScreenCaptureKitSystemAudioCaptureService` receives ScreenCaptureKit buffers in `stream(_:didOutputSampleBuffer:of:)` and converts audio buffers before notifying delegates.

Evidence:

- `Sources/Hireva/Services/ScreenCaptureKitSystemAudioCaptureService.swift:194` defines `stream(_:didOutputSampleBuffer:of:)`.
- `Sources/Hireva/Services/ScreenCaptureKitSystemAudioCaptureService.swift:233` calls `delegate.systemAudioCaptureService(self, didReceive: pcmBuffer, at: time)`.

## 2. Which class sends audio to ASR?

`AppleSpeechTranscriptionService` receives the system audio PCM buffer as a `SystemAudioBufferDelegate` and forwards it to `AppleSpeechTranscriptionSession.appendBuffer(_:)`, which appends into `SFSpeechAudioBufferRecognitionRequest`.

Evidence:

- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:631` defines `systemAudioCaptureService(_:didReceive:at:)`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:636` calls `systemAudioSession?.appendBuffer(buffer)`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:282` defines `appendBuffer(_:)`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:296` appends to `request?.append(buffer)`.

## 3. Which class receives partial transcript?

`AppleSpeechTranscriptionSession` receives Apple Speech partials inside `recognitionTask` and emits a `TranscriptSegment` with `asrFinalizationReason: "partial"`.

Evidence:

- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:183` creates `recognitionTask`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:185` branches on `!result.isFinal`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:210` emits the partial segment.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:373` defines `emit(text:id:)`.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:392` marks emitted partials with `asrFinalizationReason: "partial"`.

## 4. Which class receives final transcript?

`AppleSpeechTranscriptionSession` receives Apple Speech final results in the same recognition task, chooses the best final transcript, and emits it through `emitWithLatency(text:id:)`.

Evidence:

- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:207` enters the final-result branch.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:264` emits the finalized best transcript.
- `Sources/Hireva/Services/AppleSpeechTranscriptionService.swift:399` defines `emitWithLatency(text:id:)`.

## 5. Which state property drives UI transcript display?

The explicit current transcript display state is `AppState.displayTranscriptText`. The full transcript view still renders the transcript history from `AppState.transcriptSegments`.

Evidence:

- `Sources/Hireva/AppState.swift:49` defines `@Published var displayTranscriptText`.
- `Sources/Hireva/AppState+RuntimeTranscriptEvents.swift:36` updates `displayTranscriptText` on ASR partial.
- `Sources/Hireva/AppState+RuntimeTranscriptEvents.swift:45` updates `displayTranscriptText` on ASR final.
- `Sources/Hireva/Views/FloatingAssistantView.swift:410` reads `appState.displayTranscriptText` for the current question fallback.
- `Sources/Hireva/Views/LiveInterviewView.swift:650` renders `TranscriptView(segments: appState.transcriptSegments)` for transcript history.

## 6. Which code calls `QuestionCandidatePipeline`?

The runtime guard and system-audio extractor call `QuestionCandidatePipeline`; AppState routes accepted/rejected candidates through those helpers rather than invoking the pipeline directly from generation.

Evidence:

- `Sources/Hireva/Services/QuestionRuntimeAcceptanceGuard.swift:30` calls `QuestionCandidatePipeline.extract`.
- `Sources/Hireva/Services/SystemAudioQuestionExtractor.swift:25` maps `QuestionCandidatePipeline.extract`.
- `Sources/Hireva/AppState+QuestionDetection.swift:37` defines `processExtractedSystemAudioQuestions`.
- `Sources/Hireva/AppState+QuestionDetection.swift:545` calls the runtime acceptance path before generation.

## 7. Which code calls `generateSuggestion(...)`?

Auto-detection calls `generateSuggestion(...)` only after `runtimeAcceptedQuestionForGeneration(...)`. Manual/provider retry paths still call `generateSuggestion(...)`, but `generateSuggestion(...)` itself re-runs `QuestionRuntimeAcceptanceGuard.validateDetectedQuestionForGeneration` before any provider call or UI answer mutation.

Evidence:

- `Sources/Hireva/AppState+QuestionDetection.swift:506` defines `startAutoSuggestionGeneration`.
- `Sources/Hireva/AppState+QuestionDetection.swift:511` gates through `runtimeAcceptedQuestionForGeneration`.
- `Sources/Hireva/AppState+QuestionDetection.swift:521` calls `generateSuggestion(...)`.
- `Sources/Hireva/AppState.swift:1019` defines `generateSuggestion(...)`.
- `Sources/Hireva/AppState.swift:1029` validates the question with the runtime guard before generation continues.
- `Sources/Hireva/AppState+Generation.swift:191`, `Sources/Hireva/AppState+Providers.swift:345`, and `Sources/Hireva/AppState+ManualCapture.swift:489` are non-auto call sites; they are protected by the guard in `generateSuggestion(...)`.

## 8. Which code persists `suggestion_cards`?

`persistSuggestionInBackground(...)` and `saveSuggestionSnapshotInBackground(...)` persist suggestion cards after a pre-persistence guard validates accepted question, prompt-question equality, answer alignment, and final-card safety.

Evidence:

- `Sources/Hireva/AppState+Generation.swift:1603` defines `persistSuggestionInBackground`.
- `Sources/Hireva/AppState+Generation.swift:1619` validates with `QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence`.
- `Sources/Hireva/AppState+Generation.swift:1650` calls `repository.saveSuggestionCard`.
- `Sources/Hireva/AppState+Transcript.swift:520` defines `saveSuggestionSnapshotInBackground`.
- `Sources/Hireva/AppState+Transcript.swift:525` validates with the same persistence guard.
- `Sources/Hireva/AppState+Transcript.swift:543` calls `repository.saveSuggestionCard`.
- `Sources/Hireva/Services/SuggestionRepository.swift:55` is the repository write implementation for suggestion cards.

## 9. Can any path call generation without transcript UI update?

The normal ASR runtime path updates transcript state before detection/generation. `handleTranscriptSegment(_:)` records ASR runtime events and updates transcript segments before it can route to detection. Manual/provider paths can call `generateSuggestion(...)` without a new ASR segment, but they still cannot bypass the generation guard.

Evidence:

- `Sources/Hireva/AppState+Transcript.swift:31` defines `handleTranscriptSegment(_:)`.
- `Sources/Hireva/AppState+Transcript.swift:39` records the ASR transcript runtime event.
- `Sources/Hireva/AppState+Transcript.swift:58` appends/replaces `transcriptSegments`.
- `Sources/Hireva/AppState+Transcript.swift:63` updates `lastTranscriptSnippet`.
- `Sources/Hireva/AppState+Transcript.swift:319` records an utterance candidate before the extracted-question path.
- `Sources/Hireva/AppState+Transcript.swift:353` records an utterance candidate before provider detection.
- `Sources/Hireva/AppState.swift:1029` re-validates before generation.

## 10. Can any path persist a card without `AcceptedQuestionCandidate`?

No accepted persistence path should persist without passing `QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence`, which reconstructs the accepted candidate from `questionText` and `promptPrimaryQuestion`. Unsafe direct repository writes remain possible only from tests or explicit mock data helpers.

Evidence:

- `Sources/Hireva/Services/QuestionRuntimeAcceptanceGuard.swift:82` calls `acceptedCandidate(from:)` for card question text.
- `Sources/Hireva/Services/QuestionRuntimeAcceptanceGuard.swift:87` calls `acceptedCandidate(from:)` for prompt primary question.
- `Sources/Hireva/Services/QuestionRuntimeAcceptanceGuard.swift:92` rejects question/prompt mismatch.
- `Sources/Hireva/AppState+Generation.swift:1619` enforces the guard before normal DB persistence.
- `Sources/Hireva/AppState+Transcript.swift:525` enforces the guard before snapshot persistence.

## 11. Can the ASR engine stop while UI still says listening?

Yes, that remains possible in macOS runtime if capture stays alive but Apple Speech callbacks stop. The app now exposes heartbeat diagnostics to distinguish capture stopped, ASR callback missing, UI state not updated, candidate rejected, or generation guard rejected.

Evidence:

- `Sources/Hireva/AppState+Audio.swift:555` defines `monitorAudioSignal`.
- `Sources/Hireva/AppState+Audio.swift:558` reads `speechService.systemAudioSession?.recognitionTask`.
- `Sources/Hireva/AppState.swift:195` publishes `systemASRTaskRunning`.
- `Sources/Hireva/AppState.swift:208` defines `runtimeTranscriptChainStatus`.
- `Sources/Hireva/Models/TranscriptRuntimeEvent.swift:88` reports `"ASR callback missing after audio buffer"` when buffers arrive with no callback.
- `Sources/Hireva/Views/DiagnosticsView.swift:289` displays the Runtime Transcript Chain card.

## 12. Are rejected fragments visible in the transcript UI?

Yes. `handleTranscriptSegment(_:)` updates transcript state before detection gating. Incomplete fragments are rejected after visibility is updated, and tests verify no generation or DB persistence occurs.

Evidence:

- `Sources/Hireva/AppState+Transcript.swift:39` records partial/final runtime transcript event.
- `Sources/Hireva/AppState+Transcript.swift:58` appends/replaces `transcriptSegments`.
- `Sources/Hireva/AppState+Transcript.swift:63` updates `lastTranscriptSnippet`.
- `Sources/Hireva/AppState+Transcript.swift:295` records `questionRejected` for incomplete fragments.
- `Tests/HirevaTests/RuntimePathSingleSourceOfTruthTests.swift:123` verifies rejected fragment UI transcript state updates with no generation or persistence.
- `Tests/HirevaTests/RuntimePathSingleSourceOfTruthTests.swift:180` verifies visible transcript with generation blocked for an incomplete question.

## Manual Diagnostics

Use a fresh timestamp before a manual smoke test:

```bash
TEST_START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%S")
echo "$TEST_START_UTC"
```

After testing, inspect persisted answers:

```bash
DB="$HOME/Library/Application Support/Hireva/hireva.sqlite"

sqlite3 "$DB" "
SELECT
  created_at,
  substr(question_text,1,220) AS question,
  question_intent,
  substr(prompt_primary_question,1,220) AS prompt_question,
  substr(say_first,1,320) AS answer,
  alignment_verdict,
  mismatch_reason,
  stage_b_status
FROM suggestion_cards
WHERE created_at >= '$TEST_START_UTC'
ORDER BY created_at DESC;
"
```

In the app, open Diagnostics -> Audio -> Runtime Transcript Chain and check:

- `audio_is_running`
- `last_audio_buffer_at`
- `last_asr_partial_at`
- `last_asr_final_at`
- `displayTranscriptText`
- `last_question_accepted_at`
- `last_question_rejected_at`
- `last_generation_started_at`
- `last_generation_rejected_reason`
- `chainStatus`
