# Signing and Notarization Notes

The current project is a SwiftPM-native macOS app staged into `dist/Hireva.app` by `script/build_and_run.sh` for local development. That bundle includes a stable bundle identifier, version metadata, and microphone/speech permission strings.

For future public distribution, follow `docs/notarization-prep.md`. Do not add
candidate entitlements until the actual Developer ID build and distribution
channel have been reviewed.

1. Create the release bundle with a stable Developer ID Application identity.
2. Review the actual required entitlements and hardened-runtime configuration.
3. Sign the app and nested code with the reviewed configuration.
4. Package the DMG with an explicit identity, expected Team ID, and distribution
   authorization. The script signs and strictly verifies the completed DMG in
   Developer ID mode; it never re-signs the app.
5. Validate the app and signed DMG:
   - `codesign -dvvv --entitlements :- dist/Hireva.app`
   - `codesign --verify --deep --strict dist/Hireva.app`
   - `codesign --verify --strict Hireva-<version>-<build>-arm64.dmg`
6. Submit the exact manifest-checksummed DMG through
   `script/release/notarize_release.sh` only with separate explicit upload
   authorization.
7. After `Accepted`, validate the stapled final DMG with `stapler`, `hdiutil`,
   `codesign`, and `spctl -a -t open --context context:primary-signature`.

No private APIs, stealth behavior, process disguise, screen-share bypass, or anti-detection mechanisms are part of this app.
