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
      `dist/Hireva.app/Contents/MacOS/Hireva`.
- [ ] The bundle ID is `com.langcheng.Hireva`.

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

- [ ] `./scripts/signing_status.sh` reports the expected explicit status.
- [ ] `security find-identity -v -p codesigning` output is recorded.
- [ ] Signing mode is recorded as Apple Development or ad-hoc fallback.
- [ ] `codesign --verify --deep --strict --verbose=4 dist/Hireva.app`
      passes.
- [ ] Any Gatekeeper rejection is classified separately from signature validity.
- [ ] Local handoff limitations are documented using `docs/macos-local-signing.md`.

## Known Limitations

- Ad-hoc rebuilds change CDHash and can cause Keychain/TCC prompts.
- The current local bundle is not automatically a notarized public distribution.
- A packaged copy launched outside the source workspace's canonical `dist` path
  can show the existing stale-build warning because the expected bundle path is
  embedded as an absolute build-identity value.
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

## Local Distribution Package

- [ ] `./scripts/package_local_release.sh` passes without `--skip-verify`.
- [ ] `RELEASE_INFO.txt` records branch, commit, dirty state, bundle ID,
      verification results, signing mode, and local-path warnings.
- [ ] Recipients understand that the copied app is a local handoff artifact and
      may show the existing stale-build warning outside the canonical `dist` path.
- [ ] The release directory and ZIP contain only the app and named operator docs.
- [ ] Archive listing contains no `.git`, `.build`, DB, trace, `.DS_Store`,
      AppleDouble `._*`, Keychain, or transcript data.
- [ ] If the source is under Google Drive, migration guidance in
      `docs/local-workspace-migration.md` is acknowledged.
- [ ] Public distribution is blocked until `docs/notarization-prep.md` is
      completed with a Developer ID Application identity and accepted ticket.
- [ ] Rollback source and procedure are recorded using
      `docs/rollback-known-good.md`.

Phase 2J references: `scripts/package_local_release.sh`,
`scripts/signing_status.sh`, `docs/local-workspace-migration.md`,
`docs/notarization-prep.md`, and `docs/rollback-known-good.md`.

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
