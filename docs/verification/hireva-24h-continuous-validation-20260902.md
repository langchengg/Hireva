# Hireva 24-Hour Continuous Interview Quality, Reliability and Release Campaign

## Executive Summary

- Campaign: `hireva-24h-20260831T152152Z`
- Original UTC wall span: 2026-08-31 15:21:52 to 2026-09-02 01:12:57.
- Corrective campaign UTC wall span: 2026-09-02 07:19:49 to 2026-09-08 14:18:52; only 6:02:01 of active execution inside that interrupted span was counted.
- Counted active execution: 88,305 seconds (`24:31:45`), above the 86,400-second target. Manual investigation and inactive interruption time were conservatively excluded.
- Duration result: the original campaign reached the full 24-hour active-duration requirement. A resumable corrective campaign then added 21,721 seconds (`6:02:01`) of real-app soak, bringing counted active engineering and validation time to 110,026 seconds (`30:33:46`). Interrupted wall-clock time was never counted.
- Verified core result: System Audio + local Parakeet + local Qwen passed 170 real `Hireva.app` sessions and 1,360 synthetic system-audio turns across the original and corrective matrices. The corrective soak alone completed 154 sessions, 1,232 turns, 770 accepted questions/answers, and 1,640 completed-attempt resource samples.
- Automated result at code commit `b804190`: three consecutive 943-test full suites passed, followed by full TSan and ASan passes, RuntimeSmoke 12/12, the reconciled stability gate, an independent signed-app launch, and metadata-only DB diagnostics.
- Answer result: the corrective real-app corpus scored mean relevance 4.932/5, evidence grounding 5/5, directness 2.969/3, completeness 3/3, spoken fluency 3/3, and role fit 3/3 across 770 answers. All recorded hard-failure counts were zero. This is not a claim that every possible interview answer is correct.
- Defects: all 32 original H24 records are fixed. H24-0035 and H24-0036 were closed by the corrective campaign; its own 32 H24C failure records are also fixed with zero open failures.
- Primary risk: Apple Speech, physical microphone, simultaneous dual-source capture, optional DeepSeek, and public notarized distribution remain unverified or NO-GO. The GO verdict is limited to the real System Audio + Parakeet + Qwen local configuration.
- Capabilities used: repository scripts, Swift Package Manager, Swift Testing, real bundled `Hireva.app`, ScreenCaptureKit, local Parakeet/sherpa-onnx/ONNX Runtime, local Ollama Qwen, GRDB/SQLite, macOS `say`/audio playback, Git, `jq`, `curl`, GitHub/official documentation research, sanitizers, and code-signing diagnostics. No write-capable external connector, optional plugin, subagent, real third-party interview recording, or private CV was used.
- Reuse decision: 151 source-ledger entries informed behavior and design across both campaigns; `codeCopied=true` is zero. External implementations were reference-only, with license checks recorded before independent Hireva-specific fixes.

## Git Safety

- Base commit: `6ad205f235c0f5825eec3e2d175f2a81489839e7`.
- Backup branch: `backup/hireva-pre-24h-20260831-161121`.
- Backup tag: `backup-hireva-pre-24h-20260831-161121`.
- Working branch: `codex/hireva-24h-continuous-validation-20260831-161121`.
- Last fully verified code commit before this report: `b8041906ab82f0a49b7fdea4252a0de385395d3a`.
- Push status: ordinary, non-force pushes succeeded through `b804190`; the final report-only commit is pushed before handoff.
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
| Corrective real-app soak | 06:02:01 | 154 signed-app sessions, 1,232 real system-audio turns, resource sampling, WER, answer rubrics, separated latency, failure-first repair | H24-0035/H24-0036 closed; 32/32 H24C records fixed |
| Post-closure final gates | 00:00:00 campaign time | Three full suites, TSan, ASan, RuntimeSmoke, reconciled stability, signed app, DB/release/signing diagnostics | All correctness gates passed at `b804190`; this verification time was not added to the persisted campaign counters |
| **Total persisted active execution** | **30:33:46** | Original campaign plus resumable corrective campaign; inactive wall time excluded | **24-hour target and six-hour corrective real-app soak reached; zero open campaign failures** |

## Online And GitHub Research

The original and corrective research ledgers contain 151 entries in total. Issue reports were used only as hypotheses. No external code was copied.

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
| Capture-callback serialization/backpressure | [Apple ScreenCaptureKit capture flow](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [AVCaptureAudioDataOutput delegate queue](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/setsamplebufferdelegate(_:queue:)) | [Recordly recorder](https://github.com/Jan-Eichhorn/Recordly/tree/a5bb4263b6a30d979ea6c5e5da86ef4553273dd3), [listnr SystemAudioCapture](https://github.com/rokib16x/listnr/tree/c17bab7554b54429e527015f8f4c50bad3e6ee67) | Keep the ownership-safe audio copy on the capture callback, but reserve bounded capacity first and move Base64/JSON serialization plus pipe writes to the bounded serial writer queue | Recordly AGPL-3.0 reference-only; listnr MIT reference-only; no code copied |

## Coverage

| Coverage item | Recorded result |
|---|---:|
| Core role families executed | 16 |
| Additional taxonomy families documented but not executed in the core matrix | 8 |
| Synthetic candidate profiles | 10 |
| Opportunity contexts | 48 |
| Automated interview sessions | 160 |
| Real `.app` interview sessions | 170 (16 original + 154 corrective) |
| Total sessions across automated and real matrices | 330 |
| Automated dialogue turns | 1,280 |
| Real system-audio turns | 1,360 (128 original + 1,232 corrective) |
| Automated positive / negative turns | 800 / 480 |
| Real-audio positive / negative turns | 850 / 510 |
| Combined automated + real positive / negative turns | 1,650 / 990 |
| Rapid/cancellation turns in deterministic manifest | 160 |
| Partial/final/replay turns in deterministic manifest | 160 |
| Missing-evidence/adversarial turns | 160 |
| Real-audio rapid transitions | At least 170 scenario-level rapid-generation-supersession injections across both matrices |
| Corrective completed-attempt resource samples | 1,640; 1,555 exact-app samples (`94.817%`) |
| Failure records | Original: 32 fixed / 0 open; corrective: 32 fixed / 0 open |
| Consolidated injected-failure turn count | Not emitted as a single cross-campaign count; per-cycle injection identity is retained in `cycle_results.jsonl` |

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

The corrective soak added the following real-app-only coverage. Every turn was semantically accepted as its reviewed scenario expected; each accepted question produced one aligned, grounded, exactly-once suggestion.

| Role Family | Sessions | Turns | Trigger Accuracy | Grounded Answers | Failures |
|---|---:|---:|---:|---:|---:|
| Robotics Research Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Robotics Software Engineer | 9 | 72 | 72/72 | 45/45 | 0 |
| Embodied AI / VLA Engineer | 9 | 72 | 72/72 | 45/45 | 0 |
| Computer Vision Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Machine Learning Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Applied Scientist | 10 | 80 | 80/80 | 50/50 | 0 |
| AI Research Scientist / PhD Interview | 10 | 80 | 80/80 | 50/50 | 0 |
| AI Infrastructure / MLOps Engineer | 9 | 72 | 72/72 | 45/45 | 0 |
| Backend Software Engineer | 9 | 72 | 72/72 | 45/45 | 0 |
| Distributed Systems Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| macOS / Swift Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Systems / Platform Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Data Scientist | 9 | 72 | 72/72 | 45/45 | 0 |
| Graduate Software Engineer | 9 | 72 | 72/72 | 45/45 | 0 |
| Founding Engineer / Startup AI Engineer | 10 | 80 | 80/80 | 50/50 | 0 |
| Security / Privacy Engineer | 10 | 80 | 80/80 | 50/50 | 0 |

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
| H24-0035 | P1 | Long soak lacked continuous real-app turn/resource evidence | Original supervisor rotated test filters and discrete app launches | Campaign specification and local script inspection | Corrective continuation gates for duration, exact-app sampling, cleanup, and SQLite identity | `2d824d4` plus corrective evidence at `b804190` | **Fixed** — 6:02:01, 154 sessions, 1,232 turns, 1,640 samples |
| H24-0036 | P2 | Per-answer rubric, WER, and separated latency streams were incomplete | Original runners did not serialize the requested measurements | Local artifact/schema inspection | Analyzer tests for missing fields, answer quality, WER, and separated paths | `c47995a` plus corrective evidence at `b804190` | **Fixed** — complete corrective metrics emitted |
| H24C-0032 | P1 | Replayed rapid follow-up degraded to “You too” under real app load | Base64/JSON audio serialization and pipe preparation ran synchronously on the serial ScreenCaptureKit callback queue, producing `coreaudiod` client-timeout overloads | Apple capture/delegate-queue docs; Recordly and listnr compared as reference-only | `audioSerializationDoesNotRunOnTheCaptureCallbackCallStack` plus real signed-app replay | `b804190` | **Fixed** — 8/8 transcripts, 5/5 Q/G/visible/DB, no residue |

## Answer Quality

| Metric | Result | Evidence boundary |
|---|---:|---|
| Deterministic semantic alignment | 781/800 (`97.625%`) | `QuestionAnswerAlignmentEvaluator`; 19 non-aligned fixtures remain below the allowed 5% threshold but were not individually persisted to the report |
| Deterministic candidate-evidence grounding | 800/800 (`100%`) | Every triggering fixture passed `AnswerClaimValidator` with its allowed candidate evidence |
| Required concepts | 800/800 | Deterministic exact concept checks |
| First-person, spoken, maximum four sentences | 800/800 | Deterministic shape checks |
| Corrective real-app answers | 770/770 aligned, grounded, and exactly once | Structured per-answer evidence joined to app events and SQLite |
| Relevance | mean 4.932/5; p50/p90/p95/p99 5/5 | 770 corrective real-app answers |
| Evidence grounding | mean 5/5; p50/p90/p95/p99 5/5 | 770 corrective real-app answers |
| Directness | mean 2.969/3; p50/p90/p95/p99 3/3 | 770 corrective real-app answers |
| Spoken fluency / completeness / role fit | mean 3/3 for each | 770 corrective real-app answers |
| Unsupported personal claims | 0 | Deterministic and corrective hard gate |
| Wrong profile/job evidence | 0 / 0 | Frozen snapshot and per-answer identity checks |
| JD-to-experience / future-to-past | 0 / 0 | Candidate/opportunity partition and tense/claim validators |
| Stale answer / answer-question mismatch / context bleed | 0 / 0 / 0 | Question, generation, session, and context identity joins |
| Duplicate successful persistence / provider source mislabel | 0 / 0 | Per-cycle SQLite and source metadata tie-outs |

The quality layer combines deterministic validators, structured rubric scoring, and retained human-readable reports. No independent second-model judge was used, so the report does not describe these scores as an omniscient quality judgment.

## ASR And Audio

- Apple Speech: automated permission, cumulative replay, source metadata, and failure-path tests passed. No real `.app` Apple Speech audio session was run; this configuration is `NOT VERIFIED`.
- Parakeet: the original and corrective real-app matrices observed 1,360/1,360 final transcripts. The corrective corpus WER was `0.032073` and normalized character edit distance was `0.010298`; direct-WAV WER was 0 across three utterances.
- ScreenCaptureKit: 170 sessions used the real bundled app with independent synthetic system-audio playback. Corrective semantic acceptance was 1,232/1,232, including a critical-clean subset of 251/251; false triggers were zero.
- Voices/locales: Daniel (`en_GB`), Karen (`en_AU`), Samantha (`en_US`), and Tingting (`zh_CN`); three English voices and four locale slots.
- Rates: 145, 175, and 210 words per minute.
- Audio profiles: clean, low-volume, high-volume-limited, synthetic white-noise, synthetic café-noise, mild echo, rapid follow-up, pauses, fillers, corrections, acronyms, numbers, and mixed Chinese/English. All media remained locally generated and synthetic.
- Dialogue phenomena in the real matrix include direct questions, false premises, missing evidence, system design, panel transitions, candidate speech, partial/final, and rapid follow-ups.
- Semantic question acceptance: original expected triggers 80/80 and rejections 48/48; corrective turns 1,232/1,232 matched their reviewed semantic expectation. False trigger, wrong source, and wrong speaker counts were zero.
- Source attribution: real transcripts remained `systemAudio` / interviewer / local Parakeet in the independent tie-outs. Apple Speech was never mislabeled as Parakeet in automated source tests.
- Real physical microphone and simultaneous dual-source capture were not revalidated.

## Real App Verification

- Bundle: `dist/Hireva.app` built and launched through `./script/build_and_run.sh --verify`; no bare SwiftPM GUI executable was used.
- Bundle identity: `com.langcheng.Hireva`; `CFBundleExecutable=Hireva`; app and helper architecture `arm64`.
- Isolation: a campaign-only fixed user home, app-support directory, defaults suite, and verification mode protected production user data.
- Capture: real ScreenCaptureKit system audio from independently rendered synthetic audio.
- ASR: local Parakeet helper with source metadata and bounded lifecycle.
- Question/RAG: accepted questions were bound to frozen session/profile/opportunity/context identities; contextual follow-up and cache identity regressions passed.
- Provider: local Ollama Qwen; provider candidates remained subject to alignment and deterministic candidate-evidence validation.
- UI/persistence: the original 80 and corrective 770 final visible suggestions matched their question, generation, session, context, and SQLite records.
- SQLite: the corrective 154 isolated databases contained 770 suggestions with zero null or duplicate identities; the final metadata-only diagnostic sampled 5 rows with 5 distinct suggestion and question IDs, all aligned/completed.
- Cleanup: final independent app count 0 and helper count 0.
- The final launch-only gate used an isolated home; the explicit DB diagnostic targeted the completed corrective cycle 154 database rather than production Application Support.
- Signing: internal code-signature verification passed in ad-hoc mode. This is not public-distribution evidence.

## Performance

Corrective-campaign values use persisted monotonic interval measurements. Paths remain separate; sanitizer timing is excluded from product performance judgments.

| Path / interval | n | p50 | p90 | p95 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| Deterministic 64-case harness elapsed | 64 | 291.7 ms | 337.7 ms | 343.4 ms | 471.0 ms | 471.0 ms |
| Provider-only → first answer content | 5 | 247.2 ms | 3267.6 ms | 3267.6 ms | 3267.6 ms | 3267.6 ms |
| Provider-only → complete | 5 | 1483.6 ms | 4451.5 ms | 4451.5 ms | 4451.5 ms | 4451.5 ms |
| Direct WAV ASR → first final | 3 | 11988.5 ms | 32777.5 ms | 32777.5 ms | 32777.5 ms | 32777.5 ms |
| Direct WAV ASR → decode complete | 3 | 32851.9 ms | 32851.9 ms | 32851.9 ms | 32851.9 ms | 32851.9 ms |
| Real SCK question accepted → RAG complete | 770 | 1 ms | 1 ms | 1 ms | 2 ms | 4 ms |
| Real SCK question accepted → provider first content | 770 | 1243 ms | 1416 ms | 1488 ms | 1569 ms | 4232 ms |
| Real SCK question accepted → first/full visible | 770 | 2731 ms | 5090 ms | 7443 ms | 8707 ms | 9627 ms |
| Real SCK question accepted → persistence complete | 770 | 2811 ms | 5185 ms | 7511 ms | 8777 ms | 9702 ms |

“Provider first content” is the earliest non-empty answer-content event exported by the provider boundary. It is not a lower-level tokenizer callback and is not relabeled as one.

## Soak Results

| Measure | Result |
|---|---|
| Original automated-loop active duration / cycles | 22:11:45 / 8,220 passed |
| Corrective real-app active duration | 6:02:01; six-hour target reached |
| Corrective real-app cycles / sessions / turns | 154 / 154 / 1,232 |
| Accepted questions / persisted suggestions | 770 / 770 |
| Crashes / hangs / `SQLITE_BUSY` | 0 / 0 / 0 in completed corrective cycles |
| Orphan helpers/apps at finish | 0 / 0 |
| Completed-attempt samples | 1,640 total; 1,555 exact-app (`94.817%`) |
| App RSS | first 136,331,264 B; last 148,258,816 B; delta +11,927,552 B; p50 147,390,464 B; max 837,402,624 B |
| App open files | p50 31; p95 32; max 33 |
| Helper RSS / open files | p50 966,311,936 B / 4; max 1,196,032,000 B / 4 |
| Ollama RSS | p50 5,114,707,968 B; max 5,137,612,800 B |
| Per-session DB / trace / WAL max | 208,896 B / 50,404 B / 0 B |
| Artifact-root disk growth | p50 436,789,248 B; max 766,083,072 B across retained evidence |
| Privacy leaks | 0 observed in privacy gates and final scans |

RSS is the resident-set value sampled by `ps`, not macOS physical footprint. The transient app maximum coincided with model/runtime transitions; first-to-last RSS increased by about 11.4 MiB, while open-file, per-session DB, trace, and WAL series remained bounded. This is evidence against an observed unbounded leak, not a proof that no leak can exist.

## Automated Gates

| Gate | Result |
|---|---|
| Full suite run 1 | PASS — 943/943, coverage enabled, 231.829 s |
| Full suite run 2 | PASS — 943/943, 232.880 s |
| Full suite run 3 | PASS — 943/943, 224.991 s |
| Full TSan | PASS — 943/943, 306.593 s; exit 0 and no ThreadSanitizer race diagnostic |
| Full ASan | PASS — 943/943, 397.114 s; exit 0 and no AddressSanitizer/LeakSanitizer diagnostic |
| RuntimeSmoke | PASS — 12/12, 33.130 s |
| Stability gate | PASS — build, fresh-scratch reconciled 943/943, RuntimeSmoke, and app verification; 378 s |
| Real app verification | PASS — `dist/Hireva.app`, `com.langcheng.Hireva`, arm64, nested signatures valid, isolated launch, clean exit |
| Privacy canary | PASS — automated privacy gates and final source/artifact scans found no retained canary value or credential |
| DB tie-out | PASS — sampled corrective DB had 5/5 distinct question/suggestion identities, all aligned/completed; campaign aggregate 770/770 |
| Release status script | PASS |
| Signing/Gatekeeper | `AD_HOC_ONLY`; Gatekeeper rejected — public distribution gate failed |
| Exact process cleanup | PASS — app 0, helper 0 |

The first post-closure coverage attempt intentionally remains in the evidence log as invalid because three mandatory local-integration environment variables were absent. It executed 943 tests but exited non-zero on those three fail-closed checks; the correctly configured coverage run then passed 943/943 and is the gate result reported above.

## Remaining Risks

1. Apple Speech + Qwen, physical microphone-only, simultaneous microphone + system audio, and optional real DeepSeek were not exercised end to end.
2. The audio corpus is authorized synthetic playback. It does not establish behavior on every accent, device, acoustic environment, or real interview platform.
3. “Provider first content” is instrumented, but a lower-level tokenizer-first-token event is not separately exposed.
4. RSS is sampled resident set rather than Instruments physical-footprint/leak analysis; no unbounded trend was observed, but the maximum transient app RSS warrants future profiling if model loading changes.
5. The app has only an ad-hoc signature: no Developer ID Application identity, accepted notarization, stapled ticket, or passing Gatekeeper assessment.

## Final Verdict

**Parakeet + Qwen Controlled-Use: GO**

Evidence: 170 real bundled-app sessions and 1,360 synthetic system-audio turns across both matrices; the corrective soak added 154 sessions, 1,232 turns, 770 aligned/grounded answers, 6:02:01 active duration, complete resource/latency/ASR evidence, and zero open failures.

**Apple Speech + Qwen Controlled-Use: NOT VERIFIED**

Blocker: automated paths passed, but no real `.app` Apple Speech audio session was run.

**System Audio Controlled-Use: GO**

Evidence: real ScreenCaptureKit capture passed all 1,232 corrective turns, including the 251/251 critical-clean subset, with zero false trigger, stale answer, wrong evidence, duplicate persistence, or process leak.

**Microphone Controlled-Use: NOT VERIFIED**

Blocker: permission state and automated source policy were tested, but no controlled physical microphone audio run was completed.

**Dual-Source Controlled-Use: NOT VERIFIED**

Blocker: automated source-isolation tests passed, but real simultaneous microphone + system capture was not revalidated.

**Optional DeepSeek: NOT VERIFIED**

Blocker: no safely configured real cloud-provider run was recorded; mock/provider-contract tests do not establish end-to-end cloud behavior.

**Overall Local Controlled-Use: GO**

Evidence: the verified local System Audio + Parakeet + Qwen scope passed the six-hour corrective soak and all current automated gates. This does not promote the separately unverified Apple Speech, microphone, dual-source, or DeepSeek configurations.

**Public Distribution: NO-GO**

Blocker: `Signature=adhoc`, `TeamIdentifier=not set`, Gatekeeper rejected, and there is no accepted/stapled notarization evidence.

## Resume Instructions

Not applicable: the original campaign reached 88,305 active seconds and the corrective campaign reached 21,721 active seconds. Both states are `completed`; no resume command is required and elapsed time must not be inflated.
