# Continuation acceptance — 2026-09-27

**Overall core is NOT COMPLETE.** Routing recall misses its fixed gate; physical
microphone/TTS/denial and the defined B1→B2 audio performance comparison remain
unverified. Passing native tests does not override those failures.

## Current source and evidence

Branch `test/question-evidence-corrections`, HEAD `cfdda9eecb623b9104ce8b193a5a1451579be3d4`.
B1 was the actual clean source after the earlier, separately authorized push to
main, not the historical 84-file dirty version. This continuation is uncommitted;
no commit, push, PR, merge or release was performed during it. B1/B2 file manifests,
source archives, command ledgers, failed attempts and consistent synthetic SQLite
backups are outside the repository at
`/Users/delaynomore/Hireva-validation/continuation-20260927-180847` (R2).
The previous enhancement record below remains historical evidence, not this run's
result. Same arm64/macOS 27/Swift 6.1/Ollama 0.24.0/qwen3.5:4b; no upgrade/download.

## Repairs and observed scope

| Reproduction → cause | Change / verification scope |
|---|---|
| Original102: task36/102, evidence58/102,44 missed required cases | Shared immutable `InterviewQuestionDecision`, final-question-only local classifier; task/evidence/basis/parent and revisions frozen across live, Practice and re-evaluation. Strict decoder and bounded repair. Chinese NLTokenizer replaces whitespace-only segmentation. Current quality below remains FAIL. |
| Schema-validity failures on local Qwen3.5 | Inspected installed-version Ollama code: chat thinking-parser path can omit schema even with think=false. Existing `OllamaQwenProvider` now uses `/api/generate` and the installed template for constrained schema requests. Native transport and real-model runs; no new SDK/runtime. Format success is separate from semantics. |
| General answers/visible citations inherited unrelated CV; nil snapshot and late rewrite could bypass checks | Frozen evidence policy filters prompt/retrieval/retry/fallback and displayed source chunks. Every visible field goes through personal-claim checks, including nil snapshot. Removed unowned provider rewrite; existing owned retry remains. Real-model live/correction cases and native canaries; validator is heuristic, not proof of truth. |
| Late Stage B relabelled terminal fallback; rejected expansion left UI waiting; cumulative answer could truncate or replace complete content with unfinished next clause | Preserve generation terminal ownership; reject unsafe expansion but finish checked first answer; pass actual provider completion status; update complete cumulative text only. Claim checking preserves field/list boundaries. Focused 110-test regression passed; original64 fixture/deadline unchanged. |
| Historical text edits did not drive evaluation | v21 correction overlays preserve original ASR and attempt revisions; explicit re-evaluation, versioned recap, exact citations and assisted history. Parent correction invalidates dependent follow-ups/review cards while preserving real FSRS ratings. Populated-v20 migration includes induced transactional failure, retry and reopen. Actual UI retrieve→retry and On→O(n), re-evaluate, quote and restart observed; latest descendant invalidation checked natively. |
| Edited fact draft disappeared/rebuilt from source | Review list includes inferred drafts; `hasReviewEdits` preserves edits. Explicit confirmation stores individual/team contribution, completion status, environment, system scope and metric conditions. Actual UI draft remained Uncertain; Confirm saved team contribution with unknown/empty fields retained. |
| Deletion retained derivative text; privacy off→on left an empty session | Redact/delete source chunks, card strategy/caution, snapshots, past feedback and review derivatives; invalidate tasks/tickets. Practice started with saving off uses an ephemeral session. Actual isolated UI document/card/Practice/live-session deletes, global clear/restart and off→on exercise verified against DB/private files. Zero canary hits; unrelated records preserved before global clear. User exports/external backups are separate and were retained. |

## Routing quality (unchanged original labels)

| Metric | B1 original102 | B2 original102, known regression | New V3 one-shot160 |
|---|---:|---:|---:|
| All task matches |36/102|89/102|139/160|
| All evidence matches |58/102|92/102|139/160|
| Domain accuracy / macro-F1 |See B1-workflow-quality.json|83/96 / .8962|125/144 / .8792|
| English / Chinese domain accuracy |Not inferred|44/48 /39/48|65/72 /60/72|
| Automatic domain coverage |Not inferred|91/96|137/144|
| Required recall (gate≥.95) |14/58|51/58 **FAIL**|39/42 **FAIL**|
| Negative specificity (gate≥.90) |44/44|41/44|89/92|
| Unknown / failed cases |See original output|10/102 /1/102|17/160 /1/160|
| Model requests / repaired cases |Rules only|103 /1|161 /1|

Evidence confusion (rows gold; columns required/notRequired/optional/uncertain):
original102 required=[51,1,0,6], negative=[0,41,0,3];
V3 required=[39,1,0,2], negative=[1,89,0,2], optional=[0,6,2,2], uncertain=[2,5,0,9].
Unknown includes deliberately unknown gold. Invalid output remains in denominators.
V3=80 English+80 Chinese,144 domain+16 unknown,78 related scenario groups; translations
and related dialogue stay together. All labels are synthetic/model-assisted and
unreviewed, **not independent human gold**. V1/V2 failed and became diagnostic sets;
those failures and proposed-label sidecars remain. V3 was frozen before its one-shot
run, then inspected; routing was not tuned afterward. Full per-class P/R/F1,
confusions and raw model-vs-guard decisions are in `quality-final-summary.json`.
100% model-call rate on these automatic cases; manual task choices excluded.

Native reproduction (pre-create output directory):
`HIREVA_ROUTING_EVAL=1 HIREVA_ROUTING_CASES=<fixture.json> HIREVA_TEST_ARTIFACT_DIR=<output> HIREVA_ROUTING_ENFORCE_GATE=1 swift test --filter QuestionDecisionEvaluationTests`.
`development-12-final` and `holdout-v3-result` exited **1**, not an export-only pass.
Routing p50/p95 were 2045/2265ms and2098/2466ms respectively; these are NOT audio
end-to-visible latency or a B1/B2 performance comparison.

## Native, model, UI and system results

Final source native tests: `manual-final-11` **17 PASS** (2.506s); `full-final-11`
reports820 total: **812 executed PASS,8 opt-in SKIPPED** (117.432s), exit0.
`smoke-final-11` **12 PASS** (32.075s), including the unchanged original64 threshold,
exit0; exact commands are in `final-11-command-ledger.json`. Earlier failures remain in their original logs.
Actual opt-in `live-final-6` ran4 tests: manual local decision/DB, cancellation N3,
and eight live canary/personal cases passed; corrected-attempt evaluation **FAILED**
when the model omitted a targeted follow-up despite rubric gaps, including after
its bounded repair. The guard refused it. `live-final-4` had3 passing tests and
`practice-final-4` had3; these earlier successes do not override the latest failure.
Ordinary `swift test` skips opt-in model work. Actual commands explicitly set
`HIREVA_RUN_LOCAL_LIVE_DECISION=1 HIREVA_RUN_LOCAL_CANCEL=1` or
`HIREVA_RUN_LOCAL_PRACTICE=1`. Model feedback quality remains a limitation.

Home now exposes **Capture Question**, reusing the previous preview-only manual
workspace. Source selection and Close use the shared capture cancellation. Actual
system playback through the sheet produced954buffers, Apple Speech text, local
Qwen visible answer and DB row with unknown speaker; unrelated CV remained present
but visible/stored citations were0. ASR corrupted atomicity and the model did not
ask to clarify that term: path sample PASS, semantic limitation retained. UI/DB
inspection exposed stale question-provider metadata; both assignment sites now
honor frozen local mode. `local-manual-final-11` actual Qwen/DB test passed1 (5.642s),
including provider identity assertions. A second actual sheet playback in
bundle-final-11 produced838buffers, a local question/answer row and0 citations.
Its ASR lost atomicity; editing the captured question in the visible UI and sending
again produced an atomicity answer with0 citations. This is a new manual question,
separate from the versioned historical correction flow above. `manual-final-12`
passed17 (2.569s) after clearing the old manual card at new-request start; full/Smoke
immediately before that display-only reset are in `final-11-command-ledger.json`.
Canonical `build_and_run.sh --verify` and `release/verify_app.sh dist/Hireva.app`
passed in ad-hoc arm64 mode; final command logs/manifests remain in R2.

Manual recording now uses the same decision, frozen evidence, local-mode and
publication policies. New-operation opt-in creates a durable session without
backfilling temporary history. Retry/clear invalidate capture and generation;
Speech request revisions isolate callbacks/timeouts and resume cancelled waiters;
SCK stops late-started local streams. Synchronous history snapshots explicitly
carry their originating persistence ticket. These repairs have native regression
coverage; they are not substitutes for real Speech/SCK cancellation acceptance.

| System acceptance | Actual current-round evidence |
|---|---|
| System Audio Only | Synthetic say/afplay N1: system capture true, mic false; Apple Speech→Qwen→visible card→DB, speaker unknown. Path sample PASS, ASR misrecognized atomicity. |
| Microphone Only | N1:197 capture buffers, system capture false, no ASR/no answer. E2E FAIL/NOT VERIFIED. Builtin mic/lid-open read-only check did not establish cause. |
| Combined | N1: system leg produced one unknown-speaker answer/row. Real dual recognized echo/dedup NOT RUN; microphone leg unverified. |
| TTS echo/interrupt; permission denial | NOT RUN in actual capture. Existing granted permissions not reset. |
| Chinese voice / general code execution | Chinese ASR adapter/model NOT IMPLEMENTED/NOT RUN; Docker daemon unavailable, no host execution fallback. Chinese text tested separately. |
| Cancellation | Actual local request cancellation plus immediate next request N3 recorded; does not prove instantaneous GPU kernel termination. |
| B1→B2 performance / competing inference | NOT RUN at the requested last-voiced-sample definition or50+50 samples. p50+20%,p95+30% budgets unchanged. No original-enhancement performance claim. |
| Sanitizers | Cached independent AppKit ASan probe timed out; TSan aborted during runtime initialization before tests. BLOCKED, not sanitizer PASS. |
| URL brief / distribution | Reserved fake-IP DNS198.18.0.103 remains blocked by SSRF; no proxy/DNS changes. Ad-hoc developer preview; Developer ID/notarization NOT RUN. |

## Reuse and user workflow

Existing ZIPFoundation0.9.20,SwiftSoup2.13.9,FSRS4.1.0 and GRDB6.29.3 locks unchanged.
This continuation copied/ported no third-party source. Actual reuse is the existing
Ollama transport plus Apple NaturalLanguage, PDFKit/Vision/SQLite/audio frameworks.
Pinned Ollama v0.24.0 `c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0` (MIT) informed the
schema/cancel protocol adaptation. Semantic Router `6a8b7a0cd40613dee2e240f3e00d3e11430ffaa9`
(MIT) aggregation/tests reviewed, not used: no verified bilingual embedding.
Promptfoo `68ce0f7be992d85095190c37d5fb9c6eaa298b76` (MIT) script/assertion/telemetry
code reviewed, not used: native Swift evaluator suffices. Upstream source tests
were read, not executed; no Promptfoo install/telemetry. Full paths/URLs in existing
third-party notices and R2/research/research-summary.md.

In the canonical app: Documents→Import synthetic CV/JD→review source facts and
explicitly Confirm; Practice/Review→enter question→answer→Submit→targeted follow-up.
Sessions→select saved attempt→Edit history→correct text/speaker/question boundary→
Save revision→explicit Re-evaluate→inspect exact quote/version and updated recap.
An edited attempt stays assisted after feedback. Update stale review cards explicitly;
actual ratings remain. Use item Delete or Settings→Clear Local Data for test records.
Saving off creates temporary Practice; enabling it later does not authorize old work.
GUI evidence uses only isolated R2/gui-support, gui-home and gui-output. Final UI
regression uses a separate gui-final-support backup-API clone of synthetic records;
the globally cleared original gui-support remains empty.

---

# Prior enhancement acceptance — historical record

**Core acceptance is not complete.** Implemented paths and observed checks below
are separate from the required full GUI/audio workflow. This record describes
validation before Git submission and is not a release verdict.

## Workspace and evidence

- Branch `test/interview-workflows`; HEAD `005e06187d40bf11f6a0b3f4b4a19a325b411e61`.
  Initial local/origin main matched that commit and the worktree was clean.
- arm64 macOS 27.0 (26A428), Swift 6.1 command-line tools; existing Ollama 0.24.0
  and installed `qwen3.5:4b`. No model/toolchain/admin software installation.
- External local evidence directory:
  `/Users/delaynomore/Hireva-validation/enhancement-20260927-142952`.
  It contains baseline archive/diff/status, synthetic fixtures, command logs,
  model-format failures, evaluation results and a SQLite backup-API copy of the
  isolated GUI database (including committed WAL contents).
- Test bundle uses `gui-support/hireva.sqlite`, `gui-home`, and `gui-output` there.
  `lsof` confirmed the running test app's database. No real session was started or
  interrupted; real interview records were not used. One integration writer;
  read-only agents reviewed live ownership, workflows and dependency sources.
- During this validation run, no commit, push, PR, merge, Release upload or
  notarization was performed. Git submission was authorized separately afterward.

## Implemented paths and actual status

| Path | Current evidence / limit |
|---|---|
| Live routing/evidence/ownership | IMPLEMENTED; system architecture no longer defaults to debugging; introduction/improvement use direct answers; personal project-name rules removed. No-snapshot answers still pass personal-claim checks. Source-only ASR identity stays unknown. Unit/lifecycle regression passed. Real System Audio Only → Apple Speech → Qwen → visible answer → DB VERIFIED for three synthetic playbacks; first exposed CV constraint contamination, second verified its removal, third verified metadata-only logging with the final bundle. Microphone/combined modes and Chinese audio NOT RUN. |
| Materials/context | IMPLEMENTED; PDFKit text plus selective Vision OCR, bounded ZIPFoundation DOCX/XML, image originals, source hash/locations, indexing, reprocess/delete, automatic context and editable story drafts. Synthetic PDF/DOCX import and automatic context visibly VERIFIED in `.app`; native OCR and malformed/encrypted/archive tests passed. Image import, original preview and OCR warning visibly VERIFIED; story draft creation/save with blank results and separate persistence visibly VERIFIED. Model facts now keep exact source spans; generated location labels are excluded from facts. |
| Eight tasks / Practice | IMPLEMENTED; editable distinct rubrics, answer/feedback language, keyboard/mic/TTS state, pause/resume/retry, answer-before-reference, max two targeted follow-ups, exact quote validation, local Qwen only. Actual English, Chinese text and focused follow-up evaluations VERIFIED on the installed model. GUI answer → targeted follow-up → quoted feedback VERIFIED; general-question CV bias found in GUI, repaired and verified by reanswering the same question. Subjective narrative still needs human review. |
| Recap/review | IMPLEMENTED; all saved text units, question boundaries, unknown-speaker units not graded, exact source quotations, all practice attempts, explicit FSRS recall rating, export/delete. Repository/state/golden tests VERIFIED. GUI two-attempt recap, restart recovery, knowledge-card creation, reveal and explicit Good rating with due-date change VERIFIED. JSON export decoded successfully; repeated Markdown exports produced distinct files with identical recap content. GUI deletion NOT RUN. |
| SQL | IMPLEMENTED; separate in-memory SQLite, actual authorizer, function allowlist, one read-only statement, row/byte/VM/time limits. NULL, duplicate, JOIN/window, write/extension/ATTACH/PRAGMA and runaway-query tests VERIFIED. GUI LEFT JOIN execution returned Ada=20.0, Lin=NULL, Sam=NULL; DROP TABLE was rejected by authorization. Both result records survived restart. |
| Public URL brief | IMPLEMENTED; explicit one-page HTTPS fetch + robots, checked/pinned public IPv4, no redirects/cookies/proxy inheritance, bounded transfer and SwiftSoup parsing/cache. Parser/injection/URL-policy tests VERIFIED. Actual fetch BLOCKED: local DNS returned reserved fake IP `198.18.0.103` for example.com; the real Prepare UI displayed that failure; policy was not weakened. |
| General code execution | BLOCKED/UNAVAILABLE: Docker CLI exists but daemon was unavailable. Static review checklist only; no host execution fallback. |
| Chinese/mixed ASR, screen selection, search | NOT IMPLEMENTED/NOT RUN in this change. Existing Parakeet/Apple Speech preserved; no Chinese model download, no WhisperKit adapter, no search credentials used. Chinese text verification is not Chinese voice verification. |
| Package | Canonical `.app`, existing Bundle ID/signing/runtime logic retained. Ad-hoc developer preview only; Developer ID/notarization/clean-Mac distribution NOT RUN. Canonical final launch and verification command details below. |

Observed GUI sequence: synthetic CV PDF → page/source/index status → synthetic JD
DOCX → automatic candidate/role context → typed main answer → real local Qwen
feedback with exact answer citations → targeted bottleneck follow-up → two-attempt
recap → canonical restart and recovery. The first follow-up incorrectly demanded
personal experience despite `requiresPersonalEvidence=false`. The failure remains
in the synthetic history; generic evaluation now omits irrelevant CV facts and
explicitly prohibits this requirement. Reanswering the same question in the rebuilt
app covered the bottleneck criterion and correctly marked the new attempt assisted.
A separate coding practice imported `synthetic-code.png`, displayed original/OCR
text and warnings, evaluated a real typed answer, and saved a knowledge card.
Reveal → explicit Good changed its due time from 16:30 to 16:41. OCR lost code
indentation, as warned. These observations are not voice or general model-quality
verification. Prepare UI initially caused CUA native-pipe failures while the application remained
alive (main thread sampled in its run loop). Replacing the three GroupBox containers
with ordinary native VStack/material containers restored visible controls in this
configuration; this does not establish a general SwiftUI framework bug. SQL execution,
rejection, URL error, JSON export and two unique Markdown exports were then observed.
Story creation displayed actual project source text, left result/reflection blank,
and saved to preparation_records separately from CandidateProfile facts.

## Reproductions and repairs

| Failure or risk | Repair / regression |
|---|---|
| Architecture routed to debugging; introduction/improvement forced into STAR | `IntentRouter`, prompt/alignment policies; `WorkflowSafetyTests` plus existing dialogue/relevance suites. |
| Inferred edits/notes treated as usable facts; nil snapshot skipped claim checking | `ProfileEvidence`, context repositories and both live publication validators; explicit confirm action, source-deletion and unsupported-condition tests. |
| Repeated start / deleting unrelated session cancelled shared live generation | Check start eligibility before cancellation; recap owns separate task/session; focused no-cancellation regression. |
| Late writes after deletion or privacy off→on | Revocable persistence tickets; ephemeral Practice remains non-persistent after reenabling history; preparation/recap save boundaries checked. |
| Full practice resume persisted cancelled; replacement material allowed an unprompted redo | Restore invalidates tasks without cancelling the restored row; same-question feedback makes later attempts assisted; per-attempt task/material/hash/revision frozen and tested. |
| Follow-up regraded the whole main rubric / generic question demanded a personal story | Freeze the targeted criterion; omit irrelevant CV facts from generic evaluation and use an explicit evidence policy. Installed-model regression plus same-answer GUI replay passed. |
| New Question relabelled completed runs cancelled | Preserve completed state when invalidating old work; repository regression checks the previous run remains completed. |
| JSON save panel stayed disabled; Markdown practice IDs shared a filename prefix | Reuse existing local Exports directory and reveal workflow; fresh UUID filenames for both formats. JSON readback and two non-overwriting Markdown exports verified. |
| Live general question imported unrelated CV formula as a five-second retry limit | PromptContextBuilder gates profile summaries/chunks for general tasks (including unclassified generic questions); Qwen retries reuse the frozen filtered background, citations use actual included chunks; non-Qwen personal-template fallback follows the same gate. Same-intent independent questions exclude old constraints. Focused regressions and synthetic audio replay passed. |
| Verification-only event writer ignored Diagnostic Off/Metadata settings | Gate events using existing effectiveDiagnosticTraceMode; Off emits no events, metadata uses an allowlist, full text requires explicit opt-in and saving permission. Unit regression and real synthetic audio canary check passed. Earlier raw synthetic event logs retained outside the repo. |
| DOCX location label became a role responsibility; model paraphrase could drop qualifiers | StructuredEvidenceExtractor and automatic extraction exclude exact generated location labels; accepted model facts retain their exact source span. Tests cover location metadata and units/plan/simulation/negation preservation. |
| Long recap dropped later text; model could invent source quotes | Bounded all-unit processing, exact segment/quote/speaker checks; tail canary and forged/wrong-unit/unknown-speaker regressions. |
| Complementary personal work/experience comparison fell through after removing candidate-name rules | `IntentRouter` now uses comparison relation plus repeated personal-work references; original RuntimeSmoke fixture/expectations retained and a non-robotics regression added. |
| Qwen ignored nested JSON schema / emitted string null | Flat string-only wire fields with explicit empty gaps, strict key/rubric/quote decoding, at most one format repair. No regex reconstruction or missing-field invention. Failure logs retained. |

Model-quality disagreement: the first follow-up fixture covered reliable delivery
but omitted trade-offs, while the initial human expectation marked the composite
criterion complete. The model called it missing. That failed run is retained in
`local-practice-9.log`; a separately expanded synthetic answer explicitly discussing
contention/storage/consistency trade-offs passed in `local-practice-10.log`.
Neither result establishes agreement with human interview grading.

## Reuse and sources

- **Dependency:** [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/0.9.20) (`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, MIT),
  `Archive+Reading.swift`/`Entry.swift`; actual DOCX import calls Archive consumer
  extraction, compares CRC and enforces size/path/entity limits. It replaces the
  unsupported manual-conversion path; no custom ZIP decoder was written.
- **Dependency:** [SwiftSoup 2.13.9](https://github.com/scinfu/SwiftSoup/tree/2.13.9) (`18b80329749eca5ea29fc50211dca5c7eff5bfec`, MIT with
  jsoup/SwiftSoup notices), `Sources/SwiftSoup.swift`; actual preparation page
  parsing uses DOM selectors, not a regex HTML parser.
- **Dependency:** [swift-fsrs 4.1.0](https://github.com/open-spaced-repetition/swift-fsrs/tree/4.1.0) (`1d3cd7a4e72b210b31ca47c23efe4b464673bb54`, MIT),
  `Sources/FSRS/FSRS.swift`; `PracticeController.rate` persists returned Card and
  ReviewLog. **Adapted test:** upstream `Tests/FSRSTests/FSRSTests.swift` 13-step
  interval golden vector and weights, with copyright attribution. This is adapter
  compatibility evidence, not an independent learning-effect evaluation.
- Existing GRDB 6.29.3, SQLite, PDFKit, Vision, Foundation XMLParser, audio capture
  and Ollama transport were reused. Existing working implementations were not
  replaced merely to add dependencies. Exact notices are merged into the existing
  [notice inventory](third-party-licenses.md) and canonical bundle script.
- WhisperKit/Argmax v1.1.0 (`1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`, MIT) source/API
  reviewed; separate tokenizer/model networking and model licenses were not fully
  verified. Not installed or reported as an integrated ASR path. FSRS v5 internal
  API prevented direct application use; v4 public API was selected.
- Official references: [SQLite authorizer](https://www.sqlite.org/c3ref/set_authorizer.html),
  [progress handler](https://www.sqlite.org/c3ref/progress_handler.html),
  [Vision cancellation](https://developer.apple.com/documentation/vision/vnrequest/cancel()),
  [DOCX numbering properties](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.numberingproperties),
  [CoreAudio active output processes](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunningoutput),
  [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs).
  [Ollama issue 14645](https://github.com/ollama/ollama/issues/14645) was a diagnostic
  reference for format behavior, not copied code or proof of this local bug's cause.
- Listed business-agent repositories were NOT REVIEWED/NOT REUSED; no Java/web/
  multi-agent framework was introduced. Native state machines extend existing
  Hireva responsibilities. Markdown renderer retained.

## Commands and verification

Logs named below are in the external evidence directory. Counts are this run,
not inherited historical reports. `swift test` skips opt-in real model/network
checks unless their environment flags are set.

| Command / log | Exit / result |
|---|---|
| `swift build` — `baseline-build.log` | 0; baseline build, 12.85 s |
| `swift test` — `baseline-tests.log` | 0; 753 tests, 55.740 s |
| `swift test` — `full-tests-final-12.log` | 0; 792 tests, 54.429 s; full text-routing metric below is not a pass |
| `HIREVA_RUN_LOCAL_PRACTICE=1 HIREVA_TEST_ARTIFACT_DIR=…/fixtures swift test --filter 'PracticeLocalIntegrationTests\|PracticeWorkflowTests'` — `local-practice-11.log` | 0; 8 tests, 29.641 s; actual four Qwen requests plus deterministic state/FSRS checks; artifacts in `gui-regression-model` |
| `HIREVA_RUN_PUBLIC_FETCH=1 … swift test --filter PracticalToolsTests` — `core-tests-4.log` | 1; reserved-address DNS policy blocked real transport; earlier tests passed |
| `scripts/runtime_smoke.sh --suite all` — `runtime-smoke-final-4.log` | 0; 12 tests, 30.372 s, including the original 64-question gate |
| `swift test --filter VerificationBootstrapTests` — `verification-privacy-regression.log` | 0; 7 tests, 0.040 s |
| `swift test --filter AutomaticInterviewContextTests` — `source-label-regression-3.log` | 0; 17 tests, 0.343 s |
| `script/build_and_run.sh --verify` with isolated environment below — `canonical-final-5.log` | 0; native bundle launched; observed Ready, then real synthetic audio generation and Stop |
| `HIREVA_SIGNING_MODE=adhoc HIREVA_BUILD_ARCHS=arm64 script/release/verify_app.sh dist/Hireva.app` — `package-final-5.log` | 0; ad-hoc bundle/helpers/libraries validated. Seven notice files, three new dependency license hashes match resolved source; no bundled DB/model/audio files; Bundle ID and minimum macOS 14.0 unchanged (`bundle-content-audit-final.json`). |
| `swift test --scratch-path …/asan-build --sanitize address …` — `asan-final.log` | 1; package-cache resolution failed before sanitizer execution; not a memory-safety verdict |

Additional sanitizer evidence: `asan-existing-cache.log` compiled successfully
using the resolved checkout cache, then blocked before Swift Testing startup.
`asan-helper-sample.txt` shows ASan allocator initialization recursing into a
StaticSpinMutex. The owned helper/test process was terminated (exit 143).
`swift test --sanitize thread --disable-automatic-resolution --filter
'WorkflowSafetyTests|PracticeWorkflowTests|PracticalToolsTests'` compiled, then
exited 1 / signal 11 in native ColorSync/TSan initialization (`tsan-final.log`,
`tsan-runtime-crash.ips`). Both sanitizer execution gates remain unverified; no
memory/race PASS or application defect conclusion is inferred from startup failure.
The toolchain was not changed. A separate two-line AppKit probe compiled with each sanitizer reproduced ASan startup timeout and TSan interceptor abort outside Hireva (`sanitizer-probe-results.json`, `probe-thread.log`).

The canonical launch uses `HIREVA_VERIFICATION_MODE=1`, a synthetic manual-UI
scenario, the external app-support/output/home directories, and the existing
local model root, followed by `script/build_and_run.sh --verify`. No TCC reset.
The aggregate `verify_runtime_stability.sh` was not run unchanged because it
hardcodes the normal user database path; its relevant component checks were used
with isolated launch configuration instead.

Migration checks open populated synthetic v16 databases, upgrade through current
migrations, reopen, and preserve legacy session/document data. A deliberately
failing GRDB migration rolls back and subsequently recovers. New-empty-db tests
are not counted as upgrade coverage. The canonical synthetic GUI database was
backed up with SQLite backup API before rebuilding. An expanded canary scan initially FAILED: the verification-only writer retained
synthetic question/answer text even with Diagnostic Off (11 matches across two
saved audio logs). This was fixed in `HirevaVerificationEventPolicy`; the final
real audio run in Metadata only mode retained stage/ownership events with zero
canary matches and no text/question/answer fields (`gui-log-canary-after-fix.json`).
Off/full-text/privacy-off policies also have unit coverage. Earlier synthetic raw
logs are preserved only in the external validation directory. This does not audit
all OS/provider logs.

## Quality, performance and remaining limits

- Fixed independent 102-question set: **36/102 task classifications, 58/102 personal
  evidence flags, 44 false-negative evidence flags**. Quality status is
  `LIMITED_HEURISTIC_WITH_MISSES`, not PASS. Do not tune individual fixture phrases
  or treat test-suite success as classification correctness. Practice explicit
  task selection bypasses automatic task guessing; output claim checks remain
  necessary and heuristic.
- Predeclared live latency regression budget: p50 +20%, p95 +30% on the same device,
  model and material. **NOT MEASURED** before/after: no audio-end timestamp samples
  were obtained, so no audio→visible or audio→DB percentile, cold/warm comparison,
  GPU contention or real cancellation-latency verdict is available. Two diagnostic
  samples from generation start (not audio end): before token/visible/DB =
  1460/3504/3552 ms; after = 1169/2757/2818 ms. N=1 per version, different ASR text
  and rebuilt context snapshots; these cannot establish p50/p95 or budget compliance.
  `live-generic-result-check.json` also verifies zero profile chunks/citations after
  the fix and separate session/question/generation/snapshot ownership. Qwen evaluation
  test durations are not live TTFT or end-to-end latency.
- Real System Audio Only with Apple Speech was exercised three times using a locally
  generated 5.961-second English AIFF, with no other active output process detected
  by a CoreAudio metadata-only preflight. The second ASR result misheard "retry" as
  "retrieve"; this is not an ASR accuracy pass. Microphone/combined capture, permission
  refusal, real TTS echo and Chinese/mixed speech remain NOT RUN. Text Practice/recap/review/restart and
  image import were observed in the actual bundle as described above.
- DOCX exact numbering/layout/tracked changes and OCR code indentation/formula/
  diagram interpretation are not certified. Original review is required. Current
  document source hashes/originals and immutable evidence snapshots are retained;
  a full original-document version browser is not implemented.
- Personal/team ownership and experiment conditions still rely substantially on
  source spans rather than a complete structured correction workflow. Sources are
  not independent fact verification. Historical live transcription correction and
  versioned re-evaluation UI is incomplete. No hiring/personality probability claim.
- DNS fake-IP environment, unavailable container daemon and absent verified
  Chinese ASR model are explicit blockers; none was bypassed. The earlier lock
  screen cleared; the Prepare-page CUA failure was reproduced and resolved by the local view-container
  change described above; it was not treated as proof of an application crash.

## Capabilities used

`build-macos-apps:build-run-debug` skill and the canonical build script preserve
native bundle identity. Swift/SPM and Swift Testing build/test actual dependencies;
SQLite/GRDB exercises storage and constrained SQL; PDFKit/Vision exercise native
extraction. Official web/GitHub sources validate APIs/licenses. CUA inspected and
operated the real `.app`; it reported the lock-screen blocker. A small external
CoreAudio metadata probe checked active playback; system `say`/`afplay` generated and
played synthetic English speech without downloading a model. Shell/git were used
for read-only state, local edits, backups and validation, not publication.
