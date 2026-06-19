# Runtime Regression Checklist

## Standard Pre-Merge Gate

Run the complete automated stability gate from the repository root:

```bash
./scripts/verify_runtime_stability.sh
```

This command runs the Swift build, full test suite, terminal runtime smoke
harness, and verified rebuild/launch of `dist/InterviewCopilotMac.app`. A
passing `swift test` result alone is not sufficient acceptance for runtime
changes.

The final verification step terminates any running app instance, rebuilds and
signs the app bundle, then relaunches it to verify the packaged executable.

## macOS Signing and Launch Verification

Ad-hoc signing is the fallback for local builds, but repeated rebuilds produce
a new code-signing hash. AMFI can reject an ad-hoc build on some systems, and
TCC permissions can stop matching the rebuilt app. An Apple Development
identity is recommended for stable launch verification.

List the available code-signing identities:

```bash
security find-identity -v -p codesigning
```

Run verification with a configured identity:

```bash
INTERVIEW_COPILOT_SIGNING_IDENTITY="Apple Development: NAME (TEAMID)" ./script/build_and_run.sh --verify
```

The repository is currently under a Google Drive file-provider path. Cloud
synchronization can recreate extended attributes, `.DS_Store`, or AppleDouble
`._*` files after cleanup, making signing verification unstable. If those
artifacts keep returning, copy the repository to a non-cloud local path before
diagnosing the signing identity itself.

When launch verification fails, `build_and_run.sh` prints the following
diagnostics automatically. They can also be run manually:

```bash
codesign -dv --verbose=4 dist/InterviewCopilotMac.app
codesign --verify --deep --strict --verbose=4 dist/InterviewCopilotMac.app
spctl --assess --type execute --verbose=4 dist/InterviewCopilotMac.app || true
xattr -lr dist/InterviewCopilotMac.app || true
log show --predicate 'process == "amfid" OR eventMessage CONTAINS "InterviewCopilotMac"' --last 5m --style compact
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
