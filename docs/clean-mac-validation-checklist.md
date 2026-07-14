# Clean-Mac Validation Checklist

> Current result: **not run**. Every item below remains unchecked. Do not make a
> release-ready claim until this checklist passes against the exact final
> Developer ID-signed and notarized artifact.

## Test Record

- [ ] Tester, date, Mac model, macOS version, and architecture recorded.
- [ ] Release filename, version/build, Git commit/tag, source URL, byte size,
      and expected SHA-256 recorded.
- [ ] Test Mac is Apple Silicon `arm64` with macOS 14.0 or later.
- [ ] No prior Hireva app, Application Support directory, TCC grants, Keychain
      entries, Ollama process, or Hireva/Ollama models are present.
- [ ] Network conditions and any proxy, VPN, firewall, or content filter are
      recorded.

## Artifact Integrity And Trust

- [ ] Release archive SHA-256 matches the independently published value.
- [ ] `codesign --verify --deep --strict --verbose=4 Hireva.app` passes.
- [ ] All nested executables and dylibs are signed with the intended Developer
      ID Application identity.
- [ ] `spctl --assess --type execute --verbose=4 Hireva.app` passes without a
      user security override.
- [ ] `xcrun stapler validate Hireva.app` confirms the notarization ticket.
- [ ] App, helper, sherpa-onnx dylib, and ONNX Runtime dylib report `arm64`.
- [ ] Bundle contains no Python executable, Python sidecar, Python package,
      `numpy`, model weights, SQLite database, trace, or user data.
- [ ] Distribution contains the required third-party full licenses, ONNX
      Runtime `ThirdPartyNotices.txt`, and model attribution/change notice.

Apple source of truth:
https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Installation And First Launch

- [ ] App installs into `/Applications` using the published procedure.
- [ ] First launch succeeds without **Open Anyway** or another Gatekeeper
      bypass.
- [ ] About/build identity reports version `0.1.0`, build `1`, and the expected
      bundle identifier.
- [ ] App creates only expected paths under
      `~/Library/Application Support/Hireva`.
- [ ] Relaunch from `/Applications/Hireva.app` succeeds with stable identity.

## Permissions

- [ ] Microphone denial leaves capture disabled and produces a clear status.
- [ ] Microphone approval enables microphone capture after the documented
      restart behavior.
- [ ] Screen & System Audio Recording denial leaves system-audio capture
      disabled and produces a clear status.
- [ ] Approval followed by a full quit/reopen enables system-audio capture.
- [ ] Changing microphone/audio devices does not crash, hang, or install
      duplicate taps.

## Native Parakeet Runtime

- [ ] Runtime diagnostics report `bundled_native`, `arm64`, sherpa-onnx
      `1.13.4`, and ONNX Runtime `1.27.0`.
- [ ] Release build ignores external helper override paths.
- [ ] Local Parakeet cannot be selected while the model is absent.
- [ ] No Python or `numpy` installation is required or requested.

## Parakeet Model Installation

- [ ] Download goes only to the documented GitHub/trusted release-asset hosts.
- [ ] Downloaded archive reports exactly `487170055` bytes.
- [ ] Archive SHA-256 equals
      `5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf`.
- [ ] Installed path is exactly
      `~/Library/Application Support/Hireva/LocalModels/asr/parakeet-tdt-0.6b-v3-int8/asr-models-5793d0fd397c5778`.
- [ ] Interrupted download does not produce an installed/ready state.
- [ ] Tampered archive and payload fixtures are rejected without replacing a
      verified install.
- [ ] Repair succeeds from a damaged state; rollback is offered only when a
      verified prior version exists.
- [ ] A known audio sample produces a non-empty
      `local_parakeet_asr` transcript without network access after installation.

## Ollama Boundary

- [ ] With Ollama absent, Hireva launches and reports local Qwen unavailable
      without attempting to treat Ollama as bundled.
- [ ] Installing Ollama follows the external official installer:
      https://ollama.com/download/mac
- [ ] Hireva communicates with Ollama only through the configured localhost
      endpoint for the tested local setup.
- [ ] Ollama model downloads, storage, logs, and removal are documented as
      Ollama-owned, not Hireva-owned.

## Privacy And Persistence

- [ ] Local-Parakeet-only run sends no interview audio or transcript to NVIDIA,
      sherpa-onnx, Microsoft, GitHub, DeepSeek, or another remote provider.
- [ ] DeepSeek use is opt-in and clearly indicates that prompt/interview context
      is sent to `https://api.deepseek.com/chat/completions`.
- [ ] API keys are stored in Keychain and do not appear in SQLite, traces,
      exports, logs, or crash output.
- [ ] SQLite, runtime trace, attachments, exports, preferences, Keychain items,
      and local model locations match `docs/privacy-and-data-flow.md`.
- [ ] Shared diagnostics are redacted and contain no secret or interview
      content not explicitly approved by the tester.

## Functional Smoke

- [ ] Microphone-only interview produces correctly attributed transcript,
      question, answer, and persistence records.
- [ ] System-audio-only interview produces the same end-to-end result after
      permission approval.
- [ ] Mixed capture keeps microphone and system-audio speaker/source attribution
      correct.
- [ ] Three rapid questions preserve question/answer alignment and expected
      database rows.
- [ ] Quit/relaunch preserves intended settings and does not duplicate or lose
      completed records.

## Removal And Residue

- [ ] Removing the app leaves user data in place only where documented.
- [ ] Separate, explicitly approved removal of Application Support, preferences,
      Keychain items, and Ollama data is tested without deleting unrelated data.
- [ ] Reinstallation after full approved cleanup behaves like a true first
      launch.

## Release Decision

- [ ] All failures have owners, evidence, and a resolved retest result.
- [ ] Third-party licenses/notices and privacy wording match the exact artifact.
- [ ] Developer ID signing, notarization, stapling, and Gatekeeper checks pass.
- [ ] A second reviewer confirms the checklist evidence.
- [ ] Release owner explicitly records **GO** for the exact artifact.

Until every release-decision item is checked, the result is **NO-GO** and the
artifact must not be described as release-ready.
