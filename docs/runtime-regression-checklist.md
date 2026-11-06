# Runtime Regression Checklist

## Standard Pre-Merge Gate

Run the complete automated stability gate from the repository root:

```bash
./scripts/verify_runtime_stability.sh
```

This command runs the Swift build, full test suite, terminal runtime smoke
harness, and a signed, verified build in the managed application slot. A
passing `swift test` result alone is not sufficient acceptance for runtime
changes.

The final step uses `--build-only`; it does not launch or terminate applications.
The artifact coordinator refuses to replace a running or externally changed
managed bundle. GUI and real-audio verification are separate checks.

## macOS Signing and Launch Verification

Ad-hoc signing is the default explicit local mode, but repeated rebuilds produce
a new code-signing hash. AMFI can reject an ad-hoc build on some systems, and
TCC permissions can stop matching the rebuilt app. An Apple Development
identity is recommended for stable launch verification.

List the available code-signing identities:

```bash
security find-identity -v -p codesigning
```

Run verification with a configured identity:

```bash
HIREVA_SIGNING_MODE=development HIREVA_SIGNING_IDENTITY="Apple Development: NAME (TEAMID)" ./script/build_and_run.sh --verify
```

The canonical artifact coordinator keeps build caches and bundles outside the
source checkout, including when the checkout is under a cloud file-provider path.
It signs a fresh owned staging bundle before publication.

When launch verification fails, `build_and_run.sh` prints the following
diagnostics automatically. They can also be run manually:

```bash
HIREVA_CHECK_APP="$(python3 script/artifact_lifecycle.py paths)"
codesign -dv --verbose=4 "$HIREVA_CHECK_APP"
codesign --verify --deep --strict --verbose=4 "$HIREVA_CHECK_APP"
spctl --assess --type execute --verbose=4 "$HIREVA_CHECK_APP" || true
xattr -lr "$HIREVA_CHECK_APP" || true
```

Use the read-only database diagnostic when investigating persisted runtime
state:

```bash
./scripts/db_diagnostics.sh
```

Its output can contain interview questions and answers; handle captured output
as sensitive data.

## When Manual System Audio Smoke Is Required

Run the real System Audio smoke after changes to any of these boundaries:

- audio capture or capture-mode routing;
- Apple Speech callbacks or ASR partial/final handling;
- transcript UI state or transcript event propagation;
- accepted-question queue lifecycle or queue drain;
- suggestion persistence or persistence guards;
- provider streaming, cancellation, timeout, or late-callback handling.

The terminal harness replaces most repeated manual testing, but it does not
exercise macOS hardware, TCC permission state, or real Apple Speech callbacks.

## Manual Smoke Sequence

Use one fresh session in System Audio Only mode. Play these questions in order
and wait for each visible answer:

1. `What would you ask the engineering team to understand whether this role is a good fit?`
2. `If you had one more month to improve your LeoRover system, what would you improve first?`
3. `Can you explain the difference between your VLA project and your LeoRover project?`

Expected persisted intents:

- `interviewer_questions`
- `improvement_plan` or `project_improvement`
- `project_comparison`

Confirm the three questions remain separate, each visible answer matches its
question, queue drain completes, and the UI/session state agrees with SQLite.

## Acceptance Blockers

Do not accept a runtime change when any of these occurs:

- an expected `suggestion_cards` row is missing;
- a known question persists with `generic` intent;
- a final answer is `unknown`, `weaklyAligned`, or `mismatched`;
- the UI shows an old question with a new answer, or the reverse;
- an incomplete answer is persisted;
- a partial question creates a duplicate answer;
- consecutive questions are merged into one question;
- the terminal smoke harness passes but real System Audio fails.

## Acceptance Rule

Do not accept `swift test passed` alone for runtime changes. Automated runtime
smoke, app-bundle verification, and any required real System Audio smoke must
also pass.

## Release Handoff References

- Build, launch, configuration, and troubleshooting: `docs/release-runbook.md`
- Release acceptance and rollback: `docs/release-checklist.md`
- Stable local signing and Gatekeeper diagnosis: `docs/macos-local-signing.md`
- Read-only release metadata and runtime paths: `scripts/release_status.sh`
- Local allowlisted package creation: `scripts/package_local_release.sh`
- Signing identity classification: `scripts/signing_status.sh`
- Non-cloud workspace migration: `docs/local-workspace-migration.md`
- Future notarization requirements: `docs/notarization-prep.md`
- Known-good rollback: `docs/rollback-known-good.md`
