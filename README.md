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
