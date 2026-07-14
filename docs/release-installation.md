# Release Installation

> Release status: `0.1.0` is a hardening candidate, not a public release. No
> clean-Mac installation has been completed. Developer ID signing and Apple
> notarization are unavailable until release credentials are provided, so this
> document does not make a release-ready claim.

## Requirements

- Apple Silicon Mac with `arm64` architecture.
- macOS 14.0 or later.
- A release artifact obtained directly from the release owner, together with
  its independently published SHA-256 value.
- Microphone permission for microphone interviews.
- Screen & System Audio Recording permission for system-audio capture.
- Approximately 500 MB for the Parakeet download archive and additional space
  for its extracted ONNX files.

Intel Macs and Rosetta-only installation are not supported by `0.1.0`.

## Distribution Gate

A general-user artifact must be signed with a valid Developer ID Application
certificate, notarized by Apple, stapled, and accepted by Gatekeeper before
these steps are promoted as public installation instructions. Apple documents
those requirements at:

- https://developer.apple.com/support/developer-id/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

The current ad-hoc development bundle does not satisfy that gate.

## Authorized Internal Candidate Installation

Use this section only for an explicitly authorized internal validation build.

1. Record the artifact filename, source, build number, Git commit, and expected
   SHA-256 supplied by the release owner.
2. Verify the archive before opening it:

   ```bash
   shasum -a 256 Hireva-0.1.0-arm64.zip
   ```

3. Extract the archive and inspect the executable architecture:

   ```bash
   ditto -x -k Hireva-0.1.0-arm64.zip Hireva-0.1.0-arm64
   file Hireva-0.1.0-arm64/Hireva.app/Contents/MacOS/Hireva
   file Hireva-0.1.0-arm64/Hireva.app/Contents/Helpers/parakeet_asr_helper
   ```

   Both commands must report `arm64`.

4. Verify bundle integrity and record Gatekeeper output:

   ```bash
   codesign --verify --deep --strict --verbose=4 \
     Hireva-0.1.0-arm64/Hireva.app
   spctl --assess --type execute --verbose=4 \
     Hireva-0.1.0-arm64/Hireva.app
   ```

   An ad-hoc build may pass `codesign` and still fail `spctl`. That is expected
   for the current internal build and is a distribution blocker, not permission
   to describe the artifact as trusted or notarized.

5. Copy `Hireva.app` to `/Applications`, then launch that exact bundle path.
   Do not launch a raw SwiftPM executable.
6. For an authorized internal build only, macOS may offer **Open Anyway** after
   the first blocked attempt. Use an override only after independently verifying
   the artifact and source. Public candidates must pass Gatekeeper without this
   override. Apple explains the risk at https://support.apple.com/102445.

Apple's general installation guidance is available at:
https://support.apple.com/en-gb/guide/mac-help/-mh35835/mac

## First Launch

1. Grant only the permissions required for the intended capture mode.
2. Quit and reopen Hireva after changing Screen & System Audio Recording
   permission.
3. Open **Setup & Local Models**.
4. Install the Parakeet model if local Parakeet ASR will be used. The model is
   not bundled; follow `docs/local-model-installation.md`.
5. Enable Local Parakeet only after both model and native runtime report ready.
6. If local Qwen is required, install and run Ollama separately. Hireva does not
   bundle Ollama: https://ollama.com/download/mac

## Updates And Removal

No public auto-update channel is established for `0.1.0`. Validate each new app
artifact independently before replacing the installed bundle.

Moving `Hireva.app` to Trash does not remove interview records, traces,
attachments, exports, downloaded models, Keychain entries, or Ollama data. See
`docs/privacy-and-data-flow.md` before deleting any user data.

## Validation Still Required

The complete workflow in `docs/clean-mac-validation-checklist.md` remains
unchecked. Do not publish these instructions as a successful install record or
mark `0.1.0` release-ready until Developer ID/notarization and clean-Mac gates
pass against the exact final artifact.
