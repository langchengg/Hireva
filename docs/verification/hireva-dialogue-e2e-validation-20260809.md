# Hireva Dialogue End-to-End Release Validation

## Summary

- Validation base: `03524688f8ddeb3bf5997751469afd25e75bdfe4`.
- Validated code commit: `4212186` (`test: allow sanitizer stage b scheduling headroom`). The containing documentation commit does not change executable or test code.
- Validation branch: `codex/hireva-dialogue-e2e-hardening-20260809`.
- Scope: Swift build and tests, ThreadSanitizer, AddressSanitizer, RuntimeSmoke, real `dist/Hireva.app`, ScreenCaptureKit, Parakeet, Apple Speech, local Qwen, context/RAG, alignment, UI visibility, SQLite persistence, privacy, restart/recovery, signing, and package inspection.
- External resources checked: none were required. This validation is based on the local repository, installed runtimes, built app, generated databases, process state, and captured logs. No external code was copied or adapted.
- Capabilities used: local `git`, `swift`, `jq`, `sqlite3`, `codesign`, `spctl`, `zipinfo`, `ditto`, `shasum`, `open`, `say`, `afplay`, and `ollama`; repository build, smoke, signing, database, release, and packaging scripts. No plugin, subagent, Accessibility API, remote model, or write-capable external connector was used.

## Git Safety

- Immutable recovery references were created before integration: branch `backup/dialogue-e2e-base-20260809` and annotated tag `backup-dialogue-e2e-base-20260809`.
- The preflight status, complete diff, diff stat, untracked-file list, patch, and untracked-file copy are under `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e-preflight`.
- Existing release-hardening work was preserved. Codex changes were integrated as separate commits rather than replacing the starting worktree.
- Concurrent writer activity was stopped before integration. Potential duplicate or overlapping edits were resolved from tests, invariants, and implementation behavior rather than modification time.
- No reset, clean, destructive checkout, main merge, main push, force push, or backup-ref modification was performed.
- The pre-existing untracked `scripts/__pycache__/` remains untouched and is the only expected non-committed worktree item.

## Baseline Reproduction

- The task continued from the supplied worktree and commit instead of restarting from a clean checkout.
- The baseline sanitizer runs reproduced timing-sensitive failures in timeout, supersession, and Stage B lifecycle tests.
- No baseline failure was accepted as a sanitizer defect without a sanitizer diagnostic. The final fixes separate real behavior contracts from test scheduler headroom.
- The original release-hardening changes, this validation's changes, and possible concurrent overlap were recorded in the preflight snapshot before any single-thread integration work.

## Sanitizer Fixes

- Timeout tests now use deterministic clocks or explicit lifecycle waits where wall-clock scheduling was not the behavior under test.
- Rapid-follow-up expectations now reflect the product invariant: the older generation receives a local superseded audit snapshot, while only the newest provider answer may become visible.
- Debug fallback prompts retain project evidence instead of losing grounded context.
- Speaker-attribution tests wait for Stage B registration and terminal lifecycle completion; sanitizer scheduling headroom is 90 seconds without relaxing production deadlines.
- Local Qwen recovery prompts now require a grounded prospective support preference for support questions and a grounded development area for weakness questions. Unsafe or unaligned output is still rejected.
- Final TSan: 753/753 tests, exit 0, no ThreadSanitizer diagnostic. Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_full_tsan.log`.
- Final ASan: 753/753 tests, exit 0, no AddressSanitizer diagnostic. Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/full_asan_after_speaker_registration_90s.log`.

## Dialogue Test Matrix

- The deterministic fixture contains exactly 128 turns across 24 sessions, 3 candidate profiles, and 3 opportunities.
- It covers question detection, negative/non-question turns, context ownership, RAG evidence, alignment, intentional repeats, rapid follow-up supersession, stop/start, profile switching, failure recovery, and persistence identity.
- Focused scenario matrix: 4/4 passed.
- Related existing dialogue suites: 98/98 passed.
- Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/dialogue_scenarios_focused_round4.log` and `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/dialogue_related_tests.log`.

## Automated Dialogue Results

- All 128 fixture turns completed with the expected positive/negative classification and session/profile/opportunity ownership.
- Local Qwen alignment, stale-callback rejection, cross-profile rejection, Stage B cancellation, intentional-repeat identity, and supersession contracts passed focused regression coverage.
- Support and weakness recovery defects found by real dialogue runs were reproduced with red tests before production prompt fixes. The final Ollama/Qwen suite passed 23/23.
- Each conflict or behavior correction received regression coverage before the next issue was addressed.

## Real ScreenCaptureKit Verification

- The signed local `dist/Hireva.app` was exercised through real ScreenCaptureKit audio capture; Accessibility was not used.
- Parakeet run: 8 app sessions, 8 first ScreenCaptureKit buffers, and 40 real utterance transcripts.
- Apple Speech run: 9 app sessions, 9 first ScreenCaptureKit buffers, and 9 real utterance transcripts.
- The observed chain was ScreenCaptureKit -> ASR -> transcript -> accepted question -> context/RAG -> local Qwen -> alignment -> visible suggestion -> SQLite.
- Deep `codesign --strict` verification passed for the app, helper, and embedded dylibs. The app is ad-hoc signed, has no TeamIdentifier, and is correctly rejected by Gatekeeper as a public distribution artifact.
- Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_app_build_verify.log`.

## Real Interview Conversation Results

- Parakeet 8x40: 40 transcripts, 32 accepted questions, 32 Qwen generations, 32 aligned visible suggestions, 8 negative turns, 0 false triggers, 0 missing evidence needles, 0 invalid visible answers, and 0 remaining app/helper processes.
- Apple Speech 9x9: 9 transcripts, 7 accepted questions, 7 Qwen generations, 7 aligned visible suggestions, 2 negative turns, 0 false triggers, and 0 remaining app/helper processes.
- Intentional repeat: three repeated real utterances produced three visible answers with three distinct question IDs and three distinct generation IDs.
- Actual-overlap rapid follow-up: three strict qualifying groups passed. Each had two transcripts/questions/generations, zero visible output from the older generation, one visible output from the newest generation, and one rapid cancellation. One additional attempt did not qualify because the required visible needle was absent and was not counted as a pass.
- The earlier sequential-audio scenario was not counted as rapid supersession because its first generation could finish before the second transcript. The final gate separates ordinary 8x40 visibility from a dedicated overlap test.
- Evidence roots: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final-4212186-parakeet-8x40-v15`, `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final-4212186-apple-speech-9x9`, `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final-4212186-intentional-repeat-3x`, and `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final-4212186-rapid-growth-3x`.

## Voice And ASR Results

- Parakeet processed the required 40 real utterances over 8 independent app sessions using the packaged local helper/runtime.
- Apple Speech provided an independent 9-utterance route through the same downstream detection, Qwen, alignment, UI, and persistence pipeline.
- Focused Parakeet recovery coverage passed for invalid helper health responses, bounded writer behavior, immediate stop, real streaming, stdout EOF, a helper ignoring termination, and timeout/reap cleanup.
- Parakeet helper controlled-crash and malformed-output behavior were validated through deterministic recovery tests. Real process restarts additionally confirmed no leaked app/helper processes.
- Bluetooth input/output route switching was not exercised and remains an explicit residual risk.

## Latency

- Parakeet first token p50/p95/max: 1599/1685/1691 ms.
- Parakeet first visible p50/p95/max: 3094/7677/7813 ms.
- Parakeet SQLite persistence p50/p95/max: 3146/7715/7863 ms.
- Apple Speech first token p50/p95/max: 1539/1585/1585 ms.
- Apple Speech first visible p50/p95/max: 2948/3680/3680 ms.
- Apple Speech SQLite persistence p50/p95/max: 2986/3732/3732 ms.
- Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_db_latency_summary.txt`.

## Restart And Failure Recovery

- Ten stop/start plus ten quit/reopen cycles completed with 10/10 ready states, local Parakeet selected, and zero app/helper processes after each iteration.
- Capture recovery tests passed 10/10, including immediate restart, termination, stop during active generation, and stream-capture failure.
- ASR hardening regressions passed 7/7; native Parakeet runtime tests passed 11/11; Ollama streaming transport regressions passed 8/8.
- Profile switch cancellation, cross-profile late-callback rejection, active Stage B cancellation without provider persistence, and intentional repeat behavior passed focused tests.
- Ollama cancellation and HTTP failure recovery were validated in deterministic transport tests. Stop while Qwen was active and immediate start after stop were covered by focused runtime lifecycle tests.
- Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_restart_loop.log` and the `final_recovery_*.log` files in the verification root.

## Database And Privacy

- Parakeet database integrity: 8 sessions, 40 transcripts, 32 accepted questions/cards, 32 distinct question IDs, 32 distinct generation IDs, 93 RAG links, and 8 context snapshots.
- Apple database integrity: 9 sessions, 9 transcripts, 7 accepted questions/cards, 7 distinct question IDs, 7 distinct generation IDs, 20 RAG links, and 9 context snapshots.
- Ownership gaps, question/prompt mismatches, duplicate generation IDs, SQLite lock errors, and invalid visible events were all zero.
- Rapid supersession stores one local superseded audit snapshot and one completed latest Qwen card. It does not persist or show a stale provider answer.
- Privacy trace tests passed 5/5 and privacy integration passed 1/1. Trace-off created no file; metadata contained no raw canary; explicit full-text mode contained exactly the one expected synthetic canary; the synthetic fake API key appeared in zero files.
- Package inspection found 0 databases, traces, audio files, runtime logs, model directories, build/Git directories, common API-key patterns, or privacy UUID leaks.
- The final ZIP contains 35 allowlisted entries and passed extracted-app deep signature verification. SHA-256: `ff48e178ca8ba6c88b470f9a19bf5441ba36853cee2e92aa99a0d975ca95a936`.
- All generated dialogue databases and privacy data are under the dedicated verification root. One initial read-only `release_status.sh` invocation followed its default HOME and summarized five non-text metadata rows from the existing Hireva database; it did not modify data or print transcript/answer text. The final recorded invocation was immediately rerun with the dedicated validation HOME and overwrote that log.
- Evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_privacy_summary.log`, `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_package_scan_summary.log`, and `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_db_diagnostics.log`.

## Automated Tests

- Three consecutive final full suites passed 753/753 at validated code commit `4212186`.
- Final RuntimeSmoke passed 12/12.
- Final Runtime Stability Gate passed Swift build, full Swift test, RuntimeSmoke, deep signature verification, and real app launch. The packaging command repeated the release gate and returned 0.
- Final TSan and ASan each passed the full 753-test suite with no sanitizer diagnostic.
- Full suite evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_full_suite_round1.log`, `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_full_suite_round2.log`, and `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_full_suite_round3.log`.
- Gate evidence: `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_runtime_smoke.log`, `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_runtime_stability.log`, and `$HIREVA_VERIFICATION_ROOT/20260809-225914-dialogue-e2e/final_4212186_package_local_release.log`.

## Remaining Risks

- No Developer ID Application identity is installed, `HIREVA_SIGNING_IDENTITY` is unset, the app is ad-hoc signed, notarization was not performed, and Gatekeeper rejects the artifact. It is not ready for public distribution.
- Bluetooth route switching and Bluetooth-device failure recovery were not exercised in this environment.
- Real process-level fault injection was not used for every recovery mode. Controlled helper crash, malformed helper output, Ollama cancellation/HTTP failure, profile switch, and stop-during-Qwen are supported by deterministic focused tests plus separate real app restart/leak checks.
- Rapid follow-up timing depends on actual overlap. The strict result is based only on qualifying overlap runs; the non-qualifying attempt is retained in the artifacts rather than hidden.
- Superseded generations intentionally retain a local audit snapshot. This is not a stale provider answer, but operators should preserve that distinction in future persistence/privacy changes.

## Final Verdict

- Parakeet + Qwen Controlled-Use: **GO**.
- Apple Speech + Qwen Controlled-Use: **GO**.
- Overall Local Controlled-Use: **GO**.
- Public Distribution: **NO-GO**.

The local controlled-use configurations meet the tested release gate at code commit `4212186`. Public distribution remains blocked until Developer ID signing, notarization, and Gatekeeper acceptance are completed; Bluetooth route validation should also be added before claiming coverage for that hardware path.
