# Hireva

Hireva is a native macOS SwiftUI interview copilot. It captures user-selected
microphone and/or system audio, transcribes complete interviewer questions,
retrieves evidence from the active synthetic or user-provided interview
context, and shows an answer bound to one session, question, generation, and
frozen context snapshot.

## Architecture

```text
Microphone / System Audio
  -> Apple Speech or Local Parakeet
  -> source and speaker attribution
  -> transcript normalization and complete-question detection
  -> frozen profile, opportunity, dialogue, and RAG context
  -> Local Qwen or optional DeepSeek
  -> answer alignment and generation-ownership checks
  -> SwiftUI floating assistant
  -> GRDB / SQLite persistence and privacy-controlled diagnostics
```

The pipeline is provider-neutral. No callback may publish or persist an answer
unless its session, question, generation, and context snapshot still own the
active request.

## Provider Matrix

| Capability | Provider | Default/availability | Data boundary | Streaming behavior |
| --- | --- | --- | --- | --- |
| ASR | Apple Speech | Default | Apple Speech framework; do not assume offline operation | Partial and final callbacks as supplied by the framework |
| ASR | Local Parakeet | Optional, experimental, Apple Silicon only | Bundled native helper plus model files in Application Support | Final-only utterance transcripts |
| Answers | Local Qwen through Ollama | Default only when Ollama and the selected model are ready | Loopback Ollama API | Incremental final-answer chunks; model thinking is not displayed |
| Answers | DeepSeek | Optional remote provider | Prompt and selected context leave the Mac over HTTPS | Remote provider stream |

Hireva does not silently relabel Apple Speech output as Parakeet and does not
silently substitute a different answer provider.

## Permission Matrix

| ASR | Capture | Microphone | Speech Recognition | Screen & System Audio Recording |
| --- | --- | --- | --- | --- |
| Apple Speech | Microphone Only | Required | Required | Not required |
| Apple Speech | System Audio Only | Not required | Required | Required |
| Apple Speech | Mic + System | Required | Required | Required |
| Local Parakeet | Microphone Only | Required | Not required | Not required |
| Local Parakeet | System Audio Only | Not required | Not required | Required |
| Local Parakeet | Mic + System | Required | Not required | Required |

Denied permissions disable only the affected path. Permission checks never
authorize a fallback with incorrect provider metadata.

## Local And Cloud Data Boundaries

- Sessions, detected questions, suggestions, context snapshots, and optional
  transcripts are stored in GRDB/SQLite under Application Support.
- `Save transcripts locally` controls transcript rows. Runtime diagnostic
  traces are separately controlled by `DiagnosticTraceMode` and default to
  `off`; `metadataOnly` excludes transcript/question/answer text; `fullText`
  requires an explicit warning-backed opt-in.
- Local Parakeet audio stays in the app and bundled native helper after model
  installation. Local Qwen prompts go to the user-managed loopback Ollama
  service.
- DeepSeek and configured cloud embeddings transmit selected text to their
  configured remote services.
- Provider keys are stored in macOS Keychain and must never appear in logs,
  SQLite, release packages, or Git.

## Model Setup

Local Qwen requires a running Ollama service and the configured model, for
example:

```bash
ollama pull qwen3.5:4b
ollama list
```

Local Parakeet is installed and probed from Hireva's Local Models setup. The
release app uses `Contents/Helpers/parakeet_asr_helper`; Python is not a release
runtime dependency. See `docs/parakeet-local-asr-runtime.md`.

## Build, Test, And Run

```bash
swift package resolve
swift build
swift test
./scripts/runtime_smoke.sh --suite all
./scripts/verify_runtime_stability.sh
./script/build_and_run.sh --verify
```

Real macOS permission checks must launch `dist/Hireva.app`, never the raw
SwiftPM executable.

## Current Limitations

- Local Parakeet is experimental, arm64-only, and final-only.
- Apple Speech availability and on-device behavior depend on macOS and locale.
- System-audio verification requires a real Screen & System Audio Recording
  grant and audible source; mocks do not prove that path.
- Ollama is a separately installed and operated local service.
- Bluetooth route switching can be claimed only after a real-device test.

## Local Release Versus Public Distribution

`scripts/package_local_release.sh` creates an allowlisted package for controlled
local use. An ad-hoc signature can validate bundle integrity but is not a public
distribution identity. Distribution outside the Mac App Store requires a
Developer ID Application signature, hardened runtime, notarization, ticket
stapling, Gatekeeper assessment, and clean-Mac validation.

## Audio Route Recovery & Device Switching Manual Test Checklist

Use the following checklist to verify that audio capture, route recovery, and device switching are working correctly:

### Test Scenario: Dynamic Input Device Transition

1. **Start Capture**:
   - Open the **Audio Diagnostics** tab or the **Live Interview** tab.
   - Click **Start Listening** (or **Start Mic Test**) using the built-in Mac microphone.
2. **Verify Level Meter**:
   - Speak into the built-in microphone and confirm the mic level meter/waveform moves, showing active input.
3. **Switch to Bluetooth**:
   - Change your macOS system audio input device to a Bluetooth headset (e.g. AirPods or any Bluetooth microphone) via the macOS Sound menu or System Settings.
4. **Confirm Reconnection UI**:
   - Confirm that the application UI immediately detects the change and shows the recovery message: **“Audio device changed / reconnecting...”** or **“Reconnecting audio”**.
5. **Verify Bluetooth Input**:
   - Speak into your Bluetooth headset.
   - Confirm that the mic level meter starts moving again, showing active input from the Bluetooth headset.
   - If in a live session, confirm that the transcription resumes capturing from the Bluetooth microphone.
6. **Switch Back to Built-in Mic**:
   - Switch the system input device back to the built-in Mac microphone.
7. **Verify Final Recovery**:
   - Confirm that the audio system recovers automatically a second time and shows: **“Audio input restored.”** or **“Restored”**.
   - Speak into the built-in mic and confirm the level meter continues to move.
8. **Verify Stability**:
   - Confirm that the application does not crash or hang during these transitions.
   - Verify in the logs/diagnostics that no duplicate input taps are installed (which would cause a crash).

---

## Manual "Restart Audio Input" Recovery Path

If the system capture does not automatically recover after a route change, you can manually trigger a dynamic capture reset:
- Click the **"Restart Audio Input"** button in **Audio Diagnostics** or the **Live Interview** toolbar.
- The app will teardown the audio engine tap, re-query the current format dynamically, reinstall the tap, and resume capture and transcription without requiring a session or application restart.

---

## Permissions & Development Signing

### Stable App Identity

macOS tracks permissions (TCC) by **bundle identifier + code signing identity + bundle path**. To avoid being re-prompted for microphone, speech, and screen recording permissions after every rebuild:

- **Bundle Identifier**: `com.langcheng.Hireva` (set in `build_and_run.sh`, never change without resetting TCC)
- **Bundle Path**: Always `dist/Hireva.app` (stable across rebuilds)
- **Signing**: The build script signs the app with an available configured
  identity or uses an ad-hoc local fallback. Ad-hoc signing is never a public
  distribution result.

### Build, Sign & Launch

```bash
# Build, sign, and launch the app
./script/build_and_run.sh

# Build, sign, launch, and verify it's running
./script/build_and_run.sh --verify

# Launch with streaming log output
./script/build_and_run.sh --logs
```

**Important**: Always launch from the .app bundle via the script. Do not run the raw Swift executable directly — macOS will not persist permissions for unsigned executables.

### Screen & System Audio Recording

Screen Recording / Screen & System Audio Recording permission in macOS requires the app to **quit and reopen** after being granted in System Settings. This is a macOS system requirement, not an app bug.

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**
2. Enable **Hireva**
3. **Quit** the app completely
4. Reopen from the same .app bundle path

The app's Audio Diagnostics screen shows a banner with a **"Quit App Now"** button when this permission is missing.

### Resetting Stuck Permissions During Development

TCC reset is destructive and is not a normal troubleshooting or release step.
Use it only when intentionally changing the development identity and after
confirming existing grants may be removed:

```bash
# Option 1: Use the build script
./script/build_and_run.sh --reset-tcc

# Option 2: Manual reset
tccutil reset Microphone com.langcheng.Hireva
tccutil reset SpeechRecognition com.langcheng.Hireva
tccutil reset ScreenCapture com.langcheng.Hireva
```

Then rebuild, launch the same .app bundle path, and grant permissions again.

### Verifying Permission Persistence

1. Launch app from `dist/Hireva.app`
2. Grant microphone permission
3. Quit app
4. Reopen same app bundle → microphone permission should remain granted
5. Grant Screen & System Audio Recording in System Settings
6. Quit and reopen → `CGPreflightScreenCaptureAccess()` should return true
7. Rebuild (`./script/build_and_run.sh`) → permissions should persist

### Developer Terminal Diagnostics

Run these commands in terminal to inspect application packaging, signing authority, and running processes:

1. **Verify Info.plist Bundle Identifier**:
   Ensure the bundle ID is exactly `com.langcheng.Hireva`:
   ```bash
   defaults read "$(pwd)/dist/Hireva.app/Contents/Info.plist" CFBundleIdentifier
   ```

2. **Verify Code Signature & Entitlements**:
   Check if the app bundle is signed properly:
   ```bash
   codesign -dvvvv dist/Hireva.app
   ```

3. **Verify Designated Requirement**:
   ```bash
   codesign -d -r- dist/Hireva.app
   ```

4. **Check Running Instances and Process Paths**:
   Ensure only the signed bundle is running, and no raw binaries are active:
   ```bash
   ps aux | grep -E "Hireva|Contents/MacOS" | grep -v grep
   ```

5. **Reset TCC Permissions**:
   ```bash
   tccutil reset Microphone com.langcheng.Hireva && \
   tccutil reset ScreenCapture com.langcheng.Hireva && \
   tccutil reset SpeechRecognition com.langcheng.Hireva
   ```
