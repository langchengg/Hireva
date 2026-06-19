# Release Runbook

This runbook covers local release preparation and operator handoff for
InterviewCopilotMac. It does not replace notarization requirements for public
distribution.

## Canonical Paths

- App bundle: `dist/InterviewCopilotMac.app`
- Runner: `dist/InterviewCopilotMac.app/Contents/MacOS/InterviewCopilotMacRunner`
- SQLite database: `$HOME/Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite`
- Runtime trace: `$HOME/Library/Application Support/InterviewCopilotMac/runtime_transcript_trace.jsonl`

Always launch the app bundle. Do not use the raw SwiftPM executable when
validating macOS permissions or stable app identity.

## Build and Launch

From the repository root:

```bash
./script/build_and_run.sh
```

To launch an already-built bundle without rebuilding:

```bash
open dist/InterviewCopilotMac.app
```

To rebuild, sign, launch, and verify the exact packaged runner:

```bash
./script/build_and_run.sh --verify
```

## Verification and Diagnostics

Run the full release gate before handoff:

```bash
./scripts/verify_runtime_stability.sh
```

The individual commands are useful when isolating a failure:

```bash
./scripts/runtime_smoke.sh --suite all
./script/build_and_run.sh --verify
./scripts/db_diagnostics.sh
./scripts/release_status.sh
./scripts/signing_status.sh
```

`db_diagnostics.sh` and `release_status.sh` are read-only. DB diagnostics can
contain interview questions and answers; release status intentionally emits
only row/event metadata. Treat all captured operational logs as sensitive.

## Create a Local Release Package

Create an allowlisted local package and ZIP after the full gate:

```bash
./scripts/package_local_release.sh
```

For package-structure diagnostics only, the gate can be skipped while the app
is still rebuilt and verified:

```bash
./scripts/package_local_release.sh --skip-verify
```

Output is written under `release/InterviewCopilotMac-local-YYYYMMDD-HHMMSS/`
with a sibling ZIP and `RELEASE_INFO.txt`. Inspect signing state with
`scripts/signing_status.sh`. The package intentionally excludes repository,
build cache, DB, trace, Keychain, and transcript data.

This is a local handoff/archive package, not a portable installed-app release.
The current build identity embeds the source workspace's absolute `dist` path,
so launching the copied app elsewhere can display the existing stale-build
warning. Run and verify the canonical `dist/InterviewCopilotMac.app` when an
unambiguous build-identity check is required.

## Configure the DeepSeek Key

1. Launch `dist/InterviewCopilotMac.app`.
2. During onboarding, enter the key in **Optional DeepSeek API Key**, or open
   **Settings** and use the DeepSeek provider key field.
3. Save the key, then run **Test DeepSeek**.
4. Confirm the UI reports a successful provider test. Never paste the key into
   logs, diagnostics, source files, or SQLite.

The key is stored in macOS Keychain under the app's stable service/account, not
in the project or database.

## If Keychain Asks Again

Repeated prompts commonly mean the app was rebuilt with a different signing
identity or CDHash. Confirm that the bundle ID is
`com.langcheng.InterviewCopilotMac`, launch from `dist/InterviewCopilotMac.app`,
and use a stable Apple Development identity as described in
`docs/macos-local-signing.md`.

After changing to a stable identity, re-save the key once. If the existing item
remains unusable, `script/reset_deepseek_keychain_item.sh` can delete only the
`deepseek.default` item after an explicit confirmation; then relaunch the same
signed bundle and save the key again.

## If macOS Blocks Launch

1. Rebuild and capture the complete verification output:

   ```bash
   ./script/build_and_run.sh --verify
   ```

2. Run the signing diagnostics in `docs/macos-local-signing.md`.
3. Confirm the app is not carrying quarantine, Finder metadata, or AppleDouble
   files from the Google Drive folder.
4. If macOS offers **Open Anyway** in **System Settings → Privacy & Security**,
   use it only after verifying this locally built artifact and its source.
5. If cloud metadata returns after cleanup, build from a non-cloud local copy.

An ad-hoc signature can pass `codesign --verify` while Gatekeeper still rejects
it. That is a trust-policy limitation, not a compilation failure.

## If System Audio Does Not Work

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**
   and enable Interview Copilot.
2. Quit the app completely and reopen `dist/InterviewCopilotMac.app`; permission
   changes do not take effect in the existing process.
3. Select **System Audio Only** or **Mic + System**, play audible content from
   the interview source, and confirm the System Audio meter moves in Diagnostics.
4. Confirm the app path, bundle ID, and signing identity did not change.
5. Run `./scripts/release_status.sh` and preserve the output with the failing
   manual-smoke notes.

Do not reset TCC as a first troubleshooting step. A reset is destructive to the
current grants and requires the user to approve them again.

## If the Database Has No Rows

1. Run `./scripts/db_diagnostics.sh` and confirm the expected database exists.
2. Start a fresh interview session with local transcript saving enabled.
3. Ask one complete interviewer question and wait for a complete visible answer.
4. Inspect the runtime trace for `questionAccepted`, `persistenceStarted`, and
   either `persistenceSucceeded` or a concrete `persistenceRejected` reason.
5. Re-run DB diagnostics. Do not write rows manually to make the check pass.

## If Answers Appear in the UI but Not the Database

Treat this as a release blocker after runtime changes. Preserve the trace and
diagnostic output, verify the UI question matches the answer, and inspect the
persistence lifecycle events. A visible answer must either persist or emit a
specific rejection reason. Do not clear the database or suppress the rejection
to hide the failure.

## If Runtime Smoke Passes but Real System Audio Fails

The terminal smoke uses deterministic mocks; it does not exercise TCC,
ScreenCaptureKit hardware capture, or real Apple Speech callbacks. Re-check the
permission, bundle path, signing identity, capture mode, and audio source. Any
real System Audio failure after audio, ASR, transcript, queue, persistence, or
provider lifecycle changes blocks release even when terminal smoke passes.

Use the three-question sequence in `docs/runtime-regression-checklist.md` to
repeat the manual test and retain DB/trace evidence.

## Handoff

Attach the completed `docs/release-checklist.md`, the output of
`./scripts/release_status.sh`, and redacted verification logs. Record the exact
commit/tag and whether the build used ad-hoc or Apple Development signing.

Additional operator references:

- `scripts/package_local_release.sh`
- `scripts/signing_status.sh`
- `docs/local-workspace-migration.md`
- `docs/notarization-prep.md`
- `docs/rollback-known-good.md`
