# Hireva 24-Hour Continuous Interview Quality, Reliability and Release Campaign

## Executive Summary

- Campaign: `hireva-24h-20260831T152152Z`
- UTC wall span: 2026-08-31 15:21:52 to 2026-09-02 01:12:57.
- Counted active execution: 88,305 seconds (`24:31:45`), above the 86,400-second target. Manual investigation and inactive interruption time were conservatively excluded.
- Duration result: the full 24-hour active-duration requirement was reached. The final status is `completed_with_failures`, not an unconditional release pass.
- Verified core result: the isolated System Audio + local Parakeet + local Qwen configuration passed a real `Hireva.app` matrix of 16 sessions and 128 synthetic audio turns, with 80/80 expected questions accepted, 48/48 non-questions rejected, 80 aligned visible/persisted answers, and zero observed false trigger, stale visible answer, unsupported claim, duplicate question group, identity mismatch, source/speaker mismatch, SQLite integrity failure, or residual app/helper process.
- Automated result: 903 tests passed three consecutive ordinary runs, then passed full TSan and ASan runs; RuntimeSmoke passed 12/12; the complete stability gate passed.
- Answer result: deterministic semantic alignment was 781/800 (`97.625%`), deterministic grounding was 800/800, and real-audio final visible answers were aligned and candidate-grounded 80/80. This is not a claim that every possible interview answer is correct.
- Defects: 30 recorded defects were fixed and verified. Two campaign-evidence gaps remain open: H24-0035 (the long soak was automated test rotation, not a continuous real-app interview/resource soak) and H24-0036 (incomplete per-answer, WER, and separated latency telemetry).
- Primary risk: the campaign does not provide longitudinal real-app RSS/open-file/disk evidence or complete provider-only/direct-ASR/first-token metrics. This blocks an Overall Local GO even though the tested System Audio + Parakeet + Qwen slice is suitable for controlled synthetic use.
- Capabilities used: repository scripts, Swift Package Manager, Swift Testing, real bundled `Hireva.app`, ScreenCaptureKit, local Parakeet/sherpa-onnx/ONNX Runtime, local Ollama Qwen, GRDB/SQLite, macOS `say`/audio playback, Git, `jq`, `curl`, GitHub/official documentation research, sanitizers, and code-signing diagnostics. No write-capable external connector, optional plugin, subagent, real third-party interview recording, or private CV was used.
- Reuse decision: 112 external sources informed behavior and design; `codeCopied=true` is zero. External implementations were reference-only, with license checks recorded before independent Hireva-specific fixes.

## Git Safety

- Base commit: `6ad205f235c0f5825eec3e2d175f2a81489839e7`.
- Backup branch: `backup/hireva-pre-24h-20260831-161121`.
- Backup tag: `backup-hireva-pre-24h-20260831-161121`.
- Working branch: `codex/hireva-24h-continuous-validation-20260831-161121`.
- Last verified code commit before this report: `6f01307249e1ba254d829926e5adf500c7525814`.
- Push status: ordinary, non-force pushes succeeded through `6f01307`; the report commit is also pushed before final handoff.
- Main status: local `main` and `origin/main` both remained at `005e06187d40bf11f6a0b3f4b4a19a325b411e61`. No main merge, reset, force-push, or destructive cleanup was performed.
- Generated databases, traces, audio, logs, models, and result JSONL remain outside the repository under the campaign artifact root.

## Campaign Timeline

The active durations below are derived from persisted checkpoints. They exclude manual research/engineering time and inactive interruption time.

| Phase | Active Duration | Main Work | Result |
|---|---:|---|---|
| Baseline discovery and gates | 00:23:37 | Resolve/build, initial full suite, RuntimeSmoke, stability, TSan, ASan, `.app` verification | Six historical gate records failed and entered triage; all underlying defects were later fixed |
| Research, regression construction, fixes, corpus, real audio | 01:24:45 | 112-source research log, 1,280-turn corpus, question/grounding fixes, real `.app` audio matrix, SQLite tie-out | 16 roles and 128 real system-audio turns passed after fail-first repair cycles |
| Automated soak and periodic gates | 22:11:45 | 8 focused suites rotated over 8,220 cycles; `.app` verification every 20 cycles; full stability every 100 cycles | All resumed cycles passed; this was not the specified continuous real-app interview/resource soak (H24-0035) |
| Final gates and terminal reporting | 00:31:38 | Three full suites, TSan, ASan, RuntimeSmoke, stability, app, DB, release, signing, report reconciliation | Correctness gates passed; signing remained ad hoc; reporting-order defect H24-0034 was fixed afterward |
| **Total counted active execution** | **24:31:45** | 72 persisted checkpoints, one recorded interruption, three resumes | **24-hour duration reached; 30 fixed defects; 2 evidence gaps open** |

## Online And GitHub Research

The research ledger contains 112 entries: 73 official sources, 31 repository sources, and 8 issue reports. Issue reports were used only as hypotheses. No external code was copied.

| Problem | Official Source | GitHub Cases | Applied Finding | License Check |
|---|---|---|---|---|
| GRDB resource packaging | [Apple bundle structure](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html), [Apple privacy manifests](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk) | [SwiftPM resource accessor](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift), [GRDB manifest commit](https://github.com/groue/GRDB.swift/commit/1920482158af699c6b3a55860b7697f91a318bf8) | Preserve the privacy resource in `Contents/Resources` and distinguish a linked generated accessor from a live call | Apple reference-only; SwiftPM Apache-2.0; GRDB MIT; no code copied |
| TSan isolation and shared test state | [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/), [Apple TestScoping](https://developer.apple.com/documentation/testing/testscoping) | [Swift Testing parallelization](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Traits/ParallelizationTrait.swift), [SwiftNIO synchronized storage](https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/AsyncSequences/NIOThrowingAsyncSequenceProducer.swift) | Protect mutable mock state and serialize only suites sharing process-global resources | Swift/SwiftNIO Apache-2.0 variants; reference-only |
| Interview question forms | [NSRegularExpression](https://developer.apple.com/documentation/foundation/nsregularexpression), [Cambridge question tags](https://dictionary.cambridge.org/grammar/british-grammar/tags), [Switchboard dialogue acts](https://web.stanford.edu/~jurafsky/ws97/manual.august1.html) | [dria imperative categorization](https://github.com/CelestialBrain/dria/commit/99634ff30bc2c573ffb187e821e4f266951f8304) | Add bounded imperative, long-WH, confirmation-tag, and logistics handling without promoting narrative statements | Apple/academic facts paraphrased; dria MIT; no code copied |
| ScreenCaptureKit lifecycle | [SCStream stop](https://developer.apple.com/documentation/screencapturekit/scstream/stopcapture%28completionhandler%3A%29), [Apple capture flow](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) | [LiveKit capturer](https://github.com/livekit/client-sdk-swift/blob/ae75761885333369863897873f248a7cbc830190/Sources/LiveKit/Track/Capturers/MacOSScreenCapturer.swift), [Omi stream engine](https://github.com/BasedHardware/omi/blob/62713e0536eb180b01e69df88e91a75e6c72c2ee/desktop/macos/Desktop/Sources/WindowCaptureStreamEngine.swift) | Await probe teardown before starting the next production stream | Apache-2.0 and MIT; design comparison only |
| Helper termination | [Foundation Process wait](https://developer.apple.com/documentation/foundation/process/waituntilexit()) | [swift-corelibs-foundation Process](https://github.com/swiftlang/swift-corelibs-foundation/blob/761b621da93a856a48995efc29ed11028c283306/Sources/Foundation/Process.swift), [swift-subprocess teardown](https://github.com/swiftlang/swift-subprocess/blob/47d0c80f8a0c4e837c8d9d24dd73d11c792461c2/Sources/Subprocess/Teardown.swift), [Applite teardown](https://github.com/milanvarady/Applite/blob/9f7897cdebb332009b0d8eff92cb1d2fa080dcf0/Applite/Core/Brew/Shell.swift) | Separate signaling from observed completion and keep shutdown bounded; remove unbounded cooperative-path `waitUntilExit` | Apache-2.0/MIT; no code copied |
| Ollama/Qwen stream and grounded recovery | [Ollama streaming](https://docs.ollama.com/api/streaming), [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs), [Qwen model card](https://huggingface.co/Qwen/Qwen3.5-4B) | [ollama-swift](https://github.com/mattt/ollama-swift/blob/63a8891509399450322b19786b129024b612bcf3/Sources/Ollama/Client.swift), [OllamaKit](https://github.com/kevinhermawan/OllamaKit/blob/fcf8b3a19eef60a06e83b4b32f093aec025df977/Sources/OllamaKit/Utils/OKHTTPClient.swift), Ollama EOF issues 10015/17118/17836 | Require a terminal stream contract; use a bounded structured failure/debugging recovery with candidate-only exact evidence and existing validators | Ollama/clients MIT; Qwen Apache-2.0; issues hypothesis-only; no code copied |
| ASR lexical substitution | [Apple SFTranscription](https://developer.apple.com/documentation/speech/sftranscription), [NVIDIA Parakeet model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | [VoiceInk filter](https://github.com/Beingpax/VoiceInk/blob/16b61ac35e46dda3944a6fa982a3c564f2e3ec81/VoiceInk/Features/Recording/Processing/TranscriptionOutputFilter.swift), [Megaphone tidier](https://github.com/Kuberwastaken/megaphone/blob/360aa1532049379f8db1951c882b88ad7f6a7e8f/Sources/TranscriptTidier.swift) | Recover only an already-valid question after a bounded leading-noise boundary; retain raw transcript provenance | Parakeet CC-BY-4.0; VoiceInk GPL-3.0 explicitly incompatible and not copied; Megaphone MIT reference-only |
| Async test synchronization | [Swift Testing parallelization](https://developer.apple.com/documentation/Testing/Parallelization), [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) | [Swift Testing confirmation](https://github.com/swiftlang/swift-testing/blob/1dea52cdf305f7a8f33d5b3c6adc14dfacb5b004/Sources/Testing/Issues/Confirmation.swift), [issue 978](https://github.com/swiftlang/swift-testing/issues/978) | Await exact question-specific events and task results instead of generic prefixes or sleeps | Apache-2.0 with runtime exception; no code copied |
| Process paths containing spaces | [Apple Darwin ps](https://github.com/apple-oss-distributions/adv_cmds/blob/6bed8737a34dbb54782a18f47dccf933a9967a12/ps/ps.1), [GNU Bash read](https://www.gnu.org/software/bash/manual/bash.html#Bash-Builtins) | [Darwin pgrep/pkill](https://github.com/apple-oss-distributions/adv_cmds/blob/6bed8737a34dbb54782a18f47dccf933a9967a12/pkill/pkill.1) | Parse `ps ... comm` into PID plus the remaining command value; use bounded TERM/KILL convergence | BSD-3-Clause/GNU docs; no code copied |
| Terminal report ordering | [GNU Bash command lists](https://www.gnu.org/software/bash/manual/html_node/Lists.html) | Local fail-first contract test; no external implementation reused | Persist terminal state before invoking the synchronous analyzer | GNU FDL documentation; behavior paraphrased; no code copied |

## Coverage

| Coverage item | Recorded result |
|---|---:|
| Core role families executed | 16 |
| Additional taxonomy families documented but not executed in the core matrix | 8 |
| Synthetic candidate profiles | 10 |
| Opportunity contexts | 48 |
| Automated interview sessions | 160 |
| Real `.app` interview sessions | 16 |
| Total distinct sessions across those two matrices | 176 |
| Automated dialogue turns | 1,280 |
| Real system-audio turns | 128 |
| Automated positive / negative turns | 800 / 480 |
| Real-audio positive / negative turns | 80 / 48 |
| Combined expected positive / negative turns | 880 / 528 |
| Rapid/cancellation turns in deterministic manifest | 160 |
| Partial/final/replay turns in deterministic manifest | 160 |
| Missing-evidence/adversarial turns | 160 |
| Real-audio rapid transitions | 16 |
| Real-audio unique audio SHA-256 values | 128 |
| Failure records | 32 total: 30 fixed, 2 open |
| Consolidated injected-failure turn count | Not recorded; automated fault suites ran, but no auditable aggregate counter was emitted |

The corpus is deterministic with seed `20260831`, contains no real personal data, and has 1,181 distinct normalized utterances. Each core role has three seniority contexts, ten sessions, eighty automated turns, and at least three independent public source hosts.

## Role Results

Each row combines ten deterministic sessions (80 turns: 50 trigger, 30 reject) with one real `.app` session (8 turns: 5 trigger, 3 reject). “Grounded answers” covers deterministic claim validation plus the real final visible rows. Semantic alignment was recorded only as a campaign aggregate (781/800), so the table does not invent per-role rubric scores.

| Role Family | Sessions | Turns | Trigger Accuracy | Grounded Answers | Failures |
|---|---:|---:|---:|---:|---|
| Robotics Research Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Robotics Software Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Embodied AI / VLA Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Computer Vision Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures; historical H24-0028 fixed |
| Machine Learning Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures; historical H24-0029 fixed |
| Applied Scientist | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| AI Research Scientist / PhD Interview | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| AI Infrastructure / MLOps Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Backend Software Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Distributed Systems Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| macOS / Swift Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Systems / Platform Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Data Scientist | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Graduate Software Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Founding Engineer / Startup AI Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |
| Security / Privacy Engineer | 11 | 88 | 88/88 | 55/55 | 0 hard final failures |

## Dialogue Results

| Dialogue area | Recorded coverage | Result |
|---|---:|---|
| Multi-part | 16 tagged turns | Correct final candidate split in the deterministic gate |
| Follow-up chain | 1,120 turns with previous relevant context | Same-session, same-frozen-snapshot resolution passed |
| Explicit reference resolution | 1,120 expected references | All fixture assertions passed |
| Candidate/interviewer/self correction | 96 distinct tagged turns | Passed |
| Partial/final | 160 turns | Novel final accepted; duplicate final suppressed |
| Cumulative replay | 32 tagged turns plus targeted long-interview tests | No duplicate generation/persistence in final gates |
| Intentional repeat | Targeted `distinctNewUtteranceCanIntentionallyRepeatAQuestion` regression | Passed; no separate campaign-fixture count was emitted |
| Small talk | 160 turns | Rejected as answer-card triggers |
| Candidate speech | 160 microphone/candidate turns | Rejected by default |
| Panel | 160 panel-interview turns; 16 explicit two-interviewer panel turns | Passed without claiming speaker diarization |
| Rapid questions | 160 manifest rapid turns; 16 real-audio transitions | Latest ownership held; no stale real visible answer |
| Profile switching | Targeted snapshot/cancellation/cross-profile callback tests | Passed; no separate fixture tag count was emitted |

## Bugs Discovered And Fixed

| ID | Severity | Symptom | Root Cause | Research | Regression Test | Fix Commit | Result |
|---|---|---|---|---|---|---|---|
| H24-0001 | P1 | Campaign full suite omitted required local integration gates | Runner assumed plain `swift test` was self-contained | Repository runbooks/scripts | Campaign script contracts | `b8d3bcd` | Fixed |
| H24-0002 | P1 | Baseline stability failed | Composite of H24-0001 and H24-0005 | Same as constituent defects | Campaign + release tooling + full stability | `5a8e559` | Fixed |
| H24-0003 | P1 | TSan race and timeout cascade | Unsynchronized mock state plus unrelated suites sharing process-global resources | Swift concurrency, TestScoping, Swift Testing, SwiftNIO | Capture state + cross-suite/full TSan | `a732454` | Fixed |
| H24-0004 | P1 | ASan full suite hit one-second watchdog | Word-at-a-time mock became too slow under instrumentation | Apple sanitizer guidance, AsyncStream docs | Focused and full ASan runtime path | `14e5664` | Fixed |
| H24-0005 | P1 | App packaging rejected GRDB resource accessor | Marker-string heuristic confused linked definition with live call | Apple bundle/privacy, SwiftPM, GRDB | Release tooling accessor gate | `5a8e559` | Fixed |
| H24-0006 | P2 | Trace assertion required unsupported event order | Two async observation events had no ordering guarantee | Local traces and runtime contract | Runtime path lifecycle test | `40f6a54` | Fixed |
| H24-0007 | P1 | Imperative/tag/long-WH misses and audio-check false trigger | Question shape rules over-weighted inversion | Apple regex, Cambridge tags, Switchboard, dria | Positive/paraphrase/negative question tests | `12d1589` | Fixed |
| H24-0008 | P1 | Final “Why?” follow-up was dropped | No contextual resolution before short-question guard | Local runtime evidence | Same-session/snapshot Why tests | `a61383e` | Fixed |
| H24-0009 | P1 | Honest false-premise denial rejected | Intent router used domain keywords before confirmation shape | Question-form research | False-premise alignment test | `12d1589` | Fixed |
| H24-0010 | P2 | Evidence denials/prospective phrases became personal claims | Substring verbs ignored denial and grammar | Local validator evidence | Positive and negative grounding tests | `a4ed34f` | Fixed |
| H24-0011 | P2 | Contextual Why cache identity missed | Resolved cache key stored raw normalized question | Local cache contract | RAG precompute identity test | `a61383e` | Fixed |
| H24-0012 | P2 | Initial corpus converted role requirements to history | Generator mixed opportunity and candidate evidence | Public-source provenance and local validators | 1,280-turn grounding/identity gate | `725fb43` | Fixed |
| H24-0013 | P1 | Bash 3.2 cleanup aborted on empty PID array | Empty array expansion was not nounset-safe | GNU Bash compatibility | Real runner runtime probe | `5234088` | Fixed |
| H24-0014 | P1 | Early aborted real run could exit zero | Cleanup status lacked a completion sentinel | Local runner contract | Early-exit fail-closed test | `5234088` | Fixed |
| H24-0015 | P2 | Rapid turn was always assumed cancelled | Outcome was encoded statically instead of derived from event order | Local event model | Rapid timing/event-order tests | `5234088` | Fixed |
| H24-0016 | P2 | Bootstrap excluded legitimately completed rapid answers | Production bootstrap retained static cancellation assumption | Local scenario evidence | Rapid visible mapping test | `853723f` | Fixed |
| H24-0017 | P1 | Parakeet helper survived app shutdown | Stop returned after signal without observing termination | Apple Process, swift-corelibs, swift-subprocess, Applite | Forced-stop lifecycle test + real app | `9d53641` | Fixed |
| H24-0020 | P1 | Consecutive app launches failed before playback | ScreenCaptureKit probe returned before async teardown | Apple ScreenCaptureKit, LiveKit, Omi | Successful/cancelled teardown tests | `7afd582` | Fixed |
| H24-0021 | P1 | Two stability runs stopped progressing | Unbounded `Process.waitUntilExit` blocked async shutdown | Apple Process, swift-corelibs, swift-subprocess, issue 5197 | Static rejection of unbounded wait + full gates | `36dc276` | Fixed |
| H24-0024 | P3 | Hardened rejection lost established wording | Replacement diagnostic removed operator contract phrase | Local runner contract | Unapproved-scenario diagnostic test | `754c345` | Fixed |
| H24-0025 | P1 | “Um,”-prefixed real question was suppressed | WH patterns anchored before disfluency cleanup | ASR/question research | Leading-disfluency positives/negatives | `7411a65` | Fixed |
| H24-0026 | P2 | Spoken “one” vs digit `1` broke turn mapping | Matcher lacked numeric surface normalization | Local ASR evidence | Spoken/digit mapping test | `72ff658` | Fixed |
| H24-0027 | P2 | “apply” vs “applied” broke mapping | Matcher retained safe inflections as distinct | Local ASR evidence | Safe-inflection mapping test | `fe1a552` | Fixed |
| H24-0028 | P1 | Qwen exhausted retries on a grounded debugging answer | Free-form retries did not require naming the failure; prompt-only recovery remained stochastic | Ollama streaming/structured output, Qwen, two Swift clients, issues | Exact candidate evidence and recovery-shape tests | `0081ed4` | Fixed |
| H24-0029 | P1 | Parakeet rendered filler as “Thumb” and question was suppressed | Recovery handled only a fixed filler list | Apple Speech, Parakeet model card, VoiceInk, Megaphone | Bounded leading-noise positives/negatives | `5279270` | Fixed |
| H24-0030 | P1 | Failure ID allocator could reuse a gapped ID | Used line count instead of maximum suffix | Local persisted queue | Actual/empty/gapped queue tests | `622deba` | Fixed |
| H24-0031 | P1 | DB diagnostics repurposed `HOME` | Diagnostic script exposed only HOME-derived paths | Local privacy contract | Dedicated DB/trace path tests | `622deba` | Fixed |
| H24-0032 | P1 | Context test intermittently observed an empty second prompt | Test waited for a generic first-question prefix, not exact second retrieval completion | Swift Testing/concurrency/issue 978 | One-shot gate, exact question waits, awaited tasks | `c50a61b` | Fixed |
| H24-0033 | P1 | Cleanup missed app path containing spaces | `awk $2` truncated the executable path; first replacement also hit pipefail | Darwin ps/pgrep, Bash read | Path-safe process contract + real app | `342fb05` | Fixed |
| H24-0034 | P2 | First terminal report still said `running` | Analyzer ran before terminal state persistence | GNU Bash command ordering | Fail-first finalization-order test | `6f01307` | Fixed |
| H24-0035 | P1 | Long soak lacks continuous real-app turn/resource evidence | Supervisor rotates test filters and discrete app launches | User campaign specification and local script inspection | Not yet written | — | **Open** |
| H24-0036 | P2 | Per-answer rubric, WER, and separated latency streams are incomplete | Runners did not serialize the requested measurements | Local artifact/schema inspection | Not yet written | — | **Open** |

## Answer Quality

| Metric | Result | Evidence boundary |
|---|---:|---|
| Deterministic semantic alignment | 781/800 (`97.625%`) | `QuestionAnswerAlignmentEvaluator`; 19 non-aligned fixtures remain below the allowed 5% threshold but were not individually persisted to the report |
| Deterministic candidate-evidence grounding | 800/800 (`100%`) | Every triggering fixture passed `AnswerClaimValidator` with its allowed candidate evidence |
| Required concepts | 800/800 | Deterministic exact concept checks |
| First-person, spoken, maximum four sentences | 800/800 | Deterministic shape checks |
| Real final answer alignment/grounding | 80/80 | Independent event and SQLite tie-outs |
| Unsupported personal claims | 0 observed | Hard gate in deterministic corpus and real SQLite tie-out |
| Wrong-profile evidence | 0 observed | Frozen snapshot and cross-profile tests; forbidden evidence checks |
| JD-to-experience conversion | 0 observed | Opportunity evidence partition and candidate-only personal claim validation |
| Future-to-past conversion | 0 observed | Prospective/denial regressions and candidate evidence validation |
| Stale visible answer | 0 observed in final automated and 16-session real matrix | Question/generation/session/context identity and visible-event tie-out |
| Duplicate successful persistence | 0 observed | 800 deterministic ledger entries exactly once; 80 real rows with no duplicate question groups |
| Rubric scores for relevance 0–5, directness 0–3, fluency 0–3, completeness 0–3, role fit 0–3 | Not recorded | `answer_quality_results.jsonl` remained empty; H24-0036 |

Ten unsafe or mis-shaped real Qwen candidates across five frozen identities were rejected by alignment; each identity later produced exactly one aligned visible and persisted answer. No independent second-model judge result was recorded, so deterministic validators and human-readable evidence remain the only audited quality layers.

## ASR And Audio

- Apple Speech: automated permission, cumulative replay, source metadata, and failure-path tests passed. No real `.app` Apple Speech audio session was run; this configuration is `NOT VERIFIED`.
- Parakeet: the real `.app` matrix observed 128/128 final transcripts, accepted 80/80 expected questions, rejected 48/48 non-questions, and produced zero false trigger or source/speaker mismatch.
- ScreenCaptureKit: all 16 sessions emitted a first-buffer event and used the real bundled app with independent synthetic system-audio playback. Probe teardown races were reproduced and fixed before the final matrix.
- Voices/locales: Daniel (`en_GB`), Karen (`en_AU`), Samantha (`en_US`), and Tingting (`zh_CN`); three English voices and four locale slots.
- Rates: 145, 175, and 210 words per minute.
- Audio profiles: 26 clean, 20 low-volume, 21 high-volume-limited, 20 synthetic white-noise, 21 synthetic café-noise, and 20 mild-echo utterances; all 128 audio hashes were unique.
- Dialogue phenomena in the real matrix include direct questions, false premises, missing evidence, system design, panel transitions, candidate speech, partial/final, and rapid follow-ups.
- WER and normalized edit distance: not recorded because the privacy-safe event stream retained transcript counts and acceptance evidence rather than recognized/reference text pairs. H24-0036 remains open.
- Semantic question acceptance: 80/80 (`100%`) for expected triggers; rejection accuracy 48/48 (`100%`); false trigger 0.
- Source attribution: 128/128 observed transcripts remained `systemAudio` / interviewer / local Parakeet in the independent tie-out.
- Real physical microphone and simultaneous dual-source capture were not revalidated.

## Real App Verification

- Bundle: `dist/Hireva.app` built and launched through `./script/build_and_run.sh --verify`; no bare SwiftPM GUI executable was used.
- Bundle identity: `com.langcheng.Hireva`; `CFBundleExecutable=Hireva`; app and helper architecture `arm64`.
- Isolation: a campaign-only fixed user home, app-support directory, defaults suite, and verification mode protected production user data.
- Capture: real ScreenCaptureKit system audio from independently rendered synthetic audio.
- ASR: local Parakeet helper with source metadata and bounded lifecycle.
- Question/RAG: accepted questions were bound to frozen session/profile/opportunity/context identities; contextual follow-up and cache identity regressions passed.
- Provider: local Ollama Qwen; provider candidates remained subject to alignment and deterministic candidate-evidence validation.
- UI/persistence: 80 distinct final visible suggestions matched 80 question, generation, session, context, and SQLite records.
- SQLite: 16/16 isolated databases returned `quick_check=ok`; no foreign-key, duplicate, unsupported-claim, context, or source mismatch was observed.
- Cleanup: final independent app count 0 and helper count 0.
- Final launch-only DB diagnostics correctly showed zero suggestion rows because that final gate did not inject an interview; the separate real-audio matrix contains the 80-row tie-out.
- Signing: internal code-signature verification passed in ad-hoc mode. This is not public-distribution evidence.

## Performance

Real-audio values below were reconstructed with nearest-rank percentiles from persisted playback timestamps and privacy-safe event timestamps. App events have one-second timestamp granularity, so sub-second provider/UI distinctions must not be inferred.

| Path / interval | n | p50 | p90 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| Deterministic RuntimeSmoke 64-case turn-to-persist harness | 59 triggers | 274.0 ms | Not emitted | 303.9 ms | Not emitted | 324.4 ms |
| Provider-only | — | Not recorded | Not recorded | Not recorded | Not recorded | Not recorded |
| Direct WAV ASR | — | Not recorded | Not recorded | Not recorded | Not recorded | Not recorded |
| Real audio end → ASR final | 128 | 0.554 s | 1.151 s | 1.259 s | 1.631 s | 1.836 s |
| Real ASR final → question accepted | 80 | 0.000 s | 0.000 s | 0.000 s | 1.000 s | 1.000 s |
| Real question accepted → visible answer | 80 | 3.000 s | 4.000 s | 5.000 s | 9.000 s | 9.000 s |
| Real question accepted → persistence event | 80 | 3.000 s | 4.000 s | 5.000 s | 9.000 s | 9.000 s |
| Real audio end → visible answer | 80 | 3.343 s | 4.295 s | 5.562 s | 9.308 s | 9.308 s |
| Real audio end → persistence event | 80 | 3.460 s | 4.295 s | 5.562 s | 9.308 s | 9.308 s |

Per-utterance playback-start → first ScreenCaptureKit buffer, provider first-content, first-token versus full-card, RAG completion, and direct-ASR percentile series were not persisted. They are part of H24-0036 and must not be inferred from `suggestion.visible`.

## Soak Results

| Measure | Result |
|---|---|
| Counted long-loop active duration | 22:11:45 |
| Focused test cycles | 8,220 passed |
| Focused suite families | 8 |
| Periodic app verification | 411 loop launches; 414 total app scenario records including baseline/final |
| Periodic full stability | 82 loop gates; 84 total stability records including baseline/final |
| Real-app soak sessions / turns inside long loop | Not recorded; discrete verification launches did not drive 3–10 real turns per cycle |
| Post-fix crashes | 0 observed |
| Historical hangs | 2 occurrences under H24-0021; root cause fixed; none observed in the resumed loop |
| `SQLITE_BUSY` | 0 observed in passing stress/stability gates |
| Orphan helpers/apps at finish | 0 / 0 |
| Memory trend | Not recorded longitudinally |
| Disk/DB/trace growth trend | Not recorded longitudinally |
| Privacy leaks | 0 observed in automated privacy gates and final repository/artifact scans |

The elapsed time and regression volume exceed six hours, but this does **not** satisfy the specified six-hour continuous real-app interview/resource soak. H24-0035 remains a P1 validation gap.

## Automated Gates

| Gate | Result |
|---|---|
| Full suite run 1 | PASS — 903/903, coverage enabled, 218.224 s |
| Full suite run 2 | PASS — 903/903, 216.318 s |
| Full suite run 3 | PASS — 903/903, 213.593 s |
| Full TSan | PASS — 903/903, 294.172 s; no race diagnostic observed |
| Full ASan | PASS — 903/903, 357.247 s; no ASan/LeakSanitizer diagnostic observed |
| RuntimeSmoke | PASS — 12/12, 32.146 s |
| Stability gate | PASS — build, reconciled full suite, RuntimeSmoke, and app verification; 354 s |
| Real app verification | PASS — correct bundle path/ID/architecture and live PID |
| Privacy canary | PASS for recorded automated gates and final scans; no literal secret value retained |
| DB tie-out | PASS — 16/16 `quick_check=ok`, 80 aligned rows, zero duplicate/identity/source/foreign-key failure |
| Release status script | PASS |
| Signing/Gatekeeper | `AD_HOC_ONLY`; Gatekeeper rejected — public distribution gate failed |
| Post-final H24-0034 regression | PASS — 3/3 campaign script tests, shell syntax, diff check, and RuntimeSmoke 12/12 |

The aggregate analyzer has 8,739 scenario records: 8,733 pass and six historical baseline/fail-first records fail. Those six are retained evidence, not unresolved final failures.

## Remaining Risks

1. H24-0035: no six-hour continuous real-app multi-turn resource soak, and no longitudinal RSS/open-file/DB/trace/disk series.
2. H24-0036: the per-answer rubric JSONL is empty; WER, normalized edit distance, provider-only, direct-WAV ASR, first-token, and several required latency stages are absent.
3. Nineteen of 800 deterministic answer fixtures were not classified aligned by the semantic evaluator. The aggregate 97.625% passes the configured 95% gate, but the individual disagreement list was not persisted for human review.
4. Apple Speech + Qwen, physical microphone-only, simultaneous microphone + system audio, and optional real DeepSeek were not exercised end to end.
5. The real matrix has six explicit audio profiles rather than a separately labeled record for every requested audio-condition category; some dialogue phenomena were covered in text, but unrecorded distinctions cannot be claimed.
6. The app has only an ad-hoc signature: no Developer ID Application identity, accepted notarization, stapled ticket, or passing Gatekeeper assessment.

## Final Verdict

**Parakeet + Qwen Controlled-Use: GO**

Evidence: 16 real bundled-app sessions, 128 synthetic system-audio turns, 80/80 accepted questions, 80 aligned/grounded visible and persisted answers, zero false trigger, stale answer, wrong evidence, duplicate group, SQLite integrity failure, or process leak. Scope is supervised synthetic System Audio use; it does not include the missing long-lived resource soak.

**Apple Speech + Qwen Controlled-Use: NOT VERIFIED**

Blocker: automated paths passed, but no real `.app` Apple Speech audio session was run.

**System Audio Controlled-Use: GO**

Evidence: real ScreenCaptureKit capture passed the 16-role, 128-turn matrix with semantic trigger/rejection accuracy 100% and clean final process counts.

**Microphone Controlled-Use: NOT VERIFIED**

Blocker: permission state and automated source policy were tested, but no controlled physical microphone audio run was completed.

**Dual-Source Controlled-Use: NOT VERIFIED**

Blocker: automated source-isolation tests passed, but real simultaneous microphone + system capture was not revalidated.

**Optional DeepSeek: NOT VERIFIED**

Blocker: no safely configured real cloud-provider run was recorded; mock/provider-contract tests do not establish end-to-end cloud behavior.

**Overall Local Controlled-Use: NO-GO**

Blocker: H24-0035 and H24-0036 leave mandatory long-soak resource and measurement evidence incomplete. The narrower System Audio + Parakeet + Qwen slice remains GO as stated above.

**Public Distribution: NO-GO**

Blocker: `Signature=adhoc`, `TeamIdentifier=not set`, Gatekeeper rejected, and there is no accepted/stapled notarization evidence.

## Resume Instructions

Not applicable: 88,305 active seconds reached the 24-hour target, so the completed campaign must not be resumed merely to inflate elapsed time. Closing H24-0035 and H24-0036 requires a new, explicitly scoped verification campaign with real-app resource sampling and complete metrics emission.
