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
5. Create the final ZIP or DMG artifact.
6. Submit with `xcrun notarytool` and wait for an accepted result.
7. Staple the ticket with `xcrun stapler staple`.
8. Validate the stapled artifact and Gatekeeper assessment on a clean system.

Representative future commands, after credentials and artifact naming are
defined:

```bash
xcrun notarytool submit "Hireva.zip" \
  --keychain-profile "HirevaNotary" \
  --wait

xcrun stapler staple "Hireva.app"
xcrun stapler validate "Hireva.app"
spctl --assess --type execute --verbose=4 "Hireva.app"
```

Do not implement or run submission merely because `notarytool` is installed.
The current local package workflow must remain usable without Apple credentials.

## Credential Handling

Never store an Apple ID password, app-specific password, API key, private key,
or notary credential in the repository, scripts, release metadata, or logs.
Prefer an app-specific password stored through a local Keychain/notarytool
profile, or an approved App Store Connect API key stored outside the repository.

For example, create the local profile interactively with
`xcrun notarytool store-credentials`, then refer only to the profile name in
automation. Do not commit the command transcript if it contains account data.
