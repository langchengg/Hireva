# Interview Copilot Mac

A native macOS SwiftUI application that acts as an interview copilot with real-time audio transcription and automated suggestion generation.

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

- **Bundle Identifier**: `com.langcheng.InterviewCopilotMac` (set in `build_and_run.sh`, never change without resetting TCC)
- **Bundle Path**: Always `dist/InterviewCopilotMac.app` (stable across rebuilds)
- **Signing**: The build script automatically signs the .app bundle (Apple Development certificate if available, ad-hoc fallback otherwise)

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
2. Enable **Interview Copilot**
3. **Quit** the app completely
4. Reopen from the same .app bundle path

The app's Audio Diagnostics screen shows a banner with a **"Quit App Now"** button when this permission is missing.

### Resetting Stuck Permissions

If permissions become stuck during development (e.g. after changing bundle ID or signing identity), reset the TCC database:

```bash
# Option 1: Use the build script
./script/build_and_run.sh --reset-tcc

# Option 2: Manual reset
tccutil reset Microphone com.langcheng.InterviewCopilotMac
tccutil reset SpeechRecognition com.langcheng.InterviewCopilotMac
tccutil reset ScreenCapture com.langcheng.InterviewCopilotMac
```

Then rebuild, launch the same .app bundle path, and grant permissions again.

### Verifying Permission Persistence

1. Launch app from `dist/InterviewCopilotMac.app`
2. Grant microphone permission
3. Quit app
4. Reopen same app bundle → microphone permission should remain granted
5. Grant Screen & System Audio Recording in System Settings
6. Quit and reopen → `CGPreflightScreenCaptureAccess()` should return true
7. Rebuild (`./script/build_and_run.sh`) → permissions should persist

### Developer Terminal Diagnostics

Run these commands in terminal to inspect application packaging, signing authority, and running processes:

1. **Verify Info.plist Bundle Identifier**:
   Ensure the bundle ID is exactly `com.langcheng.InterviewCopilotMac`:
   ```bash
   defaults read "$(pwd)/dist/InterviewCopilotMac.app/Contents/Info.plist" CFBundleIdentifier
   ```

2. **Verify Code Signature & Entitlements**:
   Check if the app bundle is signed properly:
   ```bash
   codesign -dvvvv dist/InterviewCopilotMac.app
   ```

3. **Verify Designated Requirement**:
   ```bash
   codesign -d -r- dist/InterviewCopilotMac.app
   ```

4. **Check Running Instances and Process Paths**:
   Ensure only the signed bundle is running, and no raw binaries are active:
   ```bash
   ps aux | grep -E "InterviewCopilotMac|Contents/MacOS" | grep -v grep
   ```

5. **Reset TCC Permissions**:
   ```bash
   tccutil reset Microphone com.langcheng.InterviewCopilotMac && \
   tccutil reset ScreenCapture com.langcheng.InterviewCopilotMac && \
   tccutil reset SpeechRecognition com.langcheng.InterviewCopilotMac
   ```
