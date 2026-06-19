# AI Coding Agent Runtime Rules

These rules protect the live transcript-to-answer pipeline during future AI
assisted changes.

1. Every generation must originate from an `AcceptedQuestionCandidate` and
   pass the runtime acceptance guard before provider work begins.
2. Bad or incomplete transcript fragments may update transcript UI, but they
   must not trigger answer generation or persistence.
3. Every visible answer must either persist successfully or emit a concrete
   rejection reason in runtime diagnostics.
4. Queue drain must have a terminal path and must not wait forever for Stage B.
5. Every local fallback must be a complete, speakable, project-grounded answer
   for the current question.
6. Use the terminal smoke harness for repeatable regression coverage; it
   replaces most manual testing.
7. Treat real System Audio smoke as final hardware, Apple Speech, and macOS TCC
   validation when a risky runtime boundary changes.
8. Never hide runtime failures by tightening filters without tracing and
   recording the rejected event.
9. Do not accept `swift test` alone for runtime changes. Run
   `./scripts/verify_runtime_stability.sh` and complete any manual smoke required
   by `docs/runtime-regression-checklist.md`.
10. Rebuild and verify the actual `dist/InterviewCopilotMac.app` after every
    implementation change; do not validate runtime permissions from `.build`.

## Release-Readiness References

- Use `docs/release-runbook.md` for exact build, launch, configuration, and
  operator troubleshooting steps.
- Complete `docs/release-checklist.md` before handing over a release artifact.
- Use `docs/macos-local-signing.md` to distinguish ad-hoc signing, code-signing
  failures, and Gatekeeper trust policy.
- Run `scripts/release_status.sh` for read-only branch, bundle, signing, DB, and
  trace metadata. Never include secrets in its output.
- Use `scripts/package_local_release.sh` only after its verification contract is
  understood; never weaken its allowlist or forbidden-artifact scan.
- Use `scripts/signing_status.sh` to classify signing without inventing an
  identity or hiding ad-hoc limitations.
- Follow `docs/local-workspace-migration.md`, `docs/notarization-prep.md`, and
  `docs/rollback-known-good.md` for local migration, future notarization, and
  recovery. Never place credentials or runtime data in release artifacts.
