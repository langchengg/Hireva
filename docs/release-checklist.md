# Release Checklist

Complete this checklist against the exact commit and app bundle being handed
over. Record command output rather than relying on an earlier run.

## Git Clean State

- [ ] `git branch --show-current` reports the intended release branch.
- [ ] `git status --short` is empty, or every listed file is explicitly reviewed
      and included in the release.
- [ ] `git diff --check` passes.
- [ ] No secrets, local databases, traces, or diagnostic output are tracked.

## Version and Tag

- [ ] `VERSION` and `BUILD_NUMBER` in `script/build_and_run.sh` match the release.
- [ ] The release tag points to the exact verified commit.
- [ ] `./scripts/release_status.sh` reports the expected branch, commit, and tag.

## Swift Tests

- [ ] `swift test` passes with no skipped or weakened runtime tests.

## Runtime Smoke

- [ ] `./scripts/runtime_smoke.sh --suite all` passes.
- [ ] The rapid-question suites preserve question/answer alignment and DB rows.

## Build Verification

- [ ] `./script/build_and_run.sh --verify` passes.
- [ ] The launched process is
      `dist/InterviewCopilotMac.app/Contents/MacOS/InterviewCopilotMacRunner`.
- [ ] The bundle ID is `com.langcheng.InterviewCopilotMac`.

## Full Stability Gate

- [ ] `./scripts/verify_runtime_stability.sh` passes for the release commit.

## Database Diagnostics

- [ ] `./scripts/db_diagnostics.sh` runs successfully.
- [ ] After runtime changes, expected `suggestion_cards` rows exist and align
      with the visible UI/session history.
- [ ] Diagnostic output is handled as sensitive interview data.

## Optional Real System Audio Smoke

- [ ] Required after audio, ASR, transcript event, queue, persistence, or
      provider lifecycle changes; otherwise record **not required** with reason.
- [ ] When required, the three-question sequence in
      `docs/runtime-regression-checklist.md` passes in one fresh session.
- [ ] Permission, UI, SQLite, and runtime trace evidence agree.

## Signing Status

- [ ] `security find-identity -v -p codesigning` output is recorded.
- [ ] Signing mode is recorded as Apple Development or ad-hoc fallback.
- [ ] `codesign --verify --deep --strict --verbose=4 dist/InterviewCopilotMac.app`
      passes.
- [ ] Any Gatekeeper rejection is classified separately from signature validity.
- [ ] Local handoff limitations are documented using `docs/macos-local-signing.md`.

## Known Limitations

- Ad-hoc rebuilds change CDHash and can cause Keychain/TCC prompts.
- The current local bundle is not automatically a notarized public distribution.
- Google Drive/Finder can recreate xattrs, `.DS_Store`, and AppleDouble `._*` files.
- Terminal runtime smoke does not exercise real TCC, ScreenCaptureKit, hardware,
  or Apple Speech callbacks.

## Do not release if

- `verify_runtime_stability.sh` fails.
- `runtime_smoke.sh` fails.
- app launch verification fails.
- DB persistence cannot be verified after runtime changes.
- System Audio fails after audio/ASR changes.
- a visible answer and its persisted question/answer are misaligned.

## Rollback Procedure

1. Stop distributing the failed artifact and record its commit, tag, signing
   mode, and failure evidence.
2. Preserve the user's SQLite database and runtime trace before replacing the
   app bundle; do not mutate either file as part of rollback.
3. Build the last known-good tag/commit from a separate clean worktree or clone.
4. Run the full stability gate against that source.
5. Rebuild and sign the replacement with the same stable bundle ID, path, and
   Apple Development identity when available.
6. Launch with `./script/build_and_run.sh --verify` and repeat any manual System
   Audio smoke required by the changed boundary.
7. Document the rollback result and the forward-fix owner.
