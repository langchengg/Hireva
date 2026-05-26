# Signing and Notarization Notes

The current project is a SwiftPM-native macOS app staged into `dist/InterviewCopilotMac.app` by `script/build_and_run.sh` for local development. That bundle includes a stable bundle identifier, version metadata, and microphone/speech permission strings.

For distribution:

1. Create an Xcode archive or equivalent release bundle with a stable signing identity.
2. Add only required public entitlements, expected candidates:
   - `com.apple.security.network.client`
   - `com.apple.security.device.audio-input`
   - app sandbox entitlements if distributing through a sandboxed channel.
3. Sign the app and nested code with hardened runtime enabled.
4. Validate:
   - `codesign -dvvv --entitlements :- dist/InterviewCopilotMac.app`
   - `codesign --verify --deep --strict dist/InterviewCopilotMac.app`
   - `spctl -a -vv dist/InterviewCopilotMac.app`
5. Submit the signed archive for notarization with Apple notary tooling.

No private APIs, stealth behavior, process disguise, screen-share bypass, or anti-detection mechanisms are part of this app.
