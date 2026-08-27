# Notarization Preparation

This document records the future public-distribution workflow. It does not
submit the current app for notarization and does not require credentials for
local packaging.

## Current Phase 2J State

- The app is ad-hoc signed with no TeamIdentifier or hardened runtime.
- Zero valid Apple Development or Developer ID Application identities are
  installed in the current environment.
- No stapled notarization ticket is present.
- `notarytool` and `stapler` are installed, but credentials are not configured.

These facts permit local packaging only. They are not notarization evidence.

## Prerequisites

- Apple Developer Program membership is required.
- A **Developer ID Application** certificate and private key are required for
  public distribution outside the Mac App Store.
- Ad-hoc signing is suitable only for local development and trusted local
  handoff.
- Apple Development signing improves local identity stability, but it is not a
  substitute for Developer ID Application signing or notarization.
- Entitlements and hardened-runtime requirements must be reviewed against the
  actual app. Do not add speculative entitlements.

Run `./scripts/signing_status.sh` before preparing a public artifact. Continue
only when the intended Developer ID identity is available and explicitly
selected.

## Future High-Level Flow

1. Verify the exact source commit and run the full stability gate.
2. Build/archive the app from a non-cloud local workspace.
3. Sign the complete app and nested code with **Developer ID Application** and
   the reviewed hardened-runtime options/entitlements.
4. Validate with `codesign --verify --deep --strict --verbose=4`.
5. Create and Developer-ID sign the final DMG container.
6. Verify the package manifest checksum against that exact signed DMG.
7. Submit that DMG with `xcrun notarytool` and wait for an accepted result.
8. Save the submission response and retrieve Apple's notarization log even when
   the status is accepted.
9. Preserve the upload DMG unchanged; staple a private copy of it.
10. Validate the stapled DMG ticket, UDIF integrity, signature, and Gatekeeper
    primary-signature assessment before publishing its final checksum.

The repository scripts implement that contract. The following uses placeholders
only; do not commit resolved identity, Team ID, or profile values:

```bash
HIREVA_SIGNING_MODE=developer-id \
HIREVA_SIGNING_IDENTITY="<Developer ID Application common name or SHA-1>" \
HIREVA_EXPECTED_TEAM_IDENTIFIER=XXXXXXXXXX \
HIREVA_ALLOW_DISTRIBUTION_DMG=1 \
  ./scripts/package_dmg.sh \
  dist/Hireva.app release-candidates/0.1.0-1-developer-id

HIREVA_SIGNING_MODE=developer-id \
HIREVA_BUILD_ARCHS=arm64 \
HIREVA_EXPECTED_TEAM_IDENTIFIER=XXXXXXXXXX \
HIREVA_NOTARY_PROFILE="<local-notarytool-profile>" \
HIREVA_ALLOW_NOTARIZATION_SUBMIT=1 \
HIREVA_RELEASE_OUTPUT_DIR="$(pwd)/release-candidates" \
  ./script/release/notarize_release.sh \
  release-candidates/0.1.0-1-developer-id
```

The second command has an external side effect and must run only with explicit
release-owner approval. A configured profile or installed `notarytool` is not
authorization. The ad-hoc local package workflow remains usable without Apple
credentials and never signs its DMG container.

On success the directory retains the original signed upload DMG and manifest,
`notarization-submit.plist`, `notarization-log.json`, a separately stapled
`.notarized.dmg`, its `.sha256` file, and its notarized manifest. The final
manifest records response/log hashes plus upload and distribution DMG hashes,
but never the identity, Team ID, profile name, or credential.

## Credential Handling

Never store an Apple ID password, app-specific password, API key, private key,
or notary credential in the repository, scripts, release metadata, or logs.
Prefer an app-specific password stored through a local Keychain/notarytool
profile, or an approved App Store Connect API key stored outside the repository.

For example, create the local profile interactively with
`xcrun notarytool store-credentials`, then refer only to the profile name in
automation. Do not commit the command transcript if it contains account data.
