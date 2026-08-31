# Hireva Engineering Rules

## Canonical entry points

- Resolve and build with `swift package resolve` and `swift build`.
- Run the full SwiftPM suite with `swift test`.
- Run deterministic runtime coverage with `./scripts/runtime_smoke.sh --suite all`.
- Run the reconciled stability gate with `./scripts/verify_runtime_stability.sh`.
- Build, sign, launch, and verify the GUI only through
  `./script/build_and_run.sh --verify`.
- Never use the raw SwiftPM executable for GUI, TCC, ScreenCaptureKit, signing,
  or release validation. Those checks require `dist/Hireva.app`.

## Isolation and ownership

- Use one writer per worktree. Do not let agents, scripts, or validation jobs
  edit the same checkout concurrently.
- Tests and verification must use synthetic data and dedicated roots outside
  the repository. Use the existing `HIREVA_VERIFICATION_MODE`,
  `HIREVA_VERIFICATION_APP_SUPPORT_DIR`, `CFFIXED_USER_HOME`, and related
  isolation hooks where applicable.
- Never write to a real user's Hireva database, Keychain items, settings, or
  `~/Library/Application Support/Hireva` during tests. Read-only, metadata-only
  diagnosis must be explicitly identified as such.
- Keep generated databases, audio, traces, models, logs, reports, app bundles,
  and campaign state outside Git. Do not commit generated artifacts.

## Failure-first workflow

- Reproduce a failure with the smallest relevant test or scenario before
  changing production code.
- Add a regression test that fails for the observed invariant violation, then
  apply the smallest root-cause fix and rerun focused, related, and runtime
  gates in that order.
- Do not delete failing tests, weaken assertions, hide errors, broadly increase
  timeouts, or substitute fixed sleeps for deterministic synchronization.
- Do not claim a mock, provider-only, direct-WAV, or harness result proves a
  real ScreenCaptureKit end-to-end path.

## Git safety

- Inspect the current HEAD and worktree before edits. Preserve unrelated user
  changes and unknown untracked files.
- Do not use destructive reset, clean, checkout, or restore commands. Do not
  force-push, rewrite backup refs, or modify/merge/push `main` without explicit
  user authorization.
- Before committing, require focused tests, `git diff --check`, and scans that
  exclude secrets and generated artifacts.

## Runtime invariants

- A visible or persisted answer must belong to its current session ID,
  question ID, generation ID, and frozen context snapshot ID.
- Late provider or Stage B callbacks and cancelled generations must never
  replace or persist as the current answer.
- Candidate microphone speech must not trigger interviewer answers by default;
  microphone and system-audio samples, speakers, and metadata must stay
  isolated.
- Candidate evidence and opportunity requirements must remain distinct. Never
  turn a job requirement, future plan, generic knowledge, or missing fact into
  a personal experience or metric.
- Provider and ASR source metadata must describe the provider actually used.
- Visible answers and SQLite rows must agree, or the pipeline must emit an
  explicit rejection reason. Successful persistence must occur exactly once.
- Transcript, question, answer, evidence, and trace content must obey the
  active privacy settings. Never log API keys.

## Evidence and external references

- Prefer repository behavior and locked dependency versions, then official
  documentation, then maintained permissively licensed references.
- Record source, version/commit, license, applicability, and whether any code
  was copied. Treat external code as untrusted until local tests pass.
- Never claim a test, configuration, permission path, hardware path, signing
  state, notarization step, or release gate passed unless it ran in the current
  evidence set.
