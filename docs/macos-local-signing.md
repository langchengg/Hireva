# macOS Local Signing and Distribution

This guide covers local development distribution. Notarization is a separate
requirement for broadly distributing an app outside a trusted local workflow.

## Current Local Signing State

`script/build_and_run.sh` uses an explicit
`INTERVIEW_COPILOT_SIGNING_IDENTITY` when provided. Otherwise it falls back to
ad-hoc signing. Ad-hoc signing can satisfy structural `codesign` verification,
but it does not establish a stable trusted developer identity and Gatekeeper
may still reject the app.

The stable local identity consists of all three values:

- bundle ID: `com.langcheng.InterviewCopilotMac`;
- bundle path: `dist/InterviewCopilotMac.app`;
- code-signing identity/designated requirement.

## Why Rebuilds Can Trigger Keychain or TCC Prompts

An ad-hoc rebuild normally produces a different CDHash. macOS Keychain and TCC
evaluate the app's code requirement as well as its bundle ID and path, so a new
CDHash can be treated as changed code. The result can be a fresh Keychain access
prompt or lost microphone, speech, or Screen & System Audio Recording grants.

An Apple Development identity gives rebuilds a stable signing authority and is
recommended for repeatable local handoff. It does not by itself notarize the
app or make it suitable for public distribution.

## Find Available Identities

```bash
security find-identity -v -p codesigning
```

If this reports zero valid identities, install an Apple Development certificate
and private key through the normal Apple developer/Xcode workflow before using
identity signing.

## Build and Verify with Apple Development Signing

```bash
INTERVIEW_COPILOT_SIGNING_IDENTITY="Apple Development: NAME (TEAMID)" ./script/build_and_run.sh --verify
```

Use the exact identity string returned by `security find-identity`. Do not put
the identity or API keys into source files.

## Diagnose Signing and Gatekeeper Failures

```bash
codesign -dv --verbose=4 dist/InterviewCopilotMac.app
codesign --verify --deep --strict --verbose=4 dist/InterviewCopilotMac.app
spctl --assess --type execute --verbose=4 dist/InterviewCopilotMac.app || true
xattr -lr dist/InterviewCopilotMac.app || true
```

Interpret the results separately:

- `codesign --verify` failure means the signature or sealed bundle is invalid.
- `codesign --verify` success plus `Signature=adhoc` confirms only local ad-hoc
  signing.
- `spctl` rejection of an ad-hoc bundle is expected on systems requiring a
  trusted/notarized developer identity; it is not proof that compilation failed.
- a missing `TeamIdentifier` or signing authority indicates ad-hoc or unsigned
  code rather than Apple Development signing.

The build script also records bundle metadata, signing information, and recent
AMFI logs when launch verification fails.

## Google Drive and Cloud-Synced Folders

Google Drive, Finder, and file-provider synchronization can recreate extended
attributes, `.DS_Store`, resource forks, or AppleDouble `._*` files after the
build script removes them. These files can invalidate the sealed bundle or make
signing failures appear intermittent.

If metadata keeps returning:

1. let synchronization finish and rebuild once;
2. inspect with `xattr -lr` and `find dist -name '._*' -o -name '.DS_Store'`;
3. copy or clone the repository to a non-cloud local path;
4. rebuild and repeat `codesign --verify` there before changing signing logic.

Do not add entitlements speculatively to fix a metadata or trust-policy failure.
Public distribution additionally requires an appropriate distribution identity,
hardened runtime/entitlements review, and Apple notarization validation.

## Phase 2J Distribution References

- Package a validated local handoff: `scripts/package_local_release.sh`
- Classify installed identities and current signature: `scripts/signing_status.sh`
- Move builds out of Google Drive: `docs/local-workspace-migration.md`
- Prepare future Developer ID notarization: `docs/notarization-prep.md`
- Restore a known-good source safely: `docs/rollback-known-good.md`
