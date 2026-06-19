# Signing and Notarization Notes

The current project is a SwiftPM-native macOS app staged into `dist/InterviewCopilotMac.app` by `script/build_and_run.sh` for local development. That bundle includes a stable bundle identifier, version metadata, and microphone/speech permission strings.

For future public distribution, follow `docs/notarization-prep.md`. Do not add
candidate entitlements until the actual Developer ID build and distribution
channel have been reviewed.

1. Create the release bundle with a stable Developer ID Application identity.
2. Review the actual required entitlements and hardened-runtime configuration.
3. Sign the app and nested code with the reviewed configuration.
4. Validate:
   - `codesign -dvvv --entitlements :- dist/InterviewCopilotMac.app`
   - `codesign --verify --deep --strict dist/InterviewCopilotMac.app`
   - `spctl -a -vv dist/InterviewCopilotMac.app`
5. Submit the signed archive for notarization with Apple notary tooling.

No private APIs, stealth behavior, process disguise, screen-share bypass, or anti-detection mechanisms are part of this app.
