# Hireva Full Release Validation - 2026-08-07

## Verdict

- Local Controlled-Use: **NO-GO**
- Public Distribution: **NO-GO**

The code, deterministic runtime harness, real local providers, persistence tests, app lifecycle, and local package checks pass. The local controlled-use gate remains NO-GO because a signed-bundle, real ScreenCaptureKit system-audio interview was not completed, and the full TSan/ASan test commands returned nonzero because timing-sensitive assertions expired under instrumentation. Public distribution is independently NO-GO because only ad-hoc signing is available; there is no Developer ID identity, notarization, or stapled ticket.

## Scope and Environment

- Original checkout: `$HIREVA_REPOSITORY`
- Isolated worktree: `$HIREVA_VALIDATION_WORKTREE`
- Base branch/commit: `fix/release-hardening` / `578e95c`
- Validation branch: `codex/hireva-full-release-validation-20260804`
- Verification evidence: `$HIREVA_VERIFICATION_ROOT/20260807-191024`
- Host: macOS 26.3.2 (25D2150), arm64
- Swift: Apple Swift 6.1 (`swiftlang-6.1.0.110.21`)
- Developer tools: Command Line Tools selected; full Xcode is not selected
- Python: 3.14.6
- Ollama: 0.24.0
- Final commit: the report commit itself cannot self-reference; use the branch tip recorded in the final release response.

## Git Safety and Worktree Recovery

- Confirmed release-hardening commit `578e95c` before modifying files.
- Preserved original backup branch `backup/release-hardening-pre-codex-20260804` and tag `backup-release-hardening-20260804` at `578e95c`.
- Created additional immutable references `backup/codex-shared-worktree-base-20260807` and `backup-codex-shared-worktree-base-20260807` at `578e95c` before integrating concurrent work.
- Stored status, full diff, patch, untracked-file list, and copies outside the repository at `shared_worktree_snapshot_20260807` under the verification root.
- Kept the Google Drive checkout and `main` untouched. No reset, clean, destructive checkout, force push, or direct merge was used.
- After the snapshot, all writes were performed by the primary agent in a single worktree.

## Baseline

The unmodified `578e95c` baseline established that compilation and app assembly worked, but it did not satisfy the release gate:

- `swift build` passed.
- The baseline full test run stalled and was sampled; the baseline stability script classified `Swift test` as FAIL.
- Baseline RuntimeSmoke failed with two issues, including cumulative Apple Speech replay/current-card ownership behavior.
- `verify_runtime_stability.sh` ended `overall: FAIL` (`Swift test: FAIL`, `runtime_smoke: FAIL`, bundle verification PASS).
- RuntimeSmoke emitted raw question/transcript fields into its trace output, reproducing the diagnostic privacy exposure.
- The app was ad-hoc signed and Gatekeeper rejected it.

Baseline evidence is retained as `baseline_*.log` in the verification root and was not overwritten.

## Fixes and Regression Coverage

### ASR permissions and source ownership

- Centralized provider/capture-mode permission decisions in `ASRPermissionRequirements`.
- Local Parakeet does not request Speech Recognition permission; microphone and Screen/System Audio permissions are required only for active capture sources.
- Applied the same policy to readiness, setup, and start behavior.
- Preserved ASR provider identity separately from microphone/system-audio provenance.
- Mapped microphone transcripts to candidate/microphone and system-audio transcripts to interviewer/systemAudio; candidate speech remains ineligible for automatic answer generation.
- Added provider/capture permission matrix, source-isolation, simultaneous-source, stop/restart, and candidate-trigger regressions.

### Parakeet capability and lifecycle

- Declared the current native Parakeet path as local, experimental, final-after-utterance, and without partial transcript support.
- Hardened health, EOF, invalid event, unexpected source, process exit, write failure, flush, stop, and restart handling.
- Process termination now clears active state and reaps the helper instead of leaving a false Listening state or orphan process.
- Python sidecar imports are lazy and missing-runtime health failures are structured; the release bundle uses the pinned native helper.

### Diagnostic privacy

- Added `DiagnosticTraceMode` (`off`, `metadataOnly`, `fullText`) with default `off` and backward-compatible settings decoding.
- When transcript saving is disabled, effective diagnostic tracing cannot exceed metadata-only.
- Metadata serialization omits raw transcript, question, answer, CV/JD preview, and provider payload text.
- Added trace cleanup/rotation, legacy cleanup, UI controls, warning copy, and Clear Diagnostic Traces.
- Added canary tests for SQLite, trace off, metadata-only, explicit full-text opt-in, rotated-file cleanup, and simulated key redaction.

### Real Ollama/Qwen streaming

- Changed `/api/chat` to `stream: true` and `think: false`.
- Parses incremental NDJSON from `URLSession.AsyncBytes`, including split JSON boundaries, multiple lines, empty/thinking chunks, malformed input, HTTP errors, required `done`, and cancellation.
- Added readiness caching/invalidation and generation ownership so a replaced request cannot update the visible card.
- Separated request start, first provider token, first visible answer, full answer, and full-card timing.
- Added mock transport regressions and a real `qwen3.5:4b` smoke test.

### Unicode, question recognition, and RAG ownership

- Uses UTF-16 boundaries for regular-expression spans and slices source text before normalization.
- Added emoji, combining character, mixed Chinese/English, curly apostrophe, and multi-question span round-trip coverage.
- Expanded intent routing for role, system, debugging, dataset, trade-off, failure, improvement, project, and comparison questions; removed the accidental `hardware` substring match.
- Preserved frozen question/generation/session/context ownership across Stage B, provider callbacks, RAG snapshots, UI updates, and persistence.

### Queue, persistence, and race hardening

- Rejects duplicate detected-question inserts and makes suggestion updates monotonic.
- Late provider callbacks cannot replace a newer generation.
- Visible Stage A cards remain readable on stop while old background work cannot persist afterward.
- Terminal paths drain queued work; rapid follow-ups preserve per-question records and latest-card ownership.
- Added 100-transcript/100-suggestion SQLite stress coverage, stop/start, rapid-two, rapid-three, repeated-question, context-switch, malformed sidecar, controlled exit, and interrupted Ollama stream regressions.
- Fixed a TSan-reported test fixture race by isolating `CaptureRuntimeStateTests.AsyncGate` to `@MainActor`.

### Documentation and UI

- Updated README, code map, Parakeet runtime, privacy/data flow, release runbook, threat model, setup/readiness, settings, diagnostics, and local-model copy.
- Corrected an unreachable privacy-message UI branch.
- Avoided a broad AppState rewrite; extractions were limited to correctness policies and lifecycle ownership.

## Automated Test Results

| Gate | Result | Evidence |
| --- | --- | --- |
| ASR focused suite | 27/27 PASS | focused test log under verification root |
| Parakeet focused suite | 16/16 PASS | focused test log under verification root |
| Runtime trace privacy | 1/1 PASS | focused test log under verification root |
| Ollama focused suite | 33/33 PASS | focused test log under verification root |
| Generation focused suite | 90/90 PASS | focused test log under verification root |
| Persistence focused suite | 22/22 PASS | focused test log under verification root |
| Question focused suite | 231/231 PASS | focused test log under verification root |
| Capture runtime state | 10/10 PASS | focused test log under verification root |
| SQLite stress | 1/1 PASS | focused test log under verification root |
| Privacy integration | 1/1 PASS | focused test log under verification root |
| Full suite 1, coverage | 735/735 PASS in 69.210 s | `final_full_suite_1_coverage_retry.log` |
| Full suite 2 | 735/735 PASS in 68.425 s | `final_full_suite_2.log` |
| Full suite 3 | 735/735 PASS in 69.309 s | `final_full_suite_3.log` |
| RuntimeSmoke all | 12/12 PASS | `final_runtime_smoke_all.log` |
| Final stability gate | build/test/smoke/app verify PASS, 129 s | `final_runtime_stability_gate_pass.log` |

### Sanitizers

- Focused TSan after the actor-isolation fix: 10/10 PASS and no ThreadSanitizer warning.
- Full TSan: no `WARNING: ThreadSanitizer` or sanitizer summary, but command exit was nonzero because four timing-sensitive test assertions expired under instrumentation.
- Full ASan: no AddressSanitizer or LeakSanitizer diagnostic, but command exit was nonzero because twelve timing/watchdog assertions expired under instrumentation.
- These results are reported as sanitizer instrumentation clean but **not** as successful full sanitizer gates.

## 64-Question Runtime Gate

- Fixed manifest: 64 cases across role motivation, projects, architecture, model comparison, failure, trade-offs, teamwork, ambiguity, debugging, deployment, privacy/safety, multi-part/no-punctuation/cumulative ASR, candidate speech, duplicate/replay, profiles, evidence gaps, and future plans.
- Expected triggers accepted: 59/59.
- Expected non-triggers rejected: 5/5.
- False triggers: 0.
- Stale answers or duplicate suggestion ownership failures: 0.
- Final harness latency: p50 264.2 ms, p95 362.2 ms, max 370.8 ms.
- This timing starts within the deterministic runtime harness; it is not represented as end-to-end physical audio, native ASR, and real Qwen latency.

## Real Local Provider and App Evidence

### Parakeet

- Bundle helper health: `bundled_native`, sherpa-onnx 1.13.4, ONNX Runtime 1.27.0, arm64, model ready.
- A generated non-private WAV produced a nonempty final transcript with `source=local_parakeet_asr`, `audioSource=systemAudio`, interviewer attribution, and no Apple Speech fallback.
- The bundle helper processed three utterances in one real model stream: 1/1 PASS in 31.165 s.

### Qwen

- Ollama 0.24.0 with `qwen3.5:4b` was available locally.
- Explicit real-provider smoke: 1/1 PASS in 1.322 s.

### Application bundle

- Path: `$HIREVA_VALIDATION_WORKTREE/dist/Hireva.app`
- Bundle ID: `com.langcheng.Hireva`
- Executable: `Contents/MacOS/Hireva`, arm64.
- Native Parakeet helper and both bundled dylibs validate under deep code-signature verification.
- Ten quit/relaunch cycles passed. Every post-quit check found zero app/helper processes; every launch found one app at the expected executable path.
- Final graceful stop found `app_count=0` and `helper_count=0`.
- TCC was not reset.

The real native ASR decode and real Qwen checks were provider-level validations. The deterministic RuntimeSmoke exercised transcript ingestion through question detection, RAG/context ownership, answer alignment, UI/current-card state, and temporary SQLite persistence. A complete signed-bundle ScreenCaptureKit system-audio interview through all of those stages was not performed and remains the local release blocker.

## SQLite and Privacy Evidence

- Stress tests use temporary databases and passed without `SQLITE_BUSY` or database-lock errors.
- Production database diagnostics were metadata-only and read-only.
- Production DB: 14,630,912 bytes; 329 suggestion rows, 329 distinct IDs, 329 distinct question IDs, 155 completed, and 265 aligned.
- Those historical production totals are not used as the 64-case tie-out; the gate uses isolated fixtures/databases.
- Production runtime trace file did not exist at final diagnostics time.
- Automated privacy canaries passed for transcript-save-off, trace off, metadata-only, explicit full-text opt-in, and trace clearing.
- Final ZIP path scan found no SQLite/DB, JSONL trace, audio, model weight, LocalModels, secret/key, `.git`, or `.build` content.

## Release Artifact

- Directory: `$HIREVA_VALIDATION_WORKTREE/release/Hireva-local-20260807-203346`
- ZIP: `$HIREVA_VALIDATION_WORKTREE/release/Hireva-local-20260807-203346.zip`
- SHA-256: `e6e55109d835f8550a641f54dab842e3a9d2be58825525e6a4cfc66d3f90a1b3`
- ZIP entries: 35 allowlisted app/documentation paths.
- `Info.plist`: valid.
- Deep strict code-signature verification: valid on disk and satisfies the designated requirement.
- Signature: ad-hoc; TeamIdentifier absent.
- Gatekeeper: rejected, as expected for the non-distributable local signature.

## External References

Official Apple documentation was checked for Speech authorization and usage descriptions, AV microphone authorization, ScreenCaptureKit capture permission, URLSession async byte streaming, Swift string/UTF-16 indexing, Developer ID signing, and notarization. Official Ollama streaming API documentation and the official sherpa-onnx documentation/GitHub examples were also checked. No external implementation was copied; sources were used only to verify API and lifecycle behavior.

## Remaining Risks and Blockers

- Real signed-bundle ScreenCaptureKit system-audio capture through native Parakeet, detection, real Qwen, UI, and SQLite was not completed.
- Apple Speech was covered by policy/runtime mocks but not by a new real TCC audio session.
- Full sanitizer commands did not exit successfully because timing-sensitive tests expired under instrumentation, despite no sanitizer diagnostic.
- No physical Bluetooth audio route was available; real Bluetooth switching was not validated.
- No real DeepSeek account/key test was run. DeepSeek is optional and no private key was introduced for validation.
- Full Xcode is not selected, so validation used Swift Command Line Tools rather than an Xcode project build.
- Public distribution lacks Developer ID Application signing, hardened-runtime distribution evidence, notarization, and staple.
- A broad unified-log privacy canary sweep was not used as a substitute for the scoped automated canary tests and package scan.

## Final Decision

```text
Local Controlled-Use: NO-GO
Public Distribution: NO-GO
```

The local verdict can be reconsidered after a real System Audio Only session from `dist/Hireva.app` completes the full Parakeet-to-Qwen-to-UI-to-SQLite path and both full sanitizer commands either pass or their timing contracts are made instrumentation-aware without weakening production behavior. Public distribution additionally requires a configured Developer ID Application identity and successful notarization/stapling.
